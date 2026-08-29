// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SwapRouteRegistry} from "src/registries/SwapRouteRegistry.sol";

/// @title DeploySwapRouteRegistry
/// @notice Deploys the protocol's curated `asset -> Uniswap-V2 swap path` registry for a chain. One
///         per chain, shared by every consumer; today the only consumer is the token dividend module,
///         which reads it when a token pays holders in a THIRD asset (an xStock).
///
/// @dev ⚠️ ORDERING. The registry address is a compile-time constant in `DeploymentAddresses`
///      (`DIVIDEND_ROUTE_REGISTRY`), the same way the routers and WETH are, so it is baked into the
///      token implementations' bytecode. That makes this a bootstrap step:
///
///        1. run this script,
///        2. paste the address into `DIVIDEND_ROUTE_REGISTRY` for that chain in
///           `src/config/DeploymentAddresses.sol`,
///        3. redeploy the token implementations and point the factories at them,
///        4. add the routes (step 5 below) — which can happen at any time afterwards, since routes
///           are read LIVE.
///
///      Until step 2 lands, `DIVIDEND_ROUTE_REGISTRY` is `address(0)` and any token configured with a
///      third-party payout asset reverts at creation with `UnsupportedDividendAsset`. Native and
///      self-token dividends need none of this and work immediately.
///
/// @dev Post-deploy, with the owner key:
///        5. `setAdmin(<keeper/ops address>, true)`
///        6. per asset: `setRoute(asset, [WETH, ..., asset])`
///      Routes are deliberately mutable by admins: a token is a non-upgradeable clone, so a route
///      baked in at creation would brick that leg permanently the day its pool dies. The blast radius
///      of a bad route is bounded by the `minOut` every consumer must pass.
contract DeploySwapRouteRegistry is Script {
    function run() external {
        // The owner should be a cold multisig: it grants and revokes the admins who manage routes,
        // and does not manage routes itself.
        address owner = vm.envAddress("REGISTRY_OWNER");

        console.log("=== Deploy SwapRouteRegistry ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Owner:   ", owner);

        vm.startBroadcast();
        address registry = address(new SwapRouteRegistry(owner));
        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("SWAP_ROUTE_REGISTRY", registry);
        console.log("Next: paste into DIVIDEND_ROUTE_REGISTRY in src/config/DeploymentAddresses.sol");
        console.log("      for this chain, then redeploy the token implementations.");
    }
}
