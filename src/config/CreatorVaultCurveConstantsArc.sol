// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @title CreatorVaultCurveConstantsArc
/// @notice ARC-chain (Circle L1, native = USDC) counterpart of `CreatorVaultCurveConstants`.
///         ARC's native currency is 18-decimal at the msg.value/balance level (identical to ETH/wei),
///         so the curve MATH is unchanged; only the economics are repriced. Because 1 native unit is
///         ~$1 on ARC vs ~$2500 for ETH, the graduation thresholds / marketcaps / fees are scaled by
///         2500 to preserve the same USD economics, and the `(K, T0, E0)` constants are RE-SOLVED for
///         those targets (they are nonlinear in the price and cannot be linearly scaled).
/// @dev    Regenerate with:
///           uv run simulations/script/find_creator_vault_curve_params.py --scale=2500 --solidity
///         For EVERY (tier, bps) the solver hits t(0)=S and t(threshold)=T_GRAD to 0 wei with a
///         <1e-20% graduation-price deviation (same quality as the ETH library).
///
///         Unlike the ETH library, the DEFAULT no-vault (0%) slot IS present here: on ARC every curve
///         — including the base — is a `ConstantProductBondingCurveConfigurable` instance (there is no
///         hardcoded ARC base curve), so `(DEFAULT, 0)` = `DEFAULT_0` is a real entry.
///
///         Graduation invariants per tier (native units; grad mcap scales 1:2:4 with LP depth):
///           - THIN    : threshold  5000, eth into liquidity  4375, grad mcap 15312.5
///           - DEFAULT : threshold  9375, eth into liquidity  8750, grad mcap 30625
///           - THICK   : threshold 18125, eth into liquidity 17500, grad mcap 61250
///         tokens into liquidity (T_GRAD) = 285,714,285.714...M for every tier and every bps (same as
///         the ETH curves — the token split is scale-invariant).
library CreatorVaultCurveConstantsArc {
    /// @notice Thrown by `paramsForBps`/`paramsFor` when `totalBps` is not a supported allocation.
    error InvalidVaultBps(uint256 totalBps);
    /// @notice Thrown by `tierGraduation`/`paramsFor` on an unknown tier.
    error InvalidLiquidityTier();

    /// @notice Allocation step (5% in bps) and bounds for creator vaults.
    uint256 internal constant VAULT_BPS_STEP = 500; // 5%
    uint256 internal constant MAX_VAULT_TOTAL_BPS = 3000; // 30%

    /// @notice Max native accepted above any tier's graduation threshold. 0.05 ETH x 2500.
    uint256 internal constant GRADUATION_MAX_EXCESS = 125 ether;

    // ---- DEFAULT tier (lp 8750, grad mcap 30625, threshold 9375) ----
    uint256 internal constant K_DEFAULT_0 = 8789062500000000000000000007031250000000000000000;
    uint256 internal constant T0_DEFAULT_0 = 250000000000000000000000001;
    uint256 internal constant E0_DEFAULT_0 = 7031250000000000000000;
    uint256 internal constant K_DEFAULT_5 = 9872205785667324128862913453114727153188691652513;
    uint256 internal constant T0_DEFAULT_5 = 282051282051282051282064001;
    uint256 internal constant E0_DEFAULT_5 = 8012820512820512820513;
    uint256 internal constant K_DEFAULT_10 = 11403693916933467830359180313849995614227446179129;
    uint256 internal constant T0_DEFAULT_10 = 324503311258278145695395049;
    uint256 internal constant E0_DEFAULT_10 = 9312913907284768211921;
    uint256 internal constant K_DEFAULT_15 = 13711206627193050977206593568072458560514927589460;
    uint256 internal constant T0_DEFAULT_15 = 383399209486166007905146668;
    uint256 internal constant E0_DEFAULT_15 = 11116600790513833992095;
    uint256 internal constant K_DEFAULT_20 = 17517301038062283737023267645977508650519031154016;
    uint256 internal constant T0_DEFAULT_20 = 470588235294117647058797716;
    uint256 internal constant E0_DEFAULT_20 = 13786764705882352941176;
    uint256 internal constant K_DEFAULT_25 = 24730098855359001040582069782127991675338189390230;
    uint256 internal constant T0_DEFAULT_25 = 612903225806451612903211430;
    uint256 internal constant E0_DEFAULT_25 = 18145161290322580645161;
    uint256 internal constant K_DEFAULT_30 = 42102394090423638305447350964589266642933428268191;
    uint256 internal constant T0_DEFAULT_30 = 886792452830188679245292193;
    uint256 internal constant E0_DEFAULT_30 = 26533018867924528301887;

    // ---- THIN tier (lp 4375, grad mcap 15312.5, threshold 5000) ----
    uint256 internal constant K_THIN_0 = 5540166204986149584488442822382271468144044353384;
    uint256 internal constant T0_THIN_0 = 315789473684210526315857144;
    uint256 internal constant E0_THIN_0 = 4210526315789473684211;
    uint256 internal constant K_THIN_5 = 6315385949379797555700524264535738081981727106634;
    uint256 internal constant T0_THIN_5 = 356495468277945619335412858;
    uint256 internal constant E0_THIN_5 = 4833836858006042296073;
    uint256 internal constant K_THIN_10 = 7440269604144660731352325101514008349680599586120;
    uint256 internal constant T0_THIN_10 = 411347517730496453900757144;
    uint256 internal constant E0_THIN_10 = 5673758865248226950355;
    uint256 internal constant K_THIN_15 = 9196706515131978853912226936661202085136952251423;
    uint256 internal constant T0_THIN_15 = 489270386266094420600898573;
    uint256 internal constant E0_THIN_15 = 6866952789699570815451;
    uint256 internal constant K_THIN_20 = 12249527410207939508506916673345935727788279774907;
    uint256 internal constant T0_THIN_20 = 608695652173913043478274287;
    uint256 internal constant E0_THIN_20 = 8695652173913043478261;
    uint256 internal constant K_THIN_25 = 18545953360768175582990792689602194787379972567196;
    uint256 internal constant T0_THIN_25 = 814814814814814814814828573;
    uint256 internal constant E0_THIN_25 = 11851851851851851851852;
    uint256 internal constant K_THIN_30 = 36387236343969713358573583907842076798269334788506;
    uint256 internal constant T0_THIN_30 = 1255813953488372093023288574;
    uint256 internal constant E0_THIN_30 = 18604651162790697674419;

    // ---- THICK tier (lp 17500, grad mcap 61250, threshold 18125) ----
    uint256 internal constant K_THICK_0 = 15634295062462819750148805141524762046400951814490;
    uint256 internal constant T0_THICK_0 = 219512195121951219512197045;
    uint256 internal constant E0_THICK_0 = 12820121951219512195122;
    uint256 internal constant K_THICK_5 = 17442049343544018231903775032923943570107657249679;
    uint256 internal constant T0_THICK_5 = 247922437673130193905806109;
    uint256 internal constant E0_THICK_5 = 14560249307479224376731;
    uint256 internal constant K_THICK_10 = 19967961559007232084154800841213120479947403025752;
    uint256 internal constant T0_THICK_10 = 285256410256410256410249459;
    uint256 internal constant E0_THICK_10 = 16846955128205128205128;
    uint256 internal constant K_THICK_15 = 23713120220040769708973212411635450852260405675082;
    uint256 internal constant T0_THICK_15 = 336501901140684410646379902;
    uint256 internal constant E0_THICK_15 = 19985741444866920152091;
    uint256 internal constant K_THICK_20 = 29749759804349724866801307304042110664686872219880;
    uint256 internal constant T0_THICK_20 = 411214953271028037383188179;
    uint256 internal constant E0_THICK_20 = 24561915887850467289720;
    uint256 internal constant K_THICK_25 = 40785410927456382001836420278566345270890725436274;
    uint256 internal constant T0_THICK_25 = 530303030303030303030301479;
    uint256 internal constant E0_THICK_25 = 31856060606060606060606;
    uint256 internal constant K_THICK_30 = 65703125000000000000000000090625000000000000000000;
    uint256 internal constant T0_THICK_30 = 750000000000000000000000002;
    uint256 internal constant E0_THICK_30 = 45312500000000000000000;

    /// @notice Returns the graduation threshold + max-excess for a liquidity tier (passed to the
    ///         `ConstantProductBondingCurveConfigurable` constructor for that tier's curves).
    function tierGraduation(LiquidityTier tier) internal pure returns (uint256 threshold, uint256 maxExcess) {
        maxExcess = GRADUATION_MAX_EXCESS;
        if (tier == LiquidityTier.THIN) return (5000 ether, maxExcess);
        if (tier == LiquidityTier.DEFAULT) return (9375 ether, maxExcess);
        if (tier == LiquidityTier.THICK) return (18125 ether, maxExcess);
        revert InvalidLiquidityTier();
    }

    /// @notice Curve constants for a (tier, locked-allocation) pair. Unlike the ETH library, DEFAULT
    ///         accepts totalBps == 0 (ARC's base curve is a configurable instance, not hardcoded).
    function paramsFor(LiquidityTier tier, uint256 totalBps) internal pure returns (uint256 k, uint256 t0, uint256 e0) {
        if (tier == LiquidityTier.DEFAULT) return _paramsDefault(totalBps);
        if (tier == LiquidityTier.THIN) return _paramsThin(totalBps);
        if (tier == LiquidityTier.THICK) return _paramsThick(totalBps);
        revert InvalidLiquidityTier();
    }

    function _paramsDefault(uint256 totalBps) private pure returns (uint256 k, uint256 t0, uint256 e0) {
        if (totalBps == 0) return (K_DEFAULT_0, T0_DEFAULT_0, E0_DEFAULT_0);
        if (totalBps == 500) return (K_DEFAULT_5, T0_DEFAULT_5, E0_DEFAULT_5);
        if (totalBps == 1000) return (K_DEFAULT_10, T0_DEFAULT_10, E0_DEFAULT_10);
        if (totalBps == 1500) return (K_DEFAULT_15, T0_DEFAULT_15, E0_DEFAULT_15);
        if (totalBps == 2000) return (K_DEFAULT_20, T0_DEFAULT_20, E0_DEFAULT_20);
        if (totalBps == 2500) return (K_DEFAULT_25, T0_DEFAULT_25, E0_DEFAULT_25);
        if (totalBps == 3000) return (K_DEFAULT_30, T0_DEFAULT_30, E0_DEFAULT_30);
        revert InvalidVaultBps(totalBps);
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
