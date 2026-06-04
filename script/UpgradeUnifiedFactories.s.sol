// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {CreatorVaultScriptConfig} from "script/CreatorVaultScriptConfig.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Upgrade the implementations behind the unified factory UUPS proxies
/// @notice For each of `LivoFactoryUniV2Unified` and `LivoFactoryUniV4Unified`:
///         1. deploys a fresh implementation contract wired to the addresses in the per-chain
///            manifest (`src/config/deployments.{mainnet,sepolia}.sol`)
///         2. calls `upgradeToAndCall(newImpl, "")` on the existing factory proxy
///
///         The proxy addresses (and therefore the launchpad's `whitelistedFactories` mapping) do
///         NOT change. No init data is passed — there are no new storage variables to populate.
///
///         The broadcaster MUST be the proxy owner (the EOA that ran the original deploy script,
///         since `initialize()` set the owner to `msg.sender` of the proxy-deployment tx). If the
///         broadcaster isn't the owner, `_authorizeUpgrade` reverts with
///         `OwnableUnauthorizedAccount(broadcaster)` — no state changes.
///
///         Storage layout safety: the new implementations must keep `LivoFactoryAbstract`'s storage
///         layout. Today that's "empty + 50-slot gap", so any change that adds storage must shrink
///         the gap and never reorder. Review the diff before broadcasting.
///
/// @dev    Run with:
///         forge script UpgradeUnifiedFactories --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract UpgradeUnifiedFactories is Script {
    /// @dev Pre-deployed addresses sourced from the per-chain manifest. `factoryV2Proxy` and
    ///      `factoryV4Proxy` are the existing UUPS proxies whose impl we're swapping. Everything
    ///      else is wired into the new implementations as immutables.
    struct Deps {
        address factoryV2Proxy;
        address factoryV4Proxy;
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address graduatorV4_0p5;
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
        address factoryV4Impl;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsMainnet.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsMainnet.FACTORY_UNIV4_UNIFIED,
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsMainnet.GRADUATOR_UNIV4,
                graduatorV4_0p5: DeploymentsMainnet.GRADUATOR_UNIV4_0P5,
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
                factoryV2Proxy: DeploymentsSepolia.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsSepolia.FACTORY_UNIV4_UNIFIED,
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsSepolia.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsSepolia.GRADUATOR_UNIV4,
                graduatorV4_0p5: DeploymentsSepolia.GRADUATOR_UNIV4_0P5,
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
        require(d.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(d.factoryV4Proxy != address(0), "manifest: FACTORY_UNIV4_UNIFIED missing");
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
        require(d.graduatorV4_0p5 != address(0), "manifest: GRADUATOR_UNIV4_0P5 missing");
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

        // Sanity: confirm proxies are responsive and initialized. `owner()` reverts on uninitialized
        // proxies (returns 0 from storage), so an explicit nonzero check catches a wrong manifest
        // address pointing at a non-Livo contract.
        address ownerV2 = LivoFactoryUniV2Unified(d.factoryV2Proxy).owner();
        address ownerV4 = LivoFactoryUniV4Unified(d.factoryV4Proxy).owner();
        require(ownerV2 != address(0), "V2 proxy not initialized");
        require(ownerV4 != address(0), "V4 proxy not initialized");
        require(ownerV2 == ownerV4, "V2/V4 proxies have diverged owners - verify the manifest");

        console.log("=== Livo Unified Factories Upgrade ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required owner (V2/V4):  ", ownerV2);
        console.log("V2 proxy:                ", d.factoryV2Proxy);
        console.log("V4 proxy:                ", d.factoryV4Proxy);
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
        console.log("| LivoFactoryUniV2Unified (new impl)    |", fresh.factoryV2Impl);

        UUPSUpgradeable(d.factoryV2Proxy).upgradeToAndCall(fresh.factoryV2Impl, "");
        console.log("| V2 proxy upgraded to                  |", fresh.factoryV2Impl);

        fresh.factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                d.launchpad,
                d.tokenImpl,
                d.tokenSniperImpl,
                d.taxTokenImpl,
                d.taxTokenSniperImpl,
                d.bondingCurve,
                d.graduatorV4,
                d.graduatorV4_0p5,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor()
            )
        );
        console.log("| LivoFactoryUniV4Unified (new impl)    |", fresh.factoryV4Impl);

        UUPSUpgradeable(d.factoryV4Proxy).upgradeToAndCall(fresh.factoryV4Impl, "");
        console.log("| V4 proxy upgraded to                  |", fresh.factoryV4Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("Proxy addresses are UNCHANGED - no launchpad whitelisting or integrator action needed.");
        console.log("New implementation addresses (for Etherscan verification + record keeping):");
        console.log("  V2 impl:", fresh.factoryV2Impl);
        console.log("  V4 impl:", fresh.factoryV4Impl);
    }
}
