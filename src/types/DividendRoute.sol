// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap deployment the dividend asset's native -> asset conversion crosses.
/// @dev Decoded from calldata as an enum, so an out-of-range value reverts in the ABI decoder before
///      any of our own validation runs.
enum DividendVenue {
    UNIV2,
    UNIV3,
    UNIV4
}

/// @notice Which pool a token's dividend asset is bought on with the native earnings buffered for it.
///         Fixed at creation by the creator, alongside the asset itself: a clone cannot be patched
///         later, and a route supplied at freeze time by whoever calls `processRound` would let that
///         caller point the swap at a pool they control.
///
/// @dev THIS DOUBLES AS THE PROOF OF LIQUIDITY. There is no whitelist of payout assets and no admin
///      approval anywhere in this path — any ERC20 is eligible. What makes an asset eligible is that
///      the route names a pool which, at creation time, actually exists and holds a swappable amount
///      of the quote asset (`DividendDistributionLogic._requirePoolLiquidity`). An asset whose pool
///      cannot be found or is empty is refused THERE, at creation, rather than leaving a clone whose
///      dividend buffer can never be converted.
///
/// @dev One storage slot (8 + 24 + 24 + 160 bits). Only a THIRD-ASSET payout reads it — a native
///      payout needs no conversion, and the self-token payout buys on the token's own pool.
/// @dev The fields are venue-dependent, which is why this is one flat struct rather than three shapes:
///      V2 uses none of them (the pool is the canonical quote/asset pair), V3 uses `fee` (the pool's
///      fee tier), V4 uses all three.
struct DividendRoute {
    DividendVenue venue;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}
