// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ConstantProductBondingCurveImmutable} from "src/bondingCurves/ConstantProductBondingCurveImmutable.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {LivoCreatorVault} from "src/tokens/LivoCreatorVault.sol";
import {LivoCreatorVaultFactory} from "src/factories/LivoCreatorVaultFactory.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Deploy the creator-vault system
/// @notice Deploys the net-new creator-vault contracts:
///         1. The six `ConstantProductBondingCurveImmutable` curves (5%..30% locked allocation),
///            each preserving every graduation invariant of the base curve.
///         2. The `LivoCreatorVault` implementation.
///         3. The `LivoCreatorVaultFactory` implementation + its `ERC1967Proxy`.
///
///         After running, update the `CREATOR_VAULT_*` and `VAULT_CURVE_*` addresses in
///         `src/config/deployments.{mainnet,sepolia}.sol`, run `just export-deployments`, and only
///         THEN (re)deploy/upgrade the unified factories so they pick up the new addresses.
///
/// @dev    Run with:
///         forge script DeployCreatorVaultSystem --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeployCreatorVaultSystem is Script {
    function run() public {
        require(
            block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID || block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID,
            "Unsupported chain"
        );

        console.log("=== Livo Creator-Vault System Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("");

        uint256[6] memory bpsList = [uint256(500), 1000, 1500, 2000, 2500, 3000];

        vm.startBroadcast();

        console.log("| Contract Name                          | Address |");
        console.log("| -------------------------------------- | --- |");

        // 1. The six allocation-specific bonding curves.
        address[6] memory curves;
        for (uint256 i = 0; i < 6; ++i) {
            (uint256 k, uint256 t0, uint256 e0) = CreatorVaultCurveConstants.paramsForBps(bpsList[i]);
            curves[i] = address(new ConstantProductBondingCurveImmutable(k, t0, e0));
            console.log("| VAULT_CURVE bps", bpsList[i], curves[i]);
        }

        // 2. The vault implementation cloned for every creator vault.
        address vaultImpl = address(new LivoCreatorVault());
        console.log("| LivoCreatorVault (impl)               |", vaultImpl);

        // 3. The vault factory implementation + UUPS proxy.
        address vaultFactoryImpl = address(new LivoCreatorVaultFactory(vaultImpl));
        console.log("| LivoCreatorVaultFactory (impl)        |", vaultFactoryImpl);

        address vaultFactory =
            address(new ERC1967Proxy(vaultFactoryImpl, abi.encodeCall(LivoCreatorVaultFactory.initialize, ())));
        console.log("| LivoCreatorVaultFactory (proxy)       |", vaultFactory);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. In src/config/deployments.{mainnet,sepolia}.sol set:");
        console.log("   CREATOR_VAULT_IMPL, CREATOR_VAULT_FACTORY (proxy), CREATOR_VAULT_FACTORY_IMPL,");
        console.log("   and VAULT_CURVE_5 .. VAULT_CURVE_30 to the addresses above.");
        console.log("2. Run `just export-deployments` and commit the refreshed manifests.");
        console.log("3. Deploy/upgrade the unified factories so they pick up the new addresses.");
    }
}
