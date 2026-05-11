// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";

import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Redeploy `LivoTaxableTokenUniV2` + sniper-protected variant + `LivoFactoryUniV2Unified`
/// @notice Targeted redeploy after the post-window tax-residual drain change in
///         `LivoTaxableTokenUniV2._update`. The taxable V2 token and its sniper-protected
///         subclass are clone implementations, so a fresh deploy is needed to expose the new
///         logic to future tokens. The unified V2 factory stores both impl addresses as
///         `immutable`, so it must be redeployed too, pointing at the new impls.
///
///         Every other live contract keeps its current address: launchpad, bonding curve,
///         master fee handler, deployers whitelist, plain `LivoToken` impls, the V2 graduator,
///         and the entire V4 stack (factory, graduator, tax-token impls).
///
/// @dev    Existing taxable V2 tokens already cloned from the old impl keep the old `_update`
///         logic. Only tokens minted by the NEW factory (against the NEW impls) benefit.
///
///         Run with:
///         forge script RedeployV2TaxTokensAndFactory --rpc-url <sepolia|mainnet> --verify --account livo.dev --slow --broadcast
contract RedeployV2TaxTokensAndFactory is Script {
    struct Inputs {
        // Existing core that is reused — must NOT be redeployed
        address launchpad;
        address bondingCurve;
        address masterFeeHandler;
        address deployersWhitelist;
        address tokenImpl;
        address tokenSniperImpl;
        address graduatorV2;
        // Old taxable-V2 impl + factory addresses, for logging only
        address oldTaxTokenV2Impl;
        address oldTaxTokenV2SniperImpl;
        address oldFactoryV2;
    }

    function _loadInputs() internal view returns (Inputs memory i) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            i = Inputs({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER,
                deployersWhitelist: DeploymentsMainnet.DEPLOYERS_WHITELIST,
                tokenImpl: DeploymentsMainnet.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsMainnet.TOKEN_SNIPER_PROTECTED_IMPL,
                graduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                oldTaxTokenV2Impl: DeploymentsMainnet.TAXABLE_TOKEN_V2_IMPL,
                oldTaxTokenV2SniperImpl: DeploymentsMainnet.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL,
                oldFactoryV2: DeploymentsMainnet.FACTORY_UNIV2_UNIFIED
            });
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            i = Inputs({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                masterFeeHandler: DeploymentsSepolia.MASTER_FEE_HANDLER,
                deployersWhitelist: DeploymentsSepolia.DEPLOYERS_WHITELIST,
                tokenImpl: DeploymentsSepolia.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsSepolia.TOKEN_SNIPER_PROTECTED_IMPL,
                graduatorV2: DeploymentsSepolia.GRADUATOR_UNIV2,
                oldTaxTokenV2Impl: DeploymentsSepolia.TAXABLE_TOKEN_V2_IMPL,
                oldTaxTokenV2SniperImpl: DeploymentsSepolia.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL,
                oldFactoryV2: DeploymentsSepolia.FACTORY_UNIV2_UNIFIED
            });
        } else {
            revert("Unsupported chain");
        }

        require(i.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(i.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(i.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(i.deployersWhitelist != address(0), "manifest: DEPLOYERS_WHITELIST missing");
        require(i.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(i.tokenSniperImpl != address(0), "manifest: TOKEN_SNIPER_PROTECTED_IMPL missing");
        require(i.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
    }

    function run() public {
        Inputs memory i = _loadInputs();

        console.log("=== Redeploy V2 Taxable Token Impls + Unified V2 Factory ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", i.launchpad);
        console.log("Reusing GRADUATOR_UNIV2:", i.graduatorV2);
        console.log("Old TAXABLE_TOKEN_V2_IMPL:", i.oldTaxTokenV2Impl);
        console.log("Old TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL:", i.oldTaxTokenV2SniperImpl);
        console.log("Old FACTORY_UNIV2_UNIFIED:", i.oldFactoryV2);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                | Address |");
        console.log("| -------------------------------------------- | --- |");

        address newTaxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2 (impl, NEW)            |", newTaxTokenV2Impl);

        address newTaxTokenV2SniperImpl = address(new LivoTaxableTokenUniV2SniperProtected());
        console.log("| LivoTaxableTokenUniV2SniperProtected (NEW)   |", newTaxTokenV2SniperImpl);

        address newFactoryV2 = address(
            new LivoFactoryUniV2Unified(
                i.launchpad,
                i.tokenImpl,
                i.tokenSniperImpl,
                newTaxTokenV2Impl,
                newTaxTokenV2SniperImpl,
                i.bondingCurve,
                i.graduatorV2,
                i.masterFeeHandler,
                i.deployersWhitelist
            )
        );
        console.log("| LivoFactoryUniV2Unified (NEW)                |", newFactoryV2);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps (manual, owner-only):");
        console.log("1. Update TAXABLE_TOKEN_V2_IMPL, TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL,");
        console.log("   and FACTORY_UNIV2_UNIFIED in");
        console.log("   src/config/deployments.{mainnet,sepolia}.sol with the addresses above.");
        console.log("2. Run `just export-deployments` to refresh the .md manifests and commit them.");
        console.log("3. Whitelist the new factory on the launchpad with the launchpad-owner account:");
        console.log("     cast send <LAUNCHPAD> 'whitelistFactory(address)' <newFactoryV2> --account livo.admin");
        console.log("4. Blacklist the old factory so it can no longer launch tokens:");
        console.log("     cast send <LAUNCHPAD> 'blacklistFactory(address)' <oldFactoryV2> --account livo.admin");
        console.log("");
        console.log("Note: existing taxable V2 tokens already cloned from the old impl keep the old");
        console.log("`_update` logic and cannot be upgraded in-place; only tokens created via the");
        console.log("new factory benefit from the post-window residual drain.");
    }
}
