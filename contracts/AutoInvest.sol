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

    //uni的swap实例
    ISwapRouter public immutable swapRouter;
    uint256 public constant poolFee = 3000;
    //买入的开始时间,结束时间
    uint256 public immutable buyStartTime;
    uint256 public immutable buyEndTime;
    //买入期结束后的锁定期时长
    uint256 public immutable waitingPeriod;
    //买入的最少,最多时间间隔
    uint256 public immutable minBuyInterval;
    uint256 public immutable maxBuyInterval;
    //卖出的最少,最多时间间隔
    uint256 public immutable minSellInterval;
    uint256 public immutable maxSellInterval;

    //投资人的账户信息
    mapping(address => Portfolio) public accountInfos;

    struct Portfolio{
        //资产余额
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
        //上次购买,卖出时间
        uint256 lastBuyTime;
        uint256 lastSellTime;
        // 投入总额,要求必须是稳定币
        uint256 cost;
        // 投资人盈利部分的 1% 作为合约发布方的分成
        // feeRate的初始值为10,定投定抛违约该值增加,增加值=违约时长/最大买入或卖出时间间隔
        // 分成=(盈利/1000)*feeRate
        uint256 feeRate; 
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
    * 初始化买入金额限制和feeRate
    * 可多次调用,比如当用户可投资金发生变化时
    */
    function initBuyLimitAndFeeRate(uint256 _buyAmountMin,uint256 _buyAmountMax) override external {
        //买入额限制,要求最少1u
        require(_buyAmountMin >= 1e18,"buy at least 1u once");
        require(_buyAmountMax > _buyAmountMin,"the max buy limit should be larger than min");
        accountInfos[msg.sender].buyAmountMin = _buyAmountMin;
        accountInfos[msg.sender].buyAmountMax = _buyAmountMax;

        //未设置过feeRate,初始值置为10
        if(accountInfos[msg.sender].feeRate == 0){
            accountInfos[msg.sender].feeRate = 10;
        }

        emit InitBuyLimitAndFeeRate(msg.sender,_buyAmountMin,_buyAmountMax);
    }

    /*
    * 调用buy前,用于购买的稳定币要先授权给本合约
    */
    function buy(address stableCoin,uint256 stableCoinAmount,address wbtcAddress,address wethAddress) override external {
        //检查时间
        require(block.timestamp >= buyStartTime,"it doesn't start to invest yet");
        require(block.timestamp <= buyEndTime,"it has stopped investing, waiting for the harvest patiently");
        require(block.timestamp >= (accountInfos[msg.sender].lastBuyTime + minBuyInterval),"not time to buy yet,be patience!");
        
        //检查金额
        uint256 minToBuy = accountInfos[msg.sender].buyAmountMin;
        uint256 maxToBuy = accountInfos[msg.sender].buyAmountMax;
        require(minToBuy > 0,"initialize the minimum and maximum amount to buy first");
        require(stableCoinAmount >= minToBuy && stableCoinAmount <= maxToBuy,"the amount to buy exceeds the allowed range");
        
        //超过最长间隔,定投违约,超过1个maxBuyInterval,feeRate加1,以此类推
        uint256 lastBuyTime = accountInfos[msg.sender].lastBuyTime;
        if(lastBuyTime == 0){
            accountInfos[msg.sender].feeRate += (block.timestamp - buyStartTime) / maxBuyInterval;
        }else if((block.timestamp - lastBuyTime) > maxBuyInterval){
            accountInfos[msg.sender].feeRate += (block.timestamp - lastBuyTime) / maxBuyInterval;
        }

        //更新lastBuyTime和cost
        accountInfos[msg.sender].lastBuyTime = block.timestamp;
        accountInfos[msg.sender].cost += stableCoinAmount;
    
        //投入比例 BTC:ETH=2:3,swap并更新余额
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
        
        //检查余额
        uint256 wbtcBalance = accountInfos[msg.sender].wbtcBalance;
        uint256 wethBalance = accountInfos[msg.sender].wethBalance;
        require(wbtcBalance > 0 && wbtcBalance >= wbtcAmountToSell,"insufficient btc balance");
        require(wethBalance > 0 && wethBalance >= wethAmountToSell,"insufficient eth balance");

        //首次卖出前设置卖出限制,要求最低卖出比例不低于总资产的1%,最高不高于5%
        if(accountInfos[msg.sender].sellBTCMin == 0 || accountInfos[msg.sender].sellETHMin == 0){
            accountInfos[msg.sender].sellBTCMin = accountInfos[msg.sender].wbtcBalance / 100 * 1;
            accountInfos[msg.sender].sellBTCMax = accountInfos[msg.sender].wbtcBalance / 100 * 5;
            accountInfos[msg.sender].sellETHMin = accountInfos[msg.sender].wethBalance / 100 * 1;
            accountInfos[msg.sender].sellETHMax = accountInfos[msg.sender].wethBalance / 100 * 5;
        }        
        
        //检查卖出数量是否合规,如果余额小于sell min limit就不再限制卖出数量(否则就永远放在合约中了)
        uint256 sellBTCMin = accountInfos[msg.sender].sellBTCMin;
        uint256 sellETHMin = accountInfos[msg.sender].sellETHMin;
        if(wbtcBalance > sellBTCMin){
            require(wbtcAmountToSell >= sellBTCMin &&
                wbtcAmountToSell <= accountInfos[msg.sender].sellBTCMax,"the BTC sell amount exceeds the allowed range");
        }
        if(wethBalance > sellETHMin){
            require(wethAmountToSell >= sellETHMin && 
                wethAmountToSell <= accountInfos[msg.sender].sellETHMax,"the ETH sell amount exceeds the allowed range");
        }
       
        //超过最长间隔,定抛违约,超过1个maxSellInterval,feeRate加1,以此类推
        if(lastSellTime == 0){
            uint256 sellStartTime = buyEndTime + waitingPeriod;
            accountInfos[msg.sender].feeRate += (block.timestamp - sellStartTime) / maxSellInterval;
        }else if(block.timestamp - lastSellTime > maxSellInterval){
            accountInfos[msg.sender].feeRate += (block.timestamp - lastSellTime) / maxSellInterval;
        }

        //更新lastSellTime和余额
        accountInfos[msg.sender].lastSellTime = block.timestamp;
        accountInfos[msg.sender].wbtcBalance -= wbtcAmountToSell;
        accountInfos[msg.sender].wethBalance -= wethAmountToSell;

        //将资产swap成stable coin
        uint256 stableCoinReceived = swapExactInputSingle(false,wbtcAddress,wbtcAmountToSell,stableCoin);
        stableCoinReceived += swapExactInputSingle(false,wethAddress,wethAmountToSell,stableCoin);

        //将减去fee后的卖出额转给投资人
        uint256 fee = caculateFeeAndUpdateCost(stableCoinReceived);
        IERC20(stableCoin).transfer(msg.sender,(stableCoinReceived - fee));

        emit Sell(msg.sender,wbtcAmountToSell,wethAmountToSell);
    }

    function caculateFeeAndUpdateCost(uint256 sold) private returns(uint256 fee) {
        fee = 0;
        //每个sload操作要花费200gas,因多次用到该值所以取出来存到memory变量中
        uint256 cost = accountInfos[msg.sender].cost;
        if(cost == 0){
            //已收回成本,对卖出额 sold 按 feeRate 收取分成
            fee = sold / 1000 * accountInfos[msg.sender].feeRate;
        }else{
            try this.calculateCost(cost,sold) returns (uint256 retval) {
                //投资人成本未全部收回,更新成本,不分成
                accountInfos[msg.sender].cost = retval;
            }catch{
                // calculateCost()发生revert,说明最新卖出额sold已大于剩余成本
                uint256 profit = sold.sub(cost);
                //对盈利提取分成
                fee = profit / 1000 * accountInfos[msg.sender].feeRate;
                //将cost置0,以后的卖出额即全部是利润
                accountInfos[msg.sender].cost = 0;
            }
        }
    }

    function calculateCost(uint256 cost,uint256 sold) public pure returns(uint256){
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

    function claimFee(IERC20 stableCoin) external override onlyOwner {
        //调用buy函数,要么将稳定币swap成btc,eth(会转给调用者),要么交易失败,稳定币还在调用者钱包
        //调用sell函数,要么交易成功将swap的稳定币除去fee后转给调用者,要么交易失败,调用者资产余额不变
        //合约地址下的稳定币只有fee,因此可以将余额全部发送给owner,不会影响客户资产安全
        uint256 amount = stableCoin.balanceOf(address(this));
        stableCoin.transfer(msg.sender, amount);

        emit ClaimFee(msg.sender,amount);
    }
}
