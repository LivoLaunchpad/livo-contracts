// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap deployment a third-asset dividend leg's native -> asset conversion crosses.
/// @dev Decoded from calldata as an enum, so an out-of-range value reverts in the ABI decoder before
///      any of our own validation runs.
enum DividendVenue {
    UNIV2,
    UNIV3,
    UNIV4
}

/// @notice How one dividend leg buys its payout asset with the native earnings buffered for it. Fixed
///         at creation by the creator, alongside the asset itself: a clone cannot be patched later, and
///         a route supplied at swap time by whoever calls `processDividends` would let that caller point
///         the swap at a pool they control.
/// @dev One storage slot (8 + 24 + 24 + 160 bits). Only third-asset legs read it — a native leg needs no
///      conversion and the self-token leg buys on the token's own pool.
/// @dev `fee`/`tickSpacing`/`aux` are venue-dependent, which is why they are one flat struct rather than
///      three shapes: V2 uses only `aux` (an optional intermediate hop, `address(0)` = the direct
///      quote/asset pair), V3 uses only `fee` (the pool's fee tier), V4 uses all three (`aux` = hooks).
struct DividendRoute {
    DividendVenue venue;
    uint24 fee;
    int24 tickSpacing;
    address aux;
}
