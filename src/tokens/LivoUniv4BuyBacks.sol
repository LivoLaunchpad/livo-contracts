// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// this line below can be adjusted to import the Sepolia addresses when deploying in sepolia
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

    /// @dev Buys this token with `ethIn` native ETH on the pool `(ETH, this, LP_FEE, TICK_SPACING,
    ///      hook)`, requiring at least `minTokensOut` (reverts on slippage). Tokens are TAKEn to this
    ///      contract. The pool key mirrors `LivoGraduatorUniswapV4._getPoolKey` exactly, so the swap
    ///      always hits the token's real graduated pool.
    /// @dev The swap routes through `LivoSwapHook`, which charges the usual LP fee (and, inside the tax
    ///      window, tax). Callers must guard against reentrancy from those hooks themselves.
    function _buyBackTokensWithEth(address hook, uint256 ethIn, uint256 minTokensOut) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(this)),
            fee: UniswapV4PoolConstants.LP_FEE,
            tickSpacing: UniswapV4PoolConstants.TICK_SPACING,
            hooks: IHooks(hook)
        });

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
