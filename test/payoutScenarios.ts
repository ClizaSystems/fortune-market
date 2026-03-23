import { expect } from "chai";

import { BETS_PER_TRIAL, TRIAL_COUNT, buildPayoutScenarios } from "../lib/payoutScenarios";
import { renderPayoutScenarioSvg } from "../lib/payoutScenarioSvg";

describe("payout scenario simulation", function () {
  const scenarios = buildPayoutScenarios();

  function findScenario(
    volume: "low" | "high",
    liquidity: "low" | "high",
    crowding: "winner" | "balanced" | "loser",
  ) {
    const scenario = scenarios.find(
      (candidate) =>
        candidate.volume === volume && candidate.liquidity === liquidity && candidate.crowding === crowding,
    );

    expect(scenario, `missing scenario ${volume}/${liquidity}/${crowding}`).to.not.equal(undefined);

    return scenario!;
  }

  it("covers all twelve volume/liquidity/crowding combinations", function () {
    expect(scenarios).to.have.length(12);

    const ids = new Set(scenarios.map((scenario) => scenario.id));
    expect(ids.size).to.equal(12);
  });

  it("aggregates many independent simulations per scenario", function () {
    scenarios.forEach((scenario) => {
      expect(scenario.trialCount).to.equal(TRIAL_COUNT);
      expect(scenario.betCount).to.equal(BETS_PER_TRIAL);
      expect(scenario.trials).to.have.length(TRIAL_COUNT);
    });
  });

  it("conserves USDC: fortune prize pool never exceeds total volume", function () {
    scenarios.forEach((scenario) => {
      scenario.trials.forEach((trial) => {
        expect(trial.fortunePrizePoolUsdc).to.be.lessThan(trial.totalVolumeUsdc);
        expect(trial.fortuneProtocolFeeUsdc).to.be.greaterThan(0);
        expect(trial.fortunePrizePoolUsdc).to.be.closeTo(
          trial.totalVolumeUsdc - trial.fortuneProtocolFeeUsdc,
          0.01,
        );
      });

      expect(scenario.prizePoolUSDC).to.be.lessThan(scenario.totalVolumeUsdc);
    });
  });

  it("fortune underperforms traditional when the crowd is right and outperforms when wrong", function () {
    (["low", "high"] as const).forEach((volume) => {
      (["low", "high"] as const).forEach((liquidity) => {
        const winner = findScenario(volume, liquidity, "winner");
        const loser = findScenario(volume, liquidity, "loser");

        expect(winner.profitUpliftVsTraditionalPct).to.be.lessThan(0);
        expect(loser.profitUpliftVsTraditionalPct).to.be.greaterThan(0);
      });
    });
  });

  it("uses moving entry prices so traditional winner returns are not pinned to 1.0x", function () {
    const roundedTraditionalValues = new Set(
      scenarios.map((scenario) => scenario.traditionalWinnerReturnMultiple.toFixed(2)),
    );

    expect(roundedTraditionalValues.size).to.be.at.least(6);
    scenarios.forEach((scenario) => {
      expect(scenario.traditionalWinnerReturnMultiple).to.be.greaterThan(1.2);
      expect(scenario.traditionalWinnerReturnP90).to.be.greaterThan(scenario.traditionalWinnerReturnP10);
    });
  });

  it("places balanced scenarios between crowded-on-winner and crowded-on-loser outcomes", function () {
    const combinations: Array<["low" | "high", "low" | "high"]> = [
      ["low", "high"],
      ["low", "low"],
      ["high", "high"],
      ["high", "low"],
    ];

    combinations.forEach(([volume, liquidity]) => {
      const crowdedWinner = findScenario(volume, liquidity, "winner");
      const balanced = findScenario(volume, liquidity, "balanced");
      const crowdedLoser = findScenario(volume, liquidity, "loser");

      expect(crowdedWinner.profitUpliftVsTraditionalPct).to.be.lessThan(balanced.profitUpliftVsTraditionalPct);
      expect(balanced.profitUpliftVsTraditionalPct).to.be.lessThan(crowdedLoser.profitUpliftVsTraditionalPct);
    });
  });

  it("keeps balanced scenarios close to parity", function () {
    (["low", "high"] as const).forEach((volume) => {
      const balancedHighLiquidity = findScenario(volume, "high", "balanced");
      const balancedLowLiquidity = findScenario(volume, "low", "balanced");

      expect(Math.abs(balancedHighLiquidity.profitUpliftVsTraditionalPct)).to.be.lessThan(15);
      expect(Math.abs(balancedLowLiquidity.profitUpliftVsTraditionalPct)).to.be.lessThan(25);
    });
  });

  it("keeps representative aggregated outputs in expected ranges", function () {
    expect(findScenario("low", "high", "winner").traditionalWinnerReturnMultiple).to.be.within(1.35, 1.85);
    expect(findScenario("low", "high", "winner").profitUpliftVsTraditionalPct).to.be.within(-25, -3);
    expect(findScenario("low", "high", "balanced").traditionalWinnerReturnMultiple).to.be.within(1.75, 2.2);
    expect(findScenario("low", "high", "balanced").profitUpliftVsTraditionalPct).to.be.within(-5, 15);
    expect(findScenario("high", "low", "loser").traditionalWinnerReturnMultiple).to.be.within(2.4, 3.4);
    expect(findScenario("high", "low", "loser").profitUpliftVsTraditionalPct).to.be.within(20, 50);
  });

  it("renders a twelve-card svg with a shared scale and profit-uplift copy", function () {
    const svg = renderPayoutScenarioSvg(scenarios);

    expect(svg).to.contain("<svg");
    expect(svg).to.contain("128 random market simulations");
    expect(svg).to.contain("shared scale across all cards");
    expect(svg).to.contain("profit uplift versus traditional");
    expect(svg).to.contain("profit vs trad");
    expect(svg).to.not.contain("local zoom scale");
    expect(svg).to.not.contain("p10-p90 range");
    expect(svg).to.not.contain("128 sims");
    expect(svg).to.not.contain("stroke-dasharray");
    expect(svg).to.not.contain("Run seed");
    expect(svg.match(/data-scenario=/g)).to.have.length(12);
  });
});
