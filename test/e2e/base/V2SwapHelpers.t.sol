// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IUniV2RouterSwap {
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

/// @notice Reusable V2 swap helpers for end-to-end tests against the post-graduation Uniswap V2 pair.
/// @dev Uses the FeeOnTransfer-tolerant variants because LivoTokenSniperProtected enforces sniper
///      checks inside `_update`, which Uniswap V2's standard `swapExactETHForTokens` would treat as
///      an unexpected balance delta.
abstract contract V2SwapHelpers is LaunchpadBaseTests {
    function _swapBuyV2(address caller, address token, uint256 ethIn, uint256 minOut, bool expectSuccess) internal {
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = token;

        vm.startPrank(caller);
        if (!expectSuccess) vm.expectRevert();
        IUniV2RouterSwap(UNISWAP_V2_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            minOut, path, caller, block.timestamp
        );
        vm.stopPrank();
    }

    function _swapSellV2(address caller, address token, uint256 tokenIn, uint256 minEth, bool expectSuccess)
        internal
        returns (uint256 ethReceived)
    {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(WETH);

        uint256 before = caller.balance;

        vm.startPrank(caller);
        IERC20(token).approve(UNISWAP_V2_ROUTER, type(uint256).max);
        if (!expectSuccess) vm.expectRevert();
        IUniV2RouterSwap(UNISWAP_V2_ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(tokenIn, minEth, path, caller, block.timestamp);
        vm.stopPrank();

        if (expectSuccess) ethReceived = caller.balance - before;
    }
}
