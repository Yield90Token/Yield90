const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Y90NFT Basic Tests", function () {
  let Y90NFT, Yield90, y90nft, yield90, owner, multisig, user;
  
  beforeEach(async function () {
    [owner, multisig, user] = await ethers.getSigners();
    
    // Deploy Yield90 first
    const Y90 = await ethers.getContractFactory("Yield90");
    yield90 = await Y90.deploy(owner.address);
    await yield90.waitForDeployment();
    
    // Deploy Y90NFT with owner as the multisig
    const NFT = await ethers.getContractFactory("Y90NFT");
    y90nft = await NFT.deploy(yield90.target, owner.address);
    await y90nft.waitForDeployment();

    // IMPORTANT: Set the Y90NFT address in Yield90 contract
    await yield90.connect(owner).setY90NFT(y90nft.target);
  });

  it("should deploy successfully with correct parameters", async function () {
    const contractOwner = await y90nft.owner();
    expect(contractOwner).to.equal(owner.address);
    
    const yield90Address = await y90nft.yield90();
    expect(yield90Address).to.equal(yield90.target);
  });

  it("should have basic NFT functionality", async function () {
    const name = await y90nft.name();
    const symbol = await y90nft.symbol();
    
    expect(name).to.be.a('string');
    expect(symbol).to.be.a('string');
    expect(name.length).to.be.gt(0);
    expect(symbol.length).to.be.gt(0);
  });

  it("should allow owner to mint NFTs using mintNFT function", async function () {
    // Use the working mintNFT function
    await y90nft.connect(owner).mintNFT(user.address, "test_uri", 10);
    
    // Check NFT was minted
    const balance = await y90nft.balanceOf(user.address);
    expect(balance).to.equal(1);
    
    const ownerOf = await y90nft.ownerOf(1);
    expect(ownerOf).to.equal(user.address);
    
    // Check burn power was set
    const burnPower = await y90nft.burnPower(1);
    expect(burnPower).to.equal(10);
  });

  it("should not allow non-owner to mint NFTs", async function () {
    // Non-owner should not be able to mint
    await expect(y90nft.connect(user).mintNFT(user.address, "test_uri", 10))
      .to.be.reverted;
  });

  it("should track burn records correctly", async function () {
    // Mint an NFT
    await y90nft.connect(owner).mintNFT(user.address, "test_uri", 10);
    
    // Use the NFT to burn
    await y90nft.connect(user).useBurnNFT(1);
    
    // Check burn record was updated
    const burnRecord = await y90nft.burnRecords(user.address);
    expect(burnRecord.totalBurnt).to.be.gt(0);
    expect(burnRecord.burnCount).to.equal(1);
  });
});