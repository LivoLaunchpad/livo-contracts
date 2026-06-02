// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title CreatorVaultDeployHelper
/// @notice Resolves the two creator-vault constructor args the unified factories now take — the
///         `LivoCreatorVaultFactory` and the six allocation-specific bonding curves — from the
///         per-chain manifest. Used by every script that (re)constructs a unified factory impl, so
///         the args come from a single source.
/// @dev    Populated by `DeployCreatorVaultSystem` → manifest update. Until then these are
///         `address(0)`; the factory constructor doesn't validate them (vault args are only read
///         when a token actually locks supply in vaults), so an early upgrade won't revert — but
///         you MUST deploy the vault system and refresh the manifest before tokens use vaults.
library CreatorVaultDeployHelper {
    /// @notice The `LivoCreatorVaultFactory` proxy for the active chain.
    function factoryFor() internal view returns (address) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) return DeploymentsMainnet.CREATOR_VAULT_FACTORY;
        if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) return DeploymentsSepolia.CREATOR_VAULT_FACTORY;
        revert("CreatorVaultDeployHelper: unsupported chain");
    }

    /// @notice The six allocation-specific bonding curves [5%..30%] for the active chain.
    function curvesFor() internal view returns (address[6] memory) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) return DeploymentsMainnet.vaultBondingCurves();
        if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) return DeploymentsSepolia.vaultBondingCurves();
        revert("CreatorVaultDeployHelper: unsupported chain");
    }
}
