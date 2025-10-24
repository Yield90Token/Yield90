const { ethers } = require("hardhat");

//helper to transfer tokens from multisig to users for testing
async function fundUser(yield90, multisig, user, amount) {
  const balance = await yield90.balanceOf(multisig.address);
  if (balance >= amount) {
    await yield90.connect(multisig).transfer(user.address, amount);
  } else {
    //if multisig doesn't have enough, we need to handle this
    //for now, just transfer what's available
    await yield90.connect(multisig).transfer(user.address, balance);
  }
}

module.exports = {
  fundUser
};