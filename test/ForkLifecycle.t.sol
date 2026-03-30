// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Create2Deployer, FortuneMarket, FortuneMarketFactory, FortuneMarketHook} from "../src/FortuneMarket.sol";
import {FortuneMarketSwapRouter} from "../src/FortuneMarketSwapRouter.sol";
import {MarketConfig} from "../src/MarketConfig.sol";

contract ForkLifecycleTest is Test {
    struct ForkMarketSetup {
        FortuneMarket market;
        address marketAddress;
        address yesTokenAddress;
        address noTokenAddress;
    }

    struct SwapConfig {
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
    }

    address internal owner;
    MarketConfig.NetworkConstants internal networkConstants;

    function setUp() public {
        string memory baseRpcUrl = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK_NUMBER", uint256(0));

        if (forkBlock == 0) {
            vm.createSelectFork(baseRpcUrl);
        } else {
            vm.createSelectFork(baseRpcUrl, forkBlock);
        }

        owner = makeAddr("owner");
        networkConstants = MarketConfig.getNetworkConstants(block.chainid);
    }

    function testForkLifecycle() public {
        FortuneMarketHook hook = _deployHookOnFork();
        FortuneMarketFactory factory = _deployFactory(hook);

        ForkMarketSetup memory setup = _createForkMarket(
            factory,
            owner,
            true,
            "Will Fortune Market pass the Base fork lifecycle test?",
            "This market is created by the integration test and resolved by the owner."
        );

        FortuneMarket market = setup.market;

        assertEq(market.factory(), address(factory));
        assertEq(market.resolver(), owner);
        assertTrue(market.outcomeTokensSellable());
        assertEq(market.marketQuestion(), "Will Fortune Market pass the Base fork lifecycle test?");
        assertEq(market.marketNotes(), "This market is created by the integration test and resolved by the owner.");
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Open));

        (address yesPolicyMarket,,,, bool yesSellable, bool yesInitialized, bool yesClosed) =
            hook.policy(market.yesKeyHash());
        (address noPolicyMarket,,,, bool noSellable, bool noInitialized, bool noClosed) =
            hook.policy(market.noKeyHash());

        assertEq(yesPolicyMarket, address(market));
        assertEq(noPolicyMarket, address(market));
        assertTrue(yesSellable);
        assertTrue(noSellable);
        assertTrue(yesInitialized);
        assertTrue(noInitialized);
        assertFalse(yesClosed);
        assertFalse(noClosed);

        vm.prank(owner);
        market.resolve(true);

        assertTrue(market.outcomeYes());
        assertEq(market.prizePoolUSDC(), 0);
        assertEq(market.remainingPrizePoolUSDC(), 0);
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Complete));

        (,,,,,, yesClosed) = hook.policy(market.yesKeyHash());
        (,,,,,, noClosed) = hook.policy(market.noKeyHash());

        assertTrue(yesClosed);
        assertTrue(noClosed);
    }

    function testSellGatingOnFork() public {
        FortuneMarketHook hook = _deployHookOnFork();
        FortuneMarketFactory factory = _deployFactory(hook);

        ERC20 usdc = ERC20(networkConstants.usdc);
        uint256 tradeAmount = 10 ** IERC20Metadata(networkConstants.usdc).decimals();
        _topUpForkUsdcBalance(networkConstants.usdc, address(this), tradeAmount * 10);

        FortuneMarketSwapRouter router = new FortuneMarketSwapRouter(factory.poolManager());
        usdc.approve(address(router), type(uint256).max);

        ForkMarketSetup memory disabledSetup = _createForkMarket(
            factory,
            owner,
            false,
            "Will disabled sell-side trading revert on the Base fork?",
            "This market disables outcome-token sells and should reject them."
        );
        FortuneMarket disabledMarket = disabledSetup.market;
        assertFalse(disabledMarket.outcomeTokensSellable());

        PoolKey memory disabledYesKey = _buildPoolKey(
            disabledSetup.yesTokenAddress,
            networkConstants.usdc,
            disabledMarket.lpFeePpm(),
            disabledMarket.tickSpacing(),
            address(disabledMarket.hook())
        );
        SwapConfig memory disabledBuyConfig = _sqrtPriceLimitForExactInput(disabledYesKey, networkConstants.usdc);

        router.swapExactInput(
            disabledYesKey, disabledBuyConfig.zeroForOne, tradeAmount, disabledBuyConfig.sqrtPriceLimitX96, ""
        );

        ERC20 disabledYesToken = ERC20(disabledSetup.yesTokenAddress);
        uint256 disabledYesBalance = disabledYesToken.balanceOf(address(this));
        assertGt(disabledYesBalance, 0);

        disabledYesToken.approve(address(router), type(uint256).max);
        SwapConfig memory disabledSellConfig =
            _sqrtPriceLimitForExactInput(disabledYesKey, disabledSetup.yesTokenAddress);

        vm.expectRevert();
        router.swapExactInput(
            disabledYesKey,
            disabledSellConfig.zeroForOne,
            disabledYesBalance / 2,
            disabledSellConfig.sqrtPriceLimitX96,
            ""
        );

        _topUpForkUsdcBalance(networkConstants.usdc, address(this), tradeAmount * 10);

        ForkMarketSetup memory enabledSetup = _createForkMarket(
            factory,
            owner,
            true,
            "Will enabled sell-side trading still work on the Base fork?",
            "This market keeps both buy and sell flows open."
        );
        FortuneMarket enabledMarket = enabledSetup.market;
        assertTrue(enabledMarket.outcomeTokensSellable());

        PoolKey memory enabledYesKey = _buildPoolKey(
            enabledSetup.yesTokenAddress,
            networkConstants.usdc,
            enabledMarket.lpFeePpm(),
            enabledMarket.tickSpacing(),
            address(enabledMarket.hook())
        );
        SwapConfig memory enabledBuyConfig = _sqrtPriceLimitForExactInput(enabledYesKey, networkConstants.usdc);

        router.swapExactInput(
            enabledYesKey, enabledBuyConfig.zeroForOne, tradeAmount, enabledBuyConfig.sqrtPriceLimitX96, ""
        );

        ERC20 enabledYesToken = ERC20(enabledSetup.yesTokenAddress);
        uint256 enabledYesBalanceBeforeSell = enabledYesToken.balanceOf(address(this));
        assertGt(enabledYesBalanceBeforeSell, 0);

        enabledYesToken.approve(address(router), type(uint256).max);
        SwapConfig memory enabledSellConfig = _sqrtPriceLimitForExactInput(enabledYesKey, enabledSetup.yesTokenAddress);
        uint256 sellAmount = enabledYesBalanceBeforeSell / 2;
        assertGt(sellAmount, 0);

        router.swapExactInput(
            enabledYesKey, enabledSellConfig.zeroForOne, sellAmount, enabledSellConfig.sqrtPriceLimitX96, ""
        );

        uint256 enabledYesBalanceAfterSell = enabledYesToken.balanceOf(address(this));
        assertLt(enabledYesBalanceAfterSell, enabledYesBalanceBeforeSell);
    }

    function testForkSwapResolveAndClaim() public {
        FortuneMarketHook hook = _deployHookOnFork();
        FortuneMarketFactory factory = _deployFactory(hook);

        ERC20 usdc = ERC20(networkConstants.usdc);
        uint256 tradeAmount = 100 * 10 ** IERC20Metadata(networkConstants.usdc).decimals();
        _topUpForkUsdcBalance(networkConstants.usdc, address(this), tradeAmount);

        FortuneMarketSwapRouter router = new FortuneMarketSwapRouter(factory.poolManager());
        usdc.approve(address(router), type(uint256).max);

        ForkMarketSetup memory setup = _createForkMarket(
            factory,
            owner,
            true,
            "Will the fork test cover swap, resolve, and claim?",
            "This market buys YES, resolves YES, and claims the payout."
        );

        FortuneMarket market = setup.market;
        PoolKey memory yesKey = _buildPoolKey(
            setup.yesTokenAddress,
            networkConstants.usdc,
            market.lpFeePpm(),
            market.tickSpacing(),
            address(market.hook())
        );
        SwapConfig memory buyConfig = _sqrtPriceLimitForExactInput(yesKey, networkConstants.usdc);

        router.swapExactInput(yesKey, buyConfig.zeroForOne, tradeAmount, buyConfig.sqrtPriceLimitX96, "");

        ERC20 yesToken = ERC20(setup.yesTokenAddress);
        uint256 winningTokenBalance = yesToken.balanceOf(address(this));
        assertGt(winningTokenBalance, 0);

        vm.prank(owner);
        market.resolve(true);

        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Resolved));
        assertGt(market.prizePoolUSDC(), 0);
        assertGt(market.remainingPrizePoolUSDC(), 0);

        uint256 expectedPayout = market.previewClaim(winningTokenBalance);
        assertGt(expectedPayout, 0);

        yesToken.approve(address(market), type(uint256).max);

        uint256 usdcBalanceBeforeClaim = usdc.balanceOf(address(this));
        market.claimAll();

        assertEq(yesToken.balanceOf(address(this)), 0);
        assertEq(usdc.balanceOf(address(this)), usdcBalanceBeforeClaim + expectedPayout);
        assertEq(market.totalClaimedUSDC(), expectedPayout);
        assertEq(market.remainingPrizePoolUSDC(), 0);
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Complete));
    }

    function _deployHookOnFork() internal returns (FortuneMarketHook hook) {
        assertGt(networkConstants.poolManager.code.length, 0, "PoolManager missing on fork");

        Create2Deployer create2Deployer = new Create2Deployer();
        bytes memory constructorArgs = abi.encode(IPoolManager(networkConstants.poolManager), owner);
        bytes memory initCode = bytes.concat(type(FortuneMarketHook).creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);

        bytes32 salt;
        address hookAddress;

        for (uint256 i = 0; i < 1_000_000; ++i) {
            salt = bytes32(i);
            hookAddress = _computeCreate2Address(address(create2Deployer), salt, initCodeHash);
            if (
                (uint256(uint160(hookAddress)) & MarketConfig.HOOK_FLAGS_MASK) == MarketConfig.FORTUNE_MARKET_HOOK_FLAGS
            ) {
                break;
            }
        }

        require(
            (uint256(uint160(hookAddress)) & MarketConfig.HOOK_FLAGS_MASK) == MarketConfig.FORTUNE_MARKET_HOOK_FLAGS,
            "Failed to mine hook salt"
        );

        create2Deployer.deploy(salt, initCode);
        hook = FortuneMarketHook(hookAddress);
    }

    function _deployFactory(FortuneMarketHook hook) internal returns (FortuneMarketFactory factory) {
        factory = new FortuneMarketFactory(
            IPoolManager(networkConstants.poolManager), ERC20(networkConstants.usdc), hook, owner
        );

        vm.prank(owner);
        hook.setFactory(address(factory));
    }

    function _createForkMarket(
        FortuneMarketFactory factory,
        address resolver,
        bool outcomeTokensSellable,
        string memory marketQuestion,
        string memory marketNotes
    ) internal returns (ForkMarketSetup memory setup) {
        MarketConfig.TickBounds memory token0 = MarketConfig.token0TickBounds();
        MarketConfig.TickBounds memory token1 = MarketConfig.token1TickBounds();

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

        uint256 count = factory.getMarketsCount();
        address marketAddress = factory.markets(count - 1);
        FortuneMarket market = FortuneMarket(marketAddress);

        setup = ForkMarketSetup({
            market: market,
            marketAddress: marketAddress,
            yesTokenAddress: address(market.yesToken()),
            noTokenAddress: address(market.noToken())
        });
    }

    function _buildPoolKey(address tokenAddress, address usdcAddress, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        (Currency currency0, Currency currency1) = tokenAddress < usdcAddress
            ? (Currency.wrap(tokenAddress), Currency.wrap(usdcAddress))
            : (Currency.wrap(usdcAddress), Currency.wrap(tokenAddress));

        return
            PoolKey({
                currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hooks)
            });
    }

    function _sqrtPriceLimitForExactInput(PoolKey memory key, address inputToken)
        internal
        pure
        returns (SwapConfig memory)
    {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);

        if (inputToken == currency0) {
            return SwapConfig({zeroForOne: true, sqrtPriceLimitX96: MarketConfig.MIN_SQRT_PRICE + 1});
        }

        if (inputToken == currency1) {
            return SwapConfig({zeroForOne: false, sqrtPriceLimitX96: MarketConfig.MAX_SQRT_PRICE - 1});
        }

        revert("Input token not in pool");
    }

    function _topUpForkUsdcBalance(address tokenAddress, address holder, uint256 desiredBalance)
        internal
        returns (uint256)
    {
        ERC20 token = ERC20(tokenAddress);
        uint256 currentBalance = token.balanceOf(holder);

        if (currentBalance >= desiredBalance) {
            return currentBalance;
        }

        bytes32 storagePosition = _findBalanceStoragePosition(tokenAddress, holder);
        vm.store(tokenAddress, storagePosition, bytes32(desiredBalance));

        return token.balanceOf(holder);
    }

    function _findBalanceStoragePosition(address tokenAddress, address holder) internal returns (bytes32) {
        ERC20 token = ERC20(tokenAddress);
        uint256 currentBalance = token.balanceOf(holder);
        uint256 probeBalance = currentBalance + 1;

        for (uint256 slot = 0; slot <= 50; ++slot) {
            bytes32 position = keccak256(abi.encode(holder, slot));
            bytes32 originalValue = vm.load(tokenAddress, position);

            vm.store(tokenAddress, position, bytes32(probeBalance));
            uint256 updatedBalance = token.balanceOf(holder);
            vm.store(tokenAddress, position, originalValue);

            if (updatedBalance == probeBalance) {
                return position;
            }
        }

        revert("Unable to locate ERC20 balance slot");
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }
}
