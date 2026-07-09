// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

import {Script, console} from "forge-std/Script.sol";

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {CreatorVaultScriptConfig} from "script/CreatorVaultScriptConfig.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {DeploymentAddresses as AddressesFromLivoTaxableTokenV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/manifest.mainnet.sol";
import {DeploymentsSepolia} from "src/config/manifest.sepolia.sol";

/// @title Redeploy every token implementation + both unified factory implementations and upgrade
///        the unified factory proxies
/// @notice Single-broadcast rollout that refreshes the full token + factory stack while preserving
///         the existing UUPS proxy addresses (so launchpad whitelisting and integrators are
///         unaffected). Five new deployments + two proxy upgrades:
///         1. `LivoToken`
///         2. `LivoTaxableTokenUniV2`
///         3. `LivoTaxableTokenUniV4`
///         4. `LivoFactoryUniV2Unified` impl wired to (1)+(2) and the unchanged
///            bondingCurve / V2 graduator / masterFeeHandler / launchpad from the manifest.
///         5. `LivoFactoryUniV4Unified` impl wired to (1)+(3) and the unchanged
///            bondingCurve / V4 graduator / masterFeeHandler / launchpad from the manifest.
///         6. `upgradeToAndCall(newV2FactoryImpl, "")` on the existing V2 UUPS proxy.
///         7. `upgradeToAndCall(newV4FactoryImpl, "")` on the existing V4 UUPS proxy.
///
///         No init data is passed; no new storage was added to the factories. The broadcaster MUST
///         be the proxy owner on BOTH proxies, otherwise `_authorizeUpgrade` reverts with
///         `OwnableUnauthorizedAccount(broadcaster)` and the whole script reverts.
///
///         Pre-broadcast sanity: confirms that `LivoTaxableTokenUniV2` and `LivoTaxableTokenUniV4`
///         have their hardcoded `DeploymentAddresses` import pointing at the active chain (run
///         `just taxtokenaddresses` before deploying to Sepolia).
///
///         Post-broadcast: update these five address constants in `src/config/manifest.<chain>.sol`,
///         then run `just export-deployments`:
///         - `TOKEN_IMPL`
///         - `TAXABLE_TOKEN_V2_IMPL`
///         - `TAXABLE_TOKEN_V4_IMPL`
///         - `FACTORY_UNIV2_UNIFIED_IMPL`
///         - `FACTORY_UNIV4_UNIFIED_IMPL`
///
/// @dev    Run with:
///         forge script RedeployAllTokensAndUpgradeFactories --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeployAllTokensAndUpgradeFactories is Script {
    /// @dev Per-chain addresses needed to wire the new factory implementations and target the proxy
    ///      upgrades. Pulled from `src/config/manifest.<chain>.sol`. No token impls listed here —
    ///      every token impl is freshly deployed in this script.
    struct Deps {
        address factoryV2Proxy;
        address factoryV4Proxy;
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address graduatorV4_0p5;
        address masterFeeHandler;
    }

    /// @dev Addresses emitted by this script (for logging + manifest updates).
    struct FreshDeployments {
        address tokenImpl;
        address taxTokenV2Impl;
        address taxTokenV4Impl;
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
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER
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
                masterFeeHandler: DeploymentsSepolia.MASTER_FEE_HANDLER
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
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        // Catch wrong manifest addresses pointing at non-Livo contracts before we waste deploys.
        address v2ProxyOwner = LivoFactoryUniV2Unified(d.factoryV2Proxy).owner();
        address v4ProxyOwner = LivoFactoryUniV4Unified(d.factoryV4Proxy).owner();
        require(v2ProxyOwner != address(0), "V2 proxy not initialized");
        require(v4ProxyOwner != address(0), "V4 proxy not initialized");
        require(v2ProxyOwner == v4ProxyOwner, "V2 and V4 proxy owners differ; review before upgrading");

        console.log("=== Livo Full Token Stack Redeploy + Both Factory Upgrades ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required proxy owner:    ", v2ProxyOwner);
        console.log("V2 factory proxy:        ", d.factoryV2Proxy);
        console.log("V4 factory proxy:        ", d.factoryV4Proxy);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        // --- Token implementations (3) ---
        fresh.tokenImpl = address(new LivoToken());
        console.log("| LivoToken (new impl)                          |", fresh.tokenImpl);

        fresh.taxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2 (new impl)              |", fresh.taxTokenV2Impl);

        fresh.taxTokenV4Impl = address(new LivoTaxableTokenUniV4());
        console.log("| LivoTaxableTokenUniV4 (new impl)              |", fresh.taxTokenV4Impl);

        // --- Factory implementations (2) wired entirely to the fresh token impls ---
        fresh.factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                d.launchpad,
                ILivoFactory.TokenImpls({base: fresh.tokenImpl, tax: fresh.taxTokenV2Impl}),
                d.bondingCurve,
                d.graduatorV2,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor(),
                CreatorVaultScriptConfig.tierConfigFor()
            )
        );
        console.log("| LivoFactoryUniV2Unified (new impl)            |", fresh.factoryV2Impl);

        fresh.factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                d.launchpad,
                ILivoFactory.TokenImpls({base: fresh.tokenImpl, tax: fresh.taxTokenV4Impl}),
                d.bondingCurve,
                d.graduatorV4,
                d.graduatorV4_0p5,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor(),
                CreatorVaultScriptConfig.v4TierConfigFor()
            )
        );
        console.log("| LivoFactoryUniV4Unified (new impl)            |", fresh.factoryV4Impl);

        // --- Proxy upgrades (2) ---
        UUPSUpgradeable(d.factoryV2Proxy).upgradeToAndCall(fresh.factoryV2Impl, "");
        console.log("| V2 proxy upgraded to                          |", fresh.factoryV2Impl);

        UUPSUpgradeable(d.factoryV4Proxy).upgradeToAndCall(fresh.factoryV4Impl, "");
        console.log("| V4 proxy upgraded to                          |", fresh.factoryV4Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeploy Complete ===");
        console.log("Proxy addresses are UNCHANGED - no launchpad whitelisting or integrator action needed.");
        console.log("Update the per-chain manifest with these addresses, then run `just export-deployments`:");
        console.log("  TOKEN_IMPL                              :", fresh.tokenImpl);
        console.log("  TAXABLE_TOKEN_V2_IMPL                   :", fresh.taxTokenV2Impl);
        console.log("  TAXABLE_TOKEN_V4_IMPL                      :", fresh.taxTokenV4Impl);
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL              :", fresh.factoryV2Impl);
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL              :", fresh.factoryV4Impl);
    }
}
