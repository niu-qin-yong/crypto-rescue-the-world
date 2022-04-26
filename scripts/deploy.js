// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // We get the contract to deploy
  const AutoInvest = await hre.ethers.getContractFactory("AutoInvest");
  
  // kovan测试网上的一个ISwapRouter实例
  const swapRouter = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
  const buyStartTime = "1672502400";//2023-01-1 00:00:00
  const buyEndTime = "1735660800";//2024-12-31 24:00:00
  const waitingPeriod = "15638400";//半年后可以开始卖出,也就是2025-07-01 00:00:00
  const minBuyInterval = "604800";//最小间隔1周
  const maxBuyInterval = "1814400";//最大间隔3周
  const minSellInterval = "604800";//最小间隔1周
  const maxSellInterval = "1209600";//最大间隔2周
  const invest = await AutoInvest.deploy(swapRouter,buyStartTime,buyEndTime,waitingPeriod
      ,minBuyInterval,maxBuyInterval,minSellInterval,maxSellInterval);

  await invest.deployed();

  console.log("AutoInvest deployed to:", invest.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
