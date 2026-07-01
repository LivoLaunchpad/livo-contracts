// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Deployer-selected post-graduation liquidity depth.
///
///         Each tier graduates into its own Uniswap pool depth, with a graduation marketcap that
///         scales 1:2:4 with the LP depth (THIN 6.125 ETH / DEFAULT 12.25 ETH / THICK 24.5 ETH).
///         Because mcap scales with depth, the token split (28.57% into liquidity, 71.43% sold) and
///         the curve steepness are identical across tiers — only the absolute price scale and the
///         post-graduation pool depth differ.
///
/// @dev    Tiers are ordered by pool depth (THIN < DEFAULT < THICK), so `THIN` is the zero value.
///         Callers must set `liquidityTier` explicitly: a zero-initialised field resolves to `THIN`,
///         not `DEFAULT`. The legacy positional `createToken` overloads pass `DEFAULT` explicitly.
enum LiquidityTier {
    THIN, // 1.75 ETH liquidity, 6.125 ETH graduation mcap
    DEFAULT, // 3.5 ETH liquidity, 12.25 ETH graduation mcap (the original, deployed system)
    THICK // 7.0 ETH liquidity, 24.5 ETH graduation mcap
}
