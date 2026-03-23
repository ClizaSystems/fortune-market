import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

import { buildPayoutScenarios } from "../lib/payoutScenarios";
import { renderPayoutScenarioSvg } from "../lib/payoutScenarioSvg";

function getArgValue(flag: string): string | undefined {
  const args = process.argv.slice(2);
  const direct = args.find((arg) => arg.startsWith(`${flag}=`));
  if (direct) {
    return direct.slice(flag.length + 1);
  }

  const index = args.indexOf(flag);
  if (index >= 0) {
    return args[index + 1];
  }

  return undefined;
}

const docsDir = resolve(__dirname, "../docs");
const outputPath = resolve(docsDir, getArgValue("--output") ?? "fortune-vs-traditional-scenarios.svg");

mkdirSync(docsDir, { recursive: true });

const svg = renderPayoutScenarioSvg(buildPayoutScenarios());
writeFileSync(outputPath, svg, "utf8");

console.log(`Wrote ${outputPath}`);
