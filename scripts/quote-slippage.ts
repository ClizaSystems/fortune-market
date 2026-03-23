import { ethers, network } from "hardhat";
import { MaxUint256 } from "ethers";

const DEFAULT_ROUTER_ADDRESS = "0x1C27f737Fec7E969AA03FCA872d69C4168fD9350";
const DEFAULT_SIZES_USDC = [
  "1",
  "10",
  "100",
  "1000",
  "10000",
  "100000",
  "1000000",
  "10000000",
  "100000000",
];
const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE =
  1461446703485210103287273052203988822378723970342n;

type PoolKeyStruct = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

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

function sqrtPriceLimitForExactInput(key: PoolKeyStruct, inputToken: string) {
  if (eqAddress(inputToken, key.currency0)) {
    return { zeroForOne: true, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1n };
  }

  if (eqAddress(inputToken, key.currency1)) {
    return { zeroForOne: false, sqrtPriceLimitX96: MAX_SQRT_PRICE - 1n };
  }

  throw new Error(`Input token ${inputToken} is not in the pool`);
}

function parseSizeList(raw: string | undefined) {
  return (raw || DEFAULT_SIZES_USDC.join(","))
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

async function findBalanceSlot(
  tokenAddress: string,
  holder: string,
  expectedBalance: bigint,
  maxSlot: number = 50
) {
  for (let slot = 0; slot <= maxSlot; slot++) {
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256"],
      [holder, slot]
    );
    const position = ethers.keccak256(encoded);
    const value = BigInt(await ethers.provider.getStorage(tokenAddress, position));

    if (value === expectedBalance) {
      return position;
    }
  }

  throw new Error("Unable to locate USDC balance storage slot on the fork");
}

async function topUpForkUsdcBalance(
  tokenAddress: string,
  holder: string,
  desiredBalance: bigint
) {
  const usdc = await ethers.getContractAt("ERC20", tokenAddress);
  const currentBalance = await usdc.balanceOf(holder);

  if (currentBalance >= desiredBalance) {
    return currentBalance;
  }

  const storagePosition = await findBalanceSlot(
    tokenAddress,
    holder,
    currentBalance
  );

  await network.provider.send("hardhat_setStorageAt", [
    tokenAddress,
    storagePosition,
    ethers.zeroPadValue(ethers.toBeHex(desiredBalance), 32),
  ]);
  await network.provider.send("evm_mine");

  return usdc.balanceOf(holder);
}

function formatPrice(usdcIn: bigint, tokensOut: bigint) {
  const usdc = Number(ethers.formatUnits(usdcIn, 6));
  const tokens = Number(ethers.formatEther(tokensOut));
  return usdc / tokens;
}

function formatSlippageBps(price: number, baselinePrice: number) {
  return ((price / baselinePrice) - 1) * 10_000;
}

async function main() {
  if (network.name !== "hardhat") {
    throw new Error("Run this script on the forked hardhat network");
  }

  const [deployer] = await ethers.getSigners();
  const marketAddress =
    process.env.SLIPPAGE_MARKET_ADDRESS || process.env.MARKET_ADDRESS;
  if (!marketAddress) {
    throw new Error("SLIPPAGE_MARKET_ADDRESS or MARKET_ADDRESS must be set");
  }

  const routerAddress =
    process.env.SLIPPAGE_ROUTER_ADDRESS || DEFAULT_ROUTER_ADDRESS;
  const sizes = parseSizeList(process.env.SLIPPAGE_SIZES_USDC);

  const market = await ethers.getContractAt("FortuneMarket", marketAddress);
  const usdcAddress = await market.usdc();
  const usdc = await ethers.getContractAt("ERC20", usdcAddress);
  const usdcDecimals = await usdc.decimals();
  const yesTokenAddress = await market.yesToken();
  const noTokenAddress = await market.noToken();
  const hookAddress = await market.hook();
  const fee = Number(await market.lpFeePpm());
  const tickSpacing = Number(await market.tickSpacing());

  const maxSize = sizes.reduce((max, size) => {
    const amount = ethers.parseUnits(size, usdcDecimals);
    return amount > max ? amount : max;
  }, 0n);

  const forkBalance = await topUpForkUsdcBalance(
    usdcAddress,
    deployer.address,
    maxSize * 2n
  );

  const router = await ethers.getContractAt(
    "FortuneMarketSwapRouter",
    routerAddress
  );
  await (await usdc.approve(routerAddress, MaxUint256)).wait();

  console.log("Fork quoting account:", deployer.address);
  console.log("Market:", marketAddress);
  console.log("Router:", routerAddress);
  console.log("Forked USDC balance:", ethers.formatUnits(forkBalance, usdcDecimals));
  console.log("Quoted size ladder (USDC):", sizes.join(", "));

  const sides = [
    { label: "YES", tokenAddress: yesTokenAddress },
    { label: "NO", tokenAddress: noTokenAddress },
  ];

  for (const side of sides) {
    const key = buildPoolKey(
      side.tokenAddress,
      usdcAddress,
      fee,
      tickSpacing,
      hookAddress
    );
    const config = sqrtPriceLimitForExactInput(key, usdcAddress);

    let baselinePrice: number | null = null;
    console.log(`\n${side.label} buy quotes`);

    for (const size of sizes) {
      const amountIn = ethers.parseUnits(size, usdcDecimals);
      const [amount0Delta, amount1Delta] =
        await router.swapExactInput.staticCall(
          key,
          config.zeroForOne,
          amountIn,
          config.sqrtPriceLimitX96,
          "0x"
        );

      const amountOut = config.zeroForOne ? amount1Delta : amount0Delta;
      const effectivePrice = formatPrice(amountIn, amountOut);
      if (baselinePrice === null) {
        baselinePrice = effectivePrice;
      }

      const slippageBps = formatSlippageBps(effectivePrice, baselinePrice);
      console.log(
        [
          `size=${size} USDC`,
          `tokensOut=${ethers.formatEther(amountOut)}`,
          `price=${effectivePrice.toFixed(8)} USDC/token`,
          `slippage=${slippageBps.toFixed(4)} bps`,
        ].join(" | ")
      );
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
