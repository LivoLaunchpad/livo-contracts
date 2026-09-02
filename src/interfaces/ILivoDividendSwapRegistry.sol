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

    /// @notice Whether `asset` can be bought with `quote` right now. THE eligibility rule, and the only
    ///         one: no curated path list, no per-asset approval — any ERC20 with a deep enough V2 pair
    ///         qualifies, with nobody's permission.
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
    /// @return pair `address(0)` when no pair exists
    /// @return quoteDepth quote-side reserve, scaled to native 18-dec units
    function pairFor(address quote, address asset) external view returns (address pair, uint256 quoteDepth);

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
