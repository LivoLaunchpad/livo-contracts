// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {DividendRoute} from "src/types/DividendRoute.sol";

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

/// @notice The earnings-allocation split: the bps of post-graduation earnings (swap tax + LP-fee
///         creator share) routed to buy-back-and-burn, holder dividends, and liquidity additions. The
///         fund wallets take the remainder. All-zero = no allocation (100% to the fund wallets).
/// @dev A non-zero `dividendsBps` also needs the payout fields. `dividendToken` is the ONE asset holders
///      are paid in: `address(0)` for native, `DividendDistribution.DIVIDEND_SELF_TOKEN` for the token
///      itself, or any ERC20. `dividendRoute` names the pool that ERC20 is bought on, and doubles as its
///      proof of liquidity — the token verifies at creation that the pool exists and is deep enough to
///      swap against, which is the ONLY thing that makes an asset eligible. There is no whitelist and no
///      admin approval. Both fields are permanent: a clone cannot be patched afterwards. `dividendRoute`
///      is ignored for the native and self-token payouts, which have nothing to buy.
struct EarningsAllocationConfig {
    uint16 burnBps;
    uint16 dividendsBps;
    uint16 liquidityBps;
    address dividendToken;
    DividendRoute dividendRoute;
}

/// @notice The full `TaxConfigs` fields (flattened) plus a nested `earningsAllocation` split. Consumed
///         by the allocation-aware `createToken` overload, which lifts the tax fields back into a
///         `TaxConfigs` for the shared creation pipeline and forwards `earningsAllocation` to
///         `initializeEarningsAllocation` at creation.
/// @dev A non-zero allocation requires a token with a long-term static tax (`taxDurationSeconds != 0`);
///      decay-only tokens are rejected by the factories (`EarningsAllocationRequiresTax`).
///      The leading fields mirror `TaxConfigs` exactly.
struct TaxConfigsWithAllocation {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
    bool startTaxFromLaunch;
    uint16 buyTaxDecayStartBps;
    uint16 sellTaxDecayStartBps;
    uint32 taxDecayDuration;
    EarningsAllocationConfig earningsAllocation;
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

    /// @notice Initializes a taxable-token clone. Used by the factory to dispatch into either V2 or V4
    ///         concrete tax-token implementations through a single shared type. Takes the full
    ///         `TaxConfigs` (the factory builds it from `TaxConfigInit` on the legacy paths, or passes
    ///         it through on the new path) plus the `AntiSniperConfigs`; anti-sniper protection is
    ///         enabled iff that config opts in (`protectionWindowSeconds != 0`), gated inside the token.
    function initialize(
        ILivoToken.InitializeParams memory params,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external;

    /// @notice Owner-only setter for `buyTaxBps` / `sellTaxBps`. Currently enforces decrease-only —
    ///         attempts to raise either rate revert.
    function setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps) external;

    /// @notice Factory-only, creation-time setter for the earnings-allocation split (burn / dividends /
    ///         liquidity bps; the fund wallets take the remainder). Guarded by the transient factory,
    ///         so it is only callable during the deploy tx.
    function initializeEarningsAllocation(uint16 burnBps, uint16 dividendsBps, uint16 liquidityBps) external;

    /// @notice Same as above plus the dividend payout configuration (which asset the dividends slice
    ///         buys, and the pool it is bought on). Separate overload so the original signature is
    ///         untouched.
    function initializeEarningsAllocation(
        uint16 burnBps,
        uint16 dividendsBps,
        uint16 liquidityBps,
        address dividendToken,
        DividendRoute calldata dividendRoute
    ) external;
}
