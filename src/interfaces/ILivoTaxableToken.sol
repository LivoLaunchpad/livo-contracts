// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @notice Initialization-time tax configuration for taxable tokens.
/// @dev Separate from `ILivoToken.TaxConfig` (which adds the post-init `graduationTimestamp`).
struct TaxConfigInit {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
    /// @dev Anchor for the tax window. `true`: window runs `[launchTimestamp, launchTimestamp + duration]`
    ///      (starts at token creation, spans graduation). `false`: window runs
    ///      `[graduationTimestamp, graduationTimestamp + duration]` (no tax before graduation).
    bool startTaxFromLaunch;
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

    /// @notice Tax-window anchor for this token: `true` if the window starts at token creation
    ///         (`launchTimestamp`), `false` if it starts at graduation (`graduationTimestamp`).
    function startTaxFromLaunch() external view returns (bool);

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
