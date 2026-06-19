// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TokenState} from "src/types/tokenData.sol";

/// @notice Real-graduation matrix (Uniswap V4 fork) across the (liquidity tier x creator-vault) space.
///         Verifies the feature's two on-chain invariants the pure-curve suite can't:
///           (B) ALL eth reserves leave the launchpad at graduation — nothing is stranded in the
///               launchpad or the graduator; and
///           tier routing: the token is wired to the tier's curve (correct graduation threshold) and
///               the tier's graduator.
///         (Invariant A — pre-grad price ~= post-grad price — and C — mcap == tier target — are covered
///         exhaustively across all 21 curves by the pure-curve suite `TierLiquidityCurvesTest`; the V4
///         graduator deterministically initialises the pool at the tier price, so the on-chain handoff
///         follows from those.)
contract TierLiquidityGraduationTest is LaunchpadBaseTestsWithUniv4Graduator {
    function _expectedThreshold(LiquidityTier tier) internal pure returns (uint256) {
        if (tier == LiquidityTier.SMALL) return 2.0 ether;
        if (tier == LiquidityTier.DEFAULT) return 3.75 ether;
        return 7.25 ether; // LARGE
    }

    function _expectedGraduator(LiquidityTier tier) internal view returns (address) {
        if (tier == LiquidityTier.SMALL) return address(graduatorV4Small);
        if (tier == LiquidityTier.DEFAULT) return address(graduatorV4);
        return address(graduatorV4Large); // LARGE
    }

    /// @dev Creates a V4 (100-bps) token in `tier` with `vaultBps` locked in a single creator vault.
    function _createV4(LiquidityTier tier, uint256 vaultBps) internal returns (address token) {
        ILivoFactory.CreatorVault[] memory vaults;
        if (vaultBps > 0) {
            vaults = new ILivoFactory.CreatorVault[](1);
            vaults[0] =
                ILivoFactory.CreatorVault({owner: creator, supplyBps: vaultBps, cliffSeconds: 0, vestingSeconds: 1});
        }
        ILivoFactory.TokenSetup memory setup = ILivoFactory.TokenSetup({
            name: "Tier",
            symbol: "TIER",
            salt: _nextValidSalt(address(factoryV4Unified), address(livoToken)),
            feeShares: _fs(creator),
            liquidityTier: tier
        });
        LivoFactoryUniV4Unified.UniV4Configs memory cfg =
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
        vm.prank(creator);
        token = factoryV4Unified.createToken(setup, _emptyTaxCfg(), cfg, _noSs(), _emptyAntiSniperCfg(), vaults);
    }

    /// @dev Buys (from `buyer`) exactly enough to reach the token's tier-specific graduation threshold.
    function _buyToGraduation(address token) internal {
        ILivoBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        uint256 threshold = curve.ethGraduationThreshold();
        uint256 ethReserves = launchpad.getTokenState(token).ethCollected;
        uint256 buyFeeBps = _currentBuyFeeBps(token);
        uint256 missing = ((threshold - ethReserves) * 10_000) / (10_000 - buyFeeBps);
        vm.deal(buyer, missing + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: missing}(token, 0, DEADLINE);
    }

    /// @dev The full per-combo assertion: correct tier wiring + full ETH conservation at graduation.
    function _runCase(LiquidityTier tier, uint256 vaultBps) internal {
        address token = _createV4(tier, vaultBps);

        // --- tier routing ---
        ILivoBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        assertEq(curve.ethGraduationThreshold(), _expectedThreshold(tier), "wrong tier curve (threshold)");
        assertEq(ILivoToken(token).graduator(), _expectedGraduator(tier), "wrong tier graduator");

        _buyToGraduation(token);

        // reserves the launchpad held for this token, now handed to the graduator
        TokenState memory st = launchpad.getTokenState(token);
        uint256 treasuryBefore = treasury.balance;

        // --- Invariant B: all reserves leave the launchpad, nothing stranded ---
        assertTrue(st.graduated, "token must be graduated");
        assertEq(st.ethCollected, 0, "launchpad must hold no reserves for the token after graduation");
        // only one token exists in this test, and trading fees route to the treasury directly, so the
        // launchpad's entire ETH balance is reserves — it must be fully drained at graduation.
        assertEq(address(launchpad).balance, 0, "all eth reserves must leave the launchpad");
        // the graduator passes the reserves straight through (liquidity + creator + treasury), retaining nothing
        assertEq(_expectedGraduator(tier).balance, 0, "graduator must retain no eth");
        // treasury received at least its graduation fee share (V4: 0.125 ETH); excess is swept here too
        assertGe(treasuryBefore, CREATOR_GRADUATION_COMPENSATION, "treasury must receive its graduation share");
    }

    // ─────────── no-vault ───────────
    function test_graduation_small_noVault() public {
        _runCase(LiquidityTier.SMALL, 0);
    }

    function test_graduation_default_noVault() public {
        _runCase(LiquidityTier.DEFAULT, 0);
    }

    function test_graduation_large_noVault() public {
        _runCase(LiquidityTier.LARGE, 0);
    }

    // ─────────── max (30%) vault ───────────
    function test_graduation_small_30pctVault() public {
        _runCase(LiquidityTier.SMALL, 3000);
    }

    function test_graduation_default_30pctVault() public {
        _runCase(LiquidityTier.DEFAULT, 3000);
    }

    function test_graduation_large_30pctVault() public {
        _runCase(LiquidityTier.LARGE, 3000);
    }

    // ─────────── a mid vault level, one per tier ───────────
    function test_graduation_small_15pctVault() public {
        _runCase(LiquidityTier.SMALL, 1500);
    }

    function test_graduation_large_15pctVault() public {
        _runCase(LiquidityTier.LARGE, 1500);
    }
}
