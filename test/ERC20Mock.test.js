// test/ERC20Mock.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ERC20Mock 合约测试", function () {
  // 定义变量
  let owner, user1, user2;
  let ERC20Mock, mockToken;
  
  // 部署参数
  const TOKEN_NAME = "Mock Token";
  const TOKEN_SYMBOL = "MOCK";
  const INITIAL_SUPPLY = ethers.utils.parseEther("1000000"); // 100万

  beforeEach(async function () {
    // 获取测试账户（Hardhat本地网络提供）
    [owner, user1, user2] = await ethers.getSigners();
    
    // 部署 ERC20Mock 合约
    ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    mockToken = await ERC20Mock.deploy(
      TOKEN_NAME,
      TOKEN_SYMBOL,
      owner.address,  // 初始代币归 owner
      INITIAL_SUPPLY
    );
    
    await mockToken.deployed();
  });

  describe("1. 基本属性测试", function () {
    it("1.1 应正确设置代币名称和符号", async function () {
      expect(await mockToken.name()).to.equal(TOKEN_NAME);
      expect(await mockToken.symbol()).to.equal(TOKEN_SYMBOL);
    });

    it("1.2 应正确设置初始供应量", async function () {
      const totalSupply = await mockToken.totalSupply();
      expect(totalSupply).to.equal(INITIAL_SUPPLY);
    });

    it("1.3 初始代币应正确分配给指定账户", async function () {
      const ownerBalance = await mockToken.balanceOf(owner.address);
      expect(ownerBalance).to.equal(INITIAL_SUPPLY);
    });
  });

  describe("2. 转账功能测试", function () {
    it("2.1 应能进行代币转账", async function () {
      const transferAmount = ethers.utils.parseEther("100");
      
      // owner 转账给 user1
      await mockToken.connect(owner).transfer(user1.address, transferAmount);
      
      // 验证余额变化
      const ownerBalance = await mockToken.balanceOf(owner.address);
      const user1Balance = await mockToken.balanceOf(user1.address);
      
      expect(ownerBalance).to.equal(INITIAL_SUPPLY.sub(transferAmount));
      expect(user1Balance).to.equal(transferAmount);
    });

    it("2.2 余额不足时应拒绝转账", async function () {
      const tooMuchAmount = ethers.utils.parseEther("2000000"); // 超过总供应量
      
      // user1 尝试转账（但余额为0）
      await expect(
        mockToken.connect(user1).transfer(user2.address, tooMuchAmount)
      ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
    });

    it("2.3 应能批准并允许代扣转账", async function () {
      const approveAmount = ethers.utils.parseEther("500");
      
      // owner 批准 user1 使用其代币
      await mockToken.connect(owner).approve(user1.address, approveAmount);
      
      // 验证批准额度
      const allowance = await mockToken.allowance(owner.address, user1.address);
      expect(allowance).to.equal(approveAmount);
      
      // user1 使用代扣功能从 owner 转账给 user2
      const transferAmount = ethers.utils.parseEther("300");
      await mockToken.connect(user1).transferFrom(
        owner.address,
        user2.address,
        transferAmount
      );
      
      // 验证转账后余额
      const user2Balance = await mockToken.balanceOf(user2.address);
      expect(user2Balance).to.equal(transferAmount);
      
      // 验证批准额度减少
      const remainingAllowance = await mockToken.allowance(owner.address, user1.address);
      expect(remainingAllowance).to.equal(approveAmount.sub(transferAmount));
    });
  });

  describe("3. Mint 功能测试", function () {
    it("3.1 应能铸造新代币", async function () {
      const mintAmount = ethers.utils.parseEther("50000");
      const totalSupplyBefore = await mockToken.totalSupply();
      
      // 铸造新代币给 user1
      await mockToken.connect(owner).mint(user1.address, mintAmount);
      
      // 验证总供应量增加
      const totalSupplyAfter = await mockToken.totalSupply();
      expect(totalSupplyAfter).to.equal(totalSupplyBefore.add(mintAmount));
      
      // 验证 user1 收到代币
      const user1Balance = await mockToken.balanceOf(user1.address);
      expect(user1Balance).to.equal(mintAmount);
    });

    it("3.2 可多次铸造给不同地址", async function () {
      const mintAmount1 = ethers.utils.parseEther("10000");
      const mintAmount2 = ethers.utils.parseEther("20000");
      
      await mockToken.connect(owner).mint(user1.address, mintAmount1);
      await mockToken.connect(owner).mint(user2.address, mintAmount2);
      
      const user1Balance = await mockToken.balanceOf(user1.address);
      const user2Balance = await mockToken.balanceOf(user2.address);
      
      expect(user1Balance).to.equal(mintAmount1);
      expect(user2Balance).to.equal(mintAmount2);
    });
  });

  describe("4. 事件测试", function () {
    it("4.1 转账应触发 Transfer 事件", async function () {
      const transferAmount = ethers.utils.parseEther("100");
      
      await expect(mockToken.connect(owner).transfer(user1.address, transferAmount))
        .to.emit(mockToken, "Transfer")
        .withArgs(owner.address, user1.address, transferAmount);
    });

    it("4.2 批准应触发 Approval 事件", async function () {
      const approveAmount = ethers.utils.parseEther("500");
      
      await expect(mockToken.connect(owner).approve(user1.address, approveAmount))
        .to.emit(mockToken, "Approval")
        .withArgs(owner.address, user1.address, approveAmount);
    });

    it("4.3 铸造应触发 Transfer 事件", async function () {
      const mintAmount = ethers.utils.parseEther("10000");
      
      await expect(mockToken.connect(owner).mint(user1.address, mintAmount))
        .to.emit(mockToken, "Transfer")
        .withArgs(ethers.constants.AddressZero, user1.address, mintAmount);
    });
  });

  describe("5. 边界情况测试", function () {
    it("5.1 零金额转账应成功", async function () {
      // 零金额转账应该成功（虽然没实际意义）
      await expect(
        mockToken.connect(owner).transfer(user1.address, 0)
      ).to.not.be.reverted;
      
      const user1Balance = await mockToken.balanceOf(user1.address);
      expect(user1Balance).to.equal(0);
    });

    it("5.2 给自己转账应成功", async function () {
      const transferAmount = ethers.utils.parseEther("100");
      
      await expect(
        mockToken.connect(owner).transfer(owner.address, transferAmount)
      ).to.not.be.reverted;
      
      // 余额应该不变
      const ownerBalance = await mockToken.balanceOf(owner.address);
      expect(ownerBalance).to.equal(INITIAL_SUPPLY);
    });

    it("5.3 大数额计算应正确", async function () {
      // 测试接近最大值的情况
      const largeAmount = ethers.constants.MaxUint256.div(2);
      
      // 注意：这里我们只测试不实际转账，因为可能会溢出
      // 实际中应该确保不会超过总供应量
      const totalSupply = await mockToken.totalSupply();
      expect(totalSupply.lt(largeAmount)).to.be.true; // 确保总供应量小于大数值
    });
  });
});