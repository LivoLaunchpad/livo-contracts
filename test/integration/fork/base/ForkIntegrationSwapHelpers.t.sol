// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

import {ForkIntegrationBase} from "test/integration/fork/base/ForkIntegrationBase.t.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

interface IUniV2RouterSwapFork {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @notice Chain-neutral post-graduation Uniswap swap helpers for fork integration tests.
abstract contract ForkIntegrationSwapHelpers is ForkIntegrationBase {
    function _swapBuyV2(address caller, address token, uint256 ethIn, uint256 minOut) internal {
        address[] memory path = new address[](2);
        path[0] = forkCfg.weth;
        path[1] = token;

        vm.prank(caller);
        IUniV2RouterSwapFork(forkCfg.uniV2Router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            minOut, path, caller, block.timestamp
        );
    }

    function _swapSellV2(address caller, address token, uint256 tokenIn, uint256 minEth)
        internal
        returns (uint256 ethReceived)
    {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = forkCfg.weth;

        uint256 beforeBal = caller.balance;
        vm.startPrank(caller);
        IERC20(token).approve(forkCfg.uniV2Router, type(uint256).max);
        IUniV2RouterSwapFork(forkCfg.uniV2Router)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(tokenIn, minEth, path, caller, block.timestamp);
        vm.stopPrank();
        ethReceived = caller.balance - beforeBal;
    }

    function _v4PoolKey(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: UniswapV4PoolConstants.LP_FEE,
            tickSpacing: UniswapV4PoolConstants.TICK_SPACING,
            hooks: IHooks(forkCfg.uniV4Hook)
        });
    }

    function _swapBuyV4(address caller, address token, uint256 ethIn, uint256 minOut) internal {
        _swapV4(caller, token, ethIn, minOut, true);
    }

    function _swapSellV4(address caller, address token, uint256 tokenIn, uint256 minEth)
        internal
        returns (uint256 ethReceived)
    {
        uint256 beforeBal = caller.balance;
        _swapV4(caller, token, tokenIn, minEth, false);
        ethReceived = caller.balance - beforeBal;
    }

    function _swapV4(address caller, address token, uint256 amountIn, uint256 minOut, bool isBuy) internal {
        vm.startPrank(caller);
        IERC20(token).approve(forkCfg.permit2, type(uint256).max);
        IPermit2(forkCfg.permit2).approve(token, forkCfg.uniV4UniversalRouter, type(uint160).max, type(uint48).max);

        PoolKey memory key = _v4PoolKey(token);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: isBuy,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                hookData: bytes("")
            })
        );

        Currency tokenIn = isBuy ? key.currency0 : key.currency1;
        params[1] = abi.encode(tokenIn, amountIn);
        Currency tokenOut = isBuy ? key.currency1 : key.currency0;
        params[2] = abi.encode(tokenOut, minOut);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes memory commands = abi.encodePacked(uint8(0x10)); // V4_SWAP
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 valueIn = isBuy ? amountIn : 0;
        IUniversalRouter(forkCfg.uniV4UniversalRouter).execute{value: valueIn}(commands, inputs, block.timestamp);
        vm.stopPrank();
    }
}
