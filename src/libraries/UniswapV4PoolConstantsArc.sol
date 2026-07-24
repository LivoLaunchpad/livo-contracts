// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title UniswapV4PoolConstantsArc
/// @notice ARC (Circle L1, native currency = USDC) variant of `UniswapV4PoolConstants`.
/// @dev ARC has no ETH: the native currency is USDC ($1), 18-dec at `msg.value` (identical wei math to
///      ETH). The V4 pool is still (currency0, currency1) = (native, token), both 18-dec, so the pool
///      decimals are unchanged vs the ETH deployment — the ONLY difference is the price level.
///
///      Repricing rule (see [[arc-integration-plan]]): assume ETH = $2500, native USDC = $1. A token
///      keeps the same USD value at graduation, so its price denominated in the native unit rises ×2500
///      (one native unit is worth 1/2500 of one ETH). The pool price P = tokens/native therefore FALLS
///      ×1/2500, i.e. sqrtPrice ×1/50 and every set-point tick shifts by log_1.0001(1/2500) ≈ −78244.
///
///      That exact shift is NOT a multiple of TICK_SPACING, so the ticks are NOT a blind −78200 of the
///      ETH values. Instead each ARC set-point is re-derived from its ARC target price via
///      `simulations/script/uniswapV4Settings.py <eth_wei_per_token × 2500>` (see below), and the range
///      bounds are translated to preserve the exact ETH tick DISTANCES (same distance ⇒ same price ratio
///      ⇒ same pool geometry). Validated in `test/graduators/uniswapV4ConstantsArc.t.sol`.
library UniswapV4PoolConstantsArc {
    /// @notice LP fees in pips. 0 because LP fees are charged by the hook (LivoSwapHook). Chain-invariant.
    uint24 internal constant LP_FEE = 0;

    /// @notice Tick spacing. Chain-invariant (pool granularity, not a price).
    int24 internal constant TICK_SPACING = 200;

    // Pair is (currency0, currency1) = (native USDC, token). sqrtPriceX96 = sqrt(amountToken/amountNative)
    // * 2^96, i.e. tokens per native unit. Max token price = low tick; min token price = high tick.

    /// @notice DEFAULT/THICK upper boundary of the primary range (minimum token price in native USDC).
    /// @dev ETH 203600 → −78200 (preserves 21400 above the DEFAULT graduation tick). Multiple of 200.
    int24 internal constant TICK_UPPER = 125400;

    /// @notice THIN-tier upper boundary of the primary range.
    /// @dev ETH 212000 → −78400 (preserves 22800 above the THIN graduation tick, keeping the "full bag
    ///      sellable" tuning). Multiple of 200.
    int24 internal constant TICK_UPPER_THIN = 133600;

    /// @notice Lower boundary of the range at position creation (maximum token price in native USDC).
    /// @dev ETH −7000 → −78200 (preserves 189200 below the DEFAULT graduation tick). Multiple of 200.
    int24 internal constant TICK_LOWER = -85200;

    /// @notice Tick at the DEFAULT-tier graduation price (reference; the graduator derives it per-tier
    ///         on-chain from the passed sqrtPrice). ETH 182200 → 104000.
    int24 internal constant TICK_GRADUATION = 104000;

    /// @notice Second position lower tick (single-sided native, concentrated right below graduation).
    int24 internal constant TICK_LOWER_2 = TICK_GRADUATION + TICK_SPACING;

    /// @notice Tick distance from the primary upper tick down to the secondary native-only position's
    ///         upper tick. Chain-invariant (a relative offset, translation-invariant under repricing).
    int24 internal constant TICK_UPPER_2_OFFSET = 51 * TICK_SPACING;

    ////////////////////// per-tier graduation prices (deploy-time constructor args) //////////////////////
    // Re-derived from `uniswapV4Settings.py <eth_wei_per_token × 2500> --tick-upper <tier upper>`.
    // ARC native-wei-per-token = ETH-wei-per-token × 2500 (token USD value unchanged; native mcap ×2500).

    /// @notice DEFAULT graduation sqrtPriceX96. ETH wei/token 12250000000 → ARC 30625000000000
    ///         (12.25 ETH → 30625 USDC mcap, same $30,625). Tick 104000.
    uint160 internal constant SQRT_PRICEX96_GRADUATION_DEFAULT = 14316654192859882082890613260288;

    /// @notice THIN graduation sqrtPriceX96. ETH wei/token 6125000000 → ARC 15312500000000
    ///         (6.125 ETH → 15312.5 USDC mcap, same $15,312.5). Tick 110800. Uses TICK_UPPER_THIN.
    uint160 internal constant SQRT_PRICEX96_GRADUATION_THIN = 20246806527348082160415067340800;

    /// @notice THICK graduation sqrtPriceX96. ETH wei/token 24500000000 → ARC 61250000000000
    ///         (24.5 ETH → 61250 USDC mcap, same $61,250). Tick 97000.
    uint160 internal constant SQRT_PRICEX96_GRADUATION_THICK = 10123403263674041080207533670400;
}
