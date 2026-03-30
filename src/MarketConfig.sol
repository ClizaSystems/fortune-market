// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library MarketConfig {
    struct NetworkConstants {
        uint256 chainId;
        address poolManager;
        address usdc;
    }

    struct TickBounds {
        int24 lower;
        int24 upper;
    }

    uint24 internal constant LP_FEE_PPM = 10_000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant TOKEN_SUPPLY_EACH = 10_000_000_000_000 ether;

    int24 internal constant TOKEN0_TICK_LOWER = -322_380;
    int24 internal constant TOKEN0_TICK_UPPER = 887_220;
    int24 internal constant TOKEN1_TICK_LOWER = -887_220;
    int24 internal constant TOKEN1_TICK_UPPER = 322_380;

    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    uint256 internal constant HOOK_FLAGS_MASK = 0x3FFF;
    uint256 internal constant FORTUNE_MARKET_HOOK_FLAGS = (1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7);

    function getNetworkConstants(uint256 chainId) internal pure returns (NetworkConstants memory) {
        if (chainId == 31337 || chainId == 8453) {
            return NetworkConstants({
                chainId: 8453,
                poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
            });
        }

        if (chainId == 84532) {
            return NetworkConstants({
                chainId: 84532,
                poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
            });
        }

        revert("Unsupported chain");
    }

    function token0TickBounds() internal pure returns (TickBounds memory) {
        return TickBounds({lower: TOKEN0_TICK_LOWER, upper: TOKEN0_TICK_UPPER});
    }

    function token1TickBounds() internal pure returns (TickBounds memory) {
        return TickBounds({lower: TOKEN1_TICK_LOWER, upper: TOKEN1_TICK_UPPER});
    }
}
