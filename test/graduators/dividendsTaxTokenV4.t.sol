// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {noDividendRoutes, v2DividendRoute, v3DividendRoute} from "test/helpers/DividendRouteHelpers.sol";
import {DividendRoute} from "src/types/DividendRoute.sol";

/// @notice Integration tests for the holder-dividends earnings-allocation leg on Uniswap V4: rounds,
///         the minimum-balance share rule, threshold-gated freezing, the push payout, and the
///         committed-funds guards that keep an undistributed pot away from every sweep path.
contract DividendsTaxTokenV4Tests is TaxTokenUniV4BaseTests {
    address internal holder2 = makeAddr("holder2");

    /// @dev Creates a taxable V4 token routing `dividendsBps` of post-graduation earnings to holders,
    ///      paid in the assets given. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createDividendToken(uint16 dividendsBps, address[3] memory assets, uint16[3] memory weights)
        internal
        returns (address token)
    {
        return _createDividendToken(dividendsBps, assets, weights, noDividendRoutes());
    }

    function _createDividendToken(
        uint16 dividendsBps,
        address[3] memory assets,
        uint16[3] memory weights,
        DividendRoute[3] memory routes
    ) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DivToken",
            symbol: "DIV",
            salt: _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 0,
                dividendsBps: dividendsBps,
                liquidityBps: 0,
                dividendTokens: assets,
                dividendWeightsBps: weights,
                dividendRoutes: routes
            })
        });
        vm.prank(creator);
        token = factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
    }

    function _nativeOnly() internal pure returns (address[3] memory assets, uint16[3] memory weights) {
        assets = [address(0), address(0), address(0)];
        weights = [uint16(10_000), 0, 0];
    }

    /// @dev A graduated, dividend-paying token with `buyer` as its only holder. Round 1 is NOT open
    ///      yet — it opens on the first earnings the token routes (see `_handleDividends`), which is
    ///      what `_accrue` triggers.
    function _graduatedDividendToken() internal returns (LivoTaxableTokenUniV4 token) {
        (address[3] memory assets, uint16[3] memory weights) = _nativeOnly();
        address addr = _createDividendToken(5_000, assets, weights);
        testToken = addr;
        _launchpadBuy(addr, 2 ether);
        _graduateToken();
        return LivoTaxableTokenUniV4(payable(addr));
    }

    /// @dev A graduated token with round 1 already open and 0.5 ETH buffered for holders.
    function _liveDividendToken() internal returns (LivoTaxableTokenUniV4 token) {
        token = _graduatedDividendToken();
        _accrue(token, 1 ether);
    }

    /// @dev The V4 graduator keeps a few thousand wei of the supply forever (measured: 7 328), and it
    ///      is an ordinary counted address, so a "sole holder" owns very slightly less than 100% of the
    ///      denominator and their payout rounds down. Nothing is lost — the remainder rolls into the
    ///      next round — but exact-wei assertions have to allow for it.
    uint256 internal constant GRADUATOR_DUST_TOLERANCE = 1e9;

    /// @dev Pushes `amount` of native earnings through the allocation split, the same way the swap hook
    ///      and the LP-fee router do. Used instead of driving real swaps where the point of the test is
    ///      the round mechanics rather than the tax collection.
    function _accrue(LivoTaxableTokenUniV4 token, uint256 amount) internal {
        vm.deal(address(this), amount);
        token.accrueFees{value: amount}();
    }

    receive() external payable {}

    ///////////////////////// configuration /////////////////////////

    function test_dividendConfig_storedAtCreation() public {
        (address[3] memory assets, uint16[3] memory weights) = _nativeOnly();
        LivoTaxableTokenUniV4 token = LivoTaxableTokenUniV4(payable(_createDividendToken(5_000, assets, weights)));

        assertEq(token.dividendsBps(), 5_000, "dividendsBps stored");
        assertTrue(token.hasDividends(), "warm-slot gate flipped on");
        assertEq(token.dividendTokens(0), address(0), "native leg");
        assertEq(token.dividendWeightsBps(0), 10_000, "full weight on leg 0");
        assertEq(token.currentRound(), 0, "no round before graduation");
    }

    /// @dev The self-token sentinel exists because a creator cannot name an address that does not exist
    ///      yet; it must resolve to the token itself at initialization.
    function test_selfTokenSentinel_resolvesToTheToken() public {
        address[3] memory assets = [token_SELF(), address(0), address(0)];
        uint16[3] memory weights = [uint16(10_000), 0, 0];
        LivoTaxableTokenUniV4 token = LivoTaxableTokenUniV4(payable(_createDividendToken(5_000, assets, weights)));
        assertEq(token.dividendTokens(0), address(token), "sentinel resolved");
    }

    function test_weightsMustSumToOneHundredPercent() public {
        address[3] memory assets = [address(0), address(0), address(0)];
        uint16[3] memory weights = [uint16(9_000), 0, 0];
        vm.expectRevert(DividendDistribution.InvalidDividendConfig.selector);
        _createDividendToken(5_000, assets, weights);
    }

    /// @dev Two legs paying the same asset would make each leg's unpaid pot un-reconcilable against that
    ///      asset's balance, which is what every sweep path subtracts.
    function test_duplicateAssetsRejected() public {
        address[3] memory assets = [address(0), address(0), address(0)];
        uint16[3] memory weights = [uint16(5_000), 5_000, 0];
        vm.expectRevert(DividendDistribution.InvalidDividendConfig.selector);
        _createDividendToken(5_000, assets, weights);
    }

    /// @dev ANY ERC20 is a valid payout asset — there is no whitelist and no curated-route requirement.
    ///      What the creator must supply is the route that buys it.
    function test_anyThirdAssetIsAccepted() public {
        address[3] memory assets = [makeAddr("xStock"), address(0), address(0)];
        uint16[3] memory weights = [uint16(10_000), 0, 0];
        DividendRoute[3] memory routes = noDividendRoutes();
        routes[0] = v2DividendRoute(address(0));

        address token = _createDividendToken(5_000, assets, weights, routes);

        assertEq(LivoTaxableTokenUniV4(payable(token)).dividendTokens(0), assets[0], "the asset was accepted");
    }

    /// @dev The one route error worth a revert: one this chain could never execute at all. A clone cannot
    ///      be patched, so the leg would accrue forever.
    function test_thirdAssetWithAnUnexecutableRouteRejected() public {
        address[3] memory assets = [makeAddr("xStock"), address(0), address(0)];
        uint16[3] memory weights = [uint16(10_000), 0, 0];
        DividendRoute[3] memory routes = noDividendRoutes();
        routes[0] = v3DividendRoute(0); // no V3 pool has a zero fee tier

        vm.expectRevert(DividendDistribution.UnsupportedDividendAsset.selector);
        _createDividendToken(5_000, assets, weights, routes);
    }

    ///////////////////////// rounds /////////////////////////

    /// @dev The first round opens on the first EARNINGS — not at creation, and not at graduation. At
    ///      creation the launchpad holds the whole supply; at `markGraduated()` the graduator does. By
    ///      the time earnings arrive both are done, so the denominator is just the real holders — and
    ///      the transfer hot path never has to know either address exists.
    function test_firstRoundOpensOnTheFirstEarnings() public {
        LivoTaxableTokenUniV4 token = _graduatedDividendToken();
        assertEq(token.currentRound(), 0, "no round yet, even though the token has graduated");

        _accrue(token, 1 ether);

        assertEq(token.currentRound(), 1, "round 1 opened by the first earnings");
        assertApproxEqAbs(
            uint256(token.roundTotalShares()),
            IERC20(address(token)).balanceOf(buyer),
            GRADUATOR_DUST_TOLERANCE,
            "denominator = the only holder, give or take the graduator's leftover dust"
        );
        assertEq(token.dividendShares(buyer), IERC20(address(token)).balanceOf(buyer), "untouched holder reads live");
    }

    function test_accrual_bufferedAsNative() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        assertEq(token.pendingNative(0), 0.5 ether, "half of the earnings buffered for holders");
    }

    function test_processDividends_revertsBeforeTheRoundIsOldEnough() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        vm.expectRevert(DividendDistribution.RoundTooYoung.selector);
        token.processDividends([uint256(0), 0, 0]);
    }

    function test_processDividends_revertsBelowThreshold() public {
        LivoTaxableTokenUniV4 token = _graduatedDividendToken();
        _accrue(token, 0.01 ether); // 0.005 ETH to dividends, well under the 0.1 ETH threshold
        skip(token.MIN_ROUND_DURATION() + 1);
        vm.expectRevert(DividendDistribution.NoLegAboveThreshold.selector);
        token.processDividends([uint256(0), 0, 0]);
    }

    ///////////////////////// payout /////////////////////////

    function test_singleHolder_receivesTheWholePot() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        skip(token.MIN_ROUND_DURATION() + 1);

        token.processDividends([uint256(0), 0, 0]);
        assertApproxEqAbs(token.roundPot(0), 0.5 ether, GRADUATOR_DUST_TOLERANCE, "pot frozen");
        assertEq(token.frozenLegs(), 1, "leg 0 frozen");

        uint256 balanceBefore = buyer.balance;
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.distributeDividends(holders);

        assertApproxEqAbs(
            buyer.balance - balanceBefore, 0.5 ether, GRADUATOR_DUST_TOLERANCE, "sole holder takes the whole pot"
        );
        assertApproxEqAbs(token.roundPaid(0), 0.5 ether, GRADUATOR_DUST_TOLERANCE, "pot fully accounted as paid");
    }

    function test_payingTwiceInARoundIsANoOp() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        address[] memory holders = new address[](2);
        holders[0] = buyer;
        holders[1] = buyer; // a duplicate in the keeper's list

        uint256 balanceBefore = buyer.balance;
        token.distributeDividends(holders);
        assertApproxEqAbs(
            buyer.balance - balanceBefore, 0.5 ether, GRADUATOR_DUST_TOLERANCE, "the duplicate pays nothing"
        );

        uint256 afterFirstBatch = buyer.balance;
        token.distributeDividends(holders);
        assertEq(buyer.balance, afterFirstBatch, "a second batch pays nothing either");
    }

    function test_claimRound_isABackstopForAMissedHolder() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        uint256 balanceBefore = buyer.balance;
        vm.prank(buyer);
        token.claimRound();
        assertApproxEqAbs(
            buyer.balance - balanceBefore, 0.5 ether, GRADUATOR_DUST_TOLERANCE, "self-serve claim pays the same amount"
        );

        uint256 afterFirstClaim = buyer.balance;
        vm.prank(buyer);
        token.claimRound();
        assertEq(buyer.balance, afterFirstClaim, "and only once");
    }

    /// @dev THE anti-JIT property: an account that starts a round at zero has a minimum of zero for the
    ///      whole round, whatever it buys in between.
    function test_midRoundBuyerEarnsNothingThisRound() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();

        // holder2 arrives after the round opened, taking half of buyer's bag.
        uint256 half = IERC20(address(token)).balanceOf(buyer) / 2;
        vm.prank(buyer);
        IERC20(address(token)).transfer(holder2, half);

        assertEq(token.dividendShares(holder2), 0, "mid-round arrival is worth zero");

        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        address[] memory holders = new address[](2);
        holders[0] = buyer;
        holders[1] = holder2;
        uint256 buyerBefore = buyer.balance;
        token.distributeDividends(holders);

        assertEq(holder2.balance, 0, "the mid-round buyer is paid nothing");
        // buyer's minimum fell to its post-transfer balance, and the denominator fell with it, so the
        // remaining holder still takes the whole pot.
        assertApproxEqAbs(
            buyer.balance - buyerBefore,
            0.5 ether,
            GRADUATOR_DUST_TOLERANCE,
            "the seller keeps the pot at its reduced weight"
        );
    }

    /// @dev The denominator must track the drop, or the round under-distributes. Selling half mid-round
    ///      halves your weight AND the denominator, since you are the only holder.
    function test_sellingMidRoundDropsWeightAndDenominatorTogether() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        uint256 startBalance = IERC20(address(token)).balanceOf(buyer);
        uint256 denominatorBefore = token.roundTotalShares();

        vm.prank(buyer);
        IERC20(address(token)).transfer(holder2, startBalance / 4);

        assertEq(token.dividendShares(buyer), startBalance - startBalance / 4, "minimum is the post-sale balance");
        assertEq(
            uint256(token.roundTotalShares()),
            denominatorBefore - startBalance / 4,
            "denominator moved by the same amount"
        );
    }

    /// @dev A minimum never rises, so buying more after the first touch cannot raise your weight.
    function test_minimumNeverRises() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        uint256 startBalance = IERC20(address(token)).balanceOf(buyer);

        vm.prank(buyer);
        IERC20(address(token)).transfer(holder2, startBalance / 2);
        uint256 minAfterSale = token.dividendShares(buyer);

        vm.prank(holder2);
        IERC20(address(token)).transfer(buyer, startBalance / 2); // buy it all back

        assertEq(token.dividendShares(buyer), minAfterSale, "the round minimum is unchanged by the buy-back");
    }

    ///////////////////////// round roll-over /////////////////////////

    function test_finalizeRound_rollsResidualAndOpensTheNextRound() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        // Nobody is paid, so the whole pot is residual.
        skip(token.PAYOUT_WINDOW() + 1);
        token.finalizeRound();

        assertEq(token.currentRound(), 2, "next round open");
        assertEq(token.frozenLegs(), 0, "nothing payable until the new round freezes");
        assertApproxEqAbs(
            token.roundPot(0), 0.5 ether, GRADUATOR_DUST_TOLERANCE, "the residual seeds the next round's pot"
        );
        assertEq(token.roundPaid(0), 0, "paid counter reset");
    }

    function test_finalizeRound_blockedWhileThePayoutWindowIsOpen() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        vm.expectRevert(DividendDistribution.PayoutWindowOpen.selector);
        token.finalizeRound();
    }

    /// @dev Rounds must not be churnable on demand: opening a round re-snapshots everyone's minimum from
    ///      live balances, which is the one moment a borrowed balance would count.
    function test_emptyRoundCannotBeChurned() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        vm.expectRevert(DividendDistribution.RoundTooYoung.selector);
        token.finalizeRound();
    }

    /// @dev Before any earnings there is no round at all, so nothing can be frozen or rolled over.
    function test_noRoundBeforeTheFirstEarnings() public {
        LivoTaxableTokenUniV4 token = _graduatedDividendToken();
        vm.expectRevert(DividendDistribution.DividendsNotActive.selector);
        token.finalizeRound();
        vm.expectRevert(DividendDistribution.DividendsNotActive.selector);
        token.processDividends([uint256(0), 0, 0]);
    }

    ///////////////////////// committed funds (§2.9) /////////////////////////

    /// @dev `sweepStrayEth` is permissionless and repeatable. Reading the raw balance there would let
    ///      anyone recycle the dividend money through the split, handing the fund slice to the creator
    ///      on every call.
    function test_sweepStrayEth_cannotTouchTheDividendBuffer() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        uint256 buffered = token.pendingNative(0);

        token.sweepStrayEth();
        assertEq(token.pendingNative(0), buffered, "buffer untouched by the sweep");

        // Stray ETH on top IS sweepable, and only that.
        vm.deal(address(token), address(token).balance + 0.3 ether);
        token.sweepStrayEth();
        assertEq(token.pendingNative(0), buffered + 0.15 ether, "only the stray ETH was re-split");
    }

    function test_frozenPotSurvivesASweep() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        token.sweepStrayEth();
        assertApproxEqAbs(token.roundPot(0), 0.5 ether, GRADUATOR_DUST_TOLERANCE, "an undelivered pot is not stray ETH");
        assertGe(address(token).balance, 0.5 ether, "and is still backed by a real balance");
    }

    ///////////////////////// the exclusion set /////////////////////////

    /// @dev The excluded set is written out TWICE in `LivoTaxableToken` — once as a predicate
    ///      (`_dividendExcluded`) and once as an arithmetic subtraction (`_dividendEligibleSupply`) — and
    ///      the two must name the same addresses. If they drift, the denominator counts a balance that
    ///      can never be paid, and every round under-distributes by that much, forever.
    /// @dev Asserted from outside via the only two things the pair is observable through: the opening
    ///      `roundTotalShares` (the subtraction) and `dividendShares` per address (the predicate).
    function test_theTwoExclusionListsAgree() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        IERC20 erc = IERC20(address(token));

        address[4] memory excluded = [address(token), token.pair(), address(token.launchpad()), address(0xdEaD)];

        uint256 expected = erc.totalSupply();
        for (uint256 i; i < excluded.length; ++i) {
            expected -= erc.balanceOf(excluded[i]);
            assertEq(token.dividendShares(excluded[i]), 0, "an excluded address must carry no weight");
        }

        assertEq(
            token.roundTotalShares(),
            expected,
            "the opening denominator is exactly supply minus the balances of the SAME four addresses"
        );
    }

    /// @dev The graduator is deliberately NOT excluded — the round opens on the first earnings, by which
    ///      point graduation is over and it holds only dust. Pinning that here so the decision (and the
    ///      per-transfer SLOAD it avoids) is not quietly reversed.
    function test_graduatorIsAnOrdinaryAddress_notExcluded() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        uint256 dust = IERC20(address(token)).balanceOf(token.graduator());
        assertEq(token.dividendShares(token.graduator()), dust, "the graduator is counted like any holder");
        assertLt(dust, GRADUATOR_DUST_TOLERANCE, "and what it still holds is dust, which is why that is safe");
    }

    ///////////////////////// the self-token leg /////////////////////////

    /// @dev A graduated token paying its holders in ITSELF. On V4 this is the only leg that runs a swap:
    ///      earnings arrive as ETH and `_acquireDividendAsset` buys the token back on its own pool,
    ///      reusing the primitive `processBurn` uses.
    function _graduatedSelfTokenDividendToken() internal returns (LivoTaxableTokenUniV4 token) {
        address addr = _createDividendToken(5_000, [token_SELF(), address(0), address(0)], [uint16(10_000), 0, 0]);
        testToken = addr;
        _launchpadBuy(addr, 2 ether);
        _graduateToken();
        return LivoTaxableTokenUniV4(payable(addr));
    }

    /// @dev The whole V4 self-token path end to end: accrue ETH, buy the token back on its own pool at
    ///      freeze time, and pay holders in tokens. Nothing else exercises `_acquireDividendAsset`'s V4
    ///      override, so without this the leg is configurable but never executed.
    function test_selfTokenLeg_boughtBackOnFreezeAndPaidInTokens() public {
        LivoTaxableTokenUniV4 token = _graduatedSelfTokenDividendToken();
        _accrue(token, 1 ether);
        assertEq(token.pendingNative(0), 0.5 ether, "the self-token leg buffers as ETH on V4");

        uint256 holderBefore = IERC20(address(token)).balanceOf(buyer);
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        uint256 pot = token.roundPot(0);
        assertGt(pot, 0, "ETH was converted into the token itself");
        assertEq(token.dividendTokens(0), address(token), "the pot is denominated in the token");
        // A self-token leg swaps, so one freeze converts at most `MAX_DIVIDEND_PER_FREEZE`. What is left
        // is the uncapped remainder plus the buy-back's own tax, which loops back in as fresh earnings.
        assertApproxEqAbs(
            token.pendingNative(0),
            0.5 ether - token.MAX_DIVIDEND_PER_FREEZE(),
            0.01 ether,
            "the freeze took the cap, the remainder stayed buffered"
        );

        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.distributeDividends(holders);

        assertGt(IERC20(address(token)).balanceOf(buyer), holderBefore, "the holder was paid in tokens");
        assertApproxEqAbs(
            IERC20(address(token)).balanceOf(buyer) - holderBefore, pot, GRADUATOR_DUST_TOLERANCE, "paid the whole pot"
        );
    }

    /// @dev The buy-back is an ordinary pool swap, so `LivoSwapHook` emits a `LivoSwapBuy` crediting
    ///      `tx.origin` — the keeper. `DividendBuyBackInitiated` must land BEFORE it so an indexer can
    ///      classify that buy as protocol-internal as it arrives, rather than as a trade by the keeper.
    function test_selfTokenBuyBack_isFlaggedBeforeTheSwap() public {
        LivoTaxableTokenUniV4 token = _graduatedSelfTokenDividendToken();
        _accrue(token, 1 ether);
        skip(token.MIN_ROUND_DURATION() + 1);

        vm.recordLogs();
        token.processDividends([uint256(0), 0, 0]);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 marker = keccak256("DividendBuyBackInitiated(uint256)");
        bytes32 swapBuy = keccak256("LivoSwapBuy(address,address,uint256,uint256,uint256)");
        uint256 markerAt = type(uint256).max;
        uint256 swapAt = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == marker && markerAt == type(uint256).max) markerAt = i;
            if (logs[i].topics[0] == swapBuy && swapAt == type(uint256).max) swapAt = i;
        }

        assertLt(markerAt, type(uint256).max, "the precursor marker was emitted");
        assertLt(swapAt, type(uint256).max, "the hook's buy event was emitted");
        assertLt(markerAt, swapAt, "the marker must precede the swap it flags");
    }

    /// @dev The self-token pot is the token's OWN balance, shared with the tax pool. It must be invisible
    ///      to the swap-back accounting, or an undelivered pot would be re-processed as tax.
    function test_selfTokenPot_isNotSweepableAsStray() public {
        LivoTaxableTokenUniV4 token = _graduatedSelfTokenDividendToken();
        _accrue(token, 1 ether);
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        uint256 pot = token.roundPot(0);
        assertEq(token.committedDividends(address(token)), pot, "the pot is reported as committed");

        // A rescue must not be able to reach it either: it is holders' money, not a stuck balance.
        vm.prank(creator);
        vm.expectRevert(LivoTaxableToken.CannotRescueSelfToken.selector);
        token.rescueTokens(address(token));
    }

    /// @dev Helper: the "pay me in the token itself" sentinel.
    function token_SELF() internal pure returns (address) {
        return address(type(uint160).max);
    }
}
