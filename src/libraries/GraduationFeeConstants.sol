// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GraduationFeeConstants
/// @notice Per-chain graduation fee amounts, in the native unit (18-dec wei-scale).
/// @dev The graduators reference these via a local alias so the `graduators-arc-*` recipe can
///      import-swap this file for `GraduationFeeConstantsArc` (native = USDC), exactly like the
///      taxable tokens swap `DeploymentAddresses`. Ethereum/Robinhood values (native = ETH) below.
library GraduationFeeConstants {
    /// @notice Total graduation fee (creator compensation + treasury fee [+ triggerer, V2 only]).
    uint256 internal constant GRADUATION_FEE = 0.25 ether;

    /// @notice Native compensation paid to `tx.origin` for triggering V2 graduation (offsets the gas
    ///         of the lazy pair deploy inside `graduateToken()`).
    uint256 internal constant TRIGGERER_GRADUATION_COMPENSATION = 0.005 ether;

    /// @notice Build-vs-target guard, called from BOTH graduator constructors so EVERY graduator
    ///         deployment is checked automatically (any script, a raw `cast` deploy, or a test) — the
    ///         graduators bake this whole lib (fees + the V4 pool geometry that swaps in lockstep with
    ///         it) at compile time, and the V4 constructor's own sanity checks do NOT catch an ETH-built
    ///         graduator deployed to ARC. This is the ETH-priced lib, so it must NOT land on an ARC
    ///         (native = USDC) chain. Deny-list keeps it future-proof for new ETH-family chains.
    /// @dev ARC chain-ids (native = USDC): testnet 5042002, mainnet 5402 (placeholder). See [[arc-chain-facts]].
    function assertDeployableOn(uint256 chainId) internal pure {
        require(
            chainId != 5042002 && chainId != 5402,
            "GraduationFeeConstants: ETH-priced graduator on an ARC chain -- run `just graduators-arc-testnet` && rebuild"
        );
    }
}
