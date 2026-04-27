// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";

import {LivoFactoryUniV2} from "src/factories/LivoFactoryUniV2.sol";
import {LivoFactoryBase} from "src/factories/LivoFactoryBase.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
import {LivoFactoryUniV2SniperProtected} from "src/factories/LivoFactoryUniV2SniperProtected.sol";
import {LivoFactorySniperProtected} from "src/factories/LivoFactorySniperProtected.sol";
import {LivoFactoryTaxTokenSniperProtected} from "src/factories/LivoFactoryTaxTokenSniperProtected.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";

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
    /// @dev Sourced from deployments.{mainnet,sepolia}.md. Also asserts that LivoTaxableTokenUniV4's
    ///      hardcoded chain import matches the active chain (must run `just taxtokenaddresses` before sepolia).
    function _getDeployedCore() internal view returns (LivoCore memory c) {
        if (block.chainid == 1) {
            c = LivoCore({
                launchpad: 0xd9f8bbe437a3423b725c6616C1B543775ecf1110,
                bondingCurve: 0x3faCE9330730fB6f2a9Bb5994cDC882F21ee0A23,
                graduatorV2: 0x46aF9F05825459d149ed036Bb6461E1FE8fA25D8,
                graduatorV4: 0xCF6910d89d052F025ed402638e4Ae78ecDCdDfA5,
                feeHandler: 0xc18030d76573784fff4E6365309E1acD967506ff,
                feeSplitterImpl: 0x80d97b49169067f339934C39F3ae76C50ED046a6
            });
            require(
                AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Mainnet"
            );
        } else if (block.chainid == 11155111) {
            c = LivoCore({
                launchpad: 0xd9f8bbe437a3423b725c6616C1B543775ecf1110,
                bondingCurve: 0x1A7f2E2e4bdB14Dd75b6ce60ce7a6Ff7E0a3F3A5,
                graduatorV2: 0x7131c8141cd356dF22a9d30B292DB3f64B281AA5,
                graduatorV4: 0xc304593F9297f4f67E07cc7cAf3128F9027A2A3d,
                feeHandler: 0xC8e37Ff6bE0f3Ad39cF7481f8D5Ec89c96Bc48EF,
                feeSplitterImpl: 0xDEAA2606f3F6Ff3B4277a30B7dCD382F9BA4bdB7
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

        LivoFactoryBase factoryV4 = new LivoFactoryBase(
            c.launchpad, address(livoToken), c.bondingCurve, c.graduatorV4, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryBase (V4) | ", address(factoryV4));

        LivoFactoryTaxToken factoryTax = new LivoFactoryTaxToken(
            c.launchpad, address(livoTaxableToken), c.bondingCurve, c.graduatorV4, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryTaxToken (V4) | ", address(factoryTax));

        // ---- Sniper-protected factories ----
        LivoFactoryUniV2SniperProtected factoryV2Sniper = new LivoFactoryUniV2SniperProtected(
            c.launchpad, address(livoTokenSniper), c.bondingCurve, c.graduatorV2, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV2SniperProtected | ", address(factoryV2Sniper));

        LivoFactorySniperProtected factoryV4Sniper = new LivoFactorySniperProtected(
            c.launchpad, address(livoTokenSniper), c.bondingCurve, c.graduatorV4, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactorySniperProtected (V4) | ", address(factoryV4Sniper));

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
        console.log("2. Update deployments.{sepolia,mainnet}.md with the new factory addresses");
    }
}
