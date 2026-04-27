// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @notice Initialization-time tax configuration for taxable tokens.
/// @dev Separate from `ILivoToken.TaxConfig` (which includes the post-init `graduationTimestamp`).
struct TaxConfigInit {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
}

/// @title ILivoTaxableTokenUniV4
/// @notice Interface for tokens that support time-limited buy/sell taxes via Uniswap V4 hooks
/// @dev Extends ILivoToken to add tax configuration functionality
interface ILivoTaxableTokenUniV4 is ILivoToken {
    /// @notice Returns the graduation timestamp for this token
    function graduationTimestamp() external view returns (uint40);
}
