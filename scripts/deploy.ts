import { ethers, network, run } from "hardhat";

import { FORTUNE_MARKET_HOOK_FLAGS, HOOK_FLAGS_MASK, getNetworkConstants } from "../lib/marketConstants";

function computeCreate2Address(deployer: string, salt: string, initCodeHash: string): string {
  const data = ethers.concat(["0xff", deployer, salt, initCodeHash]);
  return ethers.getAddress("0x" + ethers.keccak256(data).slice(-40));
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const etherscanApiKey = process.env.ETHERSCAN_API_KEY || process.env.BASESCAN_API_KEY;
  console.log("Deploying Fortune Market with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  const treasuryAddress = process.env.PROTOCOL_TREASURY;
  if (!treasuryAddress) {
    console.error("ERROR: PROTOCOL_TREASURY not set in environment");
    process.exit(1);
  }

  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const networkConstants = getNetworkConstants(chainId);
  console.log("Network:", network.name, "Chain ID:", chainId);
  console.log("PoolManager:", networkConstants.POOL_MANAGER);
  console.log("USDC:", networkConstants.USDC);
  console.log("Treasury:", treasuryAddress);

  const pmCode = await ethers.provider.getCode(networkConstants.POOL_MANAGER);
  if (pmCode === "0x") {
    console.error("ERROR: PoolManager contract not found at", networkConstants.POOL_MANAGER);
    process.exit(1);
  }

  console.log("\nPreparing hook deployment...");
  const FortuneMarketHook = await ethers.getContractFactory("FortuneMarketHook");
  const constructorArgs = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address"],
    [networkConstants.POOL_MANAGER, deployer.address]
  );
  const initCode = ethers.concat([FortuneMarketHook.bytecode, constructorArgs]);
  const initCodeHash = ethers.keccak256(initCode);

  const Create2Deployer = await ethers.getContractFactory("Create2Deployer");
  const create2Deployer = await Create2Deployer.deploy();
  const create2DeployTx = create2Deployer.deploymentTransaction();

  if (create2DeployTx) {
    await create2DeployTx.wait(2);
  }
  await create2Deployer.waitForDeployment();
  const create2DeployerAddress = await create2Deployer.getAddress();
  console.log("Create2Deployer:", create2DeployerAddress);

  const requiredFlags = BigInt(FORTUNE_MARKET_HOOK_FLAGS);
  const flagMask = BigInt(HOOK_FLAGS_MASK);
  let salt = 0n;
  let hookAddress = "";

  console.log("\nMining hook address...");
  for (let i = 0; i < 100_000_000; i++) {
    const saltBytes = ethers.zeroPadValue(ethers.toBeHex(salt), 32);
    const candidate = computeCreate2Address(create2DeployerAddress, saltBytes, initCodeHash);
    if ((BigInt(candidate) & flagMask) === requiredFlags) {
      hookAddress = candidate;
      console.log(`Found valid salt after ${i + 1} iterations`);
      break;
    }
    salt += 1n;
  }

  if (!hookAddress) {
    console.error("Failed to mine valid hook address");
    process.exit(1);
  }

  const saltBytes = ethers.zeroPadValue(ethers.toBeHex(salt), 32);
  await (await create2Deployer.deploy(saltBytes, ethers.hexlify(initCode), { gasLimit: 5_000_000 })).wait();
  const hook = await ethers.getContractAt("FortuneMarketHook", hookAddress);
  console.log("Hook:", hookAddress);

  console.log("\nDeploying factory...");
  const FortuneMarketFactory = await ethers.getContractFactory("FortuneMarketFactory");
  const factory = await FortuneMarketFactory.deploy(
    networkConstants.POOL_MANAGER,
    networkConstants.USDC,
    hookAddress,
    treasuryAddress
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  const factoryDeployTx = factory.deploymentTransaction();

  await (await hook.setFactory(factoryAddress)).wait();

  console.log("\n=== DEPLOYMENT SUMMARY ===");
  console.log("HOOK_ADDRESS=", hookAddress);
  console.log("FACTORY_ADDRESS=", factoryAddress);
  console.log("Hook factory:", await hook.factory());
  console.log("Factory owner:", await factory.owner());

  if (etherscanApiKey) {
    if (factoryDeployTx) {
      console.log("\nWaiting for 5 confirmations before verification...");
      await factoryDeployTx.wait(5);
    }

    console.log("\nVerifying factory on Basescan...");
    try {
      await run("verify:verify", {
        address: factoryAddress,
        constructorArguments: [
          networkConstants.POOL_MANAGER,
          networkConstants.USDC,
          hookAddress,
          treasuryAddress,
        ],
      });
      console.log("Factory verified successfully");
    } catch (error: any) {
      if (error.message.includes("Already Verified")) {
        console.log("Factory already verified");
      } else if (error.message.includes("does not have bytecode")) {
        console.log("Explorer backend is still indexing the deployment, retrying verification in 15 seconds...");
        await sleep(15_000);
        await run("verify:verify", {
          address: factoryAddress,
          constructorArguments: [
            networkConstants.POOL_MANAGER,
            networkConstants.USDC,
            hookAddress,
            treasuryAddress,
          ],
        });
        console.log("Factory verified successfully");
      } else {
        console.error("Factory verification failed:", error.message);
      }
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
