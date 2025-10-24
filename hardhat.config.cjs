const { resolve } = require("path");
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-ethers");
require("dotenv").config();
require("hardhat-abi-exporter");
require("@nomicfoundation/hardhat-verify");
require("@nomicfoundation/hardhat-ignition-ethers");
require("@nomicfoundation/hardhat-network-helpers");


module.exports = {
  solidity: {
    version: "0.8.22",
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 200 }
    }
  },

  abiExporter: {
    path: './abis',
    runOnCompile: true,
    clear: true
  },

  gasReporter: {
    enabled: true,
    currency: 'USD',
    gasPrice: 21
  },

  paths: {
    sources: resolve(__dirname, "contracts"),
    tests: resolve(__dirname, "test"),
    cache: resolve(__dirname, "cache"),
    artifacts: resolve(__dirname, "artifacts")
  },
   networks: {
    arbitrum: {
      url: process.env.ARBITRUM_RPC_URL || "https://arb1.arbitrum.io/rpc",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 42161,
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  mocha: {
    timeout: 40000
  }
};
