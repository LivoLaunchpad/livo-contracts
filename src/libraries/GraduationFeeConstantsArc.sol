// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GraduationFeeConstantsArc
/// @notice ARC (Circle L1, native currency = USDC, $1) variant of `GraduationFeeConstants`.
/// @dev The graduation fee is the Ethereum amount × 2000 (ETH assumed $2000), i.e. the SAME fee in
///      USD terms: $500. The triggerer compensation is NOT scaled 1:1 — $2 instead of the ×2000 $10 —
///      because it only offsets the lazy-pair-deploy gas, which is far cheaper on ARC.
///      Import-swapped in by the `chain-arc-*` recipe. See [[arc-integration-plan]].
library GraduationFeeConstantsArc {
    /// @notice Total graduation fee: $500 (0.25 ETH × 2000).
    uint256 internal constant GRADUATION_FEE = 500 ether;

    /// @notice Triggerer compensation: $2. Deliberately below the ×2000 scaling (which would be $10):
    ///         it reimburses ARC gas, not ETH gas.
    uint256 internal constant TRIGGERER_GRADUATION_COMPENSATION = 2 ether;

    /// @notice Build-vs-target guard, called from BOTH graduator constructors (see the note on the ETH
    ///         `GraduationFeeConstants.assertDeployableOn`). This is the ARC (native = USDC) lib, so a
    ///         graduator that baked it MUST land only on an ARC chain — otherwise its ×2000 fees and
    ///         shifted pool geometry are wrong. Allow-list of the ARC chain-ids.
    /// @dev ARC chain-ids: testnet 5042002, mainnet 5042. See [[arc-chain-facts]].
    function assertDeployableOn(uint256 chainId) internal pure {
        require(
            chainId == 5042002 || chainId == 5042,
            "GraduationFeeConstantsArc: ARC graduator on a non-ARC chain -- run the matching `just chain-*` (e.g. chain-mainnet) && rebuild"
        );
    }
}
