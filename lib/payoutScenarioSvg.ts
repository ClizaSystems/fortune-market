import type { PayoutScenario } from "./payoutScenarios";

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function renderBadge(x: number, y: number, label: string, fill: string, textFill: string): string {
  const width = 14 + label.length * 7.1;

  return `
    <g>
      <rect x="${x}" y="${y}" width="${width}" height="26" rx="13" fill="${fill}"/>
      <text x="${x + 12}" y="${y + 17}" fill="${textFill}" font-size="12" font-weight="600" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">${escapeXml(label)}</text>
    </g>
  `;
}

function volumeBadgeColors(volume: PayoutScenario["volume"]): { fill: string; text: string } {
  if (volume === "high") {
    return { fill: "#DBEAFE", text: "#1D4ED8" };
  }

  return { fill: "#F3F4F6", text: "#475569" };
}

function liquidityBadgeColors(liquidity: PayoutScenario["liquidity"]): { fill: string; text: string } {
  if (liquidity === "high") {
    return { fill: "#DCFCE7", text: "#166534" };
  }

  return { fill: "#FFF7ED", text: "#C2410C" };
}

function crowdingBadgeColors(crowding: PayoutScenario["crowding"]): { fill: string; text: string } {
  if (crowding === "loser") {
    return { fill: "#ECFDF5", text: "#047857" };
  }
  if (crowding === "balanced") {
    return { fill: "#E0F2FE", text: "#075985" };
  }

  return { fill: "#FEF3C7", text: "#92400E" };
}

function fortuneBarFill(payout: number): string {
  return payout >= 1 ? "#047857" : "#B45309";
}

function deltaLabel(deltaPct: number): string {
  const rounded = Math.round(deltaPct);
  return `${rounded > 0 ? "+" : ""}${rounded}% profit vs trad`;
}

function crowdingLabel(crowding: PayoutScenario["crowding"]): string {
  if (crowding === "balanced") {
    return "balanced flow";
  }

  return `crowded on ${crowding}`;
}

export function renderPayoutScenarioSvg(scenarios: PayoutScenario[]): string {
  const columns = 4;
  const rows = Math.ceil(scenarios.length / columns);
  const width = 1440;
  const cardWidth = 314;
  const cardHeight = 310;
  const startX = 56;
  const startY = 224;
  const columnGap = 24;
  const rowGap = 24;
  const footerY = startY + rows * cardHeight + (rows - 1) * rowGap + 56;
  const height = footerY + 28;
  const chartScaleMax = Math.ceil(
    Math.max(
      1,
      ...scenarios.flatMap((scenario) => [scenario.traditionalWinnerReturnP90, scenario.fortuneWinnerReturnP90]),
    ) + 0.1,
  );

  const cards = scenarios.map((scenario, index) => {
    const col = index % columns;
    const row = Math.floor(index / columns);
    const x = startX + col * (cardWidth + columnGap);
    const y = startY + row * (cardHeight + rowGap);
    const chartLeft = x + 38;
    const chartTop = y + 96;
    const chartHeight = 136;
    const chartBottom = chartTop + chartHeight;
    const traditionalHeight = (scenario.traditionalWinnerReturnMultiple / chartScaleMax) * chartHeight;
    const fortuneHeight = (scenario.fortuneWinnerReturnMultiple / chartScaleMax) * chartHeight;
    const traditionalBarX = chartLeft + 36;
    const fortuneBarX = chartLeft + 154;
    const barWidth = 58;
    const traditionalBarY = chartBottom - traditionalHeight;
    const fortuneBarY = chartBottom - fortuneHeight;
    const fortuneFill = fortuneBarFill(
      scenario.fortuneWinnerReturnMultiple / Math.max(0.0001, scenario.traditionalWinnerReturnMultiple),
    );
    const deltaFill = scenario.profitUpliftVsTraditionalPct >= 0 ? "#ECFDF5" : "#FFF7ED";
    const deltaText = scenario.profitUpliftVsTraditionalPct >= 0 ? "#065F46" : "#9A3412";
    const volumeColors = volumeBadgeColors(scenario.volume);
    const liquidityColors = liquidityBadgeColors(scenario.liquidity);
    const crowdingColors = crowdingBadgeColors(scenario.crowding);
    const deltaTextValue = deltaLabel(scenario.profitUpliftVsTraditionalPct);
    const deltaPillWidth = 24 + deltaTextValue.length * 7.1;
    const deltaPillX = x + (cardWidth - deltaPillWidth) / 2;
    const deltaTextX = x + cardWidth / 2;

    return `
      <g data-scenario="${escapeXml(scenario.id)}">
        <rect x="${x}" y="${y}" width="${cardWidth}" height="${cardHeight}" rx="24" fill="#FFFDF8" stroke="#E7E0D4"/>
        ${renderBadge(x + 24, y + 28, `${scenario.volume} volume`, volumeColors.fill, volumeColors.text)}
        ${renderBadge(x + 126, y + 28, `${scenario.liquidity} liquidity`, liquidityColors.fill, liquidityColors.text)}
        ${renderBadge(x + 24, y + 62, crowdingLabel(scenario.crowding), crowdingColors.fill, crowdingColors.text)}

        <rect x="${traditionalBarX}" y="${traditionalBarY}" width="${barWidth}" height="${traditionalHeight}" rx="16" fill="#2563EB"/>
        <rect x="${fortuneBarX}" y="${fortuneBarY}" width="${barWidth}" height="${fortuneHeight}" rx="16" fill="${fortuneFill}"/>

        <text x="${traditionalBarX - 1}" y="${traditionalBarY - 10}" fill="#1D4ED8" font-size="13" font-weight="700" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">${scenario.traditionalWinnerReturnMultiple.toFixed(2)}x</text>
        <text x="${fortuneBarX - 1}" y="${fortuneBarY - 10}" fill="${fortuneFill}" font-size="13" font-weight="700" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">${scenario.fortuneWinnerReturnMultiple.toFixed(2)}x</text>

        <text x="${traditionalBarX - 6}" y="${chartBottom + 24}" fill="#1D4ED8" font-size="12" font-weight="700" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">Traditional</text>
        <text x="${fortuneBarX + 2}" y="${chartBottom + 24}" fill="${fortuneFill}" font-size="12" font-weight="700" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">Fortune</text>

        <rect x="${deltaPillX}" y="${y + 278}" width="${deltaPillWidth}" height="26" rx="13" fill="${deltaFill}"/>
        <text x="${deltaTextX}" y="${y + 295}" text-anchor="middle" fill="${deltaText}" font-size="12" font-weight="700" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">${deltaTextValue}</text>
      </g>
    `;
  });

  return `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="${width}" height="${height}" rx="28" fill="#F7F2EA"/>
  <rect x="28" y="28" width="${width - 56}" height="${height - 56}" rx="26" fill="#FCFAF5" stroke="#E7E0D4"/>

  <text x="56" y="84" fill="#111827" font-size="31" font-weight="600" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">
    Fortune Market vs Traditional Prediction Market
  </text>
  <text x="56" y="116" fill="#92400E" font-size="18" font-weight="600" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">
    Convex payouts can turn being right against the crowd into materially larger upside.
  </text>
  <text x="56" y="146" fill="#6B7280" font-size="16" font-weight="400" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">
    Twelve scenarios, each aggregating 128 random market simulations with 2,000 timed and sized bets per market.
  </text>
  <text x="56" y="174" fill="#6B7280" font-size="14" font-weight="400" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">
    Bars show median simulated winner returns on a shared scale across all cards so heights remain comparable.
  </text>
  <text x="56" y="198" fill="#6B7280" font-size="14" font-weight="400" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">
    The delta pill shows median winner profit uplift versus traditional, so entry timing now affects the comparison.
  </text>

  ${cards.join("\n")}

  <text x="56" y="${footerY}" fill="#6B7280" font-size="13" font-weight="400" font-family="'IBM Plex Sans', 'Avenir Next', 'Helvetica Neue', Helvetica, sans-serif">
    Model note: each card runs 128 random market simulations, summarizes median winner returns, and derives the pill from winner profit (net of protocol fees) versus a fee-free traditional baseline.
  </text>
</svg>`;
}
