// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title CreatorVaultCurveConstants
/// @notice Single source of truth for the `(K, T0, E0)` constants of the six creator-vault bonding
///         curves, one per locked allocation (5%, 10%, 15%, 20%, 25%, 30% of the 1B supply).
/// @dev    Derived in `simulations/script/find_creator_vault_curve_params.py`. Each set keeps EVERY
///         graduation invariant identical to the base `ConstantProductBondingCurve`:
///           - eth reserves at graduation : 3.75 ETH
///           - eth into liquidity         : 3.5 ETH
///           - tokens into liquidity      : 285,714,285.714...M (T_GRAD, identical to 1 wei)
///           - graduation price           : 1.225e-8 wei/wei
///           - graduation marketcap       : 12.25 ETH
///         Only the starting market cap is relaxed (it rises as more supply is locked).
///         Consumed by the deploy script and the invariant tests.
library CreatorVaultCurveConstants {
    /// @notice Allocation step (5% in bps) and bounds for creator vaults.
    uint256 internal constant VAULT_BPS_STEP = 500; // 5%
    uint256 internal constant MAX_VAULT_TOTAL_BPS = 3000; // 30%

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

    /// @notice Returns the curve constants for a given total locked allocation (in bps).
    /// @param totalBps Total supply locked across all vaults, in bps. Must be a multiple of 500 in
    ///        the inclusive range [500, 3000].
    /// @return k Constant K
    /// @return t0 Constant T0
    /// @return e0 Constant E0
    function paramsForBps(uint256 totalBps) internal pure returns (uint256 k, uint256 t0, uint256 e0) {
        if (totalBps == 500) return (K_5, T0_5, E0_5);
        if (totalBps == 1000) return (K_10, T0_10, E0_10);
        if (totalBps == 1500) return (K_15, T0_15, E0_15);
        if (totalBps == 2000) return (K_20, T0_20, E0_20);
        if (totalBps == 2500) return (K_25, T0_25, E0_25);
        if (totalBps == 3000) return (K_30, T0_30, E0_30);
        revert("CreatorVaultCurveConstants: invalid bps");
    }
}
