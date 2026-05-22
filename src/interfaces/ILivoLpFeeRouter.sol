// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ILivoLpFeeRouter
/// @notice Receives LP fee deposits from `LivoSwapHook` and splits them between the protocol
///         treasury, the token's creator (via the master fee handler), and a future
///         liquidity-reinvestment slice, using a marketcap-tiered split.
/// @dev This interface is intentionally minimal so the router implementation can be upgraded
///      without forcing a corresponding hook redeploy. The hook only relies on `depositLpFees`.
///      Future implementations may compute the split from different inputs internally, but the
///      `(token, ethSwapAmount, tokenSwapAmount)` signature must remain stable.
interface ILivoLpFeeRouter {
    /// @notice Routes `msg.value` ETH as LP fees for `token`.
    /// @dev The router derives the swap's avg price from `(ethSwapAmount, tokenSwapAmount)`,
    ///      multiplies it by the token's total supply to obtain the marketcap, looks up the
    ///      corresponding split tier, sends the treasury slice to the configured treasury, and
    ///      forwards the creator slice through `ILivoToken(token).accrueFees`.
    /// @dev MUST revert on any internal transfer failure so the calling hook can apply its own
    ///      try/catch fallback. The router must NOT silently drop funds.
    /// @param token           The Livo token whose LP fees are being routed.
    /// @param ethSwapAmount   Net ETH that crossed the pool during the swap leg that produced
    ///                        these fees (gross minus the hook-extracted LP fee + taxes).
    /// @param tokenSwapAmount Token amount that crossed the pool during the same swap leg.
    function depositLpFees(address token, uint256 ethSwapAmount, uint256 tokenSwapAmount) external payable;
}
