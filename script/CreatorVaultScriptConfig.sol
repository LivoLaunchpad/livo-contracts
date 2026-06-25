// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploymentsMainnet} from "src/config/manifest.mainnet.sol";
import {DeploymentsSepolia} from "src/config/manifest.sepolia.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";

/// @title CreatorVaultScriptConfig
/// @notice Script-only helper that resolves the two creator-vault constructor args the unified
///         factories now take — the `LivoCreatorVaultFactory` and the six allocation-specific
///         bonding curves — from the per-chain manifest. Lives under `script/` (not `src/`) so the
///         per-chain `block.chainid` split stays out of production/deployable code: this is a
///         deploy-time-only `internal` library, inlined into the scripts that use it.
/// @dev    Populated by `DeployCreatorVaultSystem` → manifest update. Until then these are
///         `address(0)`; the factory constructor doesn't validate them (vault args are only read
///         when a token actually locks supply in vaults), so an early upgrade won't revert — but
///         you MUST deploy the vault system and refresh the manifest before tokens use vaults.
library CreatorVaultScriptConfig {
    /// @notice The `LivoCreatorVaultFactory` proxy for the active chain.
    function factoryFor() internal view returns (address) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) return DeploymentsMainnet.CREATOR_VAULT_FACTORY;
        if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) return DeploymentsSepolia.CREATOR_VAULT_FACTORY;
        revert("CreatorVaultScriptConfig: unsupported chain");
    }

    /// @notice The six allocation-specific bonding curves [5%..30%] for the active chain.
    function curvesFor() internal view returns (address[6] memory) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) return DeploymentsMainnet.vaultBondingCurves();
        if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) return DeploymentsSepolia.vaultBondingCurves();
        revert("CreatorVaultScriptConfig: unsupported chain");
    }

    /// @notice THIN + THICK tier curve sets (no-vault base + six vault curves each) for the active chain.
    /// @dev Reads the manifest tier slots populated by `DeployTierLiquiditySystem`. Until that script
    ///      has run and the manifest is refreshed these resolve to `address(0)` — the factory
    ///      constructor doesn't validate them and they're only read when a token actually selects the
    ///      THIN/THICK tier, so an early factory deploy/upgrade won't revert. You MUST deploy the tier
    ///      system and refresh the manifest before THIN/THICK tokens can be created.
    function tierConfigFor() internal view returns (ILivoFactory.LiquidityTierConfig memory tierConfig) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            tierConfig.thin = ILivoFactory.TierCurves({
                base: DeploymentsMainnet.THIN_CURVE_BASE, vaults: DeploymentsMainnet.thinVaultCurves()
            });
            tierConfig.thick = ILivoFactory.TierCurves({
                base: DeploymentsMainnet.THICK_CURVE_BASE, vaults: DeploymentsMainnet.thickVaultCurves()
            });
            return tierConfig;
        }
        if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            tierConfig.thin = ILivoFactory.TierCurves({
                base: DeploymentsSepolia.THIN_CURVE_BASE, vaults: DeploymentsSepolia.thinVaultCurves()
            });
            tierConfig.thick = ILivoFactory.TierCurves({
                base: DeploymentsSepolia.THICK_CURVE_BASE, vaults: DeploymentsSepolia.thickVaultCurves()
            });
            return tierConfig;
        }
        revert("CreatorVaultScriptConfig: unsupported chain");
    }

    /// @notice The full V4 tier config (curves + per-tier graduators) for the active chain. See `tierConfigFor`.
    function v4TierConfigFor() internal view returns (LivoFactoryUniV4Unified.V4TierConfig memory v4Tier) {
        v4Tier.curves = tierConfigFor();
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            v4Tier.graduators = LivoFactoryUniV4Unified.TierGraduators({
                thin: DeploymentsMainnet.GRADUATOR_UNIV4_THIN,
                thin0p5: DeploymentsMainnet.GRADUATOR_UNIV4_THIN_0P5,
                thick: DeploymentsMainnet.GRADUATOR_UNIV4_THICK,
                thick0p5: DeploymentsMainnet.GRADUATOR_UNIV4_THICK_0P5
            });
            return v4Tier;
        }
        if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            v4Tier.graduators = LivoFactoryUniV4Unified.TierGraduators({
                thin: DeploymentsSepolia.GRADUATOR_UNIV4_THIN,
                thin0p5: DeploymentsSepolia.GRADUATOR_UNIV4_THIN_0P5,
                thick: DeploymentsSepolia.GRADUATOR_UNIV4_THICK,
                thick0p5: DeploymentsSepolia.GRADUATOR_UNIV4_THICK_0P5
            });
            return v4Tier;
        }
        revert("CreatorVaultScriptConfig: unsupported chain");
    }
}
