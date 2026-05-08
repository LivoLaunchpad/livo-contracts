// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @notice Initialization-time tax configuration for taxable tokens.
/// @dev Separate from `ILivoToken.TaxConfig` (which adds the post-init `graduationTimestamp`).
struct TaxConfigInit {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
}

/// @title ILivoTaxableToken
/// @notice Unified interface for Livo taxable tokens, regardless of the underlying graduation
///         venue (Uniswap V2 with intrinsic taxation, Uniswap V4 with hook-driven taxation).
/// @dev Extends `ILivoToken`. Variant-specific entry points (e.g. V2's owner-only `swapBack`)
///      are not surfaced here — callers that need them should cast to the concrete contract.
interface ILivoTaxableToken is ILivoToken {
    /// @notice Returns the graduation timestamp for this token (0 before graduation).
    function graduationTimestamp() external view returns (uint40);
}
