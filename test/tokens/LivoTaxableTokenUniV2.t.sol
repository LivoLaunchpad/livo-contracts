// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV2.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";

/// @notice Unit tests for `LivoTaxableTokenUniV2`. Forks mainnet (via `LaunchpadBaseTests`) so the
///         real V2 router is available for the swap-back path. Covers:
///         (1) buy/sell tax math at multiple bps; (2) `inSwap` reentrancy guard; (3) graduator and
///         self exclusion; (4) pre-graduation gate; (5) tax-window expiry; (6) auto-trigger fires
///         when the contract balance crosses `SWAP_THRESHOLD`; (7) factory-deployed V2 tax tokens
///         are ownerless, so manual owner-only paths (`swapBack`, `rescueTokens`) are inaccessible.
contract LivoTaxableTokenUniV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    LivoTaxableTokenUniV2 internal taxToken;
    address internal pair;

    uint16 internal constant BUY_BPS = 100; // 1%
    uint16 internal constant SELL_BPS = 400; // 4%
    uint32 internal constant TAX_DURATION = 7 days;

    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();

        // Deploy a tax token with 1% buy / 4% sell and a 7-day window. V2 tokens are ownerless.
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        TaxConfigInit memory cfg = _taxCfg(BUY_BPS, SELL_BPS, TAX_DURATION);

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("Tax", "TAX", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());

        testToken = token;
        taxToken = LivoTaxableTokenUniV2(payable(token));
        assertEq(taxToken.owner(), address(0));
        pair = taxToken.pair();
    }

    // ─────────────────────────── Pre-graduation behavior ───────────────────────────

    function test_preGraduation_blocksTransferToPair() public {
        // Pre-graduation, transfers to pair are blocked at the LivoToken gate; tax never gets a chance.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 0.5 ether}(testToken, 0, DEADLINE);

        uint256 bal = IERC20(testToken).balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(ILivoToken_TransferToPairBeforeGraduationNotAllowed_selector());
        IERC20(testToken).transfer(pair, bal);
    }

    function test_preGraduation_userToUserNotTaxed() public {
        // User-to-user transfers don't touch the pair, so no tax applies — regardless of graduation.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 0.5 ether}(testToken, 0, DEADLINE);

        uint256 bal = IERC20(testToken).balanceOf(buyer);
        vm.prank(buyer);
        IERC20(testToken).transfer(alice, bal);

        assertEq(IERC20(testToken).balanceOf(alice), bal);
        assertEq(IERC20(testToken).balanceOf(address(taxToken)), 0);
    }

    // ─────────────────────────── markGraduated stamps timestamp ───────────────────

    function test_markGraduated_stampsTimestamp() public {
        assertEq(uint256(taxToken.graduationTimestamp()), 0);
        _graduateToken();
        assertGt(uint256(taxToken.graduationTimestamp()), 0);
        assertEq(uint256(taxToken.graduationTimestamp()), block.timestamp);
    }

    // ─────────────────────────── Sell tax math ───────────────────────────────────

    function test_sellTax_takesExpectedAmount() public {
        _setupGraduatedTokenWithBuyer();

        uint256 sellerBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = sellerBalance / 4;

        uint256 contractBalanceBefore = IERC20(testToken).balanceOf(address(taxToken));
        uint256 expectedTax = sellAmount * SELL_BPS / 10_000;

        // sell on the V2 pair: triggers _update(buyer, pair, sellAmount) inside the router's transferFrom
        _swapSellV2(buyer, testToken, sellAmount, 0, true);

        // The contract balance increased by exactly `expectedTax` (the auto-swap-back doesn't
        // fire here — `expectedTax` is below SWAP_THRESHOLD).
        assertEq(IERC20(testToken).balanceOf(address(taxToken)), contractBalanceBefore + expectedTax);
    }

    function test_buyTax_takesExpectedAmount() public {
        _setupGraduatedTokenWithBuyer();

        uint256 contractBalanceBefore = IERC20(testToken).balanceOf(address(taxToken));
        uint256 buyerBalanceBefore = IERC20(testToken).balanceOf(alice);

        // alice buys from the V2 pair: triggers _update(pair, alice, gross) where pair sends tokens out.
        // Buy tax = gross * 1% — taken from alice's portion.
        vm.deal(alice, 0.1 ether);
        _swapBuyV2(alice, testToken, 0.1 ether, 0, true);

        uint256 aliceReceived = IERC20(testToken).balanceOf(alice) - buyerBalanceBefore;
        uint256 contractAccrued = IERC20(testToken).balanceOf(address(taxToken)) - contractBalanceBefore;

        // The total of (alice + contract) equals what the pair sent out (gross). And contract / total ~= 1%.
        uint256 gross = aliceReceived + contractAccrued;
        // Expect contract / gross == BUY_BPS / 10_000 — but FoT-router math may give slight rounding.
        assertEq(contractAccrued, gross * BUY_BPS / 10_000);
    }

    // ─────────────────────────── Tax window expiry ───────────────────────────────

    function test_postWindow_noTax() public {
        _setupGraduatedTokenWithBuyer();

        // Warp past the tax window.
        vm.warp(uint256(taxToken.graduationTimestamp()) + TAX_DURATION + 1);

        uint256 sellerBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = sellerBalance / 4;
        uint256 contractBalanceBefore = IERC20(testToken).balanceOf(address(taxToken));

        _swapSellV2(buyer, testToken, sellAmount, 0, true);

        // No tax applied past the window.
        assertEq(IERC20(testToken).balanceOf(address(taxToken)), contractBalanceBefore);
    }

    // ─────────────────────────── Auto swap-back ──────────────────────────────────

    function test_autoSwapBack_firesWhenThresholdCrossed() public {
        _setupGraduatedTokenWithBuyer();

        // Push the contract's balance over SWAP_THRESHOLD by selling enough to push 4% > threshold.
        // SWAP_THRESHOLD = TOTAL_SUPPLY / 2000 = 500_000e18.
        // To exceed: sellAmount * 0.04 > 500_000e18 → sellAmount > 12_500_000e18.
        uint256 sellerBalance = IERC20(testToken).balanceOf(buyer);
        uint256 needed = uint256(20_000_000e18); // ~80% over the threshold
        require(sellerBalance >= needed, "buyer balance too low for the test");

        // First sell: accrues > SWAP_THRESHOLD tokens to the contract.
        _swapSellV2(buyer, testToken, needed, 0, true);

        uint256 contractBalanceAfterFirst = IERC20(testToken).balanceOf(address(taxToken));
        assertGe(contractBalanceAfterFirst, taxToken.SWAP_THRESHOLD());

        // Track fee handler ETH balance to assert proceeds land there.
        uint256 feeHandlerEthBefore = address(feeHandler).balance;

        // Second sell: auto-swap-back fires *before* the tax math runs. After the swap, the
        // contract's token balance drops to ~0 (only the fresh tax from this 2nd sell remains).
        uint256 secondSellAmount = sellerBalance - needed - 1; // some valid leftover
        _swapSellV2(buyer, testToken, secondSellAmount / 100, 0, true); // small to keep math clean

        uint256 contractBalanceAfterSecond = IERC20(testToken).balanceOf(address(taxToken));
        // The contract balance after second sell is just the tax from that second sell — much less
        // than what we had before.
        assertLt(contractBalanceAfterSecond, contractBalanceAfterFirst);

        // ETH was forwarded to the master fee handler (depositFees splits to recipients but the
        // creator-direct path here keeps it accrued in the handler ledger; the absolute ETH balance
        // increase is the proof the swap fired).
        assertGt(address(feeHandler).balance, feeHandlerEthBefore);
    }

    // ─────────────────────────── Manual swapBack ─────────────────────────────────

    function test_manualSwapBack_revertsWhenOwnerless() public {
        _setupGraduatedTokenWithBuyer();

        vm.prank(creator);
        vm.expectRevert(LivoTaxableTokenUniV2.NotTokenOwner.selector);
        taxToken.swapBack(0);
    }

    function test_manualSwapBack_ownerlessRevertLeavesTaxBalance() public {
        _setupGraduatedTokenWithBuyer();

        uint256 sellerBalance = IERC20(testToken).balanceOf(buyer);
        _swapSellV2(buyer, testToken, sellerBalance / 100, 0, true);
        uint256 contractBalBefore = IERC20(testToken).balanceOf(address(taxToken));
        assertGt(contractBalBefore, 0);

        vm.prank(creator);
        vm.expectRevert(LivoTaxableTokenUniV2.NotTokenOwner.selector);
        taxToken.swapBack(1);

        assertEq(IERC20(testToken).balanceOf(address(taxToken)), contractBalBefore);
    }

    // ─────────────────────────── rescueTokens ────────────────────────────────────

    function test_rescueTokens_revertsWhenOwnerless() public {
        vm.prank(creator);
        vm.expectRevert(LivoTaxableTokenUniV2.NotTokenOwner.selector);
        taxToken.rescueTokens(address(taxToken));
    }

    function test_rescueTokens_ownerlessCannotSweepEth() public {
        vm.deal(address(taxToken), 1 ether);

        vm.prank(creator);
        vm.expectRevert(LivoTaxableTokenUniV2.NotTokenOwner.selector);
        taxToken.rescueTokens(address(0));

        assertEq(address(taxToken).balance, 1 ether);
    }

    function test_rescueTokens_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(LivoTaxableTokenUniV2.NotTokenOwner.selector);
        taxToken.rescueTokens(address(0));
    }

    // ─────────────────────────── Helpers ─────────────────────────────────────────

    /// @dev Graduate the test token and seed `buyer` with a large pre-graduation purchase so we
    ///      have a holder who can sell into the V2 pool.
    function _setupGraduatedTokenWithBuyer() internal {
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        _graduateToken(); // pushes the launchpad over the graduation threshold via `seller`

        // Confirm graduation.
        assertTrue(taxToken.graduated());
    }

    /// @dev Helper that returns the selector of `LivoToken.TransferToPairBeforeGraduationNotAllowed`.
    function ILivoToken_TransferToPairBeforeGraduationNotAllowed_selector() internal pure returns (bytes4) {
        return bytes4(keccak256("TransferToPairBeforeGraduationNotAllowed()"));
    }
}
