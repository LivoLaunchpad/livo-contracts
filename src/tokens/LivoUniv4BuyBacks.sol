// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Self-aliased so the `chain-arc-*` recipes can import-swap it for the ARC pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
// The repo vendors TWO v4-core copies: lib/v4-core (used by all Livo contracts, incl.
// `UniswapV4PoolConstants.livoPoolKey`) and v4-periphery's own pin (which types `IV4Router`).
// The structs are field-identical but nominally distinct, so the canonical key is converted at
// this periphery boundary via an abi round-trip (see `_buyBackTokensWithEth`).
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode) — see the justfile `_taxtoken` recipe.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title LivoUniv4BuyBacks
/// @notice Buy-back primitive for Uniswap-V4 Livo tokens: swaps native ETH for THIS token on its own
///         V4 pool via the universal router. Bought tokens are TAKEn to this contract; the inheriting
///         token measures its own balance delta and decides what to do with them (burn, distribute, …).
/// @dev Abstract mixin with no storage. `address(this)` is the token (pool `currency1`); the pool
///      `hook` is supplied by the caller (the token reads it from its graduator). This keeps the
///      fiddly universal-router encoding in one place, reusable by every ETH→token buy-back use case
///      (burn today; dividends/liquidity later).
abstract contract LivoUniv4BuyBacks {
    /// @notice Universal router used for buy-back swaps.
    address public constant UNIV4_UNIVERSAL_ROUTER = DeploymentAddresses.UNIV4_UNIVERSAL_ROUTER;

    /// @notice Universal-router command byte selecting a V4 swap.
    uint8 internal constant V4_SWAP_COMMAND = 0x10;

    /// @dev Buys this token with `ethIn` native ETH on its canonical graduated pool
    ///      (`UniswapV4PoolConstants.livoPoolKey` — the same key the graduator initialized), requiring at
    ///      least `minTokensOut` (reverts on slippage). Tokens are TAKEn to this contract.
    /// @dev The swap routes through `LivoSwapHook`, which charges the usual LP fee (and, inside the tax
    ///      window, tax). Callers must guard against reentrancy from those hooks themselves.
    function _buyBackTokensWithEth(address hook, uint256 ethIn, uint256 minTokensOut) internal {
        // abi round-trip converts the canonical lib/v4-core key into v4-periphery's identical PoolKey.
        PoolKey memory key = abi.decode(abi.encode(UniswapV4PoolConstants.livoPoolKey(address(this), hook)), (PoolKey));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true, // ETH (currency0) -> token (currency1)
                amountIn: uint128(ethIn),
                amountOutMinimum: uint128(minTokensOut),
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, ethIn); // SETTLE_ALL native ETH
        params[2] = abi.encode(key.currency1, minTokensOut); // TAKE_ALL token to this contract

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        IUniversalRouter(UNIV4_UNIVERSAL_ROUTER).execute{value: ethIn}(
            abi.encodePacked(V4_SWAP_COMMAND), inputs, block.timestamp
        );
    }
}
