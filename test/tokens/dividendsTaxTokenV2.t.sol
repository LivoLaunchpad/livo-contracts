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
import {noDividendRoutes, v2DividendRoute} from "test/helpers/DividendRouteHelpers.sol";
import {DividendRoute} from "src/types/DividendRoute.sol";

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
                burnBps: 0,
                dividendsBps: dividendsBps,
                liquidityBps: 0,
                dividendTokens: assets,
                dividendWeightsBps: weights,
                dividendRoutes: routes
            })
        });
        vm.prank(creator);
        token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    /// @dev A graduated dividend token with `buyer` holding the whole float.
    function _graduated(address[3] memory assets, uint16[3] memory weights)
        internal
        returns (LivoTaxableTokenUniV2 token)
    {
        return _graduated(assets, weights, noDividendRoutes());
    }

    function _graduated(address[3] memory assets, uint16[3] memory weights, DividendRoute[3] memory routes)
        internal
        returns (LivoTaxableTokenUniV2 token)
    {
        address addr = _createDividendToken(5_000, assets, weights, routes);
        testToken = addr;
        _launchpadBuy(addr, 1 ether);
        _graduateToken();
        return LivoTaxableTokenUniV2(payable(addr));
    }

    function _nativeToken() internal returns (LivoTaxableTokenUniV2) {
        return _graduated([address(0), address(0), address(0)], [uint16(10_000), 0, 0]);
    }

    function _selfToken() internal returns (LivoTaxableTokenUniV2) {
        return _graduated([address(type(uint160).max), address(0), address(0)], [uint16(10_000), 0, 0]);
    }

    /// @dev A leg paying a third ERC20, bought on the direct WETH/DAI Uniswap-V2 pair.
    function _thirdAssetToken() internal returns (LivoTaxableTokenUniV2) {
        DividendRoute[3] memory routes = noDividendRoutes();
        routes[0] = v2DividendRoute(address(0));
        return _graduated([DAI, address(0), address(0)], [uint16(10_000), 0, 0], routes);
    }

    function _accrue(LivoTaxableTokenUniV2 token, uint256 amount) internal {
        vm.deal(address(this), amount);
        token.accrueFees{value: amount}();
    }

    receive() external payable {}

    ///////////////////////// native leg /////////////////////////

    function test_nativeDividends_accrueFreezeAndPay() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        assertEq(token.pendingNative(0), 0.5 ether, "half the earnings buffered for holders");

        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);

        uint256 before = buyer.balance;
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.distributeDividends(holders);
        assertEq(buyer.balance - before, 0.5 ether, "sole holder takes the pot");
    }

    /// @dev THE automatic leak. `_processCollectedTokens` fires on every sell that crosses the swap-back
    ///      threshold and used to route `address(this).balance` through the split — which would re-split
    ///      the dividend buffer into fund/burn/liquidity on every trade, forever, with nobody attacking.
    function test_autoSwapBackDoesNotRecycleTheDividendBuffer() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        uint256 buffered = token.pendingNative(0);
        assertGt(buffered, 0, "buffer funded");

        // A real sell large enough to trigger the automatic swap-back.
        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 2;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        // The buffer only ever GREW (the sell's own tax adds to it); nothing was swept out of it.
        assertGe(token.pendingNative(0), buffered, "dividend buffer never shrinks on a swap-back");
        assertGe(address(token).balance, token.pendingNative(0), "buffer backed by a real balance");
    }

    /// @dev A frozen, undelivered pot is holders' money sitting in the token's balance. The swap-back's
    ///      ETH sweep must not see it either.
    function test_frozenPotSurvivesTheSwapBack() public {
        LivoTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        skip(token.MIN_ROUND_DURATION() + 1);
        token.processDividends([uint256(0), 0, 0]);
        assertEq(token.roundPot(0), 0.5 ether, "pot frozen");

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 2;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        assertEq(token.roundPot(0), 0.5 ether, "pot untouched");
        assertGe(address(token).balance, 0.5 ether, "and still fully backed");
    }

    ///////////////////////// self-token leg (token space) /////////////////////////

    function test_selfTokenLeg_carvedInTokenSpaceDuringTheSwapBack() public {
        LivoTaxableTokenUniV2 token = _selfToken();
        assertEq(token.dividendTokens(0), address(token), "self-token leg configured");

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 10;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
        assertGt(taxBalance, 0, "sell tax accrued as tokens");

        vm.prank(admin);
        token.swapBack(taxBalance, 0);

        uint256 buffered = token.dividendPendingTokens();
        assertGt(buffered, 0, "dividend tokens set aside in token space");
        assertEq(token.pendingNative(0), 0, "and nothing buffered as native for this leg");
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
        token.processDividends([uint256(0), 0, 0]);
        assertEq(token.roundPot(0), buffered, "the token buffer became the pot, with no conversion");
        assertEq(token.dividendPendingTokens(), 0, "buffer consumed");

        uint256 before = IERC20(address(token)).balanceOf(buyer);
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.distributeDividends(holders);
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
        token.processDividends([uint256(0), 0, 0]);

        uint256 pot = token.roundPot(0);
        assertGt(pot, 0, "DAI pot frozen");
        assertEq(token.committedDividends(DAI), pot, "the whole pot is owed to holders");
        assertEq(IERC20(DAI).balanceOf(address(token)), pot, "backed by a real DAI balance");

        uint256 stray = 123e18;
        deal(DAI, address(token), pot + stray);

        vm.prank(admin); // the launchpad owner; factory-deployed tokens have no token owner
        token.rescueTokens(DAI);

        assertEq(IERC20(DAI).balanceOf(address(token)), pot, "the stray left, the owed pot stayed");
    }

    ///////////////////////// config /////////////////////////

    function test_dividendsWithoutPayoutConfigIsRejected() public {
        vm.expectRevert(DividendDistribution.InvalidDividendConfig.selector);
        _createDividendToken(5_000, [address(0), address(0), address(0)], [uint16(0), 0, 0]);
    }
}
