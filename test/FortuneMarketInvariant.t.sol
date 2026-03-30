// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FortuneMarket, FortuneMarketFactory, FortuneMarketHook, OutcomeToken} from "../src/FortuneMarket.sol";
import {MarketConfig} from "../src/MarketConfig.sol";

contract FortuneMarketHandler is Test {
    uint256 internal constant MIN_USDC_TRADE = 1e6;
    uint256 internal constant MAX_USDC_TRADE = 1_000e6;

    FortuneMarket public immutable market;
    PoolSwapTest public immutable swapRouter;
    MockERC20 public immutable usdc;
    IERC20 public immutable yesToken;
    IERC20 public immutable noToken;
    address public immutable resolver;
    bool public immutable outcomeTokensSellable;

    PoolKey internal yesKey;
    PoolKey internal noKey;

    address[4] public actors;

    bool public unexpectedBuyFailure;
    bool public unexpectedSellFailure;
    bool public unexpectedClaimFailure;
    bool public unexpectedDisabledSellSuccess;
    bool public unexpectedPostResolutionSwapSuccess;

    constructor(
        FortuneMarket market_,
        PoolSwapTest swapRouter_,
        MockERC20 usdc_,
        IERC20 yesToken_,
        IERC20 noToken_,
        PoolKey memory yesKey_,
        PoolKey memory noKey_,
        address resolver_,
        bool outcomeTokensSellable_,
        address[4] memory actors_
    ) {
        market = market_;
        swapRouter = swapRouter_;
        usdc = usdc_;
        yesToken = yesToken_;
        noToken = noToken_;
        resolver = resolver_;
        outcomeTokensSellable = outcomeTokensSellable_;
        yesKey = yesKey_;
        noKey = noKey_;
        actors = actors_;
    }

    function buyYes(uint256 actorSeed, uint256 amountSeed) external {
        if (market.state() != FortuneMarket.State.Open) return;

        address actor = _actor(actorSeed);
        uint256 amountIn = _boundUsdcAmount(actor, amountSeed);
        if (amountIn == 0) return;

        if (!_trySwap(actor, yesKey, address(usdc), amountIn)) {
            unexpectedBuyFailure = true;
        }
    }

    function buyNo(uint256 actorSeed, uint256 amountSeed) external {
        if (market.state() != FortuneMarket.State.Open) return;

        address actor = _actor(actorSeed);
        uint256 amountIn = _boundUsdcAmount(actor, amountSeed);
        if (amountIn == 0) return;

        if (!_trySwap(actor, noKey, address(usdc), amountIn)) {
            unexpectedBuyFailure = true;
        }
    }

    function sellYes(uint256 actorSeed, uint256 amountSeed) external {
        _sell(actorSeed, amountSeed, yesKey, yesToken);
    }

    function sellNo(uint256 actorSeed, uint256 amountSeed) external {
        _sell(actorSeed, amountSeed, noKey, noToken);
    }

    function transferYes(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        _transferToken(yesToken, fromSeed, toSeed, amountSeed);
    }

    function transferNo(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        _transferToken(noToken, fromSeed, toSeed, amountSeed);
    }

    function resolveYes() external {
        if (market.state() != FortuneMarket.State.Open) return;

        vm.prank(resolver);
        market.resolve(true);
    }

    function resolveNo() external {
        if (market.state() != FortuneMarket.State.Open) return;

        vm.prank(resolver);
        market.resolve(false);
    }

    function claimWinning(uint256 actorSeed, uint256 amountSeed, bool claimAll_) external {
        if (market.state() != FortuneMarket.State.Resolved) return;

        OutcomeToken winner = market.winningToken();
        address actor = _actor(actorSeed);
        uint256 balance = winner.balanceOf(actor);
        if (balance == 0) return;

        uint256 previewAmount = claimAll_ ? balance : bound(amountSeed, 1, balance);
        try market.previewClaim(previewAmount) returns (uint256 payout) {
            if (payout == 0) return;

            vm.prank(actor);
            if (claimAll_) {
                market.claimAll();
            } else {
                market.claim(previewAmount);
            }
        } catch {
            unexpectedClaimFailure = true;
        }
    }

    function attemptBuyAfterResolution(uint256 actorSeed, uint256 amountSeed) external {
        if (market.state() == FortuneMarket.State.Open) return;

        address actor = _actor(actorSeed);
        uint256 amountIn = _boundUsdcAmount(actor, amountSeed);
        if (amountIn == 0) return;

        if (_trySwap(actor, yesKey, address(usdc), amountIn)) {
            unexpectedPostResolutionSwapSuccess = true;
        }
    }

    function _sell(uint256 actorSeed, uint256 amountSeed, PoolKey memory key, IERC20 token) internal {
        if (market.state() != FortuneMarket.State.Open) return;

        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;

        uint256 maxAmount = balance / 2;
        if (maxAmount == 0) {
            maxAmount = balance;
        }

        uint256 amountIn = bound(amountSeed, 1, maxAmount);
        bool success = _trySwap(actor, key, address(token), amountIn);

        if (outcomeTokensSellable) {
            if (!success) {
                unexpectedSellFailure = true;
            }
        } else if (success) {
            unexpectedDisabledSellSuccess = true;
        }
    }

    function _transferToken(IERC20 token, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) internal {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(from);
        token.transfer(to, amount);
    }

    function _trySwap(address actor, PoolKey memory key, address inputToken, uint256 amountIn) internal returns (bool) {
        try this.executeSwap(actor, key, inputToken, amountIn) {
            return true;
        } catch {
            return false;
        }
    }

    function executeSwap(address actor, PoolKey memory key, address inputToken, uint256 amountIn) external {
        require(msg.sender == address(this), "handler only");

        vm.prank(actor);
        swapRouter.swap(
            key,
            _exactInputParams(key, inputToken, amountIn),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _boundUsdcAmount(address actor, uint256 amountSeed) internal view returns (uint256) {
        uint256 balance = usdc.balanceOf(actor);
        if (balance < MIN_USDC_TRADE) return 0;

        uint256 maxAmount = balance;
        if (maxAmount > MAX_USDC_TRADE) {
            maxAmount = MAX_USDC_TRADE;
        }

        return bound(amountSeed, MIN_USDC_TRADE, maxAmount);
    }

    function _exactInputParams(PoolKey memory key, address inputToken, uint256 amountIn)
        internal
        pure
        returns (SwapParams memory)
    {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);

        if (inputToken == currency0) {
            return SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MarketConfig.MIN_SQRT_PRICE + 1
            });
        }

        if (inputToken == currency1) {
            return SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: MarketConfig.MAX_SQRT_PRICE - 1
            });
        }

        revert("input token not in pool");
    }
}

abstract contract FortuneMarketTestBase is Test {
    uint256 internal constant ACTOR_USDC_BALANCE = 100_000e6;
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address internal owner;
    address internal treasury;
    address internal resolver;
    address[4] internal actors;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    MockERC20 internal usdc;
    FortuneMarketHook internal hook;
    FortuneMarketFactory internal factory;
    FortuneMarket internal market;
    OutcomeToken internal yesToken;
    OutcomeToken internal noToken;
    PoolKey internal yesKey;
    PoolKey internal noKey;

    uint256 internal initialUsdcSupply;

    function _setUpMarket(bool outcomeTokensSellable) internal {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        resolver = makeAddr("resolver");

        for (uint256 i = 0; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor-", vm.toString(i)));
        }

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        usdc = new MockERC20("USD Coin", "USDC", 6);

        hook = _deployHook(owner);
        factory = new FortuneMarketFactory(IPoolManager(address(manager)), IERC20(address(usdc)), hook, treasury);

        vm.prank(owner);
        hook.setFactory(address(factory));

        _createMarket(outcomeTokensSellable);

        yesToken = market.yesToken();
        noToken = market.noToken();
        yesKey = _buildPoolKey(address(yesToken));
        noKey = _buildPoolKey(address(noToken));

        _fundAndApproveActors();
        initialUsdcSupply = usdc.totalSupply();
    }

    function _deployHook(address hookOwner) internal returns (FortuneMarketHook deployedHook) {
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(MarketConfig.FORTUNE_MARKET_HOOK_FLAGS),
            type(FortuneMarketHook).creationCode,
            abi.encode(IPoolManager(address(manager)), hookOwner)
        );

        deployedHook = new FortuneMarketHook{salt: salt}(IPoolManager(address(manager)), hookOwner);

        assertEq(address(deployedHook), predicted);
        assertEq(
            uint160(address(deployedHook)) & uint160(MarketConfig.HOOK_FLAGS_MASK),
            uint160(MarketConfig.FORTUNE_MARKET_HOOK_FLAGS)
        );
    }

    function _createMarket(bool outcomeTokensSellable) internal {
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
            "Will the local invariant suite hold?",
            "Locally deployed market used for fuzz and invariant testing."
        );

        market = FortuneMarket(factory.markets(factory.getMarketsCount() - 1));
    }

    function _fundAndApproveActors() internal {
        for (uint256 i = 0; i < actors.length; ++i) {
            usdc.mint(actors[i], ACTOR_USDC_BALANCE);

            vm.startPrank(actors[i]);
            IERC20(address(usdc)).approve(address(swapRouter), type(uint256).max);
            IERC20(address(yesToken)).approve(address(swapRouter), type(uint256).max);
            IERC20(address(noToken)).approve(address(swapRouter), type(uint256).max);
            IERC20(address(yesToken)).approve(address(market), type(uint256).max);
            IERC20(address(noToken)).approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _buildPoolKey(address tokenAddress) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = tokenAddress < address(usdc)
            ? (Currency.wrap(tokenAddress), Currency.wrap(address(usdc)))
            : (Currency.wrap(address(usdc)), Currency.wrap(tokenAddress));

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: market.lpFeePpm(),
            tickSpacing: market.tickSpacing(),
            hooks: IHooks(address(hook))
        });
    }

    function _exactInputParams(PoolKey memory key, address inputToken, uint256 amountIn)
        internal
        pure
        returns (SwapParams memory)
    {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);

        if (inputToken == currency0) {
            return SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MarketConfig.MIN_SQRT_PRICE + 1
            });
        }

        if (inputToken == currency1) {
            return SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: MarketConfig.MAX_SQRT_PRICE - 1
            });
        }

        revert("input token not in pool");
    }

    function _swapExactInput(address actor, PoolKey memory key, address inputToken, uint256 amountIn) internal {
        vm.prank(actor);
        swapRouter.swap(
            key,
            _exactInputParams(key, inputToken, amountIn),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _buyYes(address actor, uint256 amountIn) internal {
        _swapExactInput(actor, yesKey, address(usdc), amountIn);
    }

    function _buyNo(address actor, uint256 amountIn) internal {
        _swapExactInput(actor, noKey, address(usdc), amountIn);
    }

    function _sellYes(address actor, uint256 amountIn) internal {
        _swapExactInput(actor, yesKey, address(yesToken), amountIn);
    }

    function _sellNo(address actor, uint256 amountIn) internal {
        _swapExactInput(actor, noKey, address(noToken), amountIn);
    }

    function _resolve(bool outcomeYes_) internal {
        vm.prank(resolver);
        market.resolve(outcomeYes_);
    }

    function _aggregateUsdcBalances() internal view returns (uint256 total) {
        total += usdc.balanceOf(address(manager));
        total += usdc.balanceOf(address(market));
        total += usdc.balanceOf(address(treasury));
        total += usdc.balanceOf(address(swapRouter));
        total += usdc.balanceOf(address(factory));
        total += usdc.balanceOf(address(hook));
        total += usdc.balanceOf(address(this));

        for (uint256 i = 0; i < actors.length; ++i) {
            total += usdc.balanceOf(actors[i]);
        }
    }

    function _aggregateTokenBalances(IERC20 token) internal view returns (uint256 total) {
        total += token.balanceOf(address(manager));
        total += token.balanceOf(address(market));
        total += token.balanceOf(address(swapRouter));
        total += token.balanceOf(address(factory));
        total += token.balanceOf(address(hook));
        total += token.balanceOf(address(this));
        total += token.balanceOf(BURN_ADDRESS);

        for (uint256 i = 0; i < actors.length; ++i) {
            total += token.balanceOf(actors[i]);
        }
    }
}

abstract contract FortuneMarketInvariantBase is FortuneMarketTestBase {
    FortuneMarketHandler internal handler;

    function _setUpInvariant(bool outcomeTokensSellable) internal {
        _setUpMarket(outcomeTokensSellable);

        handler = new FortuneMarketHandler(
            market,
            swapRouter,
            usdc,
            IERC20(address(yesToken)),
            IERC20(address(noToken)),
            yesKey,
            noKey,
            resolver,
            outcomeTokensSellable,
            actors
        );

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.buyYes.selector;
        selectors[1] = handler.buyNo.selector;
        selectors[2] = handler.sellYes.selector;
        selectors[3] = handler.sellNo.selector;
        selectors[4] = handler.transferYes.selector;
        selectors[5] = handler.transferNo.selector;
        selectors[6] = handler.resolveYes.selector;
        selectors[7] = handler.resolveNo.selector;
        selectors[8] = handler.claimWinning.selector;
        selectors[9] = handler.attemptBuyAfterResolution.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_marketLifecycleMatchesHookPolicy() public view {
        (
            address yesPolicyMarket,
            int24 yesTickLower,
            int24 yesTickUpper,
            bool yesOutcomeIsCurrency0,
            bool yesSellable,
            bool yesInitialized,
            bool yesClosed
        ) = hook.policy(market.yesKeyHash());
        (
            address noPolicyMarket,
            int24 noTickLower,
            int24 noTickUpper,
            bool noOutcomeIsCurrency0,
            bool noSellable,
            bool noInitialized,
            bool noClosed
        ) = hook.policy(market.noKeyHash());

        assertEq(yesPolicyMarket, address(market));
        assertEq(noPolicyMarket, address(market));
        assertEq(yesTickLower, market.yesTickLower());
        assertEq(yesTickUpper, market.yesTickUpper());
        assertEq(noTickLower, market.noTickLower());
        assertEq(noTickUpper, market.noTickUpper());
        assertEq(yesOutcomeIsCurrency0, address(yesToken) < address(usdc));
        assertEq(noOutcomeIsCurrency0, address(noToken) < address(usdc));
        assertEq(yesSellable, market.outcomeTokensSellable());
        assertEq(noSellable, market.outcomeTokensSellable());
        assertTrue(yesInitialized);
        assertTrue(noInitialized);

        FortuneMarket.State state = market.state();
        if (state == FortuneMarket.State.Open) {
            assertFalse(yesClosed);
            assertFalse(noClosed);
            assertGt(market.yesLiquidity(), 0);
            assertGt(market.noLiquidity(), 0);
            assertEq(address(market.winningToken()), address(0));
            assertEq(market.resolvedBlock(), 0);
        } else {
            assertTrue(yesClosed);
            assertTrue(noClosed);
            assertEq(market.yesLiquidity(), 0);
            assertEq(market.noLiquidity(), 0);
            assertTrue(market.resolvedBlock() > 0);
            assertEq(address(market.winningToken()), market.outcomeYes() ? address(yesToken) : address(noToken));
        }
    }

    function invariant_prizePoolAccountingHolds() public view {
        FortuneMarket.State state = market.state();

        if (state == FortuneMarket.State.Open) {
            assertEq(market.prizePoolUSDC(), 0);
            assertEq(market.remainingPrizePoolUSDC(), 0);
            assertEq(market.totalClaimedUSDC(), 0);
            return;
        }

        assertEq(usdc.balanceOf(address(market)), market.remainingPrizePoolUSDC());
        assertLe(market.totalClaimedUSDC() + market.remainingPrizePoolUSDC(), market.prizePoolUSDC());
        assertGe(market.prizePoolUSDC(), market.totalClaimedUSDC());
        assertGe(market.prizePoolUSDC(), market.remainingPrizePoolUSDC());

        if (state == FortuneMarket.State.Resolved) {
            assertGt(market.remainingPrizePoolUSDC(), 0);
            assertGt(market.claimableWinningSupply(), 0);
        }

        if (state == FortuneMarket.State.Complete) {
            assertEq(market.remainingPrizePoolUSDC(), 0);
        }
    }

    function invariant_assetConservationHolds() public view {
        assertEq(_aggregateUsdcBalances(), initialUsdcSupply);
        assertEq(_aggregateTokenBalances(IERC20(address(yesToken))), yesToken.totalSupply());
        assertEq(_aggregateTokenBalances(IERC20(address(noToken))), noToken.totalSupply());
    }

    function invariant_handlerDidNotObserveUnexpectedPaths() public view {
        assertFalse(handler.unexpectedBuyFailure());
        assertFalse(handler.unexpectedSellFailure());
        assertFalse(handler.unexpectedClaimFailure());
        assertFalse(handler.unexpectedPostResolutionSwapSuccess());
    }
}

contract FortuneMarketSellableInvariantTest is FortuneMarketInvariantBase {
    function setUp() public {
        _setUpInvariant(true);
    }
}

contract FortuneMarketSellDisabledInvariantTest is FortuneMarketInvariantBase {
    function setUp() public {
        _setUpInvariant(false);
    }

    function invariant_disabledOutcomeTokenSellsNeverSucceed() public view {
        assertFalse(handler.unexpectedDisabledSellSuccess());
    }
}

contract FortuneMarketFuzzTest is FortuneMarketTestBase {
    uint256 internal constant MIN_USDC_TRADE = 1e6;
    uint256 internal constant MAX_USDC_TRADE = 1_000e6;

    function testFuzz_disabledOutcomeTokenSellReverts(uint96 buyAmountRaw, uint256 sellAmountRaw) public {
        _setUpMarket(false);

        address actor = actors[0];
        uint256 buyAmount = bound(uint256(buyAmountRaw), MIN_USDC_TRADE, MAX_USDC_TRADE);
        _buyYes(actor, buyAmount);

        uint256 yesBalance = yesToken.balanceOf(actor);
        uint256 usdcBalance = usdc.balanceOf(actor);
        assertGt(yesBalance, 0);

        uint256 sellAmount = bound(sellAmountRaw, 1, yesBalance);

        vm.expectRevert();
        _sellYes(actor, sellAmount);

        assertEq(yesToken.balanceOf(actor), yesBalance);
        assertEq(usdc.balanceOf(actor), usdcBalance);
    }

    function testFuzz_sellableMarketAllowsPartialRoundTrip(uint96 buyAmountRaw) public {
        _setUpMarket(true);

        address actor = actors[0];
        uint256 buyAmount = bound(uint256(buyAmountRaw), MIN_USDC_TRADE, MAX_USDC_TRADE);

        uint256 usdcBeforeBuy = usdc.balanceOf(actor);
        _buyYes(actor, buyAmount);

        uint256 yesBalanceBeforeSell = yesToken.balanceOf(actor);
        uint256 usdcAfterBuy = usdc.balanceOf(actor);

        assertLt(usdcAfterBuy, usdcBeforeBuy);
        assertGt(yesBalanceBeforeSell, 0);

        uint256 sellAmount = yesBalanceBeforeSell / 2;
        if (sellAmount == 0) {
            sellAmount = yesBalanceBeforeSell;
        }

        _sellYes(actor, sellAmount);

        assertLt(yesToken.balanceOf(actor), yesBalanceBeforeSell);
        assertGt(usdc.balanceOf(actor), usdcAfterBuy);
    }

    function testFuzz_claimAllSweepsPrizePoolForSoleWinner(bool outcomeYes, uint96 winningBuyRaw, uint96 losingBuyRaw)
        public
    {
        _setUpMarket(true);

        address winner = actors[0];
        address loser = actors[1];

        uint256 winningBuyAmount = bound(uint256(winningBuyRaw), MIN_USDC_TRADE, MAX_USDC_TRADE);
        uint256 losingBuyAmount = bound(uint256(losingBuyRaw), MIN_USDC_TRADE, MAX_USDC_TRADE);

        if (outcomeYes) {
            _buyYes(winner, winningBuyAmount);
            _buyNo(loser, losingBuyAmount);
        } else {
            _buyNo(winner, winningBuyAmount);
            _buyYes(loser, losingBuyAmount);
        }

        uint256 winnerTokenBalance = outcomeYes ? yesToken.balanceOf(winner) : noToken.balanceOf(winner);
        uint256 usdcBeforeClaim = usdc.balanceOf(winner);

        assertGt(winnerTokenBalance, 0);

        _resolve(outcomeYes);

        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Resolved));
        assertGt(market.prizePoolUSDC(), 0);
        assertEq(market.claimableWinningSupply(), winnerTokenBalance);
        assertEq(market.previewClaim(winnerTokenBalance), market.remainingPrizePoolUSDC());

        vm.prank(winner);
        market.claimAll();

        assertEq(outcomeYes ? yesToken.balanceOf(winner) : noToken.balanceOf(winner), 0);
        assertEq(usdc.balanceOf(winner), usdcBeforeClaim + market.prizePoolUSDC());
        assertEq(market.totalClaimedUSDC(), market.prizePoolUSDC());
        assertEq(market.remainingPrizePoolUSDC(), 0);
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Complete));
    }
}

contract FortuneMarketUnitTest is FortuneMarketTestBase {
    function test_marketCreationRegistersPolicies() public {
        _setUpMarket(false);

        (
            address yesPolicyMarket,
            int24 yesTickLower,
            int24 yesTickUpper,
            bool yesOutcomeIsCurrency0,
            bool yesSellable,
            bool yesInitialized,
            bool yesClosed
        ) = hook.policy(market.yesKeyHash());
        (
            address noPolicyMarket,
            int24 noTickLower,
            int24 noTickUpper,
            bool noOutcomeIsCurrency0,
            bool noSellable,
            bool noInitialized,
            bool noClosed
        ) = hook.policy(market.noKeyHash());

        assertEq(factory.getMarketsCount(), 1);
        assertEq(factory.markets(0), address(market));
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Open));

        assertEq(yesPolicyMarket, address(market));
        assertEq(noPolicyMarket, address(market));
        assertEq(yesTickLower, market.yesTickLower());
        assertEq(yesTickUpper, market.yesTickUpper());
        assertEq(noTickLower, market.noTickLower());
        assertEq(noTickUpper, market.noTickUpper());
        assertEq(yesOutcomeIsCurrency0, address(yesToken) < address(usdc));
        assertEq(noOutcomeIsCurrency0, address(noToken) < address(usdc));
        assertFalse(yesSellable);
        assertFalse(noSellable);
        assertTrue(yesInitialized);
        assertTrue(noInitialized);
        assertFalse(yesClosed);
        assertFalse(noClosed);
    }

    function test_factoryCreateMarketRevertsForBadTicks() public {
        _setUpMarket(true);

        MarketConfig.TickBounds memory token0 = MarketConfig.token0TickBounds();

        vm.expectRevert(FortuneMarket.BadTicks.selector);
        factory.createMarket(
            MarketConfig.LP_FEE_PPM,
            MarketConfig.TICK_SPACING,
            MarketConfig.TOKEN_SUPPLY_EACH,
            true,
            FortuneMarket.TickBounds({lower: token0.upper, upper: token0.lower}),
            FortuneMarket.TickBounds({lower: token0.lower, upper: token0.upper}),
            resolver,
            "invalid ticks",
            "should revert"
        );
    }

    function test_onlyResolverCanResolve() public {
        _setUpMarket(true);

        vm.prank(actors[0]);
        vm.expectRevert(FortuneMarket.OnlyResolver.selector);
        market.resolve(true);
    }

    function test_previewAndClaimAreClosedBeforeResolution() public {
        _setUpMarket(true);

        vm.expectRevert(FortuneMarket.ClaimsClosed.selector);
        market.previewClaim(1);

        vm.prank(actors[0]);
        vm.expectRevert(FortuneMarket.ClaimsClosed.selector);
        market.claim(1);

        vm.prank(actors[0]);
        vm.expectRevert(FortuneMarket.ClaimsClosed.selector);
        market.claimAll();
    }

    function test_resolveWithoutTradesCompletesImmediately() public {
        _setUpMarket(true);

        _resolve(true);

        assertTrue(market.outcomeYes());
        assertEq(address(market.winningToken()), address(yesToken));
        assertEq(market.prizePoolUSDC(), 0);
        assertEq(market.remainingPrizePoolUSDC(), 0);
        assertEq(market.totalClaimedUSDC(), 0);
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Complete));

        (,,,,,, bool yesClosed) = hook.policy(market.yesKeyHash());
        (,,,,,, bool noClosed) = hook.policy(market.noKeyHash());

        assertTrue(yesClosed);
        assertTrue(noClosed);
    }

    function test_claimAllRevertsForActorWithoutWinningTokens() public {
        _setUpMarket(true);

        _buyYes(actors[0], 100e6);
        _buyNo(actors[1], 100e6);
        _resolve(true);

        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Resolved));
        assertEq(yesToken.balanceOf(actors[2]), 0);

        vm.prank(actors[2]);
        vm.expectRevert(FortuneMarket.NoTokens.selector);
        market.claimAll();
    }

    function test_unclaimedPrizePoolSweepsToTreasury() public {
        _setUpMarket(true);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        _buyNo(actors[0], 100e6);
        _resolve(true);

        assertEq(market.claimableWinningSupply(), 0);
        assertEq(market.totalClaimedUSDC(), 0);
        assertEq(market.remainingPrizePoolUSDC(), 0);
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Complete));
        assertGt(market.prizePoolUSDC(), 0);

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, market.prizePoolUSDC() + market.retainedProtocolFeeUSDC());
    }

    function test_claimAllTransfersEntirePrizePoolToSoleWinner() public {
        _setUpMarket(true);

        address winner = actors[0];
        _buyYes(winner, 100e6);
        uint256 winnerUsdcAfterBuy = usdc.balanceOf(winner);
        _resolve(true);

        uint256 winnerBalance = yesToken.balanceOf(winner);
        uint256 prizePool = market.prizePoolUSDC();

        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Resolved));
        assertGt(winnerBalance, 0);
        assertEq(market.claimableWinningSupply(), winnerBalance);
        assertEq(market.previewClaim(winnerBalance), prizePool);

        vm.prank(winner);
        market.claimAll();

        assertEq(yesToken.balanceOf(winner), 0);
        assertEq(usdc.balanceOf(winner), winnerUsdcAfterBuy + prizePool);
        assertEq(market.totalClaimedUSDC(), prizePool);
        assertEq(market.remainingPrizePoolUSDC(), 0);
        assertEq(uint8(market.state()), uint8(FortuneMarket.State.Complete));
    }

    function test_outcomeTokenBurnOnlyMarket() public {
        _setUpMarket(true);

        vm.prank(actors[0]);
        vm.expectRevert(OutcomeToken.OnlyMarket.selector);
        yesToken.burnMarketInventory(1);
    }

    function test_hookSetFactoryOnlyOwnerAndSingleUse() public {
        owner = makeAddr("hook-owner");
        manager = new PoolManager(address(this));

        FortuneMarketHook localHook = _deployHook(owner);
        address localFactory = makeAddr("local-factory");

        vm.prank(actors[0]);
        vm.expectRevert(FortuneMarketHook.OnlyOwner.selector);
        localHook.setFactory(localFactory);

        vm.prank(owner);
        localHook.setFactory(localFactory);

        assertEq(localHook.factory(), localFactory);

        vm.prank(owner);
        vm.expectRevert(FortuneMarketHook.FactoryAlreadySet.selector);
        localHook.setFactory(makeAddr("another-factory"));
    }
}
