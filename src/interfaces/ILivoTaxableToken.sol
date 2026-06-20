// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @notice Initialization-time tax configuration for taxable tokens (legacy: static tax only).
/// @dev Separate from `ILivoToken.TaxConfig` (which adds the post-init `graduationTimestamp`).
/// @dev Kept unchanged for the backwards-compatible `createToken` overloads so existing integrators
///      aren't broken. The optional launch-tax decay lives in the superset `TaxConfigs`; the legacy
///      overloads lift this struct into a `TaxConfigs` (zeroing the decay fields) before dispatch.
struct TaxConfigInit {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
    /// @dev Anchor for the tax window. `true`: window runs `[launchTimestamp, launchTimestamp + duration]`
    ///      (starts at token creation, spans graduation). `false`: window runs
    ///      `[graduationTimestamp, graduationTimestamp + duration]` (no tax before graduation).
    bool startTaxFromLaunch;
}

/// @notice Full initialization-time tax configuration: the static tax of `TaxConfigInit` plus the
///         optional linearly-decaying launch tax. Consumed by the new struct-based `createToken`
///         overload and the whole internal token-init pipeline; the legacy `createToken` overloads build
///         one in memory from a `TaxConfigInit` (decay fields zeroed) before dispatch.
/// @dev The three `*Decay*` fields configure the optional linearly-decaying launch tax. It runs from
///      the SAME anchor `startTaxFromLaunch` selects, decaying each direction linearly from its start
///      rate to 0 over `taxDecayDuration`. The effective rate a trade pays is `max(decay, static)` per
///      direction, so a token may set ONLY the decay fields (static bps + duration all zero) to get a
///      pure decaying launch tax with no long-term tax — a "non-taxable token with tax decay". Such a
///      token is still deployed as a taxable-impl clone (the post-graduation collection machinery lives
///      there); its dispatch is triggered by `taxDecayDuration != 0` alone.
struct TaxConfigs {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
    /// @dev Anchor for BOTH the static and decay windows. `true`: windows run from `launchTimestamp`
    ///      (start at token creation, span graduation). `false`: windows run from `graduationTimestamp`
    ///      (no tax before graduation).
    bool startTaxFromLaunch;
    uint16 buyTaxDecayStartBps; // buy decay rate at the anchor (decays to 0 over taxDecayDuration); 0 = no buy decay
    uint16 sellTaxDecayStartBps; // sell decay rate at the anchor (decays to 0 over taxDecayDuration); 0 = no sell decay
    uint32 taxDecayDuration; // seconds over which the decay rate falls from its start to 0; 0 = no decay
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
    ///         or V4 concrete tax-token implementations through a single shared type. Takes the full
    ///         `TaxConfigs` so the clone receives any launch-tax-decay config; the factory builds it
    ///         (from `TaxConfigInit` on the legacy paths, or passes it through on the new path).
    function initialize(ILivoToken.InitializeParams memory params, TaxConfigs memory taxCfg) external;

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
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external;
}
