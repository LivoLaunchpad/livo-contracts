// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @notice Initialization-time tax configuration for taxable tokens.
/// @dev Init-time config only; the token's live fee state (incl. the post-graduation timestamp)
///      is tracked separately and read via `ILivoToken.getCurrentFees`.
/// @dev The per-swap LP fee is NOT part of this struct: it is a venue property set by the factory
///      via `ILivoToken.InitializeParams.lpFeeBps` (0 for V2, 50 or 100 for V4).
struct TaxConfigInit {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
}

/// @title ILivoTaxableToken
/// @notice Unified interface for Livo taxable tokens, regardless of the underlying graduation
///         venue (Uniswap V2 with intrinsic taxation, Uniswap V4 with hook-driven taxation).
/// @dev Extends `ILivoToken`. Variant-specific entry points (e.g. V2's owner-only `swapBack`)
///      and variant-specific events (e.g. V2's `CreatorTaxSwapback`) are not surfaced here —
///      callers that need them should cast to the concrete contract. On the V4 variant the
///      equivalent accrual is emitted by `LivoSwapHook` as `CreatorTaxesAccrued(token, amount)`.
interface ILivoTaxableToken is ILivoToken {
    /// @notice Returns the graduation timestamp for this token (0 before graduation).
    function graduationTimestamp() external view returns (uint40);

    /// @notice Initializes a taxable-token clone. Used by the factory to dispatch into either V2
    ///         or V4 concrete tax-token implementations through a single shared type.
    function initialize(ILivoToken.InitializeParams memory params, TaxConfigInit memory taxCfg) external;

    /// @notice Owner-only setter for `buyTaxBps` / `sellTaxBps`. Currently enforces decrease-only —
    ///         attempts to raise either rate revert.
    function setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps) external;
}

/// @title ILivoTaxableTokenSniperProtected
/// @notice Extension of `ILivoTaxableToken` for tax-token variants that also enforce anti-sniper
///         caps during the post-launch protection window.
/// @dev Used by `LivoFactoryAbstract._initializeTaxToken` to dispatch into the 3-arg `initialize`
///      overload through a venue-agnostic type.
interface ILivoTaxableTokenSniperProtected is ILivoTaxableToken {
    function initialize(
        ILivoToken.InitializeParams memory params,
        TaxConfigInit memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external;
}
