// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Robinhood Chain Mainnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 4663.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.robinhood.mainnet.md`.
library DeploymentsRobinhoodMainnet {
    uint256 internal constant BLOCKCHAIN_ID = 4663;

    // --- Core ---
    address internal constant LAUNCHPAD = address(0);
    address internal constant BONDING_CURVE = address(0);
    address internal constant GRADUATOR_UNIV2 = address(0);
    address internal constant GRADUATOR_UNIV4 = address(0);
    /// @notice V4 graduator paired with the 50-bps `SWAP_HOOK_0P5` variant. Update after deploying.
    address internal constant GRADUATOR_UNIV4_0P5 = address(0);
    address internal constant MASTER_FEE_HANDLER = address(0);

    address internal constant SWAP_HOOK = address(0);
    address internal constant SWAP_HOOK_0P5 = address(0);
    address internal constant QUOTER = address(0);

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = address(0);
    address internal constant TAXABLE_TOKEN_V4_IMPL = address(0);

    /// @notice V2 taxable token implementation (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = address(0);

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = address(0);
    address internal constant FACTORY_UNIV4_UNIFIED = address(0);

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = address(0);
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = address(0);

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = address(0);
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = address(0);
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = address(0);

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = address(0);
    address internal constant VAULT_CURVE_10 = address(0);
    address internal constant VAULT_CURVE_15 = address(0);
    address internal constant VAULT_CURVE_20 = address(0);
    address internal constant VAULT_CURVE_25 = address(0);
    address internal constant VAULT_CURVE_30 = address(0);

    /// @notice The six vault curves as the `address[6]` the unified-factory constructors expect.
    function vaultBondingCurves() internal pure returns (address[6] memory c) {
        c[0] = VAULT_CURVE_5;
        c[1] = VAULT_CURVE_10;
        c[2] = VAULT_CURVE_15;
        c[3] = VAULT_CURVE_20;
        c[4] = VAULT_CURVE_25;
        c[5] = VAULT_CURVE_30;
    }

    // --- Liquidity tiers (THIN + THICK) ---
    /// @notice THIN/THICK V4 graduators, one per (tier x hook fee). The DEFAULT tier reuses
    ///         `GRADUATOR_UNIV4` / `GRADUATOR_UNIV4_0P5`. Update after deploying with
    ///         `DeployTierLiquiditySystem`.
    address internal constant GRADUATOR_UNIV4_THIN = address(0);
    address internal constant GRADUATOR_UNIV4_THIN_0P5 = address(0);
    address internal constant GRADUATOR_UNIV4_THICK = address(0);
    address internal constant GRADUATOR_UNIV4_THICK_0P5 = address(0);

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployTierLiquiditySystem`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = address(0);
    address internal constant THIN_VAULT_CURVE_5 = address(0);
    address internal constant THIN_VAULT_CURVE_10 = address(0);
    address internal constant THIN_VAULT_CURVE_15 = address(0);
    address internal constant THIN_VAULT_CURVE_20 = address(0);
    address internal constant THIN_VAULT_CURVE_25 = address(0);
    address internal constant THIN_VAULT_CURVE_30 = address(0);

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = address(0);
    address internal constant THICK_VAULT_CURVE_5 = address(0);
    address internal constant THICK_VAULT_CURVE_10 = address(0);
    address internal constant THICK_VAULT_CURVE_15 = address(0);
    address internal constant THICK_VAULT_CURVE_20 = address(0);
    address internal constant THICK_VAULT_CURVE_25 = address(0);
    address internal constant THICK_VAULT_CURVE_30 = address(0);

    /// @notice The six THIN-tier vault curves as the `address[6]` the factory tier config expects.
    function thinVaultCurves() internal pure returns (address[6] memory c) {
        c[0] = THIN_VAULT_CURVE_5;
        c[1] = THIN_VAULT_CURVE_10;
        c[2] = THIN_VAULT_CURVE_15;
        c[3] = THIN_VAULT_CURVE_20;
        c[4] = THIN_VAULT_CURVE_25;
        c[5] = THIN_VAULT_CURVE_30;
    }

    /// @notice The six THICK-tier vault curves as the `address[6]` the factory tier config expects.
    function thickVaultCurves() internal pure returns (address[6] memory c) {
        c[0] = THICK_VAULT_CURVE_5;
        c[1] = THICK_VAULT_CURVE_10;
        c[2] = THICK_VAULT_CURVE_15;
        c[3] = THICK_VAULT_CURVE_20;
        c[4] = THICK_VAULT_CURVE_25;
        c[5] = THICK_VAULT_CURVE_30;
    }

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = address(0);
}
