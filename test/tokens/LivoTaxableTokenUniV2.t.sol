// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
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

    function test_pairMatchesUniV2FactoryPairAfterGraduationLiquidityDeployed() public {
        address predictedPair = taxToken.pair();
        assertEq(predictedPair, pair, "cached pair mismatch");
        assertEq(UNISWAP_FACTORY.getPair(testToken, address(WETH)), address(0), "pair exists before graduation");
        assertEq(predictedPair.code.length, 0, "pair code exists before graduation");

        _graduateToken();

        address deployedPair = UNISWAP_FACTORY.getPair(testToken, address(WETH));
        assertEq(deployedPair, predictedPair, "token.pair must match deployed UniV2 pair");
        assertGt(deployedPair.code.length, 0, "pair contract not deployed");
        assertGt(IERC20(testToken).balanceOf(deployedPair), 0, "pair missing token liquidity");
        assertGt(WETH.balanceOf(deployedPair), 0, "pair missing WETH liquidity");
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

    function test_autoSwapBack_capsAtTwiceThreshold() public {
        _setupGraduatedTokenWithBuyer();

        uint256 cap = 2 * taxToken.SWAP_THRESHOLD();
        uint256 excess = 200_000e18;

        // Seed the contract above the cap directly. Reaching this state via a single sell would
        // require >25M tokens at the 4% rate; `deal` short-circuits the setup and the cap behavior
        // is independent of how the balance got there.
        deal(testToken, address(taxToken), cap + excess);

        uint256 feeHandlerEthBefore = address(feeHandler).balance;

        // A small sell triggers the auto-swap-back. With balance > cap, only `cap` worth of tokens
        // should be swapped — the rest carries over to the next sell.
        uint256 sellAmount = 500_000e18;
        _swapSellV2(buyer, testToken, sellAmount, 0, true);

        uint256 expectedResidual = excess + (sellAmount * SELL_BPS / 10_000);
        assertEq(
            IERC20(testToken).balanceOf(address(taxToken)),
            expectedResidual,
            "auto-swap should cap at 2*SWAP_THRESHOLD and leave the rest on the contract"
        );
        assertGt(address(feeHandler).balance, feeHandlerEthBefore);
    }

    function test_autoSwapBack_postWindowDrainsSubThresholdResidual() public {
        // Scenario: a small sell accrues a sub-threshold tax balance during the window. The window
        // then closes — no new tax will ever flow in, so the residual would normally sit forever
        // until someone manually swaps it back. Post-window, the next sell must auto-drain it.
        _setupGraduatedTokenWithBuyer();

        // Accrue a small balance — well below SWAP_THRESHOLD — so the in-window auto-trigger does
        // not fire on this first sell.
        uint256 sellerBalance = IERC20(testToken).balanceOf(buyer);
        uint256 smallSell = sellerBalance / 1000; // tax = 0.04% of seller bal → ≪ SWAP_THRESHOLD
        _swapSellV2(buyer, testToken, smallSell, 0, true);

        uint256 residual = IERC20(testToken).balanceOf(address(taxToken));
        assertGt(residual, 0, "residual should accrue during window");
        assertLt(residual, taxToken.SWAP_THRESHOLD(), "residual must be below threshold for this scenario");

        // Close the tax window.
        vm.warp(uint256(taxToken.graduationTimestamp()) + TAX_DURATION + 1);

        uint256 feeHandlerEthBefore = address(feeHandler).balance;

        // Trigger any sell post-window — the residual must be auto-drained even though it is
        // below SWAP_THRESHOLD, and the post-window sell itself accrues no fresh tax.
        _swapSellV2(buyer, testToken, smallSell, 0, true);

        assertEq(IERC20(testToken).balanceOf(address(taxToken)), 0, "sub-threshold residual must drain post-window");
        assertGt(address(feeHandler).balance, feeHandlerEthBefore, "ETH proceeds must reach the fee handler");
    }

    function test_autoSwapBack_belowCapSwapsFullBalance() public {
        _setupGraduatedTokenWithBuyer();

        uint256 cap = 2 * taxToken.SWAP_THRESHOLD();
        // Just under the cap — the whole balance should be swapped on the next sell.
        uint256 seeded = cap - 100_000e18;
        deal(testToken, address(taxToken), seeded);

        uint256 sellAmount = 500_000e18;
        _swapSellV2(buyer, testToken, sellAmount, 0, true);

        // After the swap, the contract holds only the freshly-taxed portion of this sell.
        uint256 expectedResidual = sellAmount * SELL_BPS / 10_000;
        assertEq(IERC20(testToken).balanceOf(address(taxToken)), expectedResidual);
    }

    // ─────────────────────────── Swapback per-block cap ──────────────────────────

    function test_swapbackCap_sameBlockDoubleSell_onlyOneSwapback() public {
        _setupGraduatedTokenWithBuyer();

        // Seed above `2 * SWAP_THRESHOLD` so two consecutive sells would each satisfy the
        // auto-trigger balance condition. With the per-block gate only the first swaps.
        deal(testToken, address(taxToken), 3 * taxToken.SWAP_THRESHOLD());

        uint256 sellAmount = 500_000e18;

        // First sell: auto-swap fires (lastSwapbackBlock was 0).
        vm.recordLogs();
        _swapSellV2(buyer, testToken, sellAmount, 0, true);
        assertEq(_countCreatorTaxSwapbackEvents(), 1, "first sell swaps");
        assertEq(uint256(taxToken.lastSwapbackBlock()), block.number, "block stamped on first swap");

        uint256 balanceAfterFirst = IERC20(testToken).balanceOf(address(taxToken));
        assertGe(balanceAfterFirst, taxToken.SWAP_THRESHOLD(), "residual after first swap must still trigger auto-path");

        // Second sell IN THE SAME BLOCK (no vm.roll) — auto-trigger is gated → silent skip.
        vm.recordLogs();
        _swapSellV2(buyer, testToken, sellAmount, 0, true);
        assertEq(_countCreatorTaxSwapbackEvents(), 0, "same-block second sell must NOT swap");

        uint256 balanceAfterSecond = IERC20(testToken).balanceOf(address(taxToken));
        uint256 expectedTaxFromSecondSell = sellAmount * SELL_BPS / 10_000;
        assertEq(
            balanceAfterSecond,
            balanceAfterFirst + expectedTaxFromSecondSell,
            "residual must accumulate when the per-block gate blocks the second swap"
        );
    }

    function test_swapbackCap_adjacentBlocks_bothSwap() public {
        _setupGraduatedTokenWithBuyer();

        deal(testToken, address(taxToken), 3 * taxToken.SWAP_THRESHOLD());

        uint256 sellAmount = 500_000e18;

        vm.recordLogs();
        _swapSellV2(buyer, testToken, sellAmount, 0, true);
        assertEq(_countCreatorTaxSwapbackEvents(), 1, "first sell swaps");

        uint256 stampedBlock = uint256(taxToken.lastSwapbackBlock());

        // Roll to block N+1 → gate opens, auto-trigger fires again.
        vm.roll(stampedBlock + 1);
        vm.recordLogs();
        _swapSellV2(buyer, testToken, sellAmount, 0, true);
        assertEq(_countCreatorTaxSwapbackEvents(), 1, "first sell in next block swaps again");
        assertEq(uint256(taxToken.lastSwapbackBlock()), stampedBlock + 1, "block stamp advances");
    }

    function test_swapbackCap_manualRevertsThenSucceeds() public {
        _setupGraduatedTokenWithBuyer();

        // First manual swap stamps `lastSwapbackBlock`. Use admin (launchpad owner).
        deal(testToken, address(taxToken), 1_500_000e18);
        vm.prank(admin);
        taxToken.swapBack(500_000e18, 1);
        uint256 stampedBlock = uint256(taxToken.lastSwapbackBlock());
        assertEq(stampedBlock, block.number, "first manual swap stamps block");

        // Re-seed; second manual call in the SAME block reverts.
        deal(testToken, address(taxToken), 1_500_000e18);
        vm.prank(admin);
        vm.expectRevert(LivoTaxableTokenUniV2.SwapbackAlreadyInThisBlock.selector);
        taxToken.swapBack(500_000e18, 1);

        // Roll to the next block → succeeds.
        vm.roll(stampedBlock + 1);
        uint256 feeHandlerEthBefore = address(feeHandler).balance;
        vm.prank(admin);
        taxToken.swapBack(500_000e18, 1);
        assertGt(address(feeHandler).balance, feeHandlerEthBefore, "manual swap forwards ETH in next block");
        assertEq(uint256(taxToken.lastSwapbackBlock()), stampedBlock + 1, "block stamp updated");
    }

    function test_swapbackCap_lastSwapbackBlockTracking() public {
        // Pre-graduation, no swap has ever happened.
        assertEq(uint256(taxToken.lastSwapbackBlock()), 0, "zero before any swap");

        _setupGraduatedTokenWithBuyer();
        assertEq(uint256(taxToken.lastSwapbackBlock()), 0, "still zero before any swap, even after graduation");

        // Trigger the first swap via the manual path.
        deal(testToken, address(taxToken), 1_500_000e18);
        vm.prank(admin);
        taxToken.swapBack(500_000e18, 1);

        assertEq(uint256(taxToken.lastSwapbackBlock()), block.number, "stamped to current block on success");
    }

    /// @dev Counts `CreatorTaxSwapback` event emissions in the most recent `vm.recordLogs()` window.
    function _countCreatorTaxSwapbackEvents() internal returns (uint256 count) {
        bytes32 sig = keccak256("CreatorTaxSwapback(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(taxToken) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                count++;
            }
        }
    }

    // ─────────────────────────── Manual swapBack ─────────────────────────────────

    function test_manualSwapBack_revertsWhenOwnerless() public {
        _setupGraduatedTokenWithBuyer();

        vm.prank(creator);
        vm.expectRevert(LivoTaxableToken.NotTokenOwner.selector);
        taxToken.swapBack(0, 0);
    }

    function test_manualSwapBack_ownerlessRevertLeavesTaxBalance() public {
        _setupGraduatedTokenWithBuyer();

        uint256 sellerBalance = IERC20(testToken).balanceOf(buyer);
        _swapSellV2(buyer, testToken, sellerBalance / 100, 0, true);
        uint256 contractBalBefore = IERC20(testToken).balanceOf(address(taxToken));
        assertGt(contractBalBefore, 0);

        vm.prank(creator);
        vm.expectRevert(LivoTaxableToken.NotTokenOwner.selector);
        taxToken.swapBack(contractBalBefore, 1);

        assertEq(IERC20(testToken).balanceOf(address(taxToken)), contractBalBefore);
    }

    function test_manualSwapBack_callableByLaunchpadOwner() public {
        _setupGraduatedTokenWithBuyer();

        // Accrue some tax balance via a sell.
        uint256 sellerBalance = IERC20(testToken).balanceOf(buyer);
        _swapSellV2(buyer, testToken, sellerBalance / 100, 0, true);

        uint256 contractBalBefore = IERC20(testToken).balanceOf(address(taxToken));
        assertGt(contractBalBefore, 0);
        uint256 feeHandlerEthBefore = address(feeHandler).balance;

        // launchpad.owner() (admin) is authorized even though the token itself is ownerless.
        assertEq(taxToken.owner(), address(0));
        assertEq(launchpad.owner(), admin);

        vm.prank(admin);
        taxToken.swapBack(contractBalBefore, 1);

        // Tokens drained, ETH forwarded to the master fee handler.
        assertEq(IERC20(testToken).balanceOf(address(taxToken)), 0);
        assertGt(address(feeHandler).balance, feeHandlerEthBefore);
    }

    function test_manualSwapBack_partialAmount() public {
        _setupGraduatedTokenWithBuyer();

        // Seed the contract directly so we have a known balance to partialAmountly swap.
        uint256 seeded = 1_500_000e18;
        deal(testToken, address(taxToken), seeded);
        uint256 feeHandlerEthBefore = address(feeHandler).balance;

        // launchpad owner asks the router for a partialAmount swap. The unused remainder must stay on
        // the contract (no implicit drain).
        uint256 partialAmount = 600_000e18;
        vm.prank(admin);
        taxToken.swapBack(partialAmount, 1);

        assertEq(IERC20(testToken).balanceOf(address(taxToken)), seeded - partialAmount);
        assertGt(address(feeHandler).balance, feeHandlerEthBefore);
    }

    function test_manualSwapBack_revertsForNonOwners() public {
        _setupGraduatedTokenWithBuyer();

        // Non-token-owner, non-launchpad-owner caller still reverts.
        vm.prank(alice);
        vm.expectRevert(LivoTaxableToken.NotTokenOwner.selector);
        taxToken.swapBack(0, 0);
    }

    // ─────────────────────────── rescueTokens ────────────────────────────────────

    function test_rescueTokens_revertsWhenOwnerless() public {
        vm.prank(creator);
        vm.expectRevert(LivoTaxableToken.NotTokenOwner.selector);
        taxToken.rescueTokens(address(taxToken));
    }

    function test_rescueTokens_ownerlessCannotSweepEth() public {
        vm.deal(address(taxToken), 1 ether);

        vm.prank(creator);
        vm.expectRevert(LivoTaxableToken.NotTokenOwner.selector);
        taxToken.rescueTokens(address(0));

        assertEq(address(taxToken).balance, 1 ether);
    }

    function test_rescueTokens_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(LivoTaxableToken.NotTokenOwner.selector);
        taxToken.rescueTokens(address(0));
    }

    // ─────────────────────────── setTaxBps ───────────────────────────────────────

    function test_setTaxBps_revertsForNonOwners() public {
        vm.prank(alice);
        vm.expectRevert(LivoTaxableToken.NotTokenOwner.selector);
        taxToken.setTaxBps(0, 0);

        // Storage untouched.
        assertEq(taxToken.buyTaxBps(), BUY_BPS);
        assertEq(taxToken.sellTaxBps(), SELL_BPS);
    }

    function test_setTaxBps_callableByLaunchpadOwner_lowersBoth() public {
        // Factory-deployed token is ownerless; launchpad.owner() is the only reachable caller.
        assertEq(taxToken.owner(), address(0));
        assertEq(launchpad.owner(), admin);

        uint16 newBuy = BUY_BPS - 50;
        uint16 newSell = SELL_BPS - 100;

        vm.expectEmit(true, true, true, true, address(taxToken));
        emit LivoTaxableToken.TaxBpsUpdated(newBuy, newSell);

        vm.prank(admin);
        taxToken.setTaxBps(newBuy, newSell);

        assertEq(taxToken.buyTaxBps(), newBuy);
        assertEq(taxToken.sellTaxBps(), newSell);
    }

    function test_setTaxBps_revertsIfBuyIncreases() public {
        vm.prank(admin);
        vm.expectRevert(LivoTaxableToken.TaxBpsCanOnlyDecrease.selector);
        taxToken.setTaxBps(BUY_BPS + 1, SELL_BPS);

        // Storage untouched.
        assertEq(taxToken.buyTaxBps(), BUY_BPS);
        assertEq(taxToken.sellTaxBps(), SELL_BPS);
    }

    function test_setTaxBps_allowsEqualValues() public {
        // Keep buy unchanged, lower sell by 1 bps. Equal-on-one-side is a valid call.
        vm.prank(admin);
        taxToken.setTaxBps(BUY_BPS, SELL_BPS - 1);

        assertEq(taxToken.buyTaxBps(), BUY_BPS);
        assertEq(taxToken.sellTaxBps(), SELL_BPS - 1);
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
