// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Read side of the protocol's curated `asset -> Uniswap-V2 swap path` registry.
interface ISwapRouteRegistry {
    /// @notice The configured swap path for `asset`, or an empty array if there is none.
    function getRoute(address asset) external view returns (address[] memory);

    /// @notice Whether `asset` has a route configured.
    function hasRoute(address asset) external view returns (bool);
}
