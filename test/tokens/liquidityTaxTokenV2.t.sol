// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Integration tests for the V2 liquidity earnings-allocation leg: the liquidity slice is set
///         aside as tax TOKENS during the swap-back, then `processLiquidity` sells half for ETH and adds
///         a locked LP position (token-native zap).
contract LiquidityTaxTokenV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    /// @dev Creates an ownerless V2 tax token with a `liquidityBps` allocation via the allocation-aware
    ///      `createToken` overload. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createLiquidityV2Token(uint16 sellTaxBps, uint16 liquidityBps) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "LiqV2",
            symbol: "LV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({burnBps: 0, dividendsBps: 0, liquidityBps: liquidityBps})
        });
        vm.prank(creator);
        token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    function test_liquidityBps_storedAtCreation() public {
        address token = _createLiquidityV2Token(400, 5000);
        assertEq(LivoTaxableTokenUniV2(payable(token)).liquidityBps(), 5000, "liquidityBps stored via new overload");
    }

    function test_v2Liquidity_swapBackBuffersThenProcessAddsLp() public {
        address token = _createLiquidityV2Token(400, 5000); // 4% sell tax; 50% of earnings → liquidity
        testToken = token;
        LivoTaxableTokenUniV2 liqToken = LivoTaxableTokenUniV2(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        // A single sell accrues sell tax as tokens on the contract (no auto swap-back yet).
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 10;
        _swapSellV2(buyer, token, sellAmount, 0, true);

        // Manual swap-back: burns none, sets aside the liquidity slice as TOKENS, swaps the rest to ETH.
        uint256 taxBalance = IERC20(token).balanceOf(address(liqToken));
        vm.prank(admin);
        liqToken.swapBack(taxBalance, 0);

        uint256 pendingTokens = liqToken.liquidityPendingTokens();
        assertGt(pendingTokens, 0, "liquidity tokens should be set aside by the swap-back");
        // The set-aside tokens are held on the contract but excluded from the tradable/tax balance.
        assertGe(IERC20(token).balanceOf(address(liqToken)), pendingTokens, "buffer backed by real balance");

        address pair = liqToken.pair();
        uint256 deadLpBefore = IERC20(pair).balanceOf(DEAD_ADDRESS);

        liqToken.processLiquidity(0);

        assertEq(liqToken.liquidityPendingTokens(), 0, "liquidity buffer drained");
        assertGt(IERC20(pair).balanceOf(DEAD_ADDRESS), deadLpBefore, "LP minted and locked at the dead address");
    }

    function test_v2ProcessLiquidity_revertsWhenNothingPending() public {
        address token = _createLiquidityV2Token(400, 5000);
        testToken = token;
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        vm.expectRevert(LivoTaxableTokenUniV2.NothingToAdd.selector);
        LivoTaxableTokenUniV2(payable(token)).processLiquidity(0);
    }

    function test_v2ProcessLiquidity_revertsBeforeGraduation() public {
        address token = _createLiquidityV2Token(400, 5000);
        vm.expectRevert(LivoTaxableTokenUniV2.NotGraduated.selector);
        LivoTaxableTokenUniV2(payable(token)).processLiquidity(0);
    }
}
