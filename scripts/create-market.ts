import { ethers } from "hardhat";
import {
  DEFAULT_MARKET_CONFIG,
  calculateUnboundedTickBounds,
  estimateGrossBuyToPriceMultipleUsd,
  estimatePriceImpactBps,
  getAlignedFloorPriceUsd,
} from "../lib/marketConstants";

/**
 * Create a new prediction market.
 *
 * Prerequisites:
 * - The Fortune Market factory must be deployed (run deploy.ts)
 * - Set FACTORY_ADDRESS in environment
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Creating market with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  const factoryAddress = process.env.FACTORY_ADDRESS;
  if (!factoryAddress) {
    console.error("ERROR: FACTORY_ADDRESS not set in environment");
    process.exit(1);
  }

  // Connect to factory
  const factory = await ethers.getContractAt("FortuneMarketFactory", factoryAddress);
  console.log("\nFactory address:", factoryAddress);
  console.log("Markets created so far:", await factory.getMarketsCount());

  const marketQuestion = process.env.MARKET_QUESTION;
  if (!marketQuestion) {
    console.error("ERROR: MARKET_QUESTION not set in environment");
    process.exit(1);
  }

  const marketNotes = process.env.MARKET_NOTES || "";

  // Configure market parameters
  const config = {
    lpFeePpm: DEFAULT_MARKET_CONFIG.LP_FEE_PPM,
    tickSpacing: DEFAULT_MARKET_CONFIG.TICK_SPACING,
    tokenSupplyEach: DEFAULT_MARKET_CONFIG.TOKEN_SUPPLY_EACH,
    floorPriceUsd: DEFAULT_MARKET_CONFIG.FLOOR_PRICE_USD,
    priceImpactReferenceTradeUsd:
      DEFAULT_MARKET_CONFIG.PRICE_IMPACT_REFERENCE_TRADE_USD,
    comparisonPriceMultiple:
      DEFAULT_MARKET_CONFIG.COMPARISON_PRICE_MULTIPLE,
  };

  // Calculate tick bounds
  const tickBounds = calculateUnboundedTickBounds(
    config.floorPriceUsd,
    config.tickSpacing
  );
  const alignedFloorPriceUsd = getAlignedFloorPriceUsd(
    config.floorPriceUsd,
    config.tickSpacing
  );
  const referenceTradeImpactBps = estimatePriceImpactBps(
    config.tokenSupplyEach,
    alignedFloorPriceUsd,
    config.priceImpactReferenceTradeUsd,
    config.lpFeePpm
  );
  const grossBuyToComparisonMultipleUsd = estimateGrossBuyToPriceMultipleUsd(
    config.tokenSupplyEach,
    alignedFloorPriceUsd,
    config.comparisonPriceMultiple,
    config.lpFeePpm
  );

  console.log("\nMarket Configuration:");
  console.log("LP Fee:", config.lpFeePpm, "ppm (", config.lpFeePpm / 10000, "% )");
  console.log("Tick Spacing:", config.tickSpacing);
  console.log("Token Supply Each:", ethers.formatEther(config.tokenSupplyEach));
  console.log("Target Floor Price: $", config.floorPriceUsd);
  console.log("Aligned Floor Price: $", alignedFloorPriceUsd.toFixed(8));
  console.log(
    `Estimated Price Impact for $${config.priceImpactReferenceTradeUsd.toFixed(2)}:`,
    `${referenceTradeImpactBps.toFixed(2)} bps`
  );
  console.log(
    `Estimated Gross Buy To ${config.comparisonPriceMultiple.toFixed(1)}x Floor:`,
    `$${grossBuyToComparisonMultipleUsd.toFixed(2)}`
  );
  console.log("\nTick Bounds (token as currency0):");
  console.log("  Lower:", tickBounds.token0Ticks.lower);
  console.log("  Upper:", tickBounds.token0Ticks.upper);
  console.log("Tick Bounds (token as currency1):");
  console.log("  Lower:", tickBounds.token1Ticks.lower);
  console.log("  Upper:", tickBounds.token1Ticks.upper);

  // Configure the market resolver.
  // In production, this should be a dedicated resolver address.
  const resolver = process.env.RESOLVER || deployer.address;

  console.log("\nResolver Configuration:");
  console.log("Resolver:", resolver);

  console.log("\nMarket Metadata:");
  console.log("Question:", marketQuestion);
  console.log("Notes:", marketNotes || "(empty)");

  // Verify setup before creating market
  console.log("\nVerifying setup...");
  const hookAddress = await factory.hook();
  console.log("Hook address:", hookAddress);

  const hook = await ethers.getContractAt("FortuneMarketHook", hookAddress);
  const hookFactory = await hook.factory();
  console.log("Hook's factory:", hookFactory);
  console.log("Factory address matches:", hookFactory.toLowerCase() === factoryAddress.toLowerCase());

  if (hookFactory.toLowerCase() !== factoryAddress.toLowerCase()) {
    console.error("ERROR: Hook's factory doesn't match! Hook won't accept calls from this factory.");
    process.exit(1);
  }

  // Try static call first to get better error
  console.log("\nSimulating createMarket...");
  try {
    await factory.createMarket.staticCall(
      config.lpFeePpm,
      config.tickSpacing,
      config.tokenSupplyEach,
      { lower: tickBounds.token0Ticks.lower, upper: tickBounds.token0Ticks.upper },
      { lower: tickBounds.token1Ticks.lower, upper: tickBounds.token1Ticks.upper },
      resolver,
      marketQuestion,
      marketNotes
    );
    console.log("Static call succeeded!");
  } catch (error: any) {
    console.error("Static call failed with:", error.message);
    if (error.data) {
      console.error("Error data:", error.data);
    }
  }

  // Create market
  console.log("\nCreating market...");

  const tx = await factory.createMarket(
    config.lpFeePpm,
    config.tickSpacing,
    config.tokenSupplyEach,
    { lower: tickBounds.token0Ticks.lower, upper: tickBounds.token0Ticks.upper },
    { lower: tickBounds.token1Ticks.lower, upper: tickBounds.token1Ticks.upper },
    resolver,
    marketQuestion,
    marketNotes
  );

  console.log("Transaction hash:", tx.hash);
  const receipt = await tx.wait();

  // Find MarketCreated event
  const marketCreatedEvent = receipt?.logs.find((log: any) => {
    try {
      const parsed = factory.interface.parseLog(log);
      return parsed?.name === "MarketCreated";
    } catch {
      return false;
    }
  });

  if (!marketCreatedEvent) {
    console.error("MarketCreated event not found");
    process.exit(1);
  }

  const parsedEvent = factory.interface.parseLog(marketCreatedEvent);
  const marketAddress = parsedEvent?.args.market;
  const yesTokenAddress = parsedEvent?.args.yesToken;
  const noTokenAddress = parsedEvent?.args.noToken;

  console.log("\n=== MARKET CREATED ===");
  console.log("Market Address:", marketAddress);
  console.log("YES Token:", yesTokenAddress);
  console.log("NO Token:", noTokenAddress);
  console.log("Deployer:", parsedEvent?.args.deployer);

  // Get market details
  const market = await ethers.getContractAt("FortuneMarket", marketAddress);
  console.log("\nMarket State:", await market.state());
  console.log("Question:", await market.marketQuestion());
  console.log("Notes:", (await market.marketNotes()) || "(empty)");
  console.log("YES Key Hash:", await market.yesKeyHash());
  console.log("NO Key Hash:", await market.noKeyHash());
  console.log("YES Liquidity:", await market.yesLiquidity());
  console.log("NO Liquidity:", await market.noLiquidity());

  console.log("\nMarket is now OPEN for trading!");
  console.log("Users can swap USDC for YES or NO tokens via Uniswap v4.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
