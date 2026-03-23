// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
        Created, // deployed, not initialized
        Open, // pools live
        Resolved, // pools closed, prize pool finalized, claims open or sweepable
        Complete // prize fully claimed or swept

    }

    struct TickBounds {
        int24 lower;
        int24 upper;
    }

    // Immutable wiring
    address public immutable factory;
    address public immutable protocolTreasury;
    address public immutable resolver;

    IPoolManager public immutable poolManager;
    FortuneMarketHook public immutable hook;
    IERC20 public immutable usdc;

    // Outcome tokens
    OutcomeToken public immutable yesToken;
    OutcomeToken public immutable noToken;

    // Uniswap config
    uint24 public immutable lpFeePpm; // e.g. 10_000 = 1%
    int24 public immutable tickSpacing; // e.g. 60

    // Pools
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

    // Market metadata
    string public marketQuestion;
    string public marketNotes;

    // Resolution config
    // Single resolver by design in this iteration. Resolver liveness is an operational assumption.

    // State
    State public state;
    bool public outcomeYes; // true if YES won
    uint256 public resolvedBlock; // block when resolved
    uint256 public prizePoolUSDC; // finalized USDC in contract (for winner payouts)
    OutcomeToken public winningToken; // winner token contract after resolution
    uint256 public remainingPrizePoolUSDC; // remaining USDC available for claims
    uint256 public totalClaimedUSDC; // cumulative USDC claimed by winners

    // -------------------------
    // Fee accounting
    // -------------------------
    // USDC fees are accrued per pool and settled at resolution:
    // winning pool => 100% prize pool, losing pool => 50% protocol / 50% prize pool.
    // Outcome token fees: sent to the burn address immediately on collection
    uint256 public yesUsdcFeesAccrued;
    uint256 public noUsdcFeesAccrued;
    uint256 public retainedProtocolFeeUSDC;
    uint256 public waivedProtocolFeeUSDC;
    uint256 public burnedYesTokenFees;
    uint256 public burnedNoTokenFees;

    // Events
    event PoolsInitialized(bytes32 yesKeyHash, bytes32 noKeyHash);
    event MarketResolved(bool outcomeYes, uint256 resolvedBlock, uint256 prizePoolUSDC);
    event ProtocolFeeSettled(uint256 retainedProtocolFeeUSDC, uint256 waivedProtocolFeeUSDC);
    event ClaimsOpened(address indexed winningToken, uint256 claimableWinningSupply, uint256 prizePoolUSDC);
    event Claimed(address indexed claimant, uint256 winningTokenAmount, uint256 payoutUSDC);
    event PrizePoolSwept(uint256 amount);
    event OutcomeTokenFeesBurned(address indexed token, uint256 amount);

    // Errors
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
        marketQuestion = marketQuestion_;
        marketNotes = marketNotes_;

        // Deploy outcome tokens; minted to this market contract
        yesToken = new OutcomeToken(address(this), "Fortune Market YES", "YES", tokenSupplyEach);
        noToken = new OutcomeToken(address(this), "Fortune Market NO", "NO", tokenSupplyEach);

        // Build pool keys now (sorting by address)
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
        // Determine ordering for PoolKey
        Currency cToken = Currency.wrap(token);
        Currency cUsdc = Currency.wrap(address(usdc));

        (Currency c0, Currency c1) = token < address(usdc) ? (cToken, cUsdc) : (cUsdc, cToken);

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: lpFeePpm,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        keyHash_ = hook.keyHash(key);

        // Choose tick bounds based on whether token is currency0
        if (token < address(usdc)) {
            tickLower_ = ticks_token0.lower;
            tickUpper_ = ticks_token0.upper;
        } else {
            tickLower_ = ticks_token1.lower;
            tickUpper_ = ticks_token1.upper;
        }

        if (tickLower_ >= tickUpper_) revert BadTicks();
    }

    /// @notice Called by factory as part of createMarket() TX.
    /// @dev Factory must have already registered yesKeyHash/noKeyHash in the hook.
    function initializePoolsAndLiquidity() external onlyFactory nonReentrant {
        if (state != State.Created) revert BadState();

        // Initialize pools at edge for single-sided liquidity:
        uint160 yesInitSqrt =
            TickMath.getSqrtPriceAtTick(address(yesToken) < address(usdc) ? yesTickLower : yesTickUpper);
        uint160 noInitSqrt = TickMath.getSqrtPriceAtTick(address(noToken) < address(usdc) ? noTickLower : noTickUpper);

        poolManager.initialize(yesKey, yesInitSqrt);
        poolManager.initialize(noKey, noInitSqrt);

        // Add initial liquidity for both pools in a single unlock
        poolManager.unlock(abi.encode(uint8(1))); // 1 = ADD_INITIAL

        state = State.Open;
        emit PoolsInitialized(yesKeyHash, noKeyHash);
    }

    // -------------------------
    // Resolution
    // -------------------------

    /// @notice Resolve the market outcome.
    /// @param outcomeYes_ True to resolve YES, false to resolve NO.
    function resolve(bool outcomeYes_) external onlyResolver nonReentrant {
        if (state != State.Open) revert NotOpen();
        _resolve(outcomeYes_);
    }

    function _resolve(bool outcomeYes_) internal {
        // Close swaps immediately at hook level
        hook.closePool(yesKeyHash);
        hook.closePool(noKeyHash);

        // Collect fees, split, remove liquidity into prize pool
        poolManager.unlock(abi.encode(uint8(2))); // 2 = CLOSE_AND_COLLECT

        // Burn any remaining inventory outcome tokens held by this contract.
        // Collected fee tokens have already been sent to the burn address.
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

        // Prize pool keeps all remaining USDC after only the losing pool's protocol share is retained.
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

    /// @notice Returns the current winning token supply still entitled to claim USDC.
    function claimableWinningSupply() public view returns (uint256) {
        OutcomeToken token = winningToken;
        if (address(token) == address(0)) return 0;

        uint256 totalSupply = token.totalSupply();
        uint256 burnedBalance = token.balanceOf(BURN_ADDRESS);
        uint256 marketBalance = token.balanceOf(address(this));
        uint256 poolManagerBalance = token.balanceOf(address(poolManager));

        return totalSupply - burnedBalance - marketBalance - poolManagerBalance;
    }

    /// @notice Preview the USDC payout for a winning token amount at current claim ratios.
    function previewClaim(uint256 winningTokenAmount) public view returns (uint256) {
        if (state != State.Resolved) revert ClaimsClosed();
        return _previewClaim(winningTokenAmount);
    }

    /// @notice Claim USDC by transferring winning outcome tokens into the market for burning.
    /// @param winningTokenAmount The amount of winning tokens to redeem.
    function claim(uint256 winningTokenAmount) external nonReentrant {
        if (state != State.Resolved) revert ClaimsClosed();
        _claim(msg.sender, winningTokenAmount);
    }

    /// @notice Claim using the caller's full winning token balance.
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
    // -------------------------
    // Uniswap v4 unlock callback
    // -------------------------

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
        // YES pool
        yesLiquidity = _addSingleSided(
            yesKey,
            yesTickLower,
            yesTickUpper,
            YES_SALT,
            address(yesToken),
            IERC20(address(yesToken)).balanceOf(address(this))
        );

        // NO pool
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

        bool tokenIs0 = (token < address(usdc));

        // Liquidity math per canonical library
        liquidityOut = tokenIs0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, tokenAmount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, tokenAmount);

        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityOut)),
            salt: salt
        });

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(key, p, "");

        // Settle deltas: negative means we owe the pool; positive means pool owes us
        _settleCallerDelta(key, callerDelta, tokenIs0);
    }

    function _closeAndCollect() internal {
        // 1) Collect fees (liquidityDelta = 0) for both positions, split fees, then
        // 2) Remove full liquidity for both positions.

        _collectFeesAndSplit(yesKey, yesTickLower, yesTickUpper, YES_SALT, true);
        _collectFeesAndSplit(noKey, noTickLower, noTickUpper, NO_SALT, false);

        _removeAllLiquidity(yesKey, yesTickLower, yesTickUpper, YES_SALT, yesLiquidity);
        _removeAllLiquidity(noKey, noTickLower, noTickUpper, NO_SALT, noLiquidity);

        // zero out
        yesLiquidity = 0;
        noLiquidity = 0;
    }

    function _collectFeesAndSplit(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt, bool isYesPool)
        internal
    {
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: salt});

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, p, "");

        // Take what we're owed (fees) from the PoolManager
        _takePositiveDelta(key, callerDelta);

        // Determine which currency is USDC and which is the outcome token
        address currency0Addr = Currency.unwrap(key.currency0);

        int128 f0 = BalanceDeltaLibrary.amount0(feesAccrued);
        int128 f1 = BalanceDeltaLibrary.amount1(feesAccrued);

        bool usdcIs0 = (currency0Addr == address(usdc));

        // USDC fees remain in the contract until resolution decides which side lost.
        // Outcome token fees: sent to the burn address immediately on collection

        if (usdcIs0) {
            // currency0 = USDC, currency1 = outcome token
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
            // currency0 = outcome token, currency1 = USDC
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
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(uint256(liq)),
            salt: salt
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
        // For initial single-sided adds: we expect to only owe the outcome token, not USDC.
        int128 a0 = BalanceDeltaLibrary.amount0(d);
        int128 a1 = BalanceDeltaLibrary.amount1(d);

        // If we owe currency0 (negative), settle it.
        if (a0 < 0) {
            _settleCurrency(key.currency0, uint256(uint128(-a0)));
        }
        // If we owe currency1 (negative), settle it.
        if (a1 < 0) {
            _settleCurrency(key.currency1, uint256(uint128(-a1)));
        }

        // Enforce "no USDC needed at launch" by requiring the owed side is the token side only.
        // tokenIs0 => currency1 is USDC; tokenIs0==false => currency0 is USDC
        if (state == State.Created) {
            if (tokenIs0) {
                if (a1 < 0) revert UsdcRequired();
            } else {
                if (a0 < 0) revert UsdcRequired();
            }
        }

        // Take any positives (should generally be 0 on mint)
        _takePositiveDelta(key, d);
    }

    /// @dev Settle a currency debt to the PoolManager
    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        // Sync and transfer
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }
}

/// @title OutcomeToken
/// @notice Minimal fixed-supply ERC20 outcome token for prediction markets.
/// @dev Minted once to the market contract. Market may burn its own inventory post-resolution.
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

/// @title FortuneMarketHook
/// @notice Singleton hook used by all Fortune Market pools on Uniswap v4.
/// @dev Enforces: only registered market can initialize + add/remove liquidity; swaps optionally frozen after close.
contract FortuneMarketHook is BaseHook {
    address public factory;
    address public immutable owner;

    struct PoolPolicy {
        address market;
        int24 tickLower;
        int24 tickUpper;
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

    function registerPool(bytes32 keyHash_, address market_, int24 tickLower_, int24 tickUpper_) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (policy[keyHash_].market != address(0)) revert AlreadyRegistered();
        if (market_ == address(0)) revert BadMarket();
        if (tickLower_ >= tickUpper_) revert BadTicks();

        policy[keyHash_] = PoolPolicy({
            market: market_,
            tickLower: tickLower_,
            tickUpper: tickUpper_,
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

    function _afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
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

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolPolicy storage p = policy[keyHash(key)];
        if (p.closed) revert PoolClosed_();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @title FortuneMarketFactory
/// @notice Factory contract for deploying Fortune Market markets.
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
            ticks_token0,
            ticks_token1,
            marketQuestion,
            marketNotes
        );

        hook.registerPool(m.yesKeyHash(), address(m), m.yesTickLower(), m.yesTickUpper());
        hook.registerPool(m.noKeyHash(), address(m), m.noTickLower(), m.noTickUpper());
        m.initializePoolsAndLiquidity();

        markets.push(address(m));

        emit MarketCreated(address(m), address(m.yesToken()), address(m.noToken()), msg.sender);
        return address(m);
    }

    function getMarketsCount() external view returns (uint256) {
        return markets.length;
    }
}

/// @title Create2Deployer
/// @notice Helper contract for deploying contracts using CREATE2 with deterministic addresses.
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
