// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {noDividendRoute, v2DividendRoute} from "test/helpers/DividendRouteHelpers.sol";
import {DividendRoute} from "src/types/DividendRoute.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {LivoDividendLogicUniV2} from "src/tokens/LivoDividendLogicUniV2.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @notice Integration tests for holder dividends on Uniswap V2. Two things are V2-specific and get the
///         attention here: a leg paying the TOKEN ITSELF must be carved in token space (a V2 pair reverts
///         `INVALID_TO` when asked to deliver a token to its own address), and the automatic swap-back —
///         which fires on ordinary sells, with no attacker and no privilege — must not sweep the dividend
///         money back into the fund/burn/liquidity split.
contract DividendsTaxTokenV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    address internal holder2 = makeAddr("holder2");

    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function _createDividendToken(uint16 dividendsBps, address asset) internal returns (address token) {
        return _createDividendToken(dividendsBps, asset, noDividendRoute());
    }

    function _createDividendToken(uint16 dividendsBps, address asset, DividendRoute memory route)
        internal
        returns (address token)
    {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DivV2",
            symbol: "DV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
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
                burnBps: 0, dividendsBps: dividendsBps, liquidityBps: 0, dividendToken: asset, dividendRoute: route
            })
        });
        vm.prank(creator);
        token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    /// @dev A graduated dividend token with `buyer` holding the whole float.
    function _graduated(address asset) internal returns (LivoTaxableTokenUniV2 token) {
        return _graduated(asset, noDividendRoute());
    }

    function _graduated(address asset, DividendRoute memory route) internal returns (LivoTaxableTokenUniV2 token) {
        address addr = _createDividendToken(5_000, asset, route);
        testToken = addr;
        _launchpadBuy(addr, 1 ether);
        _graduateToken();
        return LivoTaxableTokenUniV2(payable(addr));
    }

    function _nativeToken() internal returns (LivoTaxableTokenUniV2) {
        return _graduated(address(0));
    }

    function _selfToken() internal returns (LivoTaxableTokenUniV2) {
        return _graduated(address(type(uint160).max));
    }

    /// @dev A token paying a third ERC20, bought on the direct WETH/DAI Uniswap-V2 pair.
    function _thirdAssetToken() internal returns (LivoTaxableTokenUniV2) {
        return _graduated(DAI, v2DividendRoute());
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _accrue(LivoTaxableTokenUniV2 token, uint256 amount) internal {
        vm.deal(address(this), amount);
        token.accrueFees{value: amount}();
    }

    receive() external payable {}

    ///////////////////////// stray native /////////////////////////

    /// @dev V2 used to have no way out for stray native at all: `rescueTokens(address(0))` was removed
    ///      with the ETH branch, and the only sweep left was inside the swap-back — which needs tax
    ///      tokens to run. Past the tax window, with the tax pool drained, anything sitting here was
    ///      stuck forever. `sweepStrayEth` is that exit, and it is shared with V4 rather than V4-only.
    function test_sweepStrayEth_recoversStrayNativeOnV2() public {
        LivoTaxableTokenUniV2 token = _nativeToken();

        // Past the tax window: no fresh tax can ever accrue, so no swap-back will ever fire again.
        skip(uint256(token.taxDurationSeconds()) + 1);
        assertEq(token.pendingNative(), 0, "nothing buffered yet");

        vm.deal(address(token), address(token).balance + 1 ether);
        token.sweepStrayEth();

        // Half to the dividend buffer, half to the fund wallets: the burn and liquidity shares are zero
        // for this token, so the split is the plain dividends/fund one.
        assertEq(token.pendingNative(), 0.5 ether, "stray native became holder earnings");
    }

    /// @dev The reason the swap-back stopped sweeping the whole balance. Router refunds from an earlier
    ///      `processLiquidity` had no token-space burn/liquidity peel, so folding them into the swap's
    ///      own split renormalizes them over a denominator that already excludes those buckets — paying
    ///      the dividend pot a share earmarked for burning. They belong to `sweepStrayEth` instead.
    function test_swapBackRoutesOnlyItsOwnProceeds() public {
        LivoTaxableTokenUniV2 token = _nativeToken();

        // Accrue some sell tax as tokens, so there is a swap-back to run.
        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 10;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);
        uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
        assertGt(taxBalance, 0, "sell tax accrued as tokens");

        // Stray native sitting in the token, on top of the tax pool.
        vm.deal(address(token), address(token).balance + 1 ether);
        uint256 strayBefore = address(token).balance;

        vm.prank(admin);
        token.swapBack(taxBalance, 0);

        // The swap-back routed its own proceeds — and only those. Under the old whole-balance sweep the
        // 1 ETH would have been split too, depositing half of it to the fund wallets and leaving the
        // balance BELOW what was already there.
        assertGt(token.pendingNative(), 0, "the swap-back routed its own proceeds");
        assertGe(address(token).balance, strayBefore, "the stray native was not swept into the swap-back");
    }

    ///////////////////////// native leg /////////////////////////

    function test_nativeDividends_accrueFreezeAndPay() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        assertEq(token.pendingNative(), 0.5 ether, "half the earnings buffered for holders");

        skip(token.MIN_ROUND_DURATION() + 1);
        token.processRound(0, _noHolders());

        uint256 before = buyer.balance;
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.processRound(0, holders);
        assertEq(buyer.balance - before, 0.5 ether, "sole holder takes the pot");
    }

    /// @dev THE automatic leak. `_processCollectedTokens` fires on every sell that crosses the swap-back
    ///      threshold and used to route `address(this).balance` through the split — which would re-split
    ///      the dividend buffer into fund/burn/liquidity on every trade, forever, with nobody attacking.
    function test_autoSwapBackDoesNotRecycleTheDividendBuffer() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        uint256 buffered = token.pendingNative();
        assertGt(buffered, 0, "buffer funded");

        // A real sell large enough to trigger the automatic swap-back.
        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 2;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        // The buffer only ever GREW (the sell's own tax adds to it); nothing was swept out of it.
        assertGe(token.pendingNative(), buffered, "dividend buffer never shrinks on a swap-back");
        assertGe(address(token).balance, token.pendingNative(), "buffer backed by a real balance");
    }

    /// @dev A frozen, undelivered pot is holders' money sitting in the token's balance. The swap-back's
    ///      ETH sweep must not see it either.
    function test_frozenPotSurvivesTheSwapBack() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processRound(0, _noHolders());
        assertEq(token.roundPot(), 0.5 ether, "pot frozen");

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 2;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        assertEq(token.roundPot(), 0.5 ether, "pot untouched");
        assertGe(address(token).balance, 0.5 ether, "and still fully backed");
    }

    ///////////////////////// self-token leg (token space) /////////////////////////

    function test_selfTokenLeg_carvedInTokenSpaceDuringTheSwapBack() public {
        LivoTaxableTokenUniV2 token = _selfToken();
        assertEq(token.dividendToken(), address(token), "self-token payout configured");

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 10;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
        assertGt(taxBalance, 0, "sell tax accrued as tokens");

        vm.prank(admin);
        token.swapBack(taxBalance, 0);

        uint256 buffered = token.dividendPendingTokens();
        assertGt(buffered, 0, "dividend tokens set aside in token space");
        assertEq(token.pendingNative(), 0, "and nothing buffered as native for this leg");
        assertGe(IERC20(address(token)).balanceOf(address(token)), buffered, "buffer backed by real balance");
    }

    /// @dev The committed token buffer must be invisible to the tax pool, or the next swap-back sells the
    ///      holders' dividend out from under them.
    function test_selfTokenBuffer_isNotReprocessedAsTax() public {
        LivoTaxableTokenUniV2 token = _selfToken();

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 10;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);
        uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
        vm.prank(admin);
        token.swapBack(taxBalance, 0);

        uint256 buffered = token.dividendPendingTokens();
        assertGt(buffered, 0, "buffer funded");

        // A second swap-back asking for far more than is available must clamp to the uncommitted balance.
        vm.roll(block.number + 1);
        vm.prank(admin);
        token.swapBack(type(uint128).max, 0);
        assertEq(token.dividendPendingTokens(), buffered, "committed tokens untouched");
        assertGe(IERC20(address(token)).balanceOf(address(token)), buffered, "still backed");
    }

    function test_selfTokenLeg_freezesAndPaysInTokens() public {
        LivoTaxableTokenUniV2 token = _selfToken();

        // Sell repeatedly so the token-space buffer crosses SWAP_THRESHOLD.
        for (uint256 i; i < 4; ++i) {
            uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 5;
            _swapSellV2(buyer, address(token), sellAmount, 0, true);
            vm.roll(block.number + 1);
            uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
            vm.prank(admin);
            token.swapBack(taxBalance, 0);
        }

        uint256 buffered = token.dividendPendingTokens();
        vm.assume(buffered >= token.SWAP_THRESHOLD());

        skip(token.MIN_ROUND_DURATION() + 1);
        token.processRound(0, _noHolders());
        assertEq(token.roundPot(), buffered, "the token buffer became the pot, with no conversion");
        assertEq(token.dividendPendingTokens(), 0, "buffer consumed");

        uint256 before = IERC20(address(token)).balanceOf(buyer);
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.processRound(0, holders);
        assertGt(IERC20(address(token)).balanceOf(buyer), before, "holder paid in the token itself");
    }

    ///////////////////////// rescue guard /////////////////////////

    /// @dev The token's own balance is never rescuable, which already covers the self-token pot; this
    ///      pins the behaviour so a future relaxation has to think about the dividend money too.
    function test_rescueTokens_cannotTakeTheSelfTokenPot() public {
        LivoTaxableTokenUniV2 token = _selfToken();
        vm.prank(admin); // the launchpad owner; factory-deployed tokens have no token owner
        vm.expectRevert(LivoTaxableToken.CannotRescueSelfToken.selector);
        token.rescueTokens(address(token));
    }

    /// @dev The self-token pot is protected by a blanket `CannotRescueSelfToken` guard, so it never
    ///      exercises the arithmetic. A THIRD-ASSET pot has no such guard: `rescueTokens` walks straight
    ///      into `_sweepableAsset`, and the only thing between the owner and holders' money is the
    ///      `committedDividends` subtraction. The stray balance dealt on top is what proves the
    ///      subtraction is exact rather than the rescue being a blanket no-op.
    function test_rescueTokens_cannotTakeAnUndeliveredThirdAssetPot() public {
        LivoTaxableTokenUniV2 token = _thirdAssetToken();
        _accrue(token, 1 ether);
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processRound(0, _noHolders());

        uint256 pot = token.roundPot();
        assertGt(pot, 0, "DAI pot frozen");
        assertEq(token.committedDividends(DAI), pot, "the whole pot is owed to holders");
        assertEq(IERC20(DAI).balanceOf(address(token)), pot, "backed by a real DAI balance");

        uint256 stray = 123e18;
        deal(DAI, address(token), pot + stray);

        vm.prank(admin); // the launchpad owner; factory-deployed tokens have no token owner
        token.rescueTokens(DAI);

        assertEq(IERC20(DAI).balanceOf(address(token)), pot, "the stray left, the owed pot stayed");
    }

    ///////////////////////// the delegatecall extension /////////////////////////

    /// @dev The dividend entry points are stubs that `delegatecall` into a separate contract,
    ///      because their bodies do not fit in the clone's implementation alongside everything else.
    ///      What has to hold for that to be safe is that the extension writes the TOKEN's storage and
    ///      keeps none of its own — which is exactly what a completed round lets us observe.
    function test_extension_roundStateLandsOnTheTokenNotTheExtension() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        LivoDividendLogicUniV2 extension = LivoDividendLogicUniV2(payable(token.dividendLogic()));

        _accrue(token, 1 ether);
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processRound(0, _noHolders());

        assertGt(token.roundPot(), 0, "the token's pot was funded through the delegatecall");
        assertTrue(token.roundFrozen(), "the token's round is frozen");
        assertEq(extension.roundPot(), 0, "the extension kept nothing of its own");
        assertEq(extension.currentRound(), 0, "the extension never opened a round of its own");
        assertEq(address(extension).balance, 0, "the extension holds no money");
    }

    /// @dev Every clone of one implementation shares that implementation's extension: it is an
    ///      `immutable` on the implementation, so a clone reads it out of the implementation's code.
    function test_extension_isSharedByEveryCloneOfAnImplementation() public {
        LivoTaxableTokenUniV2 a = _nativeToken();
        LivoTaxableTokenUniV2 b = _nativeToken();

        address logic = livoTaxTokenV2.DIVIDEND_LOGIC();
        assertGt(logic.code.length, 0, "the implementation deployed its extension");
        assertEq(a.dividendLogic(), logic, "first clone");
        assertEq(b.dividendLogic(), logic, "second clone");
    }

    /// @dev An extension is an execution body, not a token. Reverting every token entry point is what
    ///      makes the machinery behind them unreachable — the saving that buys the cold half its room —
    ///      and it is also the honest answer to anyone who arrives at the wrong address.
    function test_extension_disownsTheTokenEntryPoints() public {
        LivoDividendLogicUniV2 extension = LivoDividendLogicUniV2(payable(livoTaxTokenV2.DIVIDEND_LOGIC()));

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.transfer(buyer, 1);

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.getTaxConfig();

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.markGraduated();

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.accrueFees{value: 0}();

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.rescueTokens(DAI);
    }

    ///////////////////////// the threshold /////////////////////////

    /// @dev The threshold used to stop applying the moment the V2 tax window closed, on the theory that
    ///      no further earnings could arrive. They can: `accrueFees` and `sweepStrayEth` are both
    ///      permissionless. That made a free grief — send a wei, sweep it into `pendingNative`, freeze a
    ///      pot every holder's share rounds to zero out of, and the round cannot settle for a whole
    ///      `PAYOUT_WINDOW`, repeatably, for gas. Staleness is the only bypass now, and reaching it costs
    ///      30 days of a completely idle token.
    function test_aWeiPushedInAfterTheTaxWindowCannotForceAFreeze() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        skip(uint256(token.taxDurationSeconds()) + 1); // no fresh tax can ever accrue

        vm.deal(address(token), address(token).balance + 2 wei);
        token.sweepStrayEth();
        assertGt(token.pendingNative(), 0, "the attacker's dust did reach the buffer");
        skip(token.MIN_ROUND_DURATION() + 1);

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        token.processRound(0, _noHolders());
        assertFalse(token.roundFrozen(), "a dust pot cannot stall the round");
    }
}
