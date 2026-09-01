// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// @notice Minimal surface the graduator and taxable tokens call to add single-sided ETH liquidity.
interface ILivoUniV4LiquidityAdder {
    function addSingleSidedEth(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity);

    function addSingleSidedEthBelowPrice(
        PoolKey calldata key,
        int24 tickWidth,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity);
}

/// @title LivoUniV4LiquidityAdder
/// @notice Permissionless, stateless helper that turns native ETH into a SINGLE-SIDED ETH Uniswap-V4
///         liquidity position — a protective bid wall placed just below the current price. The pair is
///         `(currency0, currency1) = (ETH, token)`, so an ETH-only position lives at ticks ABOVE the
///         current tick (= below the current price in ETH/token terms); as the token price falls, that
///         ETH is progressively spent buying the token, cushioning the drop. No token custody, no swaps,
///         no approvals: only native ETH is settled, so anyone may call it for any pool.
/// @dev Shared by `LivoGraduatorUniswapV4` (its secondary graduation position) and the taxable tokens'
///      liquidity earnings leg (`processLiquidity`). Holds no funds between calls: the minted NFT goes to
///      `nftReceiver` and any dust ETH is swept to `excessEthReceiver` within the same call. The position
///      NFT is never withdrawable here, so wherever the caller points it the liquidity is permanent pool
///      depth.
/// @dev The `SWEEP` action sends the POSITION MANAGER's whole native balance to `excessEthReceiver`, not
///      just this call's rounding dust. That is not a drain primitive this contract creates: v4's
///      `PositionManager.modifyLiquidities` is itself permissionless and `SWEEP` is reachable through it
///      directly, so anyone can already claim anything the POSM holds — which is nothing, by design: it
///      settles every delta inside the unlock and holds no native across transactions. Sweeping "all"
///      rather than "mine" is the only shape v4 offers, and the two are the same amount here.
contract LivoUniV4LiquidityAdder is ILivoUniV4LiquidityAdder {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Uniswap V4 position manager that mints the liquidity positions.
    IPositionManager public immutable UNIV4_POSITION_MANAGER;

    /// @notice Uniswap V4 pool manager, read for the pool's current tick.
    IPoolManager public immutable UNIV4_POOL_MANAGER;

    /// @notice Thrown when called with no ETH — there is nothing to deposit.
    error NoEthProvided();
    /// @notice Thrown when the requested tick width is not strictly positive.
    error InvalidTickWidth();
    /// @notice Thrown by `addSingleSidedEthBelowPrice` when the current tick is so close to `MAX_TICK`
    ///         (token price collapsed to the absolute tick boundary, ~1e-39 native per token) that no
    ///         spacing-aligned range fits above it. Reverting leaves the caller's ETH with the caller.
    error WallOutOfRange();
    /// @notice Thrown when `msg.value` sized to no liquidity and returning it to `excessEthReceiver`
    ///         failed. Only reachable from a receiver that rejects native.
    error EthReturnFailed();

    constructor(address positionManager, address poolManager) {
        UNIV4_POSITION_MANAGER = IPositionManager(positionManager);
        UNIV4_POOL_MANAGER = IPoolManager(poolManager);
    }

    /// @inheritdoc ILivoUniV4LiquidityAdder
    /// @dev `[tickLower, tickUpper]` MUST sit entirely above the pool's current tick, otherwise the
    ///      position would require token1 (the token) that this call does not settle and the mint
    ///      reverts. Sizes the position from all of `msg.value`.
    function addSingleSidedEth(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity) {
        require(msg.value > 0, NoEthProvided());
        liquidity = _mintSingleSidedEth(key, tickLower, tickUpper, nftReceiver, excessEthReceiver);
    }

    /// @inheritdoc ILivoUniV4LiquidityAdder
    /// @dev Reads the pool's current tick and places the wall in
    ///      `[snapUp(tick + 1), snapUp(tick + 1) + tickWidth]` — starting just below the current price and
    ///      spanning `tickWidth` ticks further down in price. A percentage drop maps to a CONSTANT
    ///      `tickWidth` (ticks are log-price), so callers pass a fixed, spacing-aligned width. The lower
    ///      bound is snapped strictly above the current tick so the whole range stays ETH-only.
    function addSingleSidedEthBelowPrice(
        PoolKey calldata key,
        int24 tickWidth,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity) {
        require(msg.value > 0, NoEthProvided());
        require(tickWidth > 0, InvalidTickWidth());
        (, int24 currentTick,,) = UNIV4_POOL_MANAGER.getSlot0(key.toId());
        int24 tickLower = _ceilToSpacing(currentTick + 1, key.tickSpacing);
        // Clamp the top to the highest spacing-aligned tick: a deeply depreciated pool (current tick
        // within `tickWidth` of MAX_TICK) gets a narrower wall instead of a TickMath revert.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 maxUsableTick = (TickMath.MAX_TICK / key.tickSpacing) * key.tickSpacing;
        int24 tickUpper = tickLower + tickWidth;
        if (tickUpper > maxUsableTick) tickUpper = maxUsableTick;
        require(tickLower < tickUpper, WallOutOfRange());
        liquidity = _mintSingleSidedEth(key, tickLower, tickUpper, nftReceiver, excessEthReceiver);
    }

    /// @dev Sizes single-sided-ETH liquidity for `[tickLower, tickUpper]` from `msg.value` and mints it via
    ///      the position manager, sending the NFT to `nftReceiver` and sweeping any leftover ETH to
    ///      `excessEthReceiver`. Mirrors `LivoGraduatorUniswapV4._addLiquidity` for the ETH-only case (the
    ///      `amount1` bound is 0, and the SWEEP returns the rounding dust rather than leaving it stuck).
    function _mintSingleSidedEth(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessEthReceiver
    ) internal returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), msg.value
        );

        // Dust that sizes to nothing goes straight back: v4-core's `Position.update` reverts
        // `CannotUpdateEmptyPosition` on a zero `liquidityDelta`, and a graduation whose secondary
        // position is pure rounding remainder must not take the whole graduation down with it.
        if (liquidity == 0) {
            (bool returned,) = excessEthReceiver.call{value: msg.value}("");
            require(returned, EthReturnFailed());
            return 0;
        }

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        // MINT_POSITION: amount0Max = msg.value (slippage cap), amount1Max = 0 (ETH-only).
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, msg.value, uint256(0), nftReceiver, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1); // SETTLE_PAIR
        params[2] = abi.encode(key.currency0, excessEthReceiver); // SWEEP native ETH dust

        UNIV4_POSITION_MANAGER.modifyLiquidities{value: msg.value}(abi.encode(actions, params), block.timestamp);
    }

    /// @dev Smallest multiple of `spacing` that is `>= tick`. Solidity `%` keeps the dividend's sign, so a
    ///      positive remainder means truncation rounded down (positive ticks) and we bump up; a
    ///      non-positive remainder already left us at or above `tick` (exact, or negative ticks where
    ///      truncation rounds toward zero).
    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24 rounded) {
        // Floor-to-grid then correct up: the divide-before-multiply is the intent (snap to a spacing grid).
        // forge-lint: disable-next-line(divide-before-multiply)
        rounded = (tick / spacing) * spacing;
        if (tick % spacing > 0) rounded += spacing;
    }
}
