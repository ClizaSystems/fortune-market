import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";
const BASE_RPC_URL = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const BASE_SEPOLIA_RPC_URL = process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org";
const ETHERSCAN_API_KEY =
  process.env.ETHERSCAN_API_KEY || process.env.BASESCAN_API_KEY || "";
const ENABLE_FORKING = ["1", "true"].includes((process.env.ENABLE_FORKING || "").toLowerCase());
const BASE_FORK_BLOCK_NUMBER = process.env.BASE_FORK_BLOCK_NUMBER
  ? parseInt(process.env.BASE_FORK_BLOCK_NUMBER, 10)
  : undefined;

const hardhatNetwork = {
  hardfork: "cancun",
  ...(ENABLE_FORKING
    ? {
        forking: {
          url: BASE_RPC_URL,
          ...(BASE_FORK_BLOCK_NUMBER !== undefined
            ? { blockNumber: BASE_FORK_BLOCK_NUMBER }
            : {}),
        },
      }
    : {}),
  chainId: 31337,
  chains: {
    8453: {
      hardforkHistory: {
        cancun: 0,
      },
    },
    84532: {
      hardforkHistory: {
        cancun: 0,
      },
    },
  },
};

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1, // Minimize for size
      },
      evmVersion: "cancun",
      viaIR: true,
      debug: {
        revertStrings: "strip", // Remove revert strings to save space
      },
      metadata: {
        bytecodeHash: "none", // Keep the single-contract factory under EIP-170
      },
    },
  },
  paths: {
    sources: "./contracts",
  },
  networks: {
    hardhat: hardhatNetwork,
    base: {
      url: BASE_RPC_URL,
      chainId: 8453,
      accounts: [PRIVATE_KEY],
    },
    baseSepolia: {
      url: BASE_SEPOLIA_RPC_URL,
      chainId: 84532,
      accounts: [PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: ETHERSCAN_API_KEY,
    customChains: [
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
    ],
  },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },
};

export default config;
