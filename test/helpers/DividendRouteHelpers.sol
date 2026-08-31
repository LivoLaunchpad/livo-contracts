// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DividendRoute, DividendVenue} from "src/types/DividendRoute.sol";

/// @notice The route triple of a token whose dividend legs are native and/or the token itself. Those
///         legs buy nothing, so their routes are never read — an all-zero triple is the honest value.
function noDividendRoutes() pure returns (DividendRoute[3] memory routes) {}

/// @notice A Uniswap-V2 route: the direct quote/asset pair, or one hop through `hop`.
function v2DividendRoute(address hop) pure returns (DividendRoute memory) {
    return DividendRoute({venue: DividendVenue.UNIV2, fee: 0, tickSpacing: 0, aux: hop});
}

/// @notice A Uniswap-V3 route through the quote/asset pool with fee tier `fee`.
function v3DividendRoute(uint24 fee) pure returns (DividendRoute memory) {
    return DividendRoute({venue: DividendVenue.UNIV3, fee: fee, tickSpacing: 0, aux: address(0)});
}

/// @notice A Uniswap-V4 route through the native/asset pool keyed by `fee`, `tickSpacing` and `hooks`.
function v4DividendRoute(uint24 fee, int24 tickSpacing, address hooks) pure returns (DividendRoute memory) {
    return DividendRoute({venue: DividendVenue.UNIV4, fee: fee, tickSpacing: tickSpacing, aux: hooks});
}
