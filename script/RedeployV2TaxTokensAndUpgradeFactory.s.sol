// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {CreatorVaultDeployHelper} from "src/config/CreatorVaultDeployHelper.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Redeploy V2 taxable token implementations and upgrade the V2 unified factory proxy
/// @notice Three-step deploy, all in a single broadcast:
///         1. Deploys a fresh `LivoTaxableTokenUniV2` implementation.
///         2. Deploys a fresh `LivoTaxableTokenUniV2SniperProtected` implementation.
///         3. Deploys a fresh `LivoFactoryUniV2Unified` implementation wired to the new token impls
///            (plus the unchanged non-tax token impls + bonding curve + V2 graduator + master fee
///            handler + launchpad pulled from the per-chain manifest).
///         4. Calls `upgradeToAndCall(newFactoryImpl, "")` on the existing V2 factory UUPS proxy.
///
///         The proxy address — and therefore the launchpad's `whitelistedFactories` entry — does
///         NOT change. No init data is passed; there are no new storage variables to populate.
///
///         The broadcaster MUST be the proxy owner. If not, `_authorizeUpgrade` reverts with
///         `OwnableUnauthorizedAccount(broadcaster)` and no state changes.
///
///         Pre-broadcast sanity: confirms the V2 token implementation file imports the right
///         per-chain `DeploymentAddresses` (run `just taxtokenaddresses` before deploying to Sepolia).
///
///         Post-broadcast: update `TAXABLE_TOKEN_V2_IMPL`, `TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL`,
///         and the V2 factory impl address in `src/config/deployments.<chain>.sol`, then run
///         `just export-deployments`.
///
/// @dev    Run with:
///         forge script RedeployV2TaxTokensAndUpgradeFactory --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeployV2TaxTokensAndUpgradeFactory is Script {
    /// @dev Per-chain addresses needed to wire the new factory implementation. `factoryV2Proxy` is
    ///      the existing UUPS proxy whose impl we're swapping; everything else is constructor input
    ///      to the fresh factory implementation.
    struct Deps {
        address factoryV2Proxy;
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address masterFeeHandler;
        address tokenImpl;
        address tokenSniperImpl;
    }

    /// @dev Addresses emitted by this script (for logging + manifest updates).
    struct FreshDeployments {
        address taxTokenV2Impl;
        address taxTokenV2SniperImpl;
        address factoryV2Impl;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsMainnet.FACTORY_UNIV2_UNIFIED,
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsMainnet.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsMainnet.TOKEN_SNIPER_PROTECTED_IMPL
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesMainnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Mainnet (run `just taxtokenaddresses` only for sepolia)"
            );
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsSepolia.FACTORY_UNIV2_UNIFIED,
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsSepolia.GRADUATOR_UNIV2,
                masterFeeHandler: DeploymentsSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsSepolia.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsSepolia.TOKEN_SNIPER_PROTECTED_IMPL
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesSepolia.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else {
            revert("Unsupported chain");
        }

        require(d.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(d.tokenSniperImpl != address(0), "manifest: TOKEN_SNIPER_PROTECTED_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        // Catch a wrong manifest address pointing at a non-Livo contract before we waste a deploy.
        address proxyOwner = LivoFactoryUniV2Unified(d.factoryV2Proxy).owner();
        require(proxyOwner != address(0), "V2 proxy not initialized");

        console.log("=== Livo V2 Tax Stack Redeploy ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required proxy owner:    ", proxyOwner);
        console.log("V2 factory proxy:        ", d.factoryV2Proxy);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        fresh.taxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2 (new impl)              |", fresh.taxTokenV2Impl);

        fresh.taxTokenV2SniperImpl = address(new LivoTaxableTokenUniV2SniperProtected());
        console.log("| LivoTaxableTokenUniV2SniperProtected (new)    |", fresh.taxTokenV2SniperImpl);

        fresh.factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                d.launchpad,
                d.tokenImpl,
                d.tokenSniperImpl,
                fresh.taxTokenV2Impl,
                fresh.taxTokenV2SniperImpl,
                d.bondingCurve,
                d.graduatorV2,
                d.masterFeeHandler,
                CreatorVaultDeployHelper.factoryFor(),
                CreatorVaultDeployHelper.curvesFor()
            )
        );
        console.log("| LivoFactoryUniV2Unified (new impl)            |", fresh.factoryV2Impl);

        UUPSUpgradeable(d.factoryV2Proxy).upgradeToAndCall(fresh.factoryV2Impl, "");
        console.log("| V2 proxy upgraded to                          |", fresh.factoryV2Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeploy Complete ===");
        console.log("Proxy address is UNCHANGED - no launchpad whitelisting or integrator action needed.");
        console.log("Update the per-chain manifest with these addresses, then run `just export-deployments`:");
        console.log("  TAXABLE_TOKEN_V2_IMPL                  :", fresh.taxTokenV2Impl);
        console.log("  TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL :", fresh.taxTokenV2SniperImpl);
        console.log("  LivoFactoryUniV2Unified impl           :", fresh.factoryV2Impl);
    }
}
