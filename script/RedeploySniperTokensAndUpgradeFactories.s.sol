// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {CreatorVaultScriptConfig} from "script/CreatorVaultScriptConfig.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {DeploymentAddresses as AddressesFromLivoTaxableTokenV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Redeploy all sniper-protected token implementations and upgrade both unified factory proxies
/// @notice Single-broadcast deploy that:
///         1. Deploys a fresh `LivoTokenSniperProtected` implementation.
///         2. Deploys a fresh `LivoTaxableTokenUniV2SniperProtected` implementation.
///         3. Deploys a fresh `LivoTaxableTokenUniV4SniperProtected` implementation.
///         4. Deploys a fresh `LivoFactoryUniV2Unified` implementation wired to the new sniper
///            impls (1) and (2) plus the unchanged non-sniper impls + bonding curve + V2 graduator
///            + master fee handler + launchpad pulled from the per-chain manifest.
///         5. Deploys a fresh `LivoFactoryUniV4Unified` implementation wired to the new sniper
///            impls (1) and (3) plus the unchanged non-sniper impls + bonding curve + V4 graduator
///            + master fee handler + launchpad pulled from the per-chain manifest.
///         6. Calls `upgradeToAndCall(newFactoryImpl, "")` on the V2 factory UUPS proxy.
///         7. Calls `upgradeToAndCall(newFactoryImpl, "")` on the V4 factory UUPS proxy.
///
///         The proxy addresses — and therefore the launchpad's `whitelistedFactories` entries — do
///         NOT change. No init data is passed; there are no new storage variables to populate.
///
///         The broadcaster MUST be the owner of both proxies. If not, `_authorizeUpgrade` reverts
///         with `OwnableUnauthorizedAccount(broadcaster)` and no state changes.
///
///         Pre-broadcast sanity: confirms that both `LivoTaxableTokenUniV2` and `LivoTaxableTokenUniV4`
///         have their hardcoded `DeploymentAddresses` import pointing at the active chain (run
///         `just taxtokenaddresses` before deploying to Sepolia).
///
///         Post-broadcast: update these five address constants in `src/config/deployments.<chain>.sol`,
///         then run `just export-deployments`:
///         - `TOKEN_SNIPER_PROTECTED_IMPL`
///         - `TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL`
///         - `TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL`
///         - `FACTORY_UNIV2_UNIFIED_IMPL`
///         - `FACTORY_UNIV4_UNIFIED_IMPL`
///
/// @dev    Run with:
///         forge script RedeploySniperTokensAndUpgradeFactories --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeploySniperTokensAndUpgradeFactories is Script {
    /// @dev Per-chain addresses needed to wire the new factory implementations and to upgrade the
    ///      existing proxies. `factoryV2Proxy` and `factoryV4Proxy` are the UUPS proxies whose
    ///      implementations we're swapping; everything else is constructor input to the fresh
    ///      factory implementations.
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
        address taxTokenImpl;
        address taxTokenV2Impl;
    }

    /// @dev Addresses emitted by this script (for logging + manifest updates).
    struct FreshDeployments {
        address tokenSniperImpl;
        address taxTokenV2SniperImpl;
        address taxTokenV4SniperImpl;
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
                taxTokenImpl: DeploymentsMainnet.TAXABLE_TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsMainnet.TAXABLE_TOKEN_V2_IMPL
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesMainnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Mainnet (run `just taxtokenaddresses` only for sepolia)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.UNIV4_POOL_MANAGER == DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
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
                taxTokenImpl: DeploymentsSepolia.TAXABLE_TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsSepolia.TAXABLE_TOKEN_V2_IMPL
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesSepolia.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Sepolia (run `just taxtokenaddresses`)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.UNIV4_POOL_MANAGER == DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else {
            revert("Unsupported chain");
        }

        require(d.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(d.factoryV4Proxy != address(0), "manifest: FACTORY_UNIV4_UNIFIED missing");
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
        require(d.graduatorV4_0p5 != address(0), "manifest: GRADUATOR_UNIV4_0P5 missing");
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(d.taxTokenImpl != address(0), "manifest: TAXABLE_TOKEN_IMPL missing");
        require(d.taxTokenV2Impl != address(0), "manifest: TAXABLE_TOKEN_V2_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        // Sanity: confirm proxies are responsive and initialized. Catches a wrong manifest address
        // pointing at a non-Livo contract before we waste a deploy.
        address ownerV2 = LivoFactoryUniV2Unified(d.factoryV2Proxy).owner();
        address ownerV4 = LivoFactoryUniV4Unified(d.factoryV4Proxy).owner();
        require(ownerV2 != address(0), "V2 proxy not initialized");
        require(ownerV4 != address(0), "V4 proxy not initialized");
        require(ownerV2 == ownerV4, "V2/V4 proxies have diverged owners - verify the manifest");

        console.log("=== Livo Sniper Stack Redeploy ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required owner (V2/V4):  ", ownerV2);
        console.log("V2 factory proxy:        ", d.factoryV2Proxy);
        console.log("V4 factory proxy:        ", d.factoryV4Proxy);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        fresh.tokenSniperImpl = address(new LivoTokenSniperProtected());
        console.log("| LivoTokenSniperProtected (new impl)           |", fresh.tokenSniperImpl);

        fresh.taxTokenV2SniperImpl = address(new LivoTaxableTokenUniV2SniperProtected());
        console.log("| LivoTaxableTokenUniV2SniperProtected (new)    |", fresh.taxTokenV2SniperImpl);

        fresh.taxTokenV4SniperImpl = address(new LivoTaxableTokenUniV4SniperProtected());
        console.log("| LivoTaxableTokenUniV4SniperProtected (new)    |", fresh.taxTokenV4SniperImpl);

        fresh.factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                d.launchpad,
                d.tokenImpl,
                fresh.tokenSniperImpl,
                d.taxTokenV2Impl,
                fresh.taxTokenV2SniperImpl,
                d.bondingCurve,
                d.graduatorV2,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor()
            )
        );
        console.log("| LivoFactoryUniV2Unified (new impl)            |", fresh.factoryV2Impl);

        fresh.factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                d.launchpad,
                d.tokenImpl,
                fresh.tokenSniperImpl,
                d.taxTokenImpl,
                fresh.taxTokenV4SniperImpl,
                d.bondingCurve,
                d.graduatorV4,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor()
            )
        );
        console.log("| LivoFactoryUniV4Unified (new impl)            |", fresh.factoryV4Impl);

        UUPSUpgradeable(d.factoryV2Proxy).upgradeToAndCall(fresh.factoryV2Impl, "");
        console.log("| V2 proxy upgraded to                          |", fresh.factoryV2Impl);

        UUPSUpgradeable(d.factoryV4Proxy).upgradeToAndCall(fresh.factoryV4Impl, "");
        console.log("| V4 proxy upgraded to                          |", fresh.factoryV4Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeploy Complete ===");
        console.log("Proxy addresses are UNCHANGED - no launchpad whitelisting or integrator action needed.");
        console.log("Update the per-chain manifest with these addresses, then run `just export-deployments`:");
        console.log("  TOKEN_SNIPER_PROTECTED_IMPL              :", fresh.tokenSniperImpl);
        console.log("  TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL   :", fresh.taxTokenV2SniperImpl);
        console.log("  TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL      :", fresh.taxTokenV4SniperImpl);
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL               :", fresh.factoryV2Impl);
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL               :", fresh.factoryV4Impl);
    }
}
