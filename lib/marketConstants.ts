// Base mainnet production constants
export const BASE_MAINNET = {
  chainId: 8453,

  // Uniswap v4 PoolManager on Base mainnet
  // Note: Verify this address against the official Uniswap v4 deployment docs
  POOL_MANAGER: "0x498581fF718922c3f8e6A244956aF099B2652b2b",

  // Base mainnet USDC (native)
  USDC: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",

  // WETH on Base
  WETH: "0x4200000000000000000000000000000000000006",

  // Uniswap v3 SwapRouter02 on Base
  UNISWAP_V3_ROUTER: "0x2626664c2603336E57B271c5C0b26F421741e481",

  // USDC decimals
  USDC_DECIMALS: 6,

  // Outcome token decimals
  TOKEN_DECIMALS: 18,
};

// Base Sepolia testnet constants
export const BASE_SEPOLIA = {
  chainId: 84532,

  // Uniswap v4 PoolManager on Base Sepolia
  POOL_MANAGER: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",

  // Base Sepolia USDC (Circle official testnet)
  USDC: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",

  // WETH on Base Sepolia
  WETH: "0x4200000000000000000000000000000000000006",

  // Uniswap v3 SwapRouter02 on Base Sepolia
  UNISWAP_V3_ROUTER: "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4",

  // USDC decimals
  USDC_DECIMALS: 6,

  // Outcome token decimals
  TOKEN_DECIMALS: 18,
};

// Helper to get network constants by chain ID
export function getNetworkConstants(chainId: number) {
  switch (chainId) {
    case 31337:
      return BASE_MAINNET;
    case 8453:
      return BASE_MAINNET;
    case 84532:
      return BASE_SEPOLIA;
    default:
      throw new Error(`Unsupported chain ID: ${chainId}`);
  }
}

const UNISWAP_MAX_TICK = 887_272;
const DEFAULT_TOKEN_SUPPLY_TOKENS = 10_000_000_000_000;

function alignTick(tick: number, spacing: number, roundDown: boolean): number {
  if (roundDown) {
    return Math.floor(tick / spacing) * spacing;
  }
  return Math.ceil(tick / spacing) * spacing;
}

export function getAlignedTickExtrema(tickSpacing: number): { minTick: number; maxTick: number } {
  const maxTick = alignTick(UNISWAP_MAX_TICK, tickSpacing, true);
  return {
    minTick: -maxTick,
    maxTick,
  };
}

// Default market configuration
export const DEFAULT_MARKET_CONFIG = {
  LP_FEE_PPM: 10_000,
  TICK_SPACING: 60,
  TOKEN_SUPPLY_EACH: BigInt(DEFAULT_TOKEN_SUPPLY_TOKENS) * 10n ** 18n,
  FLOOR_PRICE_USD: 0.01,
  PRICE_IMPACT_REFERENCE_TRADE_USD: 1_000,
  COMPARISON_PRICE_MULTIPLE: 2,
};

// Hook permission flags (encoded in address lower 14 bits)
export const HOOK_FLAGS = {
  BEFORE_INITIALIZE_FLAG: 1n << 13n,
  AFTER_INITIALIZE_FLAG: 1n << 12n,
  BEFORE_ADD_LIQUIDITY_FLAG: 1n << 11n,
  AFTER_ADD_LIQUIDITY_FLAG: 1n << 10n,
  BEFORE_REMOVE_LIQUIDITY_FLAG: 1n << 9n,
  AFTER_REMOVE_LIQUIDITY_FLAG: 1n << 8n,
  BEFORE_SWAP_FLAG: 1n << 7n,
  AFTER_SWAP_FLAG: 1n << 6n,
  BEFORE_DONATE_FLAG: 1n << 5n,
  AFTER_DONATE_FLAG: 1n << 4n,
  BEFORE_SWAP_RETURNS_DELTA_FLAG: 1n << 3n,
  AFTER_SWAP_RETURNS_DELTA_FLAG: 1n << 2n,
  AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG: 1n << 1n,
  AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG: 1n << 0n,
};

export const HOOK_FLAGS_MASK = 0x3FFFn;

export const FORTUNE_MARKET_HOOK_FLAGS =
  HOOK_FLAGS.BEFORE_INITIALIZE_FLAG |
  HOOK_FLAGS.AFTER_INITIALIZE_FLAG |
  HOOK_FLAGS.BEFORE_ADD_LIQUIDITY_FLAG |
  HOOK_FLAGS.BEFORE_REMOVE_LIQUIDITY_FLAG |
  HOOK_FLAGS.BEFORE_SWAP_FLAG;

export function calculateUnboundedTickBounds(
  floorPriceUsd: number,
  tickSpacing: number,
  tokenDecimals: number = 18,
  usdcDecimals: number = 6
): { token0Ticks: { lower: number; upper: number }; token1Ticks: { lower: number; upper: number } } {
  const decimalAdj = Math.pow(10, usdcDecimals - tokenDecimals);
  const floorPriceAdj = floorPriceUsd * decimalAdj;
  const { minTick, maxTick } = getAlignedTickExtrema(tickSpacing);
  const tickFloor = Math.floor(Math.log(floorPriceAdj) / Math.log(1.0001));
  const token0Lower = alignTick(tickFloor, tickSpacing, true);
  const token0Upper = maxTick;

  const invFloorPriceAdj = 1 / floorPriceAdj;
  const tickInvFloor = Math.floor(Math.log(invFloorPriceAdj) / Math.log(1.0001));
  const token1Lower = minTick;
  const token1Upper = alignTick(tickInvFloor, tickSpacing, false);

  return {
    token0Ticks: { lower: token0Lower, upper: token0Upper },
    token1Ticks: { lower: token1Lower, upper: token1Upper },
  };
}

export function getAlignedFloorPriceUsd(
  floorPriceUsd: number,
  tickSpacing: number,
  tokenDecimals: number = 18,
  usdcDecimals: number = 6
): number {
  const { token0Ticks } = calculateUnboundedTickBounds(
    floorPriceUsd,
    tickSpacing,
    tokenDecimals,
    usdcDecimals
  );
  const decimalAdj = Math.pow(10, usdcDecimals - tokenDecimals);
  return Math.pow(1.0001, token0Ticks.lower) / decimalAdj;
}

export function estimatePrizePoolUsd(totalVolumeUsd: number, lpFeePpm: number): number {
  const feeFraction = lpFeePpm / 1_000_000;
  return totalVolumeUsd * (1 - feeFraction / 3);
}

export function estimatePriceImpactBps(
  tokenSupplyEach: bigint,
  floorPriceUsd: number,
  grossTradeUsd: number,
  lpFeePpm: number,
  tokenDecimals: number = 18
): number {
  const tokenSupply = Number(tokenSupplyEach / 10n ** BigInt(tokenDecimals));
  const feeFraction = lpFeePpm / 1_000_000;
  const netUsdc = grossTradeUsd * (1 - feeFraction);

  if (tokenSupply <= 0 || floorPriceUsd <= 0) {
    return 0;
  }

  const priceRatio = Math.pow(1 + netUsdc / (tokenSupply * floorPriceUsd), 2);
  return (priceRatio - 1) * 10_000;
}

export function estimateGrossBuyToPriceMultipleUsd(
  tokenSupplyEach: bigint,
  floorPriceUsd: number,
  targetPriceMultiple: number,
  lpFeePpm: number,
  tokenDecimals: number = 18
): number {
  if (targetPriceMultiple <= 1) {
    return 0;
  }

  const tokenSupply = Number(tokenSupplyEach / 10n ** BigInt(tokenDecimals));
  const feeFraction = lpFeePpm / 1_000_000;
  const netUsdc = tokenSupply * floorPriceUsd * (Math.sqrt(targetPriceMultiple) - 1);

  return netUsdc / (1 - feeFraction);
}
