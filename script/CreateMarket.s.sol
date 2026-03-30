// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FortuneMarket, FortuneMarketFactory} from "../src/FortuneMarket.sol";
import {MarketConfig} from "../src/MarketConfig.sol";

contract CreateMarketScript is Script {
    function run() external returns (FortuneMarket market) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address resolver = vm.envOr("RESOLVER", deployer);
        string memory marketQuestion = vm.envString("MARKET_QUESTION");
        string memory marketNotes = vm.envOr("MARKET_NOTES", string(""));
        bool outcomeTokensSellable = vm.envOr("OUTCOME_TOKENS_SELLABLE", true);

        MarketConfig.TickBounds memory token0 = MarketConfig.token0TickBounds();
        MarketConfig.TickBounds memory token1 = MarketConfig.token1TickBounds();
        FortuneMarketFactory factory = FortuneMarketFactory(factoryAddress);

        vm.startBroadcast(privateKey);
        factory.createMarket(
            MarketConfig.LP_FEE_PPM,
            MarketConfig.TICK_SPACING,
            MarketConfig.TOKEN_SUPPLY_EACH,
            outcomeTokensSellable,
            FortuneMarket.TickBounds({lower: token0.lower, upper: token0.upper}),
            FortuneMarket.TickBounds({lower: token1.lower, upper: token1.upper}),
            resolver,
            marketQuestion,
            marketNotes
        );
        vm.stopBroadcast();

        uint256 count = factory.getMarketsCount();
        require(count != 0, "Market not created");

        market = FortuneMarket(factory.markets(count - 1));

        console2.log("Factory:", factoryAddress);
        console2.log("Market:", address(market));
        console2.log("YES token:", address(market.yesToken()));
        console2.log("NO token:", address(market.noToken()));
        console2.log("Resolver:", resolver);
        console2.log("Outcome tokens sellable:", outcomeTokensSellable);
    }
}
