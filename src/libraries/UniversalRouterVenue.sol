// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
// The universal router is v4-periphery's client, so its `PoolKey` pin is the one `IV4Router` types
// against — building the key from this import avoids the abi round-trip `LivoUniv4BuyBacks` needs for
// the canonical `lib/v4-core` key it gets from `UniswapV4PoolConstants`.
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// @title UniversalRouterVenue
/// @notice Native -> ERC20 swaps on Uniswap V3 and V4, both through the universal router. The V2 leg of
///         the same job lives in `UniswapV2Venue`, which talks to the V2 router directly.
/// @dev ETH-family only: both helpers pay with `msg.value`. A chain whose native currency is an ERC20
///      (Arc) has no counterpart here, which is why `DividendDistribution` refuses a third-asset leg
///      there rather than configuring one that could never convert.
/// @dev Every helper returns `false` instead of reverting when the swap fails. A dividend leg whose pool
///      dies must not take the token's other legs down with it — see `DividendDistribution._freezeLeg`.
/// @dev All functions are `internal` so they inline into the caller's bytecode (no deployed library);
///      `address(this)` inside them is therefore the calling token.
library UniversalRouterVenue {
    /// @notice Universal-router command bytes. `WRAP_ETH` funds the router itself before a V3 swap,
    ///         which — unlike V4 — cannot take native ETH.
    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant WRAP_ETH = 0x0b;
    uint8 internal constant V4_SWAP = 0x10;

    /// @notice The universal router's "the router itself" recipient sentinel (`Constants.ADDRESS_THIS`).
    address internal constant ROUTER_ITSELF = address(2);

    /// @notice Buys `asset` on the V3 pool of the `quote`/`asset` pair with fee tier `fee`, delivering it
    ///         to `address(this)`.
    /// @param minOut minimum output in the ASSET's own decimals.
    /// @return ok false if the swap reverted (dead pool, slippage floor missed, unknown fee tier).
    function swapNativeToAssetV3(
        address router,
        address quote,
        address asset,
        uint24 fee,
        uint256 nativeIn,
        uint256 minOut
    ) internal returns (bool ok) {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ROUTER_ITSELF, nativeIn);
        // `payerIsUser = false`: the router pays with the WETH the first command just wrapped for it.
        inputs[1] = abi.encode(address(this), nativeIn, minOut, abi.encodePacked(quote, fee, asset), false);

        (ok,) = router.call{value: nativeIn}(
            abi.encodeCall(
                IUniversalRouter.execute, (abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN), inputs, block.timestamp)
            )
        );
    }

    /// @notice Buys `asset` on the V4 pool keyed by `(native, asset, fee, tickSpacing, hooks)`, delivering
    ///         it to `address(this)`. Native ETH is `address(0)`, which sorts below every asset, so the
    ///         pool is always native -> asset in `currency0 -> currency1` order.
    /// @param minOut minimum output in the ASSET's own decimals.
    /// @return ok false if the swap reverted (uninitialized pool, slippage floor missed, reverting hook).
    function swapNativeToAssetV4(
        address router,
        address asset,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 nativeIn,
        uint256 minOut
    ) internal returns (bool ok) {
        // The router's params are `uint128`. `nativeIn` is capped far below that by the freeze cap, but
        // `minOut` comes from whoever called `processDividends`: truncating it would SILENTLY weaken the
        // floor they asked for, so an unrepresentable one fails the swap instead.
        if (minOut > type(uint128).max || nativeIn > type(uint128).max) return false;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(asset),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true, // native (currency0) -> asset (currency1)
                amountIn: uint128(nativeIn),
                amountOutMinimum: uint128(minOut),
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, nativeIn); // SETTLE_ALL the native in
        params[2] = abi.encode(key.currency1, minOut); // TAKE_ALL the asset to this contract

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            params
        );

        (ok,) = router.call{value: nativeIn}(
            abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(V4_SWAP), inputs, block.timestamp))
        );
    }
}
