// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";

import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoFactoryUniV2} from "src/factories/LivoFactoryUniV2.sol";
import {LivoFactoryUniV2SniperProtected} from "src/factories/LivoFactoryUniV2SniperProtected.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Livo V2 Graduator + V2 Factories Re-Deployment
/// @notice Deploys a fresh `LivoGraduatorUniswapV2` and the two V2 factories
///         (`LivoFactoryUniV2`, `LivoFactoryUniV2SniperProtected`) wired against the new graduator.
///         Reuses the live core (launchpad, bonding curve, fee handler, fee splitter impl) and the
///         existing token implementations from `deployments.{mainnet,sepolia}.sol`.
///         Whitelists both new factories on the launchpad in the same broadcast.
/// @dev Run with:
///      forge script DeploymentsGraduatorAndFactoriesUniV2 --rpc-url <mainnet|sepolia> --broadcast --verify --account livo.dev --slow
contract DeploymentsGraduatorAndFactoriesUniV2 is Script {
    struct Deps {
        address launchpad;
        address bondingCurve;
        address feeHandler;
        address feeSplitterImpl;
        address tokenImpl;
        address tokenSniperImpl;
        address univ2Router;
        bytes32 univ2PairInitCodeHash;
    }

    /// @notice Resolves the deps needed to deploy the V2 graduator + V2 factories on the active chain.
    /// @dev Core/token-impl addresses come from `deployments.{mainnet,sepolia}.sol`.
    ///      UniV2 router + pair init-code hash come from `DeploymentAddresses.sol`.
    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                feeHandler: DeploymentsMainnet.FEE_HANDLER,
                feeSplitterImpl: DeploymentsMainnet.FEE_SPLITTER_IMPL,
                tokenImpl: DeploymentsMainnet.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsMainnet.TOKEN_SNIPER_PROTECTED_IMPL,
                univ2Router: DeploymentAddressesMainnet.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesMainnet.UNIV2_PAIR_INIT_CODE_HASH
            });
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                feeHandler: DeploymentsSepolia.FEE_HANDLER,
                feeSplitterImpl: DeploymentsSepolia.FEE_SPLITTER_IMPL,
                tokenImpl: DeploymentsSepolia.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsSepolia.TOKEN_SNIPER_PROTECTED_IMPL,
                univ2Router: DeploymentAddressesSepolia.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesSepolia.UNIV2_PAIR_INIT_CODE_HASH
            });
        } else {
            revert("Unsupported chain");
        }
    }

    function run() public {
        Deps memory d = _getDeps();

        console.log("=== Livo V2 Graduator + V2 Factories Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", d.launchpad);
        console.log("UniV2 Router:", d.univ2Router);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name | Address |");
        console.log("| ---- | --- |");

        // 1. Deploy fresh V2 graduator (constructor takes the centralized pair init-code hash).
        LivoGraduatorUniswapV2 graduatorV2 =
            new LivoGraduatorUniswapV2(d.univ2Router, d.launchpad, d.univ2PairInitCodeHash);
        console.log("| LivoGraduatorUniswapV2 | ", address(graduatorV2));

        // 2. Deploy V2 factory wired to the *just-deployed* graduator (not the manifest's stale one).
        LivoFactoryUniV2 factoryV2 = new LivoFactoryUniV2(
            d.launchpad, d.tokenImpl, d.bondingCurve, address(graduatorV2), d.feeHandler, d.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV2 | ", address(factoryV2));

        // 3. Deploy sniper-protected V2 factory wired to the same new graduator.
        LivoFactoryUniV2SniperProtected factoryV2Sniper = new LivoFactoryUniV2SniperProtected(
            d.launchpad, d.tokenSniperImpl, d.bondingCurve, address(graduatorV2), d.feeHandler, d.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV2SniperProtected | ", address(factoryV2Sniper));

        // whitelisting has to be done with livo.admin account instead

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. Update GRADUATOR_UNIV2 / FACTORY_UNIV2 / FACTORY_UNIV2_SNIPER_PROTECTED in");
        console.log("   src/config/deployments.{mainnet,sepolia}.sol with the addresses above.");
        console.log("2. Run `just export-deployments` to refresh the .md manifests and commit.");
        console.log("3. Whitelist factories in launchpad");
    }
}
