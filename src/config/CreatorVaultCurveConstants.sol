// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @title CreatorVaultCurveConstants
/// @notice Single source of truth for the `(K, T0, E0)` constants of every configurable bonding
///         curve, indexed by (liquidity tier x locked allocation). For each tier there is one curve
///         per allocation: no-vault (0%) plus 5%..30% in 5% steps.
/// @dev    Derived in `simulations/script/find_creator_vault_curve_params.py` (run with `--solidity`
///         to regenerate the THIN/THICK blocks below). For EVERY (tier, bps) the solver hits
///         `t(0)=S` and `t(threshold)=T_GRAD` to 0 wei with a negligible (<1e-17%) graduation price
///         deviation. Within a tier, locking supply relaxes only the starting market cap.
///
///         Graduation invariants per tier (graduation mcap scales 1:2:4 with LP depth, so the token
///         split is identical for all tiers):
///           - THIN  : threshold 2.00 ETH, eth into liquidity 1.75, grad mcap 6.125 ETH
///           - DEFAULT : threshold 3.75 ETH, eth into liquidity 3.50, grad mcap 12.25 ETH
///           - THICK  : threshold 7.25 ETH, eth into liquidity 7.00, grad mcap 24.5 ETH
///         tokens into liquidity (T_GRAD) = 285,714,285.714...M for every tier and every bps.
///
///         The DEFAULT tier's no-vault (0%) curve is the deployed hardcoded `ConstantProductBondingCurve`,
///         not a configurable instance, so there is no `(DEFAULT, 0)` entry here.
library CreatorVaultCurveConstants {
    /// @notice Thrown by `paramsForBps`/`paramsFor` when `totalBps` is not a supported allocation.
    error InvalidVaultBps(uint256 totalBps);
    /// @notice Thrown by `tierGraduation`/`paramsFor` on an unknown tier.
    error InvalidLiquidityTier();

    /// @notice Allocation step (5% in bps) and bounds for creator vaults.
    uint256 internal constant VAULT_BPS_STEP = 500; // 5%
    uint256 internal constant MAX_VAULT_TOTAL_BPS = 3000; // 30%

    /// @notice Max ETH accepted above any tier's graduation threshold. Identical across tiers.
    uint256 internal constant GRADUATION_MAX_EXCESS = 0.05 ether;

    // ============================ DEFAULT tier (12.25 ETH grad mcap) ============================
    // 5%
    uint256 internal constant K_5 = 3948882314266929651175842964579224194616263736;
    uint256 internal constant T0_5 = 282051282051282051245714287;
    uint256 internal constant E0_5 = 3205128205128205128;

    // 10%
    uint256 internal constant K_10 = 4561477566773387132568593485225428709275938190;
    uint256 internal constant T0_10 = 324503311258278145733333334;
    uint256 internal constant E0_10 = 3725165562913907285;

    // 15%
    uint256 internal constant K_15 = 5484482650877220391190844486023449827371978167;
    uint256 internal constant T0_15 = 383399209486166007929523811;
    uint256 internal constant E0_15 = 4446640316205533597;

    // 20%
    uint256 internal constant K_20 = 7006920415224913493855857646626297577885042016;
    uint256 internal constant T0_20 = 470588235294117646994285716;
    uint256 internal constant E0_20 = 5514705882352941176;

    // 25%
    uint256 internal constant K_25 = 9892039542143600416087185979786680541103533026;
    uint256 internal constant T0_25 = 612903225806451612895238097;
    uint256 internal constant E0_25 = 7258064516129032258;

    // 30%
    uint256 internal constant K_30 = 16840957636169455322855520548571555713783791555;
    uint256 internal constant T0_30 = 886792452830188679272380955;
    uint256 internal constant E0_30 = 10613207547169811321;

    // ============================ THIN tier (6.125 ETH grad mcap) ============================
    uint256 internal constant K_THIN_0 = 2216066481994459834400474872110803324135338346;
    uint256 internal constant T0_THIN_0 = 315789473684210526428571429;
    uint256 internal constant E0_THIN_0 = 1684210526315789474;
    uint256 internal constant K_THIN_5 = 2526154379751919021443825424968373782702762192;
    uint256 internal constant T0_THIN_5 = 356495468277945619192857144;
    uint256 internal constant E0_THIN_5 = 1933534743202416918;
    uint256 internal constant K_THIN_10 = 2976107841657864292255735916350284190942249240;
    uint256 internal constant T0_THIN_10 = 411347517730496453857142858;
    uint256 internal constant E0_THIN_10 = 2269503546099290780;
    uint256 internal constant K_THIN_15 = 3678682606052791541183479160587227615179828326;
    uint256 internal constant T0_THIN_15 = 489270386266094420550000001;
    uint256 internal constant E0_THIN_15 = 2746781115879828326;
    uint256 internal constant K_THIN_20 = 4899810964083175802701701326729678638965217391;
    uint256 internal constant T0_THIN_20 = 608695652173913043400000001;
    uint256 internal constant E0_THIN_20 = 3478260869565217391;
    uint256 internal constant K_THIN_25 = 7418381344307270233887174220729766803856481482;
    uint256 internal constant T0_THIN_25 = 814814814814814814875000002;
    uint256 internal constant E0_THIN_25 = 4740740740740740741;
    uint256 internal constant K_THIN_30 = 14554894537587885344242215888718226068156146180;
    uint256 internal constant T0_THIN_30 = 1255813953488372093071428574;
    uint256 internal constant E0_THIN_30 = 7441860465116279070;

    // ============================ THICK tier (24.5 ETH grad mcap) ============================
    uint256 internal constant K_THICK_0 = 6253718024985127899975354808061124330755737114;
    uint256 internal constant T0_THICK_0 = 219512195121951219507389163;
    uint256 internal constant E0_THICK_0 = 5128048780487804878;
    uint256 internal constant K_THICK_5 = 6976819737417607293294137614554618979298262899;
    uint256 internal constant T0_THICK_5 = 247922437673130193933990149;
    uint256 internal constant E0_THICK_5 = 5824099722991689751;
    uint256 internal constant K_THICK_10 = 7987184623602892833572001509177555884286876342;
    uint256 internal constant T0_THICK_10 = 285256410256410256405911331;
    uint256 internal constant E0_THICK_10 = 6738782051282051282;
    uint256 internal constant K_THICK_15 = 9485248088016307883885191243732127108967079361;
    uint256 internal constant T0_THICK_15 = 336501901140684410659113301;
    uint256 internal constant E0_THICK_15 = 7994296577946768061;
    uint256 internal constant K_THICK_20 = 11899903921739889946934235065390208751856949496;
    uint256 internal constant T0_THICK_20 = 411214953271028037391133006;
    uint256 internal constant E0_THICK_20 = 9824766355140186916;
    uint256 internal constant K_THICK_25 = 16314164370982552800226420068517447199269144648;
    uint256 internal constant T0_THICK_25 = 530303030303030303014778327;
    uint256 internal constant E0_THICK_25 = 12742424242424242424;
    uint256 internal constant K_THICK_30 = 26281250000000000000000000036250000000000000000;
    uint256 internal constant T0_THICK_30 = 750000000000000000000000002;
    uint256 internal constant E0_THICK_30 = 18125000000000000000;

    /// @notice Returns the graduation threshold + max-excess for a liquidity tier (passed to the
    ///         `ConstantProductBondingCurveConfigurable` constructor for that tier's curves).
    function tierGraduation(LiquidityTier tier) internal pure returns (uint256 threshold, uint256 maxExcess) {
        maxExcess = GRADUATION_MAX_EXCESS;
        if (tier == LiquidityTier.THIN) return (2.0 ether, maxExcess);
        if (tier == LiquidityTier.DEFAULT) return (3.75 ether, maxExcess);
        if (tier == LiquidityTier.THICK) return (7.25 ether, maxExcess);
        revert InvalidLiquidityTier();
    }

    /// @notice DEFAULT-tier vault curve constants for a given locked allocation (in bps). Kept for the
    ///         existing creator-vault deploy path. Must be a multiple of 500 in [500, 3000].
    function paramsForBps(uint256 totalBps) internal pure returns (uint256 k, uint256 t0, uint256 e0) {
        if (totalBps == 500) return (K_5, T0_5, E0_5);
        if (totalBps == 1000) return (K_10, T0_10, E0_10);
        if (totalBps == 1500) return (K_15, T0_15, E0_15);
        if (totalBps == 2000) return (K_20, T0_20, E0_20);
        if (totalBps == 2500) return (K_25, T0_25, E0_25);
        if (totalBps == 3000) return (K_30, T0_30, E0_30);
        revert InvalidVaultBps(totalBps);
    }

    /// @notice Curve constants for a (tier, locked-allocation) pair.
    /// @param tier The liquidity tier.
    /// @param totalBps Total supply locked across all vaults, in bps. For THIN/THICK: a multiple of
    ///        500 in [0, 3000] (0 = no vault). For DEFAULT: [500, 3000] — the no-vault DEFAULT curve
    ///        is the deployed hardcoded base curve, so `(DEFAULT, 0)` has no entry and reverts.
    function paramsFor(LiquidityTier tier, uint256 totalBps) internal pure returns (uint256 k, uint256 t0, uint256 e0) {
        if (tier == LiquidityTier.DEFAULT) return paramsForBps(totalBps);
        if (tier == LiquidityTier.THIN) return _paramsThin(totalBps);
        if (tier == LiquidityTier.THICK) return _paramsThick(totalBps);
        revert InvalidLiquidityTier();
    }

    function _paramsThin(uint256 totalBps) private pure returns (uint256 k, uint256 t0, uint256 e0) {
        if (totalBps == 0) return (K_THIN_0, T0_THIN_0, E0_THIN_0);
        if (totalBps == 500) return (K_THIN_5, T0_THIN_5, E0_THIN_5);
        if (totalBps == 1000) return (K_THIN_10, T0_THIN_10, E0_THIN_10);
        if (totalBps == 1500) return (K_THIN_15, T0_THIN_15, E0_THIN_15);
        if (totalBps == 2000) return (K_THIN_20, T0_THIN_20, E0_THIN_20);
        if (totalBps == 2500) return (K_THIN_25, T0_THIN_25, E0_THIN_25);
        if (totalBps == 3000) return (K_THIN_30, T0_THIN_30, E0_THIN_30);
        revert InvalidVaultBps(totalBps);
    }

    function _paramsThick(uint256 totalBps) private pure returns (uint256 k, uint256 t0, uint256 e0) {
        if (totalBps == 0) return (K_THICK_0, T0_THICK_0, E0_THICK_0);
        if (totalBps == 500) return (K_THICK_5, T0_THICK_5, E0_THICK_5);
        if (totalBps == 1000) return (K_THICK_10, T0_THICK_10, E0_THICK_10);
        if (totalBps == 1500) return (K_THICK_15, T0_THICK_15, E0_THICK_15);
        if (totalBps == 2000) return (K_THICK_20, T0_THICK_20, E0_THICK_20);
        if (totalBps == 2500) return (K_THICK_25, T0_THICK_25, E0_THICK_25);
        if (totalBps == 3000) return (K_THICK_30, T0_THICK_30, E0_THICK_30);
        revert InvalidVaultBps(totalBps);
    }
}
