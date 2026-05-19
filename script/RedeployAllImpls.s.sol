// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {DeploymentAddresses as AddressesFromLivoTaxableTokenV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Redeploy ALL token implementations + both unified factory implementations
/// @notice Wraps up the rollout for the `receive()` refactor on `LivoMasterFeeHandler` and the
///         matching `_accrueFees` migration on every token (base / sniper-protected / V2 tax /
///         V4 tax). Existing deployed tokens keep pointing at the OLD master fee handler — they
///         still use the legacy `depositFees(address(this))` path, which works unchanged. New
///         tokens spun up by the upgraded factories will use the NEW master fee handler via the
///         direct-ETH-transfer / `receive()` entry point.
///
///         Pre-requisite (manual step, done OFF this script): deploy the new `LivoMasterFeeHandler`
///         and write its address into `MASTER_FEE_HANDLER` in `src/config/deployments.<chain>.sol`.
///         This script reads that constant and refuses to run if it's missing or has no code.
///
///         Single broadcast:
///         1. Deploy fresh `LivoToken` (non-tax base).
///         2. Deploy fresh `LivoTokenSniperProtected` (non-tax + sniper).
///         3. Deploy fresh `LivoTaxableTokenUniV2`.
///         4. Deploy fresh `LivoTaxableTokenUniV2SniperProtected`.
///         5. Deploy fresh `LivoTaxableTokenUniV4`.
///         6. Deploy fresh `LivoTaxableTokenUniV4SniperProtected`.
///         7. Deploy fresh `LivoFactoryUniV2Unified` impl, wired to the manifest's
///            `MASTER_FEE_HANDLER` + V2 token impls + the unchanged V2 graduator / bonding curve / launchpad.
///         8. Deploy fresh `LivoFactoryUniV4Unified` impl, wired to the manifest's
///            `MASTER_FEE_HANDLER` + V4 token impls + the unchanged V4 graduator / bonding curve / launchpad.
///
///         The factory proxy upgrades are intentionally NOT performed here — they are a separate,
///         manual follow-up step done after the new impls have been deployed and inspected.
///
///         Pre-broadcast sanity: confirms both V2 and V4 tax-token sources import the right
///         per-chain `DeploymentAddresses`. Run `just taxtokenaddresses` before deploying to Sepolia.
///
///         Post-broadcast: update all six token impl addresses and both
///         `FACTORY_UNI*_UNIFIED_IMPL` addresses in `src/config/deployments.<chain>.sol`, then run
///         `just export-deployments`. The proxy upgrades (`upgradeToAndCall` on each unified factory
///         proxy) are run separately once the new impls are verified.
///
/// @dev    Run with:
///         forge script RedeployAllImpls --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeployAllImpls is Script {
    /// @dev Per-chain addresses needed to wire the new factory implementations. Pulled from
    ///      `src/config/deployments.<chain>.sol`. `masterFeeHandler` must already point at the
    ///      freshly-deployed handler (manual pre-step).
    struct Deps {
        // Shared inputs reused by both fresh factory impls (unchanged across this redeploy)
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        // New master fee handler — deployed manually beforehand and stamped into the manifest
        address masterFeeHandler;
    }

    /// @dev Addresses emitted by this script (for logging + manifest updates).
    struct FreshDeployments {
        address tokenImpl;
        address tokenSniperImpl;
        address taxTokenV2Impl;
        address taxTokenV2SniperImpl;
        address taxTokenV4Impl;
        address taxTokenV4SniperImpl;
        address factoryV2Impl;
        address factoryV4Impl;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsMainnet.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesMainnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Mainnet (run `just taxtokenaddresses` only for sepolia)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.BLOCKCHAIN_ID == DeploymentAddressesMainnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV4 import is not Mainnet (run `just taxtokenaddresses` only for sepolia)"
            );
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsSepolia.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsSepolia.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsSepolia.MASTER_FEE_HANDLER
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesSepolia.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Sepolia (run `just taxtokenaddresses`)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.BLOCKCHAIN_ID == DeploymentAddressesSepolia.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV4 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else {
            revert("Unsupported chain");
        }

        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.masterFeeHandler.code.length > 0, "manifest: MASTER_FEE_HANDLER has no code at this address");
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        console.log("=== Livo All-Impls Redeploy (new MasterFeeHandler) ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("MASTER_FEE_HANDLER (from manifest):", d.masterFeeHandler);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        // --- (1-2) Non-tax token implementations ---
        fresh.tokenImpl = address(new LivoToken());
        console.log("| LivoToken (new impl)                          |", fresh.tokenImpl);

        fresh.tokenSniperImpl = address(new LivoTokenSniperProtected());
        console.log("| LivoTokenSniperProtected (new impl)           |", fresh.tokenSniperImpl);

        // --- (3-6) Tax-token implementations ---
        fresh.taxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2 (new impl)              |", fresh.taxTokenV2Impl);

        fresh.taxTokenV2SniperImpl = address(new LivoTaxableTokenUniV2SniperProtected());
        console.log("| LivoTaxableTokenUniV2SniperProtected (new)    |", fresh.taxTokenV2SniperImpl);

        fresh.taxTokenV4Impl = address(new LivoTaxableTokenUniV4());
        console.log("| LivoTaxableTokenUniV4 (new impl)              |", fresh.taxTokenV4Impl);

        fresh.taxTokenV4SniperImpl = address(new LivoTaxableTokenUniV4SniperProtected());
        console.log("| LivoTaxableTokenUniV4SniperProtected (new)    |", fresh.taxTokenV4SniperImpl);

        // --- (7-8) Factory implementations wired to the manifest's master fee handler + fresh token impls ---
        fresh.factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                d.launchpad,
                fresh.tokenImpl,
                fresh.tokenSniperImpl,
                fresh.taxTokenV2Impl,
                fresh.taxTokenV2SniperImpl,
                d.bondingCurve,
                d.graduatorV2,
                d.masterFeeHandler
            )
        );
        console.log("| LivoFactoryUniV2Unified (new impl)            |", fresh.factoryV2Impl);

        fresh.factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                d.launchpad,
                fresh.tokenImpl,
                fresh.tokenSniperImpl,
                fresh.taxTokenV4Impl,
                fresh.taxTokenV4SniperImpl,
                d.bondingCurve,
                d.graduatorV4,
                d.masterFeeHandler
            )
        );
        console.log("| LivoFactoryUniV4Unified (new impl)            |", fresh.factoryV4Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeploy Complete ===");
        console.log("Factory proxies were NOT upgraded - run the proxy upgrade step manually next.");
        console.log("Update the per-chain manifest with these addresses, then run `just export-deployments`:");
        console.log("  TOKEN_IMPL                             :", fresh.tokenImpl);
        console.log("  TOKEN_SNIPER_PROTECTED_IMPL            :", fresh.tokenSniperImpl);
        console.log("  TAXABLE_TOKEN_V2_IMPL                  :", fresh.taxTokenV2Impl);
        console.log("  TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL :", fresh.taxTokenV2SniperImpl);
        console.log("  TAXABLE_TOKEN_IMPL                     :", fresh.taxTokenV4Impl);
        console.log("  TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL    :", fresh.taxTokenV4SniperImpl);
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL             :", fresh.factoryV2Impl);
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL             :", fresh.factoryV4Impl);
    }
}
