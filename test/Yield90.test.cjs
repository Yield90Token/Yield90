const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Yield90 Core Tests", function () {
  let Yield90, yield90, owner, multisig, user;
  
  beforeEach(async function () {
    [owner, multisig, user] = await ethers.getSigners();
    
    const Y = await ethers.getContractFactory("Yield90");
    yield90 = await Y.deploy(multisig.address);
    await yield90.waitForDeployment();
  });

  describe("Constructor & Supply", function () {
    it("mints expected amounts", async function () {
      const total = await yield90.totalSupply();
      const rewardsPool = await yield90.REWARDS_POOL();
      const initialLp = await yield90.INITIAL_LP_ALLOC();
      const projectFund = await yield90.PROJECT_FUND();
      const cex = await yield90.CEX_RESERVE_ALLOC();
      
      const totalNum = Number(total);
      const sum = Number(rewardsPool) + Number(initialLp) + Number(projectFund) + Number(cex);
      
      expect(totalNum).to.equal(sum);
    });

    it("reports circulatingSupply consistent with doc", async function () {
      const circ = await yield90.circulatingSupply();
      const t = await yield90.totalSupply();
      const balContract = await yield90.balanceOf(yield90.target);
      const balOwner = await yield90.balanceOf(await yield90.owner());
      
      const expectedCirc = t - balContract - balOwner;
      expect(circ).to.equal(expectedCirc);
    });
  });

  describe("Basic Functionality", function () {
    it("has correct initial state", async function () {
      const ownerAddress = await yield90.owner();
      expect(ownerAddress).to.equal(multisig.address);
      
      const totalSupply = await yield90.totalSupply();
      expect(totalSupply).to.be.gt(0);
      
      const initialLpRemaining = await yield90.initialLpRemaining();
      const cexReserveRemaining = await yield90.cexReserveRemaining();
      expect(initialLpRemaining).to.equal(ethers.parseEther("800000000"));
      expect(cexReserveRemaining).to.equal(ethers.parseEther("1200000000"));
    });

    it("allows owner to add pools", async function () {
      const TestToken = await ethers.getContractFactory("TestToken");
      const testToken = await TestToken.deploy();
      await testToken.waitForDeployment();

      await expect(yield90.connect(multisig).addPool(testToken.target))
        .to.not.be.reverted;
    });

    it("has proper access control for admin functions", async function () {
      const TestToken = await ethers.getContractFactory("TestToken");
      const testToken = await TestToken.deploy();
      await testToken.waitForDeployment();

      await expect(yield90.connect(user).addPool(testToken.target))
        .to.be.reverted;

      await expect(yield90.connect(multisig).addPool(testToken.target))
        .to.not.be.reverted;
    });

    it("allows basic staking in pool 0 (Y90 tokens)", async function () {
      const stakeAmount = ethers.parseEther("1000");
      
      await yield90.connect(multisig).transfer(user.address, stakeAmount);
      await yield90.connect(user).approve(yield90.target, stakeAmount);
      await yield90.connect(user).stakeFor(0, stakeAmount);

      const userInfo = await yield90.userInfo(0, user.address);
      expect(userInfo.amount).to.equal(stakeAmount);
      
      const poolInfo = await yield90.poolInfo(0);
      expect(poolInfo.totalStaked).to.equal(stakeAmount);
    });

    it("shows pending rewards for staked users", async function () {
      const stakeAmount = ethers.parseEther("1000");
      
      await yield90.connect(multisig).transfer(user.address, stakeAmount);
      await yield90.connect(user).approve(yield90.target, stakeAmount);
      await yield90.connect(user).stakeFor(0, stakeAmount);

      const pending = await yield90.pendingRewards(0, user.address);
      expect(pending).to.not.be.undefined;
    });
  });

  describe("Constants Verification", function () {
    it("has correct constant values", async function () {
      expect(await yield90.APY()).to.equal(90);
      expect(await yield90.TOTAL_SUPPLY()).to.equal(ethers.parseEther("10000000000"));
      expect(await yield90.REWARDS_POOL()).to.equal(ethers.parseEther("7000000000"));
      expect(await yield90.PROJECT_FUND()).to.equal(ethers.parseEther("1000000000"));
      expect(await yield90.DEX_CEX_LISTING()).to.equal(ethers.parseEther("2000000000"));
      expect(await yield90.INITIAL_LP_ALLOC()).to.equal(ethers.parseEther("800000000"));
      expect(await yield90.CEX_RESERVE_ALLOC()).to.equal(ethers.parseEther("1200000000"));
    });
  });
});

describe("Yield90 + Y90NFT Integration Tests", function () {
  let Yield90, Y90NFT, yield90, y90nft, owner, multisig, user;
  
  beforeEach(async function () {
    [owner, multisig, user] = await ethers.getSigners();
    
    const Y90 = await ethers.getContractFactory("Yield90");
    yield90 = await Y90.deploy(multisig.address);
    await yield90.waitForDeployment();
    
    const NFT = await ethers.getContractFactory("Y90NFT");
    y90nft = await NFT.deploy(yield90.target, multisig.address);
    await y90nft.waitForDeployment();
    
    await yield90.connect(multisig).setY90NFT(y90nft.target);
  });

  it("should allow setting Y90NFT address", async function () {
    const nftAddress = await yield90.y90NFT();
    expect(nftAddress).to.equal(y90nft.target);
  });

  it("should handle NFT burn integration", async function () {
    await y90nft.connect(multisig).mintNFT(user.address, "test_uri", 10);
    
    const initialLpBefore = await yield90.initialLpRemaining();
    const totalBurntBefore = await yield90.totalBurntFromCirculating();
    
    await y90nft.connect(user).useBurnNFT(1);
    
    const initialLpAfter = await yield90.initialLpRemaining();
    const totalBurntAfter = await yield90.totalBurntFromCirculating();
    
    expect(totalBurntAfter).to.be.gt(totalBurntBefore);
    expect(initialLpAfter).to.be.lt(initialLpBefore);
  });

  it("should track burn capacity correctly", async function () {
    const burnCapacity = await yield90.getRemainingBurnCapacity();
    const circulatingBurnLimit = await yield90.getCirculatingBurnLimit();
    
    expect(burnCapacity).to.be.lte(circulatingBurnLimit);
  });
});

describe("Yield90 Edge Cases", function () {
  let Yield90, yield90, owner, multisig, user;
  
  beforeEach(async function () {
    [owner, multisig, user] = await ethers.getSigners();
    
    const Y = await ethers.getContractFactory("Yield90");
    yield90 = await Y.deploy(multisig.address);
    await yield90.waitForDeployment();
  });

  it("should handle zero amount transfers", async function () {
    await expect(yield90.connect(multisig).transfer(user.address, 0))
      .to.not.be.reverted;
  });

  it("should revert when staking zero amount", async function () {
    await expect(yield90.connect(user).stakeFor(0, 0))
      .to.be.revertedWith("Zero amount");
  });

  it("should revert when staking in invalid pool", async function () {
    const stakeAmount = ethers.parseEther("1000");
    await yield90.connect(multisig).transfer(user.address, stakeAmount);
    await yield90.connect(user).approve(yield90.target, stakeAmount);
    
    await expect(yield90.connect(user).stakeFor(999, stakeAmount))
      .to.be.revertedWith("Invalid pool");
  });
});