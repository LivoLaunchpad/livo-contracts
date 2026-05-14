// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Redeploy `LivoGraduatorUniswapV2` and `LivoFactoryUniV2Unified` only
/// @notice Targeted redeploy after correcting `UNIV2_PAIR_INIT_CODE_HASH` for Sepolia.
///         The graduator stores the pair init code hash as `immutable`, so the only way to
///         apply the new value to future tokens is a fresh deployment. The unified V2 factory
///         in turn stores `GRADUATOR` as `immutable`, so it must be redeployed pointing at the
///         new graduator. Every other live contract on Sepolia (launchpad, bonding curve,
///         master fee handler, all token implementations, the V4 factory/graduator) keeps its
///         current address.
///
/// @dev    Mainnet is supported for completeness but mainnet's existing graduator already
///         carries the correct (canonical) hash, so re-running there is normally unnecessary.
///
///         Run with:
///         forge script RedeployV2GraduatorAndFactory --rpc-url <sepolia|mainnet> --verify --account livo.dev --slow --broadcast
contract RedeployV2GraduatorAndFactory is Script {
    struct Inputs {
        // Existing core that is reused — must NOT be redeployed
        address launchpad;
        address bondingCurve;
        address masterFeeHandler;
        address tokenImpl;
        address tokenSniperImpl;
        address taxTokenV2Impl;
        address taxTokenV2SniperImpl;
        // Inputs for the new graduator
        address uniV2Router;
        bytes32 pairInitCodeHash;
        // Old graduator/factory addresses, for logging only
        address oldGraduatorV2;
        address oldFactoryV2;
    }

    function _loadInputs() internal view returns (Inputs memory i) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            i = Inputs({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsMainnet.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsMainnet.TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenV2Impl: DeploymentsMainnet.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV2SniperImpl: DeploymentsMainnet.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL,
                uniV2Router: DeploymentAddressesMainnet.UNIV2_ROUTER,
                pairInitCodeHash: DeploymentAddressesMainnet.UNIV2_PAIR_INIT_CODE_HASH,
                oldGraduatorV2: DeploymentsMainnet.GRADUATOR_UNIV2,
                oldFactoryV2: DeploymentsMainnet.FACTORY_UNIV2_UNIFIED
            });
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            i = Inputs({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                masterFeeHandler: DeploymentsSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsSepolia.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsSepolia.TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenV2Impl: DeploymentsSepolia.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV2SniperImpl: DeploymentsSepolia.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL,
                uniV2Router: DeploymentAddressesSepolia.UNIV2_ROUTER,
                pairInitCodeHash: DeploymentAddressesSepolia.UNIV2_PAIR_INIT_CODE_HASH,
                oldGraduatorV2: DeploymentsSepolia.GRADUATOR_UNIV2,
                oldFactoryV2: DeploymentsSepolia.FACTORY_UNIV2_UNIFIED
            });
        } else {
            revert("Unsupported chain");
        }

        require(i.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(i.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(i.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(i.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(i.tokenSniperImpl != address(0), "manifest: TOKEN_SNIPER_PROTECTED_IMPL missing");
        require(i.taxTokenV2Impl != address(0), "manifest: TAXABLE_TOKEN_V2_IMPL missing");
        require(i.taxTokenV2SniperImpl != address(0), "manifest: TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL missing");
        require(i.uniV2Router != address(0), "config: UNIV2_ROUTER missing");
        require(i.pairInitCodeHash != bytes32(0), "config: UNIV2_PAIR_INIT_CODE_HASH missing");
    }

    function run() public {
        Inputs memory i = _loadInputs();

        console.log("=== Redeploy V2 Graduator + Unified V2 Factory ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", i.launchpad);
        console.log("UniV2 router:", i.uniV2Router);
        console.log("Pair init code hash:");
        console.logBytes32(i.pairInitCodeHash);
        console.log("Old GRADUATOR_UNIV2:", i.oldGraduatorV2);
        console.log("Old FACTORY_UNIV2_UNIFIED:", i.oldFactoryV2);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                    | Address |");
        console.log("| -------------------------------- | --- |");

        address newGraduatorV2 = address(new LivoGraduatorUniswapV2(i.uniV2Router, i.launchpad, i.pairInitCodeHash));
        console.log("| LivoGraduatorUniswapV2 (NEW)     |", newGraduatorV2);

        address newFactoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                i.launchpad,
                i.tokenImpl,
                i.tokenSniperImpl,
                i.taxTokenV2Impl,
                i.taxTokenV2SniperImpl,
                i.bondingCurve,
                newGraduatorV2,
                i.masterFeeHandler
            )
        );
        console.log("| LivoFactoryUniV2Unified (impl)   |", newFactoryV2Impl);

        address newFactoryV2 =
            address(new ERC1967Proxy(newFactoryV2Impl, abi.encodeCall(LivoFactoryAbstract.initialize, ())));
        console.log("| LivoFactoryUniV2Unified (proxy)  |", newFactoryV2);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps (manual, owner-only):");
        console.log("1. Update GRADUATOR_UNIV2 and FACTORY_UNIV2_UNIFIED in");
        console.log("   src/config/deployments.{mainnet,sepolia}.sol with the addresses above.");
        console.log("2. Run `just export-deployments` to refresh the .md manifests and commit them.");
        console.log("3. Whitelist the new factory on the launchpad with the launchpad-owner account:");
        console.log("     cast send <LAUNCHPAD> 'whitelistFactory(address)' <newFactoryV2> --account livo.admin");
        console.log("4. Blacklist the old factory so it can no longer launch tokens:");
        console.log("     cast send <LAUNCHPAD> 'blacklistFactory(address)' <oldFactoryV2> --account livo.admin");
        console.log("");
        console.log("Note: existing taxable V2 tokens already launched against the old graduator");
        console.log("keep their (wrong) immutable `pair` storage and cannot be fixed in-place;");
        console.log("only newly-created tokens benefit from this redeploy.");
    }
}
