//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
pragma abicoder v2;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import "./library/LowGasSafeMath.sol";
import "./interface/IAutoInvest.sol";

contract AutoInvest is IAutoInvest, Ownable{
    using LowGasSafeMath for uint256;

    ISwapRouter public immutable swapRouter;
    uint256 public immutable buyStartTime;
    uint256 public immutable buyEndTime;
    uint256 public immutable waitingPeriod;
    uint256 public immutable minBuyInterval;
    uint256 public immutable maxBuyInterval;
    uint256 public immutable minSellInterval;
    uint256 public immutable maxSellInterval;
    uint256 public constant poolFee = 3000;

    mapping(address => Portfolio) public accountInfos;

    struct Portfolio{
        uint256 wbtcBalance;
        uint256 wethBalance;
        //buy limit以稳定币计,以“wei”为单位,ERC20代币的位数和ether的一样都是18位,所以最小单位和wei一样
        uint256 buyAmountMin;
        uint256 buyAmountMax;
        //sell limit以资产(本币)计,同样以“wei”为单位
        uint256 sellBTCMin;
        uint256 sellBTCMax;
        uint256 sellETHMin;
        uint256 sellETHMax;
        uint256 lastBuyTime;
        uint256 lastSellTime;
        // 投入总额,要求必须是稳定币
        uint256 cost;
        // 投资人盈利部分的 1% 作为合约发布方的分成,定投定抛没有按规定执行的每次增加 0.1% 的分成比例
        // serviceFee的初始值为10,定投定抛违约该值增加,增加值=违约时长/最大买入或卖出时间间隔
        // 分成=(盈利/1000)*serviceFee
        uint256 serviceFee; 
    }

    //kovan测试网上的一个ISwapRouter实例: 0xE592427A0AEce92De3Edee1F18E0157C05861564
    constructor(
        ISwapRouter _swapRouter,uint256 _buyStartTime
        ,uint256 _waitingPeriod,uint256 _buyEndTime
        ,uint256 _minBuyInterval,uint256 _maxBuyInterval
        ,uint256 _minSellInterval,uint256 _maxSellInterval) {
        swapRouter = _swapRouter;
        buyStartTime = _buyStartTime;
        buyEndTime = _buyEndTime;
        waitingPeriod = _waitingPeriod;
        minBuyInterval = _minBuyInterval;
        maxBuyInterval = _maxBuyInterval;
        minSellInterval = _minSellInterval;
        maxSellInterval = _maxSellInterval;
    }

    /*
    * 初始化买入金额限制,可多次调用,用于可投资金发生变化时,同时设置基础fee为10
    */
    function initBuyLimit(uint256 _buyAmountMin,uint256 _buyAmountMax) override external {
        //要求最少1u
        require(_buyAmountMin >= 1e18,"buy at least 1u once");
        require(_buyAmountMax > _buyAmountMin,"the max buy limit should be larger than min");

        accountInfos[msg.sender].buyAmountMin = _buyAmountMin;
        accountInfos[msg.sender].buyAmountMax = _buyAmountMax;
        accountInfos[msg.sender].serviceFee = 10;

        emit InitBuyLimit(msg.sender,_buyAmountMin,_buyAmountMax);
    }

    /*
    * 初始化卖出金额限制,入参传递的是卖出的最低和最高比例值,比如1%就传1
    */
    function initSellLimit(uint8 _sellPercentMin,uint8 _sellPercentMax) override external {
        //要求定投结束后再设置sell limit,因为此时账户资产数量是明确的,有利于确定合理的卖出份额
        require(block.timestamp > buyEndTime,"initialize the sell limit after buying end");
        //要求最低卖出比例不低于总资产的1%,最高不高于5%
        require(_sellPercentMin >= 1 && _sellPercentMax <= 5 && _sellPercentMin < _sellPercentMax
            ,"sell percent exceeds the allowed range");
        
        accountInfos[msg.sender].sellBTCMin = accountInfos[msg.sender].wbtcBalance / 100 * _sellPercentMin;
        accountInfos[msg.sender].sellBTCMax = accountInfos[msg.sender].wbtcBalance / 100 * _sellPercentMax;
        accountInfos[msg.sender].sellETHMin = accountInfos[msg.sender].wethBalance / 100 * _sellPercentMin;
        accountInfos[msg.sender].sellETHMax = accountInfos[msg.sender].wethBalance / 100 * _sellPercentMax;

        emit InitSellLimit(msg.sender,_sellPercentMin,_sellPercentMax);
    }

    /*
    * 调用buy前,用于购买的稳定币要先授权给本合约
    */
    function buy(address stableCoin,uint256 stableCoinAmount,address wbtcAddress,address wethAddress) override external {
        require(block.timestamp >= buyStartTime,"it doesn't start to invest yet");
        require(block.timestamp <= buyEndTime,"it has stopped investing, waiting for the harvest patiently");
        uint256 minToBuy = accountInfos[msg.sender].buyAmountMin;
        uint256 maxToBuy = accountInfos[msg.sender].buyAmountMax;
        require(minToBuy > 0,"initialize the minimum and maximum amount to buy first");
        require(stableCoinAmount >= minToBuy && stableCoinAmount <= maxToBuy,"the amount to buy exceeds the allowed range");
        require(block.timestamp >= (accountInfos[msg.sender].lastBuyTime + minBuyInterval),"not time to buy yet,be patience!");
        
        //超过最长间隔,定投违约,超过1个maxBuyInterval,serviceFee加1,以此类推
        uint256 lastBuyTime = accountInfos[msg.sender].lastBuyTime;
        if(lastBuyTime == 0){
            accountInfos[msg.sender].serviceFee += (block.timestamp - buyStartTime) / maxBuyInterval;
        }else if((block.timestamp - lastBuyTime) > maxBuyInterval){
            accountInfos[msg.sender].serviceFee += (block.timestamp - lastBuyTime) / maxBuyInterval;
        }

        accountInfos[msg.sender].lastBuyTime = block.timestamp;
        accountInfos[msg.sender].cost += stableCoinAmount;
    
        //投入比例 BTC:ETH=2:3
        uint256 btcToBuyWithU = stableCoinAmount / 5 * 2;
        uint256 ethToBuyWithU = stableCoinAmount - btcToBuyWithU;
        uint256 wbtcReceived = swapExactInputSingle(true,stableCoin,btcToBuyWithU,wbtcAddress);
        accountInfos[msg.sender].wbtcBalance += wbtcReceived;
        uint256 wethReceived = swapExactInputSingle(true,stableCoin,ethToBuyWithU,wethAddress);
        accountInfos[msg.sender].wethBalance += wethReceived;

        emit Buy(msg.sender,stableCoinAmount);
    }

    function sell(address wbtcAddress,uint256 wbtcAmountToSell,address wethAddress,uint256 wethAmountToSell,address stableCoin) override external {
        //检查时间
        require(block.timestamp >= (buyEndTime + waitingPeriod),"it's still in the waiting period,be patient!");
        uint256 lastSellTime = accountInfos[msg.sender].lastSellTime;
        require(block.timestamp >= (lastSellTime + minSellInterval),"not time to sell again yet");
        //检查是否设置过sell limit
        uint256 sellBTCMin = accountInfos[msg.sender].sellBTCMin;
        uint256 sellETHMin = accountInfos[msg.sender].sellETHMin;
        require(sellBTCMin > 0 && sellETHMin > 0,"initialize the minimum and maximum amount to sell first");
        //检查余额
        uint256 wbtcBalance = accountInfos[msg.sender].wbtcBalance;
        uint256 wethBalance = accountInfos[msg.sender].wethBalance;
        require(wbtcBalance > 0 && wbtcBalance >= wbtcAmountToSell,"insufficient btc balance");
        require(wethBalance > 0 && wethBalance >= wethAmountToSell,"insufficient eth balance");
        //卖出数量是否合规,如果余额小于sell min limit就不再限制卖出数量
        if(wbtcBalance > sellBTCMin){
            require(wbtcAmountToSell >= sellBTCMin &&
                wbtcAmountToSell <= accountInfos[msg.sender].sellBTCMax,"the BTC sell amount exceeds the allowed range");
        }
        if(wethBalance > sellETHMin){
            require(wethAmountToSell >= sellETHMin && 
                wethAmountToSell <= accountInfos[msg.sender].sellETHMax,"the ETH sell amount exceeds the allowed range");
        }
       
        //超过最长间隔,定抛违约,超过1个maxSellInterval,serviceFee加1,以此类推
        if(lastSellTime == 0){
            uint256 sellStartTime = buyEndTime + waitingPeriod;
            accountInfos[msg.sender].serviceFee += (block.timestamp - sellStartTime) / maxSellInterval;
        }else if(block.timestamp - lastSellTime > maxSellInterval){
            accountInfos[msg.sender].serviceFee += (block.timestamp - lastSellTime) / maxSellInterval;
        }

        //更新投资人账户信息
        accountInfos[msg.sender].wbtcBalance -= wbtcAmountToSell;
        accountInfos[msg.sender].wethBalance -= wethAmountToSell;
        accountInfos[msg.sender].lastSellTime = block.timestamp;

        //将资产swap成stable coin
        uint256 stableCoinReceived = swapExactInputSingle(false,wbtcAddress,wbtcAmountToSell,stableCoin);
        stableCoinReceived += swapExactInputSingle(false,wethAddress,wethAmountToSell,stableCoin);

        //将减去fee后的卖出额转给投资人 6246-6218
        uint256 fee = caculateFeeAndUpdateCost(stableCoinReceived);
        IERC20(stableCoin).transfer(msg.sender,(stableCoinReceived - fee));

        emit Sell(msg.sender,wbtcAmountToSell,wethAmountToSell);
    }

    function caculateFeeAndUpdateCost(uint256 sold) private returns(uint256 fee) {
        fee = 0;
        //每个sload操作要花费200gas,所以取出来存到memory变量中
        uint256 cost = accountInfos[msg.sender].cost;
        if(cost == 0){
            //已收回成本,对卖出额 sold 按 serviceFee 收取分成
            fee = sold / 1000 * accountInfos[msg.sender].serviceFee;
        }else{
            try this.genNewCost(cost,sold) returns (uint256 retval) {
                //投资人成本未全部收回,更新成本,不分成
                accountInfos[msg.sender].cost = retval;
            }catch{
                // genNewCost()发生revert,说明最新卖出额sold已大于剩余成本
                uint256 profit = sold.sub(cost);
                //对盈利提取分成
                fee = profit / 1000 * accountInfos[msg.sender].serviceFee;
                //将cost置0,以后的卖出额即全部是利润
                accountInfos[msg.sender].cost = 0;
            }
        }
    }

    function genNewCost(uint256 cost,uint256 sold) public pure returns(uint256){
        return cost.sub(sold);
    }

    function swapExactInputSingle(bool doBuy,address _tokenIn,uint256 _amountIn,address _tokenOut) private returns (uint256 amountOut) {

        // 将指定数量的资产(稳定币)转到当前合约
        if(doBuy){
            TransferHelper.safeTransferFrom(_tokenIn, msg.sender, address(this), _amountIn);
        }

        // 将资产授权给 swapRouter
        TransferHelper.safeApprove(_tokenIn, address(swapRouter), _amountIn);

        // amountOutMinimum 在生产环境下应该使用 oracle 或者其他数据来源获取其值
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        amountOut = swapRouter.exactInputSingle(params);
    } 

    function claimServiceFee(IERC20 stableCoin) external override onlyOwner {
        //调用buy函数或者sell函数,调用者的稳定币都不会留在合约内,要么将swap后的币转给调用者
        //要么将sell后的稳定币转给调用者,合约内留下的稳定币只有应得的fee
        uint256 amount = stableCoin.balanceOf(address(this));
        stableCoin.transfer(msg.sender, amount);

        emit ClaimServiceFee(msg.sender,amount);
    }
}
