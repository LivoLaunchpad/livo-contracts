// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";

// ───────────────────────────────────────────────────────────────────────────────
// Finding #2 — Exact-output buys on V4 hook revert (DOS of legitimate swap mode)
// ───────────────────────────────────────────────────────────────────────────────
//
// `LivoSwapHook._beforeSwap` reads `uint256(-params.amountSpecified)` assuming
// V4's exact-input convention (amountSpecified < 0). For exact-output buys
// (amountSpecified > 0), the unary minus on a positive int256 wraps to a value
// near `type(int256).min`, and the `uint256` cast yields ~`2^256 - amountSpecified`.
// The subsequent `grossEth * lpFeeBps` in `_computeFees` overflows uint256 and reverts.
// Every Universal-Router-routed exact-output buy on a Livo V4 pool reverts;
// exact-input buys in the same pool work fine.
contract Finding02_V4ExactOutputDOS is TaxTokenUniV4BaseTests {
    address internal user = makeAddr("user");

    function _swapExactOutputBuyV4(
        address caller,
        address token,
        uint128 amountOut,
        uint128 amountInMax,
        bool expectSuccess
    ) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(taxHook))
        });

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: true, // buy: ETH -> token
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                hookData: bytes("")
            })
        );
        // SETTLE_ALL on currency0 (ETH), TAKE_ALL on currency1 (token).
        // Any unspent ETH stays in the Universal Router — refund would require a router-level
        // SWEEP command, which is out of scope for this PoC. The cap assertion below uses
        // amountInMax loosely: the test cares about success + exact output, not refund mechanics.
        params[1] = abi.encode(key.currency0, amountInMax);
        params[2] = abi.encode(key.currency1, amountOut);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes memory commands = abi.encodePacked(uint8(0x10)); // V4_SWAP
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.prank(caller);
        if (!expectSuccess) vm.expectRevert();
        IUniversalRouter(universalRouter).execute{value: amountInMax}(commands, inputs, block.timestamp);
    }

    /// @notice Asserts that exact-output buys on a graduated Livo V4 pool MUST
    ///         succeed and deliver the requested output. Fails on the buggy code
    ///         because `uint256(-params.amountSpecified)` underflows on positive
    ///         `amountSpecified` (exact-output) and the subsequent
    ///         `grossEth * lpFeeBps` overflows uint256; passes once `_beforeSwap`
    ///         handles `amountSpecified > 0` correctly (short-circuiting to
    ///         ZERO_DELTA and charging the fee in `_afterSwap` based on the
    ///         actual `BalanceDelta`).
    function test_exactOutputBuyMustSucceedOnV4Hook() public createDefaultTaxToken {
        // Graduate so the pool is fully funded and exact-input buys are known to work.
        _graduateToken();

        // Negative control: exact-input buy succeeds against the same pool.
        deal(user, 10 ether);
        _swapBuy(user, 0.1 ether, 0, true);
        assertGt(IERC20(testToken).balanceOf(user), 0, "Sanity: exact-input buy must work");

        uint256 balBefore = IERC20(testToken).balanceOf(user);

        // Request exactly `wantTokens` out, willing to pay up to `ethCap`.
        uint128 wantTokens = uint128(1e18);
        uint128 ethCap = uint128(1 ether);

        _swapExactOutputBuyV4(user, testToken, wantTokens, ethCap, true);

        // On a working hook, the user receives exactly `wantTokens`.
        assertEq(
            IERC20(testToken).balanceOf(user) - balBefore, wantTokens, "User must receive exactly the requested output"
        );
    }
}
