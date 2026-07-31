// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {CreatorVaultCurveConstantsArc as C} from "src/config/CreatorVaultCurveConstantsArc.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @notice Invariant + overflow tests for the ARC (USDC-native) bonding curves. ARC reprices the
///         curve economics x2000 (native ~$1 vs ETH ~$2000), so its graduation thresholds reach
///         ~14.5k native units and the curve constants are ~2000x larger than the ETH ones. The
///         `(e + E0)^2` terms in the sell/buy-exact paths therefore grow ~4e6x, which is why the
///         constants were RE-SOLVED (not linearly scaled) and why these tests fuzz the whole live
///         range to prove no uint256 overflow — the tightest margin is the THICK 30%-vault curve.
contract CreatorVaultCurvesArcTest is Test {
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    // Tokens into liquidity at graduation — identical across every tier and vault bps (the token
    // split is scale-invariant, so this is the same value as the ETH curves).
    uint256 constant T_GRAD = 285714285714285714285714285;

    // Graduation fee is 0.25 ETH x 2000 = 500 native, the same for every tier.
    uint256 constant GRADUATION_FEE = 500 ether;

    LiquidityTier[3] TIERS = [LiquidityTier.THIN, LiquidityTier.DEFAULT, LiquidityTier.THICK];
    // bps 0 included: on ARC the DEFAULT no-vault base is a configurable curve too.
    uint256[7] BPS = [uint256(0), 500, 1000, 1500, 2000, 2500, 3000];

    function _deploy(LiquidityTier tier, uint256 bps) internal returns (ConstantProductBondingCurveConfigurable) {
        (uint256 k, uint256 t0, uint256 e0) = C.paramsFor(tier, bps);
        (uint256 threshold, uint256 maxExcess) = C.tierGraduation(tier);
        return new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess);
    }

    /// @dev t(0) must equal the sellable supply (1B minus the locked vault allocation), to 0 wei.
    function test_eachCurve_tokenReservesAtZero_equalsSupplyInCurve() public {
        for (uint256 t; t < TIERS.length; ++t) {
            for (uint256 i; i < BPS.length; ++i) {
                uint256 s = TOTAL_SUPPLY * (10_000 - BPS[i]) / 10_000;
                assertEq(_deploy(TIERS[t], BPS[i]).getTokenReserves(0), s, "t(0) == supply in curve");
            }
        }
    }

    /// @dev Tokens into liquidity (t at the graduation threshold) must be exactly T_GRAD for every
    ///      (tier, bps) — the whole point of re-solving rather than linearly scaling.
    function test_eachCurve_tokensIntoLiquidity_identical() public {
        for (uint256 t; t < TIERS.length; ++t) {
            (uint256 threshold,) = C.tierGraduation(TIERS[t]);
            for (uint256 i; i < BPS.length; ++i) {
                assertEq(_deploy(TIERS[t], BPS[i]).getTokenReserves(threshold), T_GRAD, "t(grad) == T_GRAD");
            }
        }
    }

    /// @dev Marginal price at graduation must match the Uniswap price the graduator opens
    ///      (eth-into-liquidity / tokens-into-liquidity) within 1%.
    function test_eachCurve_graduationPrice_matchesUniswap() public {
        for (uint256 t; t < TIERS.length; ++t) {
            (uint256 threshold,) = C.tierGraduation(TIERS[t]);
            uint256 uniswapPrice = ((threshold - GRADUATION_FEE) * 1e18) / T_GRAD;
            for (uint256 i; i < BPS.length; ++i) {
                ConstantProductBondingCurveConfigurable curve = _deploy(TIERS[t], BPS[i]);
                (uint256 tokensReceived,) = curve.buyTokensWithExactEth(threshold, 0.000001e18);
                uint256 curvePrice = (1e18 * 0.000001e18) / tokensReceived;
                assertApproxEqRel(curvePrice, uniswapPrice, 0.01e18, "grad price ~ uniswap (1%)");
            }
        }
    }

    /// @dev THE overflow gate: within [0, maxEthReserves] no (tier, bps) curve may revert. Covers the
    ///      THICK 30% curve, whose constants push the `tokenAmount * (e+E0)^2` term closest to 2^256.
    function test_fuzz_eachCurve_buyDoesNotRevertInRange(
        uint256 tIdx,
        uint256 bIdx,
        uint256 ethReserves,
        uint256 ethAmount
    ) public {
        tIdx = bound(tIdx, 0, TIERS.length - 1);
        bIdx = bound(bIdx, 0, BPS.length - 1);
        ConstantProductBondingCurveConfigurable curve = _deploy(TIERS[tIdx], BPS[bIdx]);
        uint256 maxEth = curve.maxEthReserves();
        ethReserves = bound(ethReserves, 0, maxEth);
        uint256 limit = maxEth - ethReserves;
        if (limit == 0) return;
        ethAmount = bound(ethAmount, 0, limit);
        curve.buyTokensWithExactEth(ethReserves, ethAmount);
    }

    /// @dev Buy then sell must not extract more than deposited and round-trips within rounding.
    ///      Exercises sellExactTokens (the other `(e+E0)^2` path) across the ARC range.
    function test_fuzz_eachCurve_buyThenSell_roundTrips(
        uint256 tIdx,
        uint256 bIdx,
        uint256 ethReserves,
        uint256 ethAmount
    ) public {
        tIdx = bound(tIdx, 0, TIERS.length - 1);
        bIdx = bound(bIdx, 0, BPS.length - 1);
        ConstantProductBondingCurveConfigurable curve = _deploy(TIERS[tIdx], BPS[bIdx]);
        uint256 maxEth = curve.maxEthReserves();
        ethReserves = bound(ethReserves, 0, maxEth);
        uint256 maxAmount = maxEth - ethReserves;
        if (maxAmount < 0.000001e18) return;
        ethAmount = bound(ethAmount, 0.000001e18, maxAmount);

        (uint256 tokensReceived,) = curve.buyTokensWithExactEth(ethReserves, ethAmount);
        uint256 ethReceived = curve.sellExactTokens(ethReserves + ethAmount, tokensReceived);
        assertLe(ethReceived, ethAmount, "cannot extract more than put in");
        assertApproxEqRel(ethReceived, ethAmount, 0.0000001e18, "buy+sell round-trips within 0.00001%");
    }
}
