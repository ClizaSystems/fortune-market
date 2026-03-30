// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title FortuneMarket
/// @notice Per-market contract for Fortune Market.
/// @dev Creates YES/NO tokens, initializes Uniswap v4 pools, handles single-resolver resolution,
///      fee collection/splitting (winning-pool USDC fees: 100% prize pool;
///      losing-pool USDC fees: 50% protocol, 50% prize pool;
///      outcome token fees: sent to the burn address), liquidity removal,
///      and burn-to-claim USDC payouts for winning token holders.
contract FortuneMarket is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    enum State {
        Created,
        Open,
        Resolved,
        Complete
    }

    struct TickBounds {
        int24 lower;
        int24 upper;
    }

    address public immutable factory;
    address public immutable protocolTreasury;
    address public immutable resolver;

    IPoolManager public immutable poolManager;
    FortuneMarketHook public immutable hook;
    IERC20 public immutable usdc;

    OutcomeToken public immutable yesToken;
    OutcomeToken public immutable noToken;
    bool public immutable outcomeTokensSellable;

    uint24 public immutable lpFeePpm;
    int24 public immutable tickSpacing;

    PoolKey public yesKey;
    PoolKey public noKey;

    bytes32 public yesKeyHash;
    bytes32 public noKeyHash;

    int24 public yesTickLower;
    int24 public yesTickUpper;

    int24 public noTickLower;
    int24 public noTickUpper;

    uint128 public yesLiquidity;
    uint128 public noLiquidity;

    bytes32 private constant YES_SALT = keccak256("FORTUNE_MARKET_YES_POSITION");
    bytes32 private constant NO_SALT = keccak256("FORTUNE_MARKET_NO_POSITION");
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    string public marketQuestion;
    string public marketNotes;

    State public state;
    bool public outcomeYes;
    uint256 public resolvedBlock;
    uint256 public prizePoolUSDC;
    OutcomeToken public winningToken;
    uint256 public remainingPrizePoolUSDC;
    uint256 public totalClaimedUSDC;

    uint256 public yesUsdcFeesAccrued;
    uint256 public noUsdcFeesAccrued;
    uint256 public retainedProtocolFeeUSDC;
    uint256 public waivedProtocolFeeUSDC;
    uint256 public burnedYesTokenFees;
    uint256 public burnedNoTokenFees;

    event PoolsInitialized(bytes32 yesKeyHash, bytes32 noKeyHash);
    event MarketResolved(bool outcomeYes, uint256 resolvedBlock, uint256 prizePoolUSDC);
    event ProtocolFeeSettled(uint256 retainedProtocolFeeUSDC, uint256 waivedProtocolFeeUSDC);
    event ClaimsOpened(address indexed winningToken, uint256 claimableWinningSupply, uint256 prizePoolUSDC);
    event Claimed(address indexed claimant, uint256 winningTokenAmount, uint256 payoutUSDC);
    event PrizePoolSwept(uint256 amount);
    event OutcomeTokenFeesBurned(address indexed token, uint256 amount);

    error OnlyFactory();
    error OnlyResolver();
    error OnlyPoolManager();
    error BadAddress();
    error BadTreasury();
    error BadPoolManager();
    error BadHook();
    error BadUsdc();
    error BadResolver();
    error BadQuestion();
    error BadState();
    error NotOpen();
    error ClaimsClosed();
    error ClaimAmountZero();
    error ClaimPayoutZero();
    error BadAction();
    error NoTokens();
    error UsdcRequired();
    error BadTicks();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlyResolver() {
        if (msg.sender != resolver) revert OnlyResolver();
        _;
    }

    constructor(
        address factory_,
        address protocolTreasury_,
        address resolver_,
        IPoolManager poolManager_,
        FortuneMarketHook hook_,
        IERC20 usdc_,
        uint24 lpFeePpm_,
        int24 tickSpacing_,
        uint256 tokenSupplyEach,
        bool outcomeTokensSellable_,
        TickBounds memory ticks_token0,
        TickBounds memory ticks_token1,
        string memory marketQuestion_,
        string memory marketNotes_
    ) {
        if (factory_ == address(0)) revert BadAddress();
        if (protocolTreasury_ == address(0)) revert BadTreasury();
        if (resolver_ == address(0)) revert BadResolver();
        if (address(poolManager_) == address(0)) revert BadPoolManager();
        if (address(hook_) == address(0)) revert BadHook();
        if (address(usdc_) == address(0)) revert BadUsdc();
        if (bytes(marketQuestion_).length == 0) revert BadQuestion();

        factory = factory_;
        protocolTreasury = protocolTreasury_;
        resolver = resolver_;

        poolManager = poolManager_;
        hook = hook_;
        usdc = usdc_;

        lpFeePpm = lpFeePpm_;
        tickSpacing = tickSpacing_;
        outcomeTokensSellable = outcomeTokensSellable_;
        marketQuestion = marketQuestion_;
        marketNotes = marketNotes_;

        yesToken = new OutcomeToken(address(this), "Fortune Market YES", "YES", tokenSupplyEach);
        noToken = new OutcomeToken(address(this), "Fortune Market NO", "NO", tokenSupplyEach);

        (yesKey, yesKeyHash, yesTickLower, yesTickUpper) =
            _buildKeyAndTicks(address(yesToken), ticks_token0, ticks_token1);

        (noKey, noKeyHash, noTickLower, noTickUpper) = _buildKeyAndTicks(address(noToken), ticks_token0, ticks_token1);

        state = State.Created;
    }

    function _buildKeyAndTicks(address token, TickBounds memory ticks_token0, TickBounds memory ticks_token1)
        internal
        view
        returns (PoolKey memory key, bytes32 keyHash_, int24 tickLower_, int24 tickUpper_)
    {
        Currency cToken = Currency.wrap(token);
        Currency cUsdc = Currency.wrap(address(usdc));

        (Currency c0, Currency c1) = token < address(usdc) ? (cToken, cUsdc) : (cUsdc, cToken);

        key = PoolKey({
            currency0: c0, currency1: c1, fee: lpFeePpm, tickSpacing: tickSpacing, hooks: IHooks(address(hook))
        });

        keyHash_ = hook.keyHash(key);

        if (token < address(usdc)) {
            tickLower_ = ticks_token0.lower;
            tickUpper_ = ticks_token0.upper;
        } else {
            tickLower_ = ticks_token1.lower;
            tickUpper_ = ticks_token1.upper;
        }

        if (tickLower_ >= tickUpper_) revert BadTicks();
    }

    function initializePoolsAndLiquidity() external onlyFactory nonReentrant {
        if (state != State.Created) revert BadState();

        uint160 yesInitSqrt =
            TickMath.getSqrtPriceAtTick(address(yesToken) < address(usdc) ? yesTickLower : yesTickUpper);
        uint160 noInitSqrt = TickMath.getSqrtPriceAtTick(address(noToken) < address(usdc) ? noTickLower : noTickUpper);

        poolManager.initialize(yesKey, yesInitSqrt);
        poolManager.initialize(noKey, noInitSqrt);

        poolManager.unlock(abi.encode(uint8(1)));

        state = State.Open;
        emit PoolsInitialized(yesKeyHash, noKeyHash);
    }

    function resolve(bool outcomeYes_) external onlyResolver nonReentrant {
        if (state != State.Open) revert NotOpen();
        _resolve(outcomeYes_);
    }

    function _resolve(bool outcomeYes_) internal {
        hook.closePool(yesKeyHash);
        hook.closePool(noKeyHash);

        poolManager.unlock(abi.encode(uint8(2)));

        {
            uint256 yBal = IERC20(address(yesToken)).balanceOf(address(this));
            if (yBal > 0) {
                yesToken.burnMarketInventory(yBal);
            }

            uint256 nBal = IERC20(address(noToken)).balanceOf(address(this));
            if (nBal > 0) {
                noToken.burnMarketInventory(nBal);
            }
        }

        outcomeYes = outcomeYes_;
        winningToken = outcomeYes_ ? yesToken : noToken;
        resolvedBlock = block.number;

        uint256 losingPoolUsdcFees = outcomeYes_ ? noUsdcFeesAccrued : yesUsdcFeesAccrued;
        retainedProtocolFeeUSDC = losingPoolUsdcFees / 2;
        waivedProtocolFeeUSDC = yesUsdcFeesAccrued + noUsdcFeesAccrued - retainedProtocolFeeUSDC;

        if (retainedProtocolFeeUSDC > 0) {
            usdc.safeTransfer(protocolTreasury, retainedProtocolFeeUSDC);
        }

        prizePoolUSDC = usdc.balanceOf(address(this));
        remainingPrizePoolUSDC = prizePoolUSDC;

        state = prizePoolUSDC == 0 ? State.Complete : State.Resolved;

        emit MarketResolved(outcomeYes_, resolvedBlock, prizePoolUSDC);
        emit ProtocolFeeSettled(retainedProtocolFeeUSDC, waivedProtocolFeeUSDC);
        _finalizeClaimsState();
        if (state == State.Resolved) {
            emit ClaimsOpened(address(winningToken), claimableWinningSupply(), prizePoolUSDC);
        }
    }

    function claimableWinningSupply() public view returns (uint256) {
        OutcomeToken token = winningToken;
        if (address(token) == address(0)) return 0;

        uint256 totalSupply = token.totalSupply();
        uint256 burnedBalance = token.balanceOf(BURN_ADDRESS);
        uint256 marketBalance = token.balanceOf(address(this));
        uint256 poolManagerBalance = token.balanceOf(address(poolManager));

        return totalSupply - burnedBalance - marketBalance - poolManagerBalance;
    }

    function previewClaim(uint256 winningTokenAmount) public view returns (uint256) {
        if (state != State.Resolved) revert ClaimsClosed();
        return _previewClaim(winningTokenAmount);
    }

    function claim(uint256 winningTokenAmount) external nonReentrant {
        if (state != State.Resolved) revert ClaimsClosed();
        _claim(msg.sender, winningTokenAmount);
    }

    function claimAll() external nonReentrant {
        OutcomeToken token = winningToken;
        if (state != State.Resolved) revert ClaimsClosed();

        uint256 balance = token.balanceOf(msg.sender);
        if (balance == 0) revert NoTokens();

        _claim(msg.sender, balance);
    }

    function _previewClaim(uint256 winningTokenAmount) internal view returns (uint256) {
        if (winningTokenAmount == 0) revert ClaimAmountZero();

        uint256 outstandingWinningSupply = claimableWinningSupply();
        if (outstandingWinningSupply == 0 || remainingPrizePoolUSDC == 0) revert ClaimsClosed();

        return (remainingPrizePoolUSDC * winningTokenAmount) / outstandingWinningSupply;
    }

    function _claim(address claimant, uint256 winningTokenAmount) internal {
        OutcomeToken token = winningToken;
        uint256 payoutUSDC = _previewClaim(winningTokenAmount);
        if (payoutUSDC == 0) revert ClaimPayoutZero();

        remainingPrizePoolUSDC -= payoutUSDC;
        totalClaimedUSDC += payoutUSDC;

        IERC20(address(token)).safeTransferFrom(claimant, address(this), winningTokenAmount);
        token.burnMarketInventory(winningTokenAmount);
        usdc.safeTransfer(claimant, payoutUSDC);

        emit Claimed(claimant, winningTokenAmount, payoutUSDC);
        _finalizeClaimsState();
    }

    function _finalizeClaimsState() internal {
        if (remainingPrizePoolUSDC == 0) {
            state = State.Complete;
            return;
        }

        if (claimableWinningSupply() != 0) {
            state = State.Resolved;
            return;
        }

        uint256 amount = remainingPrizePoolUSDC;
        remainingPrizePoolUSDC = 0;
        state = State.Complete;

        usdc.safeTransfer(protocolTreasury, amount);
        emit PrizePoolSwept(amount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        uint8 action = abi.decode(data, (uint8));
        if (action == 1) {
            _addInitialLiquidity();
        } else if (action == 2) {
            _closeAndCollect();
        } else {
            revert BadAction();
        }

        return "";
    }

    function _addInitialLiquidity() internal {
        yesLiquidity = _addSingleSided(
            yesKey,
            yesTickLower,
            yesTickUpper,
            YES_SALT,
            address(yesToken),
            IERC20(address(yesToken)).balanceOf(address(this))
        );

        noLiquidity = _addSingleSided(
            noKey,
            noTickLower,
            noTickUpper,
            NO_SALT,
            address(noToken),
            IERC20(address(noToken)).balanceOf(address(this))
        );
    }

    function _addSingleSided(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        address token,
        uint256 tokenAmount
    ) internal returns (uint128 liquidityOut) {
        if (tokenAmount == 0) revert NoTokens();

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        bool tokenIs0 = token < address(usdc);

        liquidityOut = tokenIs0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, tokenAmount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, tokenAmount);

        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidityOut)), salt: salt
        });

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(key, p, "");

        _settleCallerDelta(key, callerDelta, tokenIs0);
    }

    function _closeAndCollect() internal {
        _collectFeesAndSplit(yesKey, yesTickLower, yesTickUpper, YES_SALT, true);
        _collectFeesAndSplit(noKey, noTickLower, noTickUpper, NO_SALT, false);

        _removeAllLiquidity(yesKey, yesTickLower, yesTickUpper, YES_SALT, yesLiquidity);
        _removeAllLiquidity(noKey, noTickLower, noTickUpper, NO_SALT, noLiquidity);

        yesLiquidity = 0;
        noLiquidity = 0;
    }

    function _collectFeesAndSplit(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt, bool isYesPool)
        internal
    {
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: salt});

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, p, "");

        _takePositiveDelta(key, callerDelta);

        address currency0Addr = Currency.unwrap(key.currency0);

        int128 f0 = BalanceDeltaLibrary.amount0(feesAccrued);
        int128 f1 = BalanceDeltaLibrary.amount1(feesAccrued);

        bool usdcIs0 = currency0Addr == address(usdc);

        if (usdcIs0) {
            if (f0 > 0) {
                uint256 usdcFee = uint256(uint128(f0));
                if (isYesPool) {
                    yesUsdcFeesAccrued += usdcFee;
                } else {
                    noUsdcFeesAccrued += usdcFee;
                }
            }
            if (f1 > 0) {
                uint256 tokenFee = uint256(uint128(f1));
                _sendOutcomeTokenFeesToBurn(isYesPool, tokenFee);
            }
        } else {
            if (f1 > 0) {
                uint256 usdcFee = uint256(uint128(f1));
                if (isYesPool) {
                    yesUsdcFeesAccrued += usdcFee;
                } else {
                    noUsdcFeesAccrued += usdcFee;
                }
            }
            if (f0 > 0) {
                uint256 tokenFee = uint256(uint128(f0));
                _sendOutcomeTokenFeesToBurn(isYesPool, tokenFee);
            }
        }
    }

    function _sendOutcomeTokenFeesToBurn(bool isYesPool, uint256 amount) internal {
        if (amount == 0) return;

        if (isYesPool) {
            burnedYesTokenFees += amount;
            IERC20(address(yesToken)).safeTransfer(BURN_ADDRESS, amount);
            emit OutcomeTokenFeesBurned(address(yesToken), amount);
        } else {
            burnedNoTokenFees += amount;
            IERC20(address(noToken)).safeTransfer(BURN_ADDRESS, amount);
            emit OutcomeTokenFeesBurned(address(noToken), amount);
        }
    }

    function _removeAllLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liq)
        internal
    {
        if (liq == 0) return;

        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(liq)), salt: salt
        });

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(key, p, "");
        _takePositiveDelta(key, callerDelta);
    }

    function _takePositiveDelta(PoolKey memory key, BalanceDelta d) internal {
        int128 a0 = BalanceDeltaLibrary.amount0(d);
        int128 a1 = BalanceDeltaLibrary.amount1(d);

        if (a0 > 0) {
            poolManager.take(key.currency0, address(this), uint256(uint128(a0)));
        }
        if (a1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(a1)));
        }
    }

    function _settleCallerDelta(PoolKey memory key, BalanceDelta d, bool tokenIs0) internal {
        int128 a0 = BalanceDeltaLibrary.amount0(d);
        int128 a1 = BalanceDeltaLibrary.amount1(d);

        if (a0 < 0) {
            _settleCurrency(key.currency0, uint256(uint128(-a0)));
        }
        if (a1 < 0) {
            _settleCurrency(key.currency1, uint256(uint128(-a1)));
        }

        if (state == State.Created) {
            if (tokenIs0) {
                if (a1 < 0) revert UsdcRequired();
            } else {
                if (a0 < 0) revert UsdcRequired();
            }
        }

        _takePositiveDelta(key, d);
    }

    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }
}

contract OutcomeToken is ERC20 {
    address public immutable market;

    error OnlyMarket();

    constructor(address market_, string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        market = market_;
        _mint(market_, supply);
    }

    function burnMarketInventory(uint256 amount) external {
        if (msg.sender != market) revert OnlyMarket();
        _burn(market, amount);
    }
}

contract FortuneMarketHook is BaseHook {
    address public factory;
    address public immutable owner;

    struct PoolPolicy {
        address market;
        int24 tickLower;
        int24 tickUpper;
        bool outcomeTokenIsCurrency0;
        bool outcomeTokensSellable;
        bool initialized;
        bool closed;
    }

    mapping(bytes32 => PoolPolicy) public policy;

    event PoolRegistered(bytes32 indexed keyHash, address indexed market, int24 tickLower, int24 tickUpper);
    event PoolClosed(bytes32 indexed keyHash);

    error OnlyFactory();
    error OnlyMarket();
    error OnlyOwner();
    error FactoryAlreadySet();
    error AlreadyRegistered();
    error BadMarket();
    error BadTicks();
    error AlreadyInitialized();
    error InitNotAuthorized();
    error AddLiqNotAuth();
    error RemLiqNotAuth();
    error PoolClosed_();
    error TicksNotAllowed();
    error OutcomeTokenSellingDisabled();

    constructor(IPoolManager pm, address owner_) BaseHook(pm) {
        owner = owner_;
    }

    function setFactory(address factory_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function keyHash(PoolKey calldata key) public pure returns (bytes32) {
        return keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
    }

    function registerPool(
        bytes32 keyHash_,
        address market_,
        int24 tickLower_,
        int24 tickUpper_,
        bool outcomeTokenIsCurrency0_,
        bool outcomeTokensSellable_
    ) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (policy[keyHash_].market != address(0)) revert AlreadyRegistered();
        if (market_ == address(0)) revert BadMarket();
        if (tickLower_ >= tickUpper_) revert BadTicks();

        policy[keyHash_] = PoolPolicy({
            market: market_,
            tickLower: tickLower_,
            tickUpper: tickUpper_,
            outcomeTokenIsCurrency0: outcomeTokenIsCurrency0_,
            outcomeTokensSellable: outcomeTokensSellable_,
            initialized: false,
            closed: false
        });

        emit PoolRegistered(keyHash_, market_, tickLower_, tickUpper_);
    }

    function closePool(bytes32 keyHash_) external {
        PoolPolicy storage p = policy[keyHash_];
        if (msg.sender != p.market) revert OnlyMarket();
        p.closed = true;
        emit PoolClosed(keyHash_);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        PoolPolicy storage p = policy[keyHash(key)];
        if (sender != p.market) revert InitNotAuthorized();
        if (p.initialized) revert AlreadyInitialized();
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolPolicy storage p = policy[keyHash(key)];
        if (sender != p.market) revert InitNotAuthorized();
        p.initialized = true;
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolPolicy storage p = policy[keyHash(key)];
        if (p.closed) revert PoolClosed_();
        if (sender != p.market) revert AddLiqNotAuth();
        if (params.tickLower != p.tickLower || params.tickUpper != p.tickUpper) revert TicksNotAllowed();
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolPolicy storage p = policy[keyHash(key)];
        if (sender != p.market) revert RemLiqNotAuth();
        if (params.tickLower != p.tickLower || params.tickUpper != p.tickUpper) revert TicksNotAllowed();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolPolicy storage p = policy[keyHash(key)];
        if (p.closed) revert PoolClosed_();
        if (!p.outcomeTokensSellable) {
            bool outcomeTokenIsInput = p.outcomeTokenIsCurrency0 ? params.zeroForOne : !params.zeroForOne;
            if (outcomeTokenIsInput) revert OutcomeTokenSellingDisabled();
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

contract FortuneMarketFactory is Ownable2Step {
    IPoolManager public immutable poolManager;
    IERC20 public immutable usdc;
    FortuneMarketHook public immutable hook;

    address public protocolTreasury;
    address[] public markets;

    event MarketCreated(address indexed market, address yesToken, address noToken, address indexed deployer);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error BadTreasury();

    constructor(IPoolManager pm, IERC20 usdc_, FortuneMarketHook hook_, address treasury) Ownable(msg.sender) {
        poolManager = pm;
        usdc = usdc_;
        hook = hook_;
        protocolTreasury = treasury;
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert BadTreasury();
        address old = protocolTreasury;
        protocolTreasury = t;
        emit TreasuryUpdated(old, t);
    }

    function createMarket(
        uint24 lpFeePpm,
        int24 tickSpacing,
        uint256 tokenSupplyEach,
        bool outcomeTokensSellable,
        FortuneMarket.TickBounds calldata ticks_token0,
        FortuneMarket.TickBounds calldata ticks_token1,
        address resolver,
        string calldata marketQuestion,
        string calldata marketNotes
    ) external returns (address marketAddr) {
        FortuneMarket m = new FortuneMarket(
            address(this),
            protocolTreasury,
            resolver,
            poolManager,
            hook,
            usdc,
            lpFeePpm,
            tickSpacing,
            tokenSupplyEach,
            outcomeTokensSellable,
            ticks_token0,
            ticks_token1,
            marketQuestion,
            marketNotes
        );

        hook.registerPool(
            m.yesKeyHash(),
            address(m),
            m.yesTickLower(),
            m.yesTickUpper(),
            address(m.yesToken()) < address(usdc),
            outcomeTokensSellable
        );
        hook.registerPool(
            m.noKeyHash(),
            address(m),
            m.noTickLower(),
            m.noTickUpper(),
            address(m.noToken()) < address(usdc),
            outcomeTokensSellable
        );
        m.initializePoolsAndLiquidity();

        markets.push(address(m));

        emit MarketCreated(address(m), address(m.yesToken()), address(m.noToken()), msg.sender);
        return address(m);
    }

    function getMarketsCount() external view returns (uint256) {
        return markets.length;
    }
}

contract Create2Deployer {
    event Deployed(address indexed deployed, bytes32 indexed salt);

    function deploy(bytes32 salt, bytes memory initCode) external returns (address deployed) {
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed != address(0), "CREATE2_FAILED");
        emit Deployed(deployed, salt);
    }

    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
