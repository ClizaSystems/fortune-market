import { randomBytes } from "crypto";

export type VolumeBand = "low" | "high";
export type LiquidityBand = "low" | "high";
export type CrowdingBand = "winner" | "balanced" | "loser";
export type BetSide = "winner" | "loser";

export const BETS_PER_TRIAL = 2_000;
export const TRIAL_COUNT = 128;

export interface TrialSummary {
  trialIndex: number;
  totalVolumeUsdc: number;
  winnerBetCount: number;
  loserBetCount: number;
  winnerStakeUsdc: number;
  loserStakeUsdc: number;
  avgWinnerEntryPrice: number;
  fortuneProtocolFeeUsdc: number;
  fortunePrizePoolUsdc: number;
  traditionalWinnerReturnMultiple: number;
  fortuneWinnerReturnMultiple: number;
  traditionalWinnerProfitMultiple: number;
  fortuneWinnerProfitMultiple: number;
  profitUpliftVsTraditionalPct: number;
}

export interface PayoutScenario {
  id: string;
  volume: VolumeBand;
  liquidity: LiquidityBand;
  crowding: CrowdingBand;
  trialCount: number;
  betCount: number;
  trials: TrialSummary[];
  totalVolumeUsdc: number;
  winnerBetCount: number;
  loserBetCount: number;
  winnerStakeUsdc: number;
  avgWinnerEntryPrice: number;
  feeRate: number;
  prizePoolUSDC: number;
  traditionalWinnerReturnMultiple: number;
  traditionalWinnerReturnP10: number;
  traditionalWinnerReturnP90: number;
  fortuneWinnerReturnMultiple: number;
  fortuneWinnerReturnP10: number;
  fortuneWinnerReturnP90: number;
  traditionalWinnerProfitMultiple: number;
  fortuneWinnerProfitMultiple: number;
  profitUpliftVsTraditionalPct: number;
}

const VOLUME_USDC: Record<VolumeBand, number> = {
  low: 120_000,
  high: 240_000,
};

const FEE_RATE: Record<VolumeBand, Record<LiquidityBand, number>> = {
  low: {
    high: 0.02,
    low: 0.03,
  },
  high: {
    high: 0.04,
    low: 0.06,
  },
};

const PRICE_BIAS: Record<LiquidityBand, Record<CrowdingBand, number>> = {
  high: {
    winner: 0.16,
    balanced: 0.0,
    loser: -0.16,
  },
  low: {
    winner: 0.24,
    balanced: 0.0,
    loser: -0.24,
  },
};

const FLOW_BIAS: Record<LiquidityBand, Record<CrowdingBand, number>> = {
  high: {
    winner: 0.24,
    balanced: 0.0,
    loser: -0.24,
  },
  low: {
    winner: 0.34,
    balanced: 0.0,
    loser: -0.34,
  },
};

const PRICE_NOISE: Record<LiquidityBand, number> = {
  high: 0.018,
  low: 0.03,
};

const SIDE_NOISE: Record<LiquidityBand, number> = {
  high: 0.05,
  low: 0.07,
};

const IMBALANCE_IMPACT: Record<LiquidityBand, number> = {
  high: 0.04,
  low: 0.08,
};

const SIZE_IMPACT: Record<LiquidityBand, number> = {
  high: 0.009,
  low: 0.017,
};

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function easeOut(value: number): number {
  return 1 - Math.pow(1 - value, 1.35);
}

function createRng(): () => number {
  let buffer = Buffer.alloc(0);
  let offset = 0;

  return () => {
    if (offset + 4 > buffer.length) {
      buffer = randomBytes(4096);
      offset = 0;
    }

    const value = buffer.readUInt32BE(offset);
    offset += 4;
    return value / 0x100000000;
  };
}

function randomNormal(rng: () => number): number {
  let u = 0;
  let v = 0;

  while (u === 0) {
    u = rng();
  }
  while (v === 0) {
    v = rng();
  }

  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

function quantile(values: number[], q: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  const position = (sorted.length - 1) * q;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);

  if (lower === upper) {
    return sorted[lower];
  }

  const weight = position - lower;
  return sorted[lower] * (1 - weight) + sorted[upper] * weight;
}

function median(values: number[]): number {
  return quantile(values, 0.5);
}

function simulateTrial(
  volume: VolumeBand,
  liquidity: LiquidityBand,
  crowding: CrowdingBand,
  trialIndex: number,
): TrialSummary {
  const rng = createRng();
  const targetVolumeUsdc = VOLUME_USDC[volume];
  const averageStake = targetVolumeUsdc / BETS_PER_TRIAL;

  const rawBets = Array.from({ length: BETS_PER_TRIAL }, (_, index) => ({
    index,
    time: rng(),
    rawStake: Math.exp(randomNormal(rng) * 0.85),
  })).sort((left, right) => left.time - right.time || left.index - right.index);

  const rawStakeTotal = rawBets.reduce((sum, bet) => sum + bet.rawStake, 0);

  let totalVolumeUsdc = 0;
  let winnerStakeUsdc = 0;
  let loserStakeUsdc = 0;
  let winnerBetCount = 0;
  let loserBetCount = 0;
  let winningTokens = 0;

  for (const rawBet of rawBets) {
    const time = rawBet.time;
    const progress = 0.18 + 0.82 * easeOut(time);
    const stakeUsdc = (targetVolumeUsdc * rawBet.rawStake) / rawStakeTotal;
    const imbalance = (winnerStakeUsdc - loserStakeUsdc) / Math.max(totalVolumeUsdc, averageStake);
    const balancedNoiseScale = crowding === "balanced" ? 0.45 : 1;
    const balancedPriceCorrection = crowding === "balanced" ? -0.05 * imbalance : 0;
    const balancedFlowCorrection = crowding === "balanced" ? -0.22 * imbalance : 0;
    const priceNoise = (rng() - 0.5) * PRICE_NOISE[liquidity] * balancedNoiseScale;
    const baseWinnerPrice = clamp(
      0.5 + PRICE_BIAS[liquidity][crowding] * progress + balancedPriceCorrection + priceNoise,
      0.08,
      0.92,
    );
    const sideProbability = clamp(
      0.5 +
        FLOW_BIAS[liquidity][crowding] * progress +
        balancedFlowCorrection +
        (rng() - 0.5) * SIDE_NOISE[liquidity] * balancedNoiseScale,
      0.08,
      0.92,
    );
    const side: BetSide = rng() < sideProbability ? "winner" : "loser";
    const sizeImpact = SIZE_IMPACT[liquidity] * Math.sqrt(stakeUsdc / averageStake);
    const imbalanceImpact = IMBALANCE_IMPACT[liquidity] * imbalance;
    const winnerEntryPrice = clamp(baseWinnerPrice + imbalanceImpact + (side === "winner" ? sizeImpact : 0), 0.05, 0.95);
    const loserEntryPrice = clamp(
      1 - baseWinnerPrice - imbalanceImpact + (side === "loser" ? sizeImpact : 0),
      0.05,
      0.95,
    );
    const entryPrice = side === "winner" ? winnerEntryPrice : loserEntryPrice;

    totalVolumeUsdc += stakeUsdc;

    if (side === "winner") {
      winnerBetCount += 1;
      winnerStakeUsdc += stakeUsdc;
      winningTokens += stakeUsdc / entryPrice;
    } else {
      loserBetCount += 1;
      loserStakeUsdc += stakeUsdc;
    }
  }

  if (winnerStakeUsdc === 0 || winningTokens === 0) {
    throw new Error(`scenario ${volume}/${liquidity}/${crowding} trial ${trialIndex} produced no winning-side flow`);
  }

  const feeRate = FEE_RATE[volume][liquidity];

  // Fortune Market prize pool matches FortuneMarket.sol _resolve():
  //   retainedProtocolFeeUSDC = losingPoolUsdcFees / 2
  //   prizePoolUSDC = usdc.balanceOf(address(this))
  // All user USDC enters via swaps; protocol retains 50 % of losing-side LP fees.
  const fortuneProtocolFeeUsdc = (loserStakeUsdc * feeRate) / 2;
  const fortunePrizePoolUsdc = totalVolumeUsdc - fortuneProtocolFeeUsdc;

  const avgWinnerEntryPrice = winnerStakeUsdc / winningTokens;
  const traditionalWinnerReturnMultiple = 1 / avgWinnerEntryPrice;
  const fortuneWinnerReturnMultiple = fortunePrizePoolUsdc / winnerStakeUsdc;
  const traditionalWinnerProfitMultiple = traditionalWinnerReturnMultiple - 1;
  const fortuneWinnerProfitMultiple = fortuneWinnerReturnMultiple - 1;
  const profitUpliftVsTraditionalPct =
    traditionalWinnerProfitMultiple <= 0
      ? 0
      : ((fortuneWinnerProfitMultiple / traditionalWinnerProfitMultiple) - 1) * 100;

  return {
    trialIndex,
    totalVolumeUsdc,
    winnerBetCount,
    loserBetCount,
    winnerStakeUsdc,
    loserStakeUsdc,
    avgWinnerEntryPrice,
    fortuneProtocolFeeUsdc,
    fortunePrizePoolUsdc,
    traditionalWinnerReturnMultiple,
    fortuneWinnerReturnMultiple,
    traditionalWinnerProfitMultiple,
    fortuneWinnerProfitMultiple,
    profitUpliftVsTraditionalPct,
  };
}

export function buildPayoutScenario(
  volume: VolumeBand,
  liquidity: LiquidityBand,
  crowding: CrowdingBand,
): PayoutScenario {
  const trials = Array.from({ length: TRIAL_COUNT }, (_, trialIndex) =>
    simulateTrial(volume, liquidity, crowding, trialIndex),
  );
  const traditionalReturns = trials.map((trial) => trial.traditionalWinnerReturnMultiple);
  const fortuneReturns = trials.map((trial) => trial.fortuneWinnerReturnMultiple);
  const traditionalProfits = trials.map((trial) => trial.traditionalWinnerProfitMultiple);
  const fortuneProfits = trials.map((trial) => trial.fortuneWinnerProfitMultiple);
  const profitUplifts = trials.map((trial) => trial.profitUpliftVsTraditionalPct);

  return {
    id: `${volume}-volume__${liquidity}-liquidity__${crowding}`,
    volume,
    liquidity,
    crowding,
    trialCount: TRIAL_COUNT,
    betCount: BETS_PER_TRIAL,
    trials,
    totalVolumeUsdc: median(trials.map((trial) => trial.totalVolumeUsdc)),
    winnerBetCount: Math.round(median(trials.map((trial) => trial.winnerBetCount))),
    loserBetCount: Math.round(median(trials.map((trial) => trial.loserBetCount))),
    winnerStakeUsdc: median(trials.map((trial) => trial.winnerStakeUsdc)),
    avgWinnerEntryPrice: median(trials.map((trial) => trial.avgWinnerEntryPrice)),
    feeRate: FEE_RATE[volume][liquidity],
    prizePoolUSDC: median(trials.map((trial) => trial.fortunePrizePoolUsdc)),
    traditionalWinnerReturnMultiple: median(traditionalReturns),
    traditionalWinnerReturnP10: quantile(traditionalReturns, 0.1),
    traditionalWinnerReturnP90: quantile(traditionalReturns, 0.9),
    fortuneWinnerReturnMultiple: median(fortuneReturns),
    fortuneWinnerReturnP10: quantile(fortuneReturns, 0.1),
    fortuneWinnerReturnP90: quantile(fortuneReturns, 0.9),
    traditionalWinnerProfitMultiple: median(traditionalProfits),
    fortuneWinnerProfitMultiple: median(fortuneProfits),
    profitUpliftVsTraditionalPct: median(profitUplifts),
  };
}

export function buildPayoutScenarios(): PayoutScenario[] {
  const volumeLiquidityCombos: Array<[VolumeBand, LiquidityBand]> = [
    ["low", "high"],
    ["low", "low"],
    ["high", "high"],
    ["high", "low"],
  ];

  const crowdings: CrowdingBand[] = ["winner", "balanced", "loser"];

  return crowdings.flatMap((crowding) =>
    volumeLiquidityCombos.map(([volume, liquidity]) => buildPayoutScenario(volume, liquidity, crowding)),
  );
}
