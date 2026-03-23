import { expect } from "chai";
import { ethers } from "hardhat";

import {
  DEFAULT_MARKET_CONFIG,
  FORTUNE_MARKET_HOOK_FLAGS,
  HOOK_FLAGS_MASK,
  calculateUnboundedTickBounds,
  getNetworkConstants,
} from "../lib/marketConstants";

function computeCreate2Address(deployer: string, salt: string, initCodeHash: string): string {
  const data = ethers.concat(["0xff", deployer, salt, initCodeHash]);
  return ethers.getAddress("0x" + ethers.keccak256(data).slice(-40));
}

async function deployHookOnFork() {
  const [owner] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const networkConstants = getNetworkConstants(chainId);

  expect(
    await ethers.provider.getCode(networkConstants.POOL_MANAGER),
    "PoolManager missing on fork"
  ).to.not.equal("0x");

  const Create2Deployer = await ethers.getContractFactory("Create2Deployer");
  const create2Deployer = await Create2Deployer.deploy();
  await create2Deployer.waitForDeployment();
  const create2DeployerAddress = await create2Deployer.getAddress();

  const FortuneMarketHook = await ethers.getContractFactory("FortuneMarketHook");
  const constructorArgs = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address"],
    [networkConstants.POOL_MANAGER, owner.address]
  );
  const initCode = ethers.concat([FortuneMarketHook.bytecode, constructorArgs]);
  const initCodeHash = ethers.keccak256(initCode);

  const requiredFlags = BigInt(FORTUNE_MARKET_HOOK_FLAGS);
  const flagMask = BigInt(HOOK_FLAGS_MASK);

  let salt = 0n;
  let saltBytes = "";
  let hookAddress = "";

  for (let i = 0; i < 1_000_000; i++) {
    saltBytes = ethers.zeroPadValue(ethers.toBeHex(salt), 32);
    hookAddress = computeCreate2Address(create2DeployerAddress, saltBytes, initCodeHash);
    if ((BigInt(hookAddress) & flagMask) === requiredFlags) {
      break;
    }
    salt += 1n;
  }

  if ((BigInt(hookAddress) & flagMask) !== requiredFlags) {
    throw new Error("Failed to mine a valid hook salt");
  }

  await (await create2Deployer.deploy(saltBytes, ethers.hexlify(initCode))).wait();

  return {
    owner,
    networkConstants,
    hook: await ethers.getContractAt("FortuneMarketHook", hookAddress),
  };
}

describe("fork market lifecycle", function () {
  this.timeout(180_000);

  it("deploys the hook and factory, creates a market, and resolves it on a Base fork", async function () {
    const { owner, networkConstants, hook } = await deployHookOnFork();

    const FortuneMarketFactory = await ethers.getContractFactory("FortuneMarketFactory");
    const factory = await FortuneMarketFactory.deploy(
      networkConstants.POOL_MANAGER,
      networkConstants.USDC,
      await hook.getAddress(),
      owner.address
    );
    await factory.waitForDeployment();

    await (await hook.setFactory(await factory.getAddress())).wait();

    const tickBounds = calculateUnboundedTickBounds(
      DEFAULT_MARKET_CONFIG.FLOOR_PRICE_USD,
      DEFAULT_MARKET_CONFIG.TICK_SPACING
    );

    const tx = await factory.createMarket(
      DEFAULT_MARKET_CONFIG.LP_FEE_PPM,
      DEFAULT_MARKET_CONFIG.TICK_SPACING,
      DEFAULT_MARKET_CONFIG.TOKEN_SUPPLY_EACH,
      {
        lower: tickBounds.token0Ticks.lower,
        upper: tickBounds.token0Ticks.upper,
      },
      {
        lower: tickBounds.token1Ticks.lower,
        upper: tickBounds.token1Ticks.upper,
      },
      owner.address,
      "Will Fortune Market pass the Base fork lifecycle test?",
      "This market is created by the integration test and resolved by the owner."
    );
    const receipt = await tx.wait();

    const marketCreatedLog = receipt?.logs.find((log: any) => {
      try {
        return factory.interface.parseLog(log)?.name === "MarketCreated";
      } catch {
        return false;
      }
    });

    expect(marketCreatedLog, "missing MarketCreated event").to.exist;

    const parsed = factory.interface.parseLog(marketCreatedLog!);
    const market = await ethers.getContractAt("FortuneMarket", parsed!.args.market);

    expect(await market.factory()).to.equal(await factory.getAddress());
    expect(await market.resolver()).to.equal(owner.address);
    expect(await market.marketQuestion()).to.equal("Will Fortune Market pass the Base fork lifecycle test?");
    expect(await market.marketNotes()).to.equal(
      "This market is created by the integration test and resolved by the owner."
    );
    expect(await market.state()).to.equal(1n);

    const yesPolicy = await hook.policy(await market.yesKeyHash());
    const noPolicy = await hook.policy(await market.noKeyHash());

    expect(yesPolicy.market).to.equal(await market.getAddress());
    expect(noPolicy.market).to.equal(await market.getAddress());
    expect(yesPolicy.initialized).to.equal(true);
    expect(noPolicy.initialized).to.equal(true);
    expect(yesPolicy.closed).to.equal(false);
    expect(noPolicy.closed).to.equal(false);

    await (await market.resolve(true)).wait();

    expect(await market.outcomeYes()).to.equal(true);
    expect(await market.prizePoolUSDC()).to.equal(0n);
    expect(await market.remainingPrizePoolUSDC()).to.equal(0n);
    expect(await market.state()).to.equal(3n);

    const yesClosedPolicy = await hook.policy(await market.yesKeyHash());
    const noClosedPolicy = await hook.policy(await market.noKeyHash());

    expect(yesClosedPolicy.closed).to.equal(true);
    expect(noClosedPolicy.closed).to.equal(true);
  });
});
