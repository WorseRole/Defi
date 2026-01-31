// scripts/deploy-mock.js
const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 开始在本地网络部署 ERC20Mock 合约...");
  
  // 获取部署者账户（Hardhat 会自动提供20个测试账户）
  const [deployer, user1, user2] = await ethers.getSigners();
  console.log("👤 部署者地址:", deployer.address);
  console.log("👤 用户1地址:", user1.address);
  console.log("👤 用户2地址:", user2.address);
  
  // 部署 ERC20Mock 合约
  console.log("\n📦 部署 ERC20Mock 合约...");
  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  
  // 部署参数：名称、符号、初始接收者、初始数量
  const tokenName = "Mock Token";
  const tokenSymbol = "MOCK";
  const initialAccount = deployer.address;
  const initialBalance = ethers.utils.parseEther("1000000"); // 100万代币
  
  const mockToken = await ERC20Mock.deploy(
    tokenName,
    tokenSymbol,
    initialAccount,
    initialBalance
  );
  
  await mockToken.deployed();
  console.log("✅ ERC20Mock 合约部署地址:", mockToken.address);
  
  // 验证初始代币分配
  const deployerBalance = await mockToken.balanceOf(deployer.address);
  console.log(`💰 部署者余额: ${ethers.utils.formatEther(deployerBalance)} ${tokenSymbol}`);
  
  // 测试 mint 功能
  console.log("\n🔄 测试 mint 功能...");
  const mintAmount = ethers.utils.parseEther("500");
  await mockToken.connect(deployer).mint(user1.address, mintAmount);
  
  const user1Balance = await mockToken.balanceOf(user1.address);
  console.log(`💰 用户1余额: ${ethers.utils.formatEther(user1Balance)} ${tokenSymbol}`);
  
  // 测试转账功能
  console.log("\n🔄 测试转账功能...");
  const transferAmount = ethers.utils.parseEther("100");
  await mockToken.connect(user1).transfer(user2.address, transferAmount);
  
  const user2Balance = await mockToken.balanceOf(user2.address);
  console.log(`💰 用户2余额: ${ethers.utils.formatEther(user2Balance)} ${tokenSymbol}`);
  
  // 验证转账后余额
  const user1BalanceAfter = await mockToken.balanceOf(user1.address);
  console.log(`💰 用户1转账后余额: ${ethers.utils.formatEther(user1BalanceAfter)} ${tokenSymbol}`);
  
  console.log("\n🎉 ERC20Mock 合约部署和基本功能测试完成！");
  console.log("=========================================");
  console.log("合约地址:", mockToken.address);
  console.log("代币名称:", tokenName);
  console.log("代币符号:", tokenSymbol);
  console.log("初始供应量:", ethers.utils.formatEther(initialBalance), tokenSymbol);
  console.log("=========================================");
  
  return mockToken.address;
}

// 执行部署
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ 部署失败:", error);
    process.exit(1);
  });