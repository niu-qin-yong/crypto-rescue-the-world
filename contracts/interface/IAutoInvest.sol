//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAutoInvest {
    event InitBuyLimit(address indexed investor,uint256 buyAmountMin,uint256 buyAmountMax);
    event InitSellLimit(address indexed investor,uint256 sellPercentMin,uint256 sellPercentMax);
    event Buy(address indexed investor,uint256 indexed uAmount);
    event Sell(address indexed investor,uint256 btcSellAmount,uint256 ethSellAmount);
    event ClaimServiceFee(address indexed owner,uint256 indexed feeAmount);

    function initBuyLimit(uint256 _buyAmountMin,uint256 _buyAmountMax) external;
    function initSellLimit(uint8 _sellPercentMin,uint8 _sellPercentMax) external;
    function buy(address stableCoin,uint256 stableCoinAmount,address wbtcAddress,address wethAddress) external;
    function sell(address wbtcAddress,uint256 wbtcAmountToSell,address wethAddress,uint256 wethAmountToSell,address stableCoin) external;
    function claimServiceFee(IERC20 stableCoin) external;
}