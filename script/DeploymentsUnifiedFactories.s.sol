// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Deploy Livo master fee handler, token implementations, and unified factories
/// @notice Deploys, in order:
///         1. `LivoMasterFeeHandler`
///         2. the deployable token implementations in `src/tokens/`
///         3. `LivoFactoryUniV2Unified` and `LivoFactoryUniV4Unified`
///
///         The factories are wired to the freshly-deployed master fee handler and token
///         implementations while reusing the launchpad, bonding curve, and graduators from
///         `src/config/deployments.{mainnet,sepolia}.sol`.
///
///         Whitelisting on the launchpad is intentionally NOT done here — the launchpad
///         owner (`livo.admin`) must whitelist after broadcast finishes (see "Next steps").
///
/// @dev    Run with:
///         forge script DeploymentsUnifiedFactories --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeploymentsUnifiedFactories is Script {
    /// @dev Bundle of pre-deployed core addresses sourced from the per-chain manifest.
    struct Deps {
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
    }

    /// @dev Freshly-deployed addresses emitted by this script.
    struct FreshDeployments {
        address masterFeeHandler;
        address tokenImpl;
        address tokenSniperImpl;
        address taxTokenImpl;
        address taxTokenSniperImpl;
        address taxTokenV2Impl;
        address taxTokenV2SniperImpl;
        address factoryV2;
        address factoryV4;
    }

    /// @notice Resolves core dependency addresses for the active chain.
    /// @dev Asserts that `LivoTaxableTokenUniV4`'s hardcoded chain import matches the active chain
    ///      (run `just taxtokenaddresses` before deploying to sepolia).
    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsMainnet.GRADUATOR_UNIV4
            });
            require(
                AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Mainnet"
            );
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsSepolia.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsSepolia.GRADUATOR_UNIV4
            });
            require(
                AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else {
            revert("Unsupported chain");
        }

        // Belt-and-braces: catch a stale or zero address in the manifest before we waste a deploy.
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        console.log("=== Livo Unified Stack Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", d.launchpad);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                          | Address |");
        console.log("| -------------------------------------- | --- |");

        fresh.masterFeeHandler = address(new LivoMasterFeeHandler());
        console.log("| LivoMasterFeeHandler                  |", fresh.masterFeeHandler);

        fresh.tokenImpl = address(new LivoToken());
        console.log("| LivoToken (impl)                      |", fresh.tokenImpl);

        fresh.tokenSniperImpl = address(new LivoTokenSniperProtected());
        console.log("| LivoTokenSniperProtected (impl)       |", fresh.tokenSniperImpl);

        fresh.taxTokenImpl = address(new LivoTaxableTokenUniV4());
        console.log("| LivoTaxableTokenUniV4 (impl)          |", fresh.taxTokenImpl);

        fresh.taxTokenSniperImpl = address(new LivoTaxableTokenUniV4SniperProtected());
        console.log("| LivoTaxableTokenUniV4SniperProtected (impl) |", fresh.taxTokenSniperImpl);

        fresh.taxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2 (impl)          |", fresh.taxTokenV2Impl);

        fresh.taxTokenV2SniperImpl = address(new LivoTaxableTokenUniV2SniperProtected());
        console.log("| LivoTaxableTokenUniV2SniperProtected (impl) |", fresh.taxTokenV2SniperImpl);

        fresh.factoryV2 = address(
            new LivoFactoryUniV2Unified(
                d.launchpad,
                fresh.tokenImpl,
                fresh.tokenSniperImpl,
                fresh.taxTokenV2Impl,
                fresh.taxTokenV2SniperImpl,
                d.bondingCurve,
                d.graduatorV2,
                fresh.masterFeeHandler
            )
        );
        console.log("| LivoFactoryUniV2Unified               |", fresh.factoryV2);

        fresh.factoryV4 = address(
            new LivoFactoryUniV4Unified(
                d.launchpad,
                fresh.tokenImpl,
                fresh.tokenSniperImpl,
                fresh.taxTokenImpl,
                fresh.taxTokenSniperImpl,
                d.bondingCurve,
                d.graduatorV4,
                fresh.masterFeeHandler
            )
        );
        console.log("| LivoFactoryUniV4Unified               |", fresh.factoryV4);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. Update MASTER_FEE_HANDLER, TOKEN_IMPL, TOKEN_SNIPER_PROTECTED_IMPL,");
        console.log("   TAXABLE_TOKEN_IMPL, TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL,");
        console.log("   FACTORY_UNIV2_UNIFIED, and FACTORY_UNIV4_UNIFIED in");
        console.log("   src/config/deployments.{mainnet,sepolia}.sol with the addresses above.");
        console.log("2. Run `just export-deployments` to refresh the .md manifests and commit them.");
        console.log("3. Whitelist both factories on the launchpad with the launchpad-owner account:");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV2Unified> --account livo.admin");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV4Unified> --account livo.admin");
    }
}
