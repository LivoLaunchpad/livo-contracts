// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";

import {LivoFactoryUniV2} from "src/factories/LivoFactoryUniV2.sol";
import {LivoFactoryUniV4} from "src/factories/LivoFactoryUniV4.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
import {LivoFactoryUniV2SniperProtected} from "src/factories/LivoFactoryUniV2SniperProtected.sol";
import {LivoFactoryUniV4SniperProtected} from "src/factories/LivoFactoryUniV4SniperProtected.sol";
import {LivoFactoryTaxTokenSniperProtected} from "src/factories/LivoFactoryTaxTokenSniperProtected.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "../deployments.mainnet.sol";
import {DeploymentsSepolia} from "../deployments.sepolia.sol";

/// @title Livo Factories Re-Deployment Script
/// @notice Deploys all six factories (V2/V4/TaxToken + their sniper-protected variants) plus their four token
///         implementations, against the already-live Livo core (launchpad, bonding curve, graduators, fee handler,
///         fee splitter impl). Whitelists each new factory on the launchpad in the same broadcast.
/// @dev Run with: forge script DeploymentsFactories --rpc-url <mainnet|sepolia> --broadcast --verify
contract DeploymentsFactories is Script {
    struct LivoCore {
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address feeHandler;
        address feeSplitterImpl;
    }

    /// @notice Returns the previously-deployed Livo core addresses for the active chain.
    /// @dev Sourced from `deployments.{mainnet,sepolia}.sol` (the per-chain manifest libraries).
    ///      Also asserts that LivoTaxableTokenUniV4's hardcoded chain import matches the active
    ///      chain (must run `just taxtokenaddresses` before sepolia).
    function _getDeployedCore() internal view returns (LivoCore memory c) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            c = LivoCore({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsMainnet.GRADUATOR_UNIV4,
                feeHandler: DeploymentsMainnet.FEE_HANDLER,
                feeSplitterImpl: DeploymentsMainnet.FEE_SPLITTER_IMPL
            });
            require(
                AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Mainnet"
            );
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            c = LivoCore({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsSepolia.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsSepolia.GRADUATOR_UNIV4,
                feeHandler: DeploymentsSepolia.FEE_HANDLER,
                feeSplitterImpl: DeploymentsSepolia.FEE_SPLITTER_IMPL
            });
            require(
                AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else {
            revert("Unsupported chain");
        }
    }

    function run() public {
        LivoCore memory c = _getDeployedCore();

        console.log("=== Livo Factories Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", c.launchpad);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name | Address |");
        console.log("| ---- | --- |");

        // Token implementations (cloned by their factories via Clones.cloneDeterministic)
        LivoToken livoToken = new LivoToken();
        console.log("| LivoToken | ", address(livoToken));

        LivoTaxableTokenUniV4 livoTaxableToken = new LivoTaxableTokenUniV4();
        console.log("| LivoTaxableTokenUniV4 | ", address(livoTaxableToken));

        LivoTokenSniperProtected livoTokenSniper = new LivoTokenSniperProtected();
        console.log("| LivoTokenSniperProtected | ", address(livoTokenSniper));

        LivoTaxableTokenUniV4SniperProtected livoTaxTokenSniper = new LivoTaxableTokenUniV4SniperProtected();
        console.log("| LivoTaxableTokenUniV4SniperProtected | ", address(livoTaxTokenSniper));

        // ---- Original (non-sniper) factories ----
        LivoFactoryUniV2 factoryV2 = new LivoFactoryUniV2(
            c.launchpad, address(livoToken), c.bondingCurve, c.graduatorV2, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV2 | ", address(factoryV2));

        LivoFactoryUniV4 factoryV4 = new LivoFactoryUniV4(
            c.launchpad, address(livoToken), c.bondingCurve, c.graduatorV4, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV4 | ", address(factoryV4));

        LivoFactoryTaxToken factoryTax = new LivoFactoryTaxToken(
            c.launchpad, address(livoTaxableToken), c.bondingCurve, c.graduatorV4, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryTaxToken | ", address(factoryTax));

        // ---- Sniper-protected factories ----
        LivoFactoryUniV2SniperProtected factoryV2Sniper = new LivoFactoryUniV2SniperProtected(
            c.launchpad, address(livoTokenSniper), c.bondingCurve, c.graduatorV2, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV2SniperProtected | ", address(factoryV2Sniper));

        LivoFactoryUniV4SniperProtected factoryV4Sniper = new LivoFactoryUniV4SniperProtected(
            c.launchpad, address(livoTokenSniper), c.bondingCurve, c.graduatorV4, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV4SniperProtected | ", address(factoryV4Sniper));

        LivoFactoryTaxTokenSniperProtected factoryTaxSniper = new LivoFactoryTaxTokenSniperProtected(
            c.launchpad, address(livoTaxTokenSniper), c.bondingCurve, c.graduatorV4, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryTaxTokenSniperProtected | ", address(factoryTaxSniper));

        console.log("");
        console.log("Whitelisting factories...");
        LivoLaunchpad lp = LivoLaunchpad(c.launchpad);
        lp.whitelistFactory(address(factoryV2));
        lp.whitelistFactory(address(factoryV4));
        lp.whitelistFactory(address(factoryTax));
        lp.whitelistFactory(address(factoryV2Sniper));
        lp.whitelistFactory(address(factoryV4Sniper));
        lp.whitelistFactory(address(factoryTaxSniper));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log(
            "1. Replace factory addresses in justfile (factoryV2 / factoryV4 / factoryTaxToken + 3 sniper slots)"
        );
        console.log("2. Update deployments.{mainnet,sepolia}.sol with the new addresses");
        console.log("3. Run `just export-deployments` to refresh the .md files and commit them");
    }
}
