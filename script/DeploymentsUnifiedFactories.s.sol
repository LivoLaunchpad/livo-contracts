// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Deploy unified factories only
/// @notice Deploys `LivoFactoryUniV2Unified` and `LivoFactoryUniV4Unified` against the
///         already-live Livo core. Reuses the four pre-deployed token implementations
///         (`TOKEN_IMPL`, `TOKEN_SNIPER_PROTECTED_IMPL`, `TAXABLE_TOKEN_IMPL`,
///         `TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL`) plus the launchpad, bonding curve,
///         graduators, and master fee handler, all read from
///         `src/config/deployments.{mainnet,sepolia}.sol`.
///
///         Whitelisting on the launchpad is intentionally NOT done here — the launchpad
///         owner (`livo.admin`) must whitelist after broadcast finishes (see "Next steps").
///
/// @dev    Run with:
///         forge script DeploymentsUnifiedFactories --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeploymentsUnifiedFactories is Script {
    /// @dev Bundle of pre-deployed addresses sourced from the per-chain manifest.
    struct Deps {
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address masterFeeHandler;
        address tokenImpl;
        address tokenSniperImpl;
        address taxTokenImpl;
        address taxTokenSniperImpl;
    }

    /// @notice Resolves all dependency addresses for the active chain.
    /// @dev Asserts that `LivoTaxableTokenUniV4`'s hardcoded chain import matches the active chain
    ///      (run `just taxtokenaddresses` before deploying to sepolia).
    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsMainnet.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsMainnet.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsMainnet.TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenImpl: DeploymentsMainnet.TAXABLE_TOKEN_IMPL,
                taxTokenSniperImpl: DeploymentsMainnet.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL
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
                graduatorV4: DeploymentsSepolia.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsSepolia.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsSepolia.TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenImpl: DeploymentsSepolia.TAXABLE_TOKEN_IMPL,
                taxTokenSniperImpl: DeploymentsSepolia.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL
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
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(d.tokenSniperImpl != address(0), "manifest: TOKEN_SNIPER_PROTECTED_IMPL missing");
        require(d.taxTokenImpl != address(0), "manifest: TAXABLE_TOKEN_IMPL missing");
        require(d.taxTokenSniperImpl != address(0), "manifest: TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();

        console.log("=== Livo Unified Factories Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", d.launchpad);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name             | Address |");
        console.log("| ------------------------- | --- |");

        LivoFactoryUniV2Unified factoryV2 = new LivoFactoryUniV2Unified(
            d.launchpad, d.tokenImpl, d.tokenSniperImpl, d.bondingCurve, d.graduatorV2, d.masterFeeHandler
        );
        console.log("| LivoFactoryUniV2Unified  |", address(factoryV2));

        LivoFactoryUniV4Unified factoryV4 = new LivoFactoryUniV4Unified(
            d.launchpad,
            d.tokenImpl,
            d.tokenSniperImpl,
            d.taxTokenImpl,
            d.taxTokenSniperImpl,
            d.bondingCurve,
            d.graduatorV4,
            d.masterFeeHandler
        );
        console.log("| LivoFactoryUniV4Unified  |", address(factoryV4));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. Update FACTORY_UNIV2_UNIFIED / FACTORY_UNIV4_UNIFIED in");
        console.log("   src/config/deployments.{mainnet,sepolia}.sol with the addresses above.");
        console.log("2. Run `just export-deployments` to refresh the .md manifests and commit them.");
        console.log("3. Whitelist both factories on the launchpad with the launchpad-owner account:");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV2Unified> --account livo.admin");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV4Unified> --account livo.admin");
    }
}
