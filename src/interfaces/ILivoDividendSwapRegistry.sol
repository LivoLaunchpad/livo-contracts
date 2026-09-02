// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Why a quote -> asset conversion is not available. `OK` is the only passing value; the rest
///         exist so a frontend can say WHICH gate the asset failed instead of "not supported".
enum SwapRejection {
    OK,
    /// @dev The `from` side is not on the quote allowlist. Never the creator's fault — it means the
    ///      registry has not been configured for the chain's quote currency.
    QuoteNotAllowed,
    /// @dev The asset is blacklisted. The one admin veto in the path.
    Blacklisted,
    /// @dev No Uniswap V2 pair exists for quote/asset. The common answer for a typo, a token on a
    ///      different chain, or a token whose only liquidity lives on V3/V4.
    NoPair,
    /// @dev The pair exists but holds less quote-side depth than the threshold for that quote token.
    InsufficientLiquidity
}

/// @notice One leg of a curated Uniswap V4 route: where the leg lands, and the three fields that —
///         together with the two currencies — identify the pool it crosses.
/// @dev V4 pools are keyed by `(currency0, currency1, fee, tickSpacing, hooks)`. The two currencies are
///      implied by the route's position, but the other three CANNOT be derived from them: one pair can
///      have any number of pools, and only one of them is the liquid one. That is the whole reason a V4
///      asset needs a stored route while a V2 asset needs nothing — see `ILivoDividendSwapRegistry`.
/// @dev Mirrors v4-periphery's `PathKey` minus `hookData`, which is always empty here: a route is
///      protocol configuration, not a place to hand arbitrary calldata to somebody's hook.
struct Hop {
    /// @dev Currency this leg buys. The LAST hop's currency is the dividend asset itself.
    address currency;
    /// @dev LP fee of the pool, in pips. `0x800000` for a dynamic-fee pool.
    uint24 fee;
    int24 tickSpacing;
    /// @dev `address(0)` for a hookless pool.
    address hooks;
}

/// @title ILivoDividendSwapRegistry
/// @notice The dividend feature's eligibility oracle AND its swap venue, behind one upgradeable proxy.
///
/// @dev WHY A SEPARATE CONTRACT. Taxable tokens are CLONES: whatever eligibility rule and whatever swap
///      route their implementation was compiled with is the rule and the route they die with. Putting
///      both behind a proxy at an address baked into the token's bytecode as a constant is the only way
///      a fix — a raised threshold, a blacklisted asset, a new venue — ever reaches a token that is
///      ALREADY live. That is the entire justification; it is not an abstraction for its own sake.
///
/// @dev WHAT THIS COSTS. Every token's dividend conversion now flows native currency through one shared
///      upgradeable contract, so whoever can upgrade it can, in principle, take the native sent for a
///      conversion in flight. Bounded per token per freeze by `MAX_DIVIDEND_PER_FREEZE`, never
///      custodial (the registry holds nothing between calls), and the calling token measures its own
///      balance delta rather than trusting the return value — so the worst case is a failed conversion,
///      which the round machinery already handles.
interface ILivoDividendSwapRegistry {
    /// @notice The token every native -> asset conversion goes through: the V2 router's canonical WETH.
    ///         Exposed so a caller can ask the registry which `quote` its own checks should name.
    function nativeQuoteToken() external view returns (address);

    /// @notice Whether `asset` can be bought with `quote` right now. Three ways in, and only three: any
    ///         ERC20 with a deep enough Uniswap V2 pair qualifies with nobody's permission, and an asset
    ///         an admin has given a Uniswap V4 or Uniswap V3 route qualifies because that route IS the
    ///         curation — an admin registers one only after checking the pool's depth AND its price
    ///         against the real market, neither of which a contract can judge for itself.
    function isSwapSupported(address quote, address asset) external view returns (bool);

    /// @notice `isSwapSupported` with the reason attached, for a frontend that wants to tell a creator
    ///         WHY their asset was refused before they pay for the transaction that refuses it.
    /// @return supported same answer as `isSwapSupported`
    /// @return trust the asset's trust status (0 unknown / 1 whitelisted / 2 blacklisted). Advisory
    ///         ONLY — `whitelisted` is a UI badge and is never required to pass.
    /// @return rejection which gate failed; `SwapRejection.OK` when `supported`
    function checkSwapSupported(address quote, address asset)
        external
        view
        returns (bool supported, uint8 trust, SwapRejection rejection);

    /// @notice The V2 pair a quote -> asset conversion would cross, and its quote-side depth. Lets a
    ///         keeper price its slippage floor against the exact pool the swap will hit.
    /// @dev Answers about the PERMISSIONLESS route only. An asset with a curated route has no V2 pair to
    ///      report and returns `(address(0), 0)` — read `routeOf` / `v3RouteOf` and price against those
    ///      pools instead.
    /// @return pair `address(0)` when no pair exists
    /// @return quoteDepth quote-side reserve, scaled to native 18-dec units
    function pairFor(address quote, address asset) external view returns (address pair, uint256 quoteDepth);

    /// @notice The curated Uniswap V4 route a conversion into `asset` crosses, hop by hop, starting from
    ///         the chain's native coin. Empty when the asset has none, which means it goes through the
    ///         permissionless V2 path instead.
    /// @dev A keeper needs this to price `minOut`: with a route set, the pools the swap will cross are
    ///      these and not the V2 pair `pairFor` would name.
    function routeOf(address asset) external view returns (Hop[] memory route);

    /// @notice The curated Uniswap V3 route a conversion into `asset` crosses, as V3's own encoded path
    ///         (`token | fee | token`, repeating). Empty when the asset has none.
    /// @dev The counterpart of `routeOf` for the V3 venue, and the reason it is a separate accessor: a
    ///      V3 pool is keyed by a fee tier alone, with no tick spacing and no hooks, so it does not fit
    ///      a `Hop` without two permanently dead fields.
    /// @dev A keeper prices `minOut` by quoting THIS path, not the V2 pair `pairFor` would name.
    function v3RouteOf(address asset) external view returns (bytes memory path);

    /// @notice Buys `asset` with the native currency sent, delivering it to `recipient`.
    /// @dev REVERTS on any failure — a dead pair, a missed floor, a disallowed asset. The caller is a
    ///      dividend freeze, which must not lose its buffer to a failed conversion: reverting is what
    ///      keeps the native with the caller, so it wraps this in a low-level call and reads the boolean.
    /// @dev Holds nothing. The asset is forwarded within the same call and the registry's balance of
    ///      both currencies is zero before and after.
    /// @param minOut slippage floor in the ASSET's own decimals. Enforced by the router, not here.
    /// @return out asset delivered to `recipient`, measured as its balance delta so a fee-on-transfer
    ///         asset is counted for what it actually delivered.
    function swapNativeToAsset(address asset, uint256 minOut, address recipient) external payable returns (uint256 out);
}
