import { ethers } from "hardhat";
import { MaxUint256 } from "ethers";

import {
  DEFAULT_MARKET_CONFIG,
  calculateUnboundedTickBounds,
} from "../lib/marketConstants";

const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE =
  1461446703485210103287273052203988822378723970342n;
const CREATE_MARKET_GAS_LIMIT = 7_000_000n;
const SWAP_GAS_LIMIT = 2_000_000n;
const RESOLVE_GAS_LIMIT = 2_000_000n;
const CLAIM_GAS_LIMIT = 1_000_000n;

type PoolKeyStruct = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function retryUntil<T>(
  read: () => Promise<T>,
  isReady: (value: T) => boolean,
  attempts: number = 8,
  delayMs: number = 2_000
): Promise<T> {
  let lastError: unknown;
  let lastValue: T | undefined;

  for (let i = 0; i < attempts; i++) {
    try {
      const value = await read();
      lastValue = value;
      if (isReady(value)) {
        return value;
      }
    } catch (error) {
      lastError = error;
    }

    if (i < attempts - 1) {
      await sleep(delayMs);
    }
  }

  if (lastValue !== undefined) {
    return lastValue;
  }

  throw lastError;
}

function eqAddress(a: string, b: string) {
  return a.toLowerCase() === b.toLowerCase();
}

function buildPoolKey(
  tokenAddress: string,
  usdcAddress: string,
  fee: number,
  tickSpacing: number,
  hooks: string
): PoolKeyStruct {
  const [currency0, currency1] =
    tokenAddress.toLowerCase() < usdcAddress.toLowerCase()
      ? [tokenAddress, usdcAddress]
      : [usdcAddress, tokenAddress];

  return {
    currency0,
    currency1,
    fee,
    tickSpacing,
    hooks,
  };
}

function sqrtPriceLimitForExactInput(key: PoolKeyStruct, inputToken: string): {
  zeroForOne: boolean;
  sqrtPriceLimitX96: bigint;
} {
  if (eqAddress(inputToken, key.currency0)) {
    return { zeroForOne: true, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1n };
  }

  if (eqAddress(inputToken, key.currency1)) {
    return { zeroForOne: false, sqrtPriceLimitX96: MAX_SQRT_PRICE - 1n };
  }

  throw new Error(`Input token ${inputToken} is not part of pool`);
}

async function balanceOf(tokenAddress: string, holder: string) {
  const token = await ethers.getContractAt("ERC20", tokenAddress);
  return token.balanceOf(holder);
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Smoke testing with account:", deployer.address);
  console.log(
    "ETH balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address))
  );

  const factoryAddress = process.env.FACTORY_ADDRESS;
  if (!factoryAddress) {
    throw new Error("FACTORY_ADDRESS not set");
  }

  const factory = await ethers.getContractAt(
    "FortuneMarketFactory",
    factoryAddress
  );
  const usdcAddress = await factory.usdc();
  const usdc = await ethers.getContractAt("ERC20", usdcAddress);
  const usdcDecimals = await usdc.decimals();

  const usdcPerSide = ethers.parseUnits(
    process.env.SMOKE_USDC_PER_SIDE || "0.25",
    usdcDecimals
  );
  const sellBps = BigInt(process.env.SMOKE_SELL_BPS || "5000");
  if (sellBps <= 0n || sellBps > 10_000n) {
    throw new Error("SMOKE_SELL_BPS must be between 1 and 10000");
  }

  const startingUsdc = await usdc.balanceOf(deployer.address);
  console.log("Starting USDC:", ethers.formatUnits(startingUsdc, usdcDecimals));

  if (startingUsdc < usdcPerSide * 2n) {
    throw new Error(
      `Need at least ${ethers.formatUnits(usdcPerSide * 2n, usdcDecimals)} USDC to run the smoke test`
    );
  }

  const routerFactory = await ethers.getContractFactory(
    "FortuneMarketSwapRouter"
  );
  const router = await routerFactory.deploy(await factory.poolManager());
  await router.waitForDeployment();
  console.log("Swap router:", await router.getAddress());

  await (await usdc.approve(await router.getAddress(), MaxUint256)).wait();
  console.log("Approved USDC for router");

  const tickBounds = calculateUnboundedTickBounds(
    DEFAULT_MARKET_CONFIG.FLOOR_PRICE_USD,
    DEFAULT_MARKET_CONFIG.TICK_SPACING
  );
  const resolver = process.env.RESOLVER || deployer.address;
  const marketQuestion =
    process.env.SMOKE_MARKET_QUESTION ||
    "Will this Fortune Market smoke test resolve successfully?";
  const marketNotes =
    process.env.SMOKE_MARKET_NOTES ||
    "Auto-generated smoke test market for end-to-end validation.";

  let marketAddress = process.env.SMOKE_MARKET_ADDRESS;
  let yesTokenAddress: string;
  let noTokenAddress: string;

  if (!marketAddress) {
    console.log("Creating market...");
    const createTx = await factory.createMarket(
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
      resolver,
      marketQuestion,
      marketNotes,
      { gasLimit: CREATE_MARKET_GAS_LIMIT }
    );
    console.log("createMarket tx:", createTx.hash);
    const receipt = await createTx.wait(2);

    const marketCreatedEvent = receipt?.logs.find((log: any) => {
      try {
        return factory.interface.parseLog(log)?.name === "MarketCreated";
      } catch {
        return false;
      }
    });

    if (!marketCreatedEvent) {
      throw new Error("MarketCreated event not found");
    }

    const parsedEvent = factory.interface.parseLog(marketCreatedEvent);
    if (!parsedEvent) {
      throw new Error("Unable to parse MarketCreated event");
    }

    marketAddress = parsedEvent.args.market as string;
    yesTokenAddress = parsedEvent.args.yesToken as string;
    noTokenAddress = parsedEvent.args.noToken as string;
  } else {
    console.log("Reusing market:", marketAddress);
    const market = await ethers.getContractAt("FortuneMarket", marketAddress);
    yesTokenAddress = await market.yesToken();
    noTokenAddress = await market.noToken();
  }

  console.log("Market:", marketAddress);
  console.log("YES token:", yesTokenAddress);
  console.log("NO token:", noTokenAddress);

  const market = await ethers.getContractAt("FortuneMarket", marketAddress);
  const yesToken = await ethers.getContractAt("ERC20", yesTokenAddress);
  const noToken = await ethers.getContractAt("ERC20", noTokenAddress);

  const hookAddress = await market.hook();
  const fee = Number(await market.lpFeePpm());
  const tickSpacing = Number(await market.tickSpacing());
  const yesKey = buildPoolKey(
    yesTokenAddress,
    usdcAddress,
    fee,
    tickSpacing,
    hookAddress
  );
  const noKey = buildPoolKey(
    noTokenAddress,
    usdcAddress,
    fee,
    tickSpacing,
    hookAddress
  );

  const yesBuyConfig = sqrtPriceLimitForExactInput(yesKey, usdcAddress);
  const noBuyConfig = sqrtPriceLimitForExactInput(noKey, usdcAddress);

  console.log("Buying YES with", ethers.formatUnits(usdcPerSide, usdcDecimals), "USDC...");
  const yesBuyTx = await router.swapExactInput(
    yesKey,
    yesBuyConfig.zeroForOne,
    usdcPerSide,
    yesBuyConfig.sqrtPriceLimitX96,
    "0x",
    { gasLimit: SWAP_GAS_LIMIT }
  );
  await yesBuyTx.wait(2);
  const yesBalanceAfterBuy = await retryUntil(
    () => yesToken.balanceOf(deployer.address),
    (value) => value > 0n
  );
  console.log("YES after buy:", ethers.formatEther(yesBalanceAfterBuy));

  const yesSellAmount = (yesBalanceAfterBuy * sellBps) / 10_000n;
  if (yesSellAmount > 0n) {
    await (await yesToken.approve(await router.getAddress(), MaxUint256)).wait();
    const yesSellConfig = sqrtPriceLimitForExactInput(yesKey, yesTokenAddress);
    console.log("Selling YES:", ethers.formatEther(yesSellAmount));
    const yesSellTx = await router.swapExactInput(
      yesKey,
      yesSellConfig.zeroForOne,
      yesSellAmount,
      yesSellConfig.sqrtPriceLimitX96,
      "0x",
      { gasLimit: SWAP_GAS_LIMIT }
    );
    await yesSellTx.wait(2);
  }

  console.log("Buying NO with", ethers.formatUnits(usdcPerSide, usdcDecimals), "USDC...");
  const noBuyTx = await router.swapExactInput(
    noKey,
    noBuyConfig.zeroForOne,
    usdcPerSide,
    noBuyConfig.sqrtPriceLimitX96,
    "0x",
    { gasLimit: SWAP_GAS_LIMIT }
  );
  await noBuyTx.wait(2);
  const noBalanceAfterBuy = await retryUntil(
    () => noToken.balanceOf(deployer.address),
    (value) => value > 0n
  );
  console.log("NO after buy:", ethers.formatEther(noBalanceAfterBuy));

  const noSellAmount = (noBalanceAfterBuy * sellBps) / 10_000n;
  if (noSellAmount > 0n) {
    await (await noToken.approve(await router.getAddress(), MaxUint256)).wait();
    const noSellConfig = sqrtPriceLimitForExactInput(noKey, noTokenAddress);
    console.log("Selling NO:", ethers.formatEther(noSellAmount));
    const noSellTx = await router.swapExactInput(
      noKey,
      noSellConfig.zeroForOne,
      noSellAmount,
      noSellConfig.sqrtPriceLimitX96,
      "0x",
      { gasLimit: SWAP_GAS_LIMIT }
    );
    await noSellTx.wait(2);
  }

  const preResolveUsdc = await retryUntil(
    () => usdc.balanceOf(deployer.address),
    () => true,
    3,
    1_500
  );
  const preResolveYes = await retryUntil(
    () => yesToken.balanceOf(deployer.address),
    () => true,
    3,
    1_500
  );
  const preResolveNo = await retryUntil(
    () => noToken.balanceOf(deployer.address),
    () => true,
    3,
    1_500
  );

  console.log("Pre-resolution balances:");
  console.log("  USDC:", ethers.formatUnits(preResolveUsdc, usdcDecimals));
  console.log("  YES:", ethers.formatEther(preResolveYes));
  console.log("  NO:", ethers.formatEther(preResolveNo));

  console.log("Resolving market to YES...");
  const resolveTx = await market.resolve(true, { gasLimit: RESOLVE_GAS_LIMIT });
  console.log("resolve tx:", resolveTx.hash);
  await resolveTx.wait(2);

  const marketState = await retryUntil(
    () => market.state(),
    (value) => value === 2n || value === 3n
  );

  await (await yesToken.approve(marketAddress, MaxUint256)).wait();
  if (preResolveYes > 0n && marketState === 2n) {
    const previewClaim = await retryUntil(
      () => market.previewClaim(preResolveYes),
      (value) => value >= 0n
    );
    console.log(
      "Preview YES claim:",
      ethers.formatUnits(previewClaim, usdcDecimals),
      "USDC"
    );

    const claimTx = await market.claimAll({ gasLimit: CLAIM_GAS_LIMIT });
    console.log("claim tx:", claimTx.hash);
    await claimTx.wait(2);
  }

  const finalUsdc = await usdc.balanceOf(deployer.address);
  const finalYes = await balanceOf(yesTokenAddress, deployer.address);
  const finalNo = await balanceOf(noTokenAddress, deployer.address);

  console.log("\n=== SMOKE TEST SUMMARY ===");
  console.log("Market:", marketAddress);
  console.log("Router:", await router.getAddress());
  console.log("State:", await market.state());
  console.log("Prize pool USDC:", ethers.formatUnits(await market.prizePoolUSDC(), usdcDecimals));
  console.log(
    "USDC delta:",
    ethers.formatUnits(finalUsdc - startingUsdc, usdcDecimals)
  );
  console.log("Final USDC:", ethers.formatUnits(finalUsdc, usdcDecimals));
  console.log("Final YES:", ethers.formatEther(finalYes));
  console.log("Final NO:", ethers.formatEther(finalNo));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
