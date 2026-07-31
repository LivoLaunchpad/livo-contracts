// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @title CreatorVaultCurveConstantsArc
/// @notice ARC-chain (Circle L1, native = USDC) counterpart of `CreatorVaultCurveConstants`.
///         ARC's native currency is 18-decimal at the msg.value/balance level (identical to ETH/wei),
///         so the curve MATH is unchanged; only the economics are repriced. Because 1 native unit is
///         ~$1 on ARC vs ~$2000 for ETH, the graduation thresholds / marketcaps / fees are scaled by
///         2000 to preserve the same USD economics, and the `(K, T0, E0)` constants are RE-SOLVED for
///         those targets (they are nonlinear in the price and cannot be linearly scaled).
/// @dev    Regenerate with:
///           uv run simulations/script/find_creator_vault_curve_params.py --scale=2000 --solidity
///         For EVERY (tier, bps) the solver hits t(0)=S and t(threshold)=T_GRAD to 0 wei with a
///         <1e-20% graduation-price deviation (same quality as the ETH library).
///
///         Unlike the ETH library, the DEFAULT no-vault (0%) slot IS present here: on ARC every curve
///         — including the base — is a `ConstantProductBondingCurveConfigurable` instance (there is no
///         hardcoded ARC base curve), so `(DEFAULT, 0)` = `DEFAULT_0` is a real entry.
///
///         Graduation invariants per tier (native units; grad mcap scales 1:2:4 with LP depth):
///           - THIN    : threshold  4000, native into liquidity  3500, grad mcap 12250
///           - DEFAULT : threshold  7500, native into liquidity  7000, grad mcap 24500
///           - THICK   : threshold 14500, native into liquidity 14000, grad mcap 49000
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

    /// @notice Max native accepted above any tier's graduation threshold. 0.05 ETH x 2000.
    uint256 internal constant GRADUATION_MAX_EXCESS = 100 ether;

    // ---- DEFAULT tier (lp 7000, grad mcap 24500, threshold 7500) ----
    uint256 internal constant K_DEFAULT_0 = 7031250000000000000000000005625000000000000000000;
    uint256 internal constant T0_DEFAULT_0 = 250000000000000000000000001;
    uint256 internal constant E0_DEFAULT_0 = 5625000000000000000000;
    uint256 internal constant K_DEFAULT_5 = 7897764628533859303089610833004602235371466146520;
    uint256 internal constant T0_DEFAULT_5 = 282051282051282051282028572;
    uint256 internal constant E0_DEFAULT_5 = 6410256410256410256410;
    uint256 internal constant K_DEFAULT_10 = 9122955133546774264285876472934301127143546350400;
    uint256 internal constant T0_DEFAULT_10 = 324503311258278145695329525;
    uint256 internal constant E0_DEFAULT_10 = 7450331125827814569536;
    uint256 internal constant K_DEFAULT_15 = 10968965301754440781765274854457966848411942071568;
    uint256 internal constant T0_DEFAULT_15 = 383399209486166007905146668;
    uint256 internal constant E0_DEFAULT_15 = 8893280632411067193676;
    uint256 internal constant K_DEFAULT_20 = 14013840830449826989619019491782006920415224915630;
    uint256 internal constant T0_DEFAULT_20 = 470588235294117647058811430;
    uint256 internal constant E0_DEFAULT_20 = 11029411764705882352941;
    uint256 internal constant K_DEFAULT_25 = 19784079084287200832466108130541103017689906347619;
    uint256 internal constant T0_DEFAULT_25 = 612903225806451612903223811;
    uint256 internal constant E0_DEFAULT_25 = 14516129032258064516129;
    uint256 internal constant K_DEFAULT_30 = 33681915272338910644356225189124243503025987906450;
    uint256 internal constant T0_DEFAULT_30 = 886792452830188679245259050;
    uint256 internal constant E0_DEFAULT_30 = 21226415094339622641509;

    // ---- THIN tier (lp 3500, grad mcap 12250, threshold 4000) ----
    uint256 internal constant K_THIN_0 = 4432132963988919667589220423800554016620498646616;
    uint256 internal constant T0_THIN_0 = 315789473684210526315714287;
    uint256 internal constant E0_THIN_0 = 3368421052631578947368;
    uint256 internal constant K_THIN_5 = 5052308759503838044559639927882366900630698880082;
    uint256 internal constant T0_THIN_5 = 356495468277945619335346429;
    uint256 internal constant E0_THIN_5 = 3867069486404833836858;
    uint256 internal constant K_THIN_10 = 5952215683315728585081860081211206679744479668896;
    uint256 internal constant T0_THIN_10 = 411347517730496453900757144;
    uint256 internal constant E0_THIN_10 = 4539007092198581560284;
    uint256 internal constant K_THIN_15 = 7357365212105583083130204398771021753946471694107;
    uint256 internal constant T0_THIN_15 = 489270386266094420600926787;
    uint256 internal constant E0_THIN_15 = 5493562231759656652361;
    uint256 internal constant K_THIN_20 = 9799621928166351606805993957807183364839319482609;
    uint256 internal constant T0_THIN_20 = 608695652173913043478300001;
    uint256 internal constant E0_THIN_20 = 6956521739130434782609;
    uint256 internal constant K_THIN_25 = 14836762688614540466391034943978052126200274375330;
    uint256 internal constant T0_THIN_25 = 814814814814814814814758930;
    uint256 internal constant E0_THIN_25 = 9481481481481481481481;
    uint256 internal constant K_THIN_30 = 29109789075175770686858167662087614926987560845100;
    uint256 internal constant T0_THIN_30 = 1255813953488372093023267860;
    uint256 internal constant E0_THIN_30 = 14883720930232558139535;

    // ---- THICK tier (lp 14000, grad mcap 49000, threshold 14500) ----
    uint256 internal constant K_THICK_0 = 12507436049970255800119734004244199881023200485402;
    uint256 internal constant T0_THICK_0 = 219512195121951219512216749;
    uint256 internal constant E0_THICK_0 = 10256097560975609756098;
    uint256 internal constant K_THICK_5 = 13953639474835214585523366343278213027831278151720;
    uint256 internal constant T0_THICK_5 = 247922437673130193905815272;
    uint256 internal constant E0_THICK_5 = 11648199445983379501385;
    uint256 internal constant K_THICK_10 = 15974369247205785667324894413018573307034845504434;
    uint256 internal constant T0_THICK_10 = 285256410256410256410274878;
    uint256 internal constant E0_THICK_10 = 13477564102564102564103;
    uint256 internal constant K_THICK_15 = 18970496176032615767178931684897714293975624918678;
    uint256 internal constant T0_THICK_15 = 336501901140684410646387686;
    uint256 internal constant E0_THICK_15 = 15988593155893536121673;
    uint256 internal constant K_THICK_20 = 23799807843479779893441045843233688531749497775904;
    uint256 internal constant T0_THICK_20 = 411214953271028037383188179;
    uint256 internal constant E0_THICK_20 = 19649532710280373831776;
    uint256 internal constant K_THICK_25 = 32628328741965105601469555488428833792470156107255;
    uint256 internal constant T0_THICK_25 = 530303030303030303030307883;
    uint256 internal constant E0_THICK_25 = 25484848484848484848485;
    uint256 internal constant K_THICK_30 = 52562500000000000000000000072500000000000000000000;
    uint256 internal constant T0_THICK_30 = 750000000000000000000000002;
    uint256 internal constant E0_THICK_30 = 36250000000000000000000;

    /// @notice Returns the graduation threshold + max-excess for a liquidity tier (passed to the
    ///         `ConstantProductBondingCurveConfigurable` constructor for that tier's curves).
    function tierGraduation(LiquidityTier tier) internal pure returns (uint256 threshold, uint256 maxExcess) {
        maxExcess = GRADUATION_MAX_EXCESS;
        if (tier == LiquidityTier.THIN) return (4000 ether, maxExcess);
        if (tier == LiquidityTier.DEFAULT) return (7500 ether, maxExcess);
        if (tier == LiquidityTier.THICK) return (14500 ether, maxExcess);
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
