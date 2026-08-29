// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapRouteRegistry} from "src/registries/SwapRouteRegistry.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @notice Unit tests for the protocol's curated swap-route registry: the two-tier access model and the
///         two structural checks on a route.
contract SwapRouteRegistryTests is Test {
    SwapRouteRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal routeAdmin = makeAddr("routeAdmin");
    address internal stranger = makeAddr("stranger");

    address internal weth = makeAddr("weth");
    address internal asset = makeAddr("asset");

    function setUp() public {
        registry = new SwapRouteRegistry(owner);
        vm.prank(owner);
        registry.setAdmin(routeAdmin, true);
    }

    function _path() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = weth;
        path[1] = asset;
    }

    function test_adminCanSetAndReadARoute() public {
        vm.prank(routeAdmin);
        registry.setRoute(asset, _path());

        assertTrue(registry.hasRoute(asset), "route registered");
        assertEq(registry.getRoute(asset)[1], asset, "path ends at the asset");
    }

    function test_unknownAssetHasNoRoute() public view {
        assertFalse(registry.hasRoute(asset), "nothing registered");
        assertEq(registry.getRoute(asset).length, 0, "empty path");
    }

    /// @dev Owner manages admins; admins manage routes. Routes change often enough that owner-only would
    ///      be operationally painful, which is the whole reason for the split.
    function test_onlyAdminsCanSetRoutes() public {
        vm.prank(stranger);
        vm.expectRevert(SwapRouteRegistry.NotRouteAdmin.selector);
        registry.setRoute(asset, _path());

        // Not even the owner — it grants the right rather than exercising it.
        vm.prank(owner);
        vm.expectRevert(SwapRouteRegistry.NotRouteAdmin.selector);
        registry.setRoute(asset, _path());
    }

    function test_onlyOwnerCanGrantAdmin() public {
        vm.prank(routeAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, routeAdmin));
        registry.setAdmin(stranger, true);
    }

    function test_revokedAdminCannotSetRoutes() public {
        vm.prank(owner);
        registry.setAdmin(routeAdmin, false);

        vm.prank(routeAdmin);
        vm.expectRevert(SwapRouteRegistry.NotRouteAdmin.selector);
        registry.setRoute(asset, _path());
    }

    /// @dev A path that does not end at the asset would have a consumer buying something other than what
    ///      it asked for — the one shape that is broken rather than merely unusual.
    function test_pathMustEndAtTheAsset() public {
        address[] memory wrong = new address[](2);
        wrong[0] = weth;
        wrong[1] = stranger;

        vm.prank(routeAdmin);
        vm.expectRevert(SwapRouteRegistry.InvalidRoute.selector);
        registry.setRoute(asset, wrong);
    }

    function test_singleHopPathRejected() public {
        address[] memory single = new address[](1);
        single[0] = asset;

        vm.prank(routeAdmin);
        vm.expectRevert(SwapRouteRegistry.InvalidRoute.selector);
        registry.setRoute(asset, single);
    }

    /// @dev Routes are read live so a dead pool can be repointed. Removal is part of that.
    function test_emptyPathRemovesTheRoute() public {
        vm.startPrank(routeAdmin);
        registry.setRoute(asset, _path());
        registry.setRoute(asset, new address[](0));
        vm.stopPrank();

        assertFalse(registry.hasRoute(asset), "route removed");
    }
}
