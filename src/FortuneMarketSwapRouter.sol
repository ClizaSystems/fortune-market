// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

/// @notice Minimal exact-input swap helper for Fortune Market smoke tests.
contract FortuneMarketSwapRouter is IUnlockCallback, DeltaResolver {
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    error OnlyPoolManager();
    error AmountInZero();

    struct CallbackData {
        address payer;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    constructor(IPoolManager poolManager_) ImmutableState(poolManager_) {}

    function swapExactInput(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external returns (int128 amount0Delta, int128 amount1Delta) {
        if (amountIn == 0) revert AmountInZero();

        BalanceDelta delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender,
                        key: key,
                        zeroForOne: zeroForOne,
                        amountIn: amountIn,
                        sqrtPriceLimitX96: sqrtPriceLimitX96,
                        hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );

        amount0Delta = delta.amount0();
        amount1Delta = delta.amount1();
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        (Currency inputCurrency, Currency outputCurrency) =
            data.zeroForOne ? (data.key.currency0, data.key.currency1) : (data.key.currency1, data.key.currency0);

        _settle(inputCurrency, data.payer, data.amountIn);
        uint256 availableInput = _getFullCredit(inputCurrency);

        BalanceDelta delta = poolManager.swap(
            data.key,
            SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(availableInput),
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            data.hookData
        );

        _take(outputCurrency, data.payer, _getFullCredit(outputCurrency));
        return abi.encode(delta);
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override {
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
    }
}
