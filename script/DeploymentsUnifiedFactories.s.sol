// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";
import {CreatorVaultScriptConfig} from "script/CreatorVaultScriptConfig.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Deploy the unified factory implementations and their UUPS proxies
/// @notice Deploys ONLY the four contracts that are net-new for this run:
///         1. `LivoFactoryUniV2Unified` (implementation) + its `ERC1967Proxy`
///         2. `LivoFactoryUniV4Unified` (implementation) + its `ERC1967Proxy`
///
///         Every other dependency — launchpad, bonding curve, graduators, master fee handler,
///         and every token implementation — is sourced from the per-chain manifest in
///         `src/config/deployments.{mainnet,sepolia}.sol`. To redeploy any of those, use the
///         dedicated script for that component, not this one.
///
///         The proxy is the address the launchpad whitelists and that integrators track —
///         it stays stable across future implementation upgrades that don't break the ABI.
///
///         Whitelisting on the launchpad is intentionally NOT done here — the launchpad
///         owner (`livo.admin`) must whitelist the proxy address after broadcast finishes
///         (see "Next steps").
///
/// @dev    Run with:
///         forge script DeploymentsUnifiedFactories --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeploymentsUnifiedFactories is Script {
    /// @dev Pre-deployed core addresses sourced from the per-chain manifest. None of these are
    ///      redeployed by this script.
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
        address taxTokenV2Impl;
        address taxTokenV2SniperImpl;
    }

    /// @dev Freshly-deployed addresses emitted by this script.
    struct FreshDeployments {
        address factoryV2Impl;
        address factoryV2;
        address factoryV4Impl;
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
                graduatorV4: DeploymentsMainnet.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsMainnet.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsMainnet.TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenImpl: DeploymentsMainnet.TAXABLE_TOKEN_IMPL,
                taxTokenSniperImpl: DeploymentsMainnet.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenV2Impl: DeploymentsMainnet.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV2SniperImpl: DeploymentsMainnet.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL
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
                taxTokenSniperImpl: DeploymentsSepolia.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenV2Impl: DeploymentsSepolia.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV2SniperImpl: DeploymentsSepolia.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL
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
        require(d.taxTokenV2Impl != address(0), "manifest: TAXABLE_TOKEN_V2_IMPL missing");
        require(d.taxTokenV2SniperImpl != address(0), "manifest: TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        console.log("=== Livo Unified Factories Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", d.launchpad);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                          | Address |");
        console.log("| -------------------------------------- | --- |");

        fresh.factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                d.launchpad,
                d.tokenImpl,
                d.tokenSniperImpl,
                d.taxTokenV2Impl,
                d.taxTokenV2SniperImpl,
                d.bondingCurve,
                d.graduatorV2,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor()
            )
        );
        console.log("| LivoFactoryUniV2Unified (impl)        |", fresh.factoryV2Impl);

        fresh.factoryV2 =
            address(new ERC1967Proxy(fresh.factoryV2Impl, abi.encodeCall(LivoFactoryAbstract.initialize, ())));
        console.log("| LivoFactoryUniV2Unified (proxy)       |", fresh.factoryV2);

        fresh.factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                d.launchpad,
                d.tokenImpl,
                d.tokenSniperImpl,
                d.taxTokenImpl,
                d.taxTokenSniperImpl,
                d.bondingCurve,
                d.graduatorV4,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor()
            )
        );
        console.log("| LivoFactoryUniV4Unified (impl)        |", fresh.factoryV4Impl);

        fresh.factoryV4 =
            address(new ERC1967Proxy(fresh.factoryV4Impl, abi.encodeCall(LivoFactoryAbstract.initialize, ())));
        console.log("| LivoFactoryUniV4Unified (proxy)       |", fresh.factoryV4);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. Update FACTORY_UNIV2_UNIFIED and FACTORY_UNIV4_UNIFIED in");
        console.log("   src/config/deployments.{mainnet,sepolia}.sol with the proxy addresses above.");
        console.log("2. Run `just export-deployments` to refresh the .md manifests and commit them.");
        console.log("3. Whitelist both factory PROXIES on the launchpad with the launchpad-owner account:");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV2 proxy> --account livo.admin");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV4 proxy> --account livo.admin");
    }
}
