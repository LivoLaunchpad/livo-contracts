// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DividendRoute, DividendVenue} from "src/types/DividendRoute.sol";

/// @notice The route of a token whose dividend asset is native or the token itself. Those buy nothing,
///         so the route is never read — an all-zero value is the honest one.
function noDividendRoute() pure returns (DividendRoute memory route) {}

/// @notice A Uniswap-V2 route: the canonical quote/asset pair.
function v2DividendRoute() pure returns (DividendRoute memory) {
    return DividendRoute({venue: DividendVenue.UNIV2, fee: 0, tickSpacing: 0, hooks: address(0)});
}

/// @notice A Uniswap-V3 route through the quote/asset pool with fee tier `fee`.
function v3DividendRoute(uint24 fee) pure returns (DividendRoute memory) {
    return DividendRoute({venue: DividendVenue.UNIV3, fee: fee, tickSpacing: 0, hooks: address(0)});
}

/// @notice A Uniswap-V4 route through the native/asset pool keyed by `fee`, `tickSpacing` and `hooks`.
function v4DividendRoute(uint24 fee, int24 tickSpacing, address hooks) pure returns (DividendRoute memory) {
    return DividendRoute({venue: DividendVenue.UNIV4, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
}
