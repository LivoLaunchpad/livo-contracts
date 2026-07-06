// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Robinhood Chain Testnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 46630.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.robinhood.testnet.md`.
library DeploymentsRobinhoodTestnet {
    uint256 internal constant BLOCKCHAIN_ID = 46630;

    // --- Core ---
    address internal constant LAUNCHPAD = 0xCbcaB7c9d9Ce45CEFb17bBEbd419881b253d7371;
    address internal constant BONDING_CURVE = 0x422fe43Ac0a9c7566b7B6A89e4bbF990c22807e7;
    address internal constant GRADUATOR_UNIV2 = 0xCF9bbdEA70731c624D1E47879E7d9DB673980fCB;
    address internal constant GRADUATOR_UNIV4 = 0xDB0e47517Fc6E4dd7F043c79BF2fA70C24B0f89C;
    /// @notice V4 graduator paired with the 50-bps `SWAP_HOOK_0P5` variant. Update after deploying.
    address internal constant GRADUATOR_UNIV4_0P5 = 0xfd68Ca33f04f6604Dad8F99F8fB31A354434a2e5;
    address internal constant MASTER_FEE_HANDLER = 0x2Bf62383a4A1349461bB744b4eC561338D8b4CF9;

    address internal constant SWAP_HOOK = 0x72bd7C3933c25723Def72c7b4c7b789Eb130C0cc;
    address internal constant SWAP_HOOK_0P5 = 0x994F38EADFF9DA05d565f28752bea6CA6E68C0cC;
    address internal constant QUOTER = 0x66534bDE4f69F69342F929479797F7118B7ca74F;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x1dbe8e4AF4163B2F08509C7551EebAd43fdFEd1b;
    address internal constant TAXABLE_TOKEN_IMPL = 0x79f83FFE7924f3e9B0c47d287F52C4188AB87Ffa;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0x787D46e3cd7d3E4fA68E4071a98947543d209590;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0x53f6B9c5aa907819635006381f39F89C49206D0A;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x7983537048B67c1266DE2B78e1223d40a85a602F;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0x80bDF35d05c08958100F92B2745993A0125ad559;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x9a1dA2D2E6De2b5BF94d52CAB9EcD9A94c3D3acF;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x43224f30cBe865E85E8890ED2Cc13A180463bC39;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xE67FCFB498085dfcd09275354B90c8db8C99554D;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0xd67E7719Efd39C59eDfa9389e2616A16D2Ac8496;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xF74aD241bDe9e2DAe7849D06ee4935731c1B5258;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x08feCd4F6340EdEb8F34a8e117fa248eD4A722d6;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0xeC46b101f042bbf0A677de0dfFe4dbD6cD2A0888;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0xc89Fd26039DaA40BeE2e8D6a2c661AF8D52cb45d;
    address internal constant VAULT_CURVE_10 = 0xb17Ac827De11b1b69c37D3A9cA8d53C1E2718b0F;
    address internal constant VAULT_CURVE_15 = 0x758Af7bCde2875a6Aa06337125EA81335a860AC5;
    address internal constant VAULT_CURVE_20 = 0x588951ecc682cBbe3BC4fa60F807e2Fa165255B2;
    address internal constant VAULT_CURVE_25 = 0x3faCE9330730fB6f2a9Bb5994cDC882F21ee0A23;
    address internal constant VAULT_CURVE_30 = 0x0776824884d9E10b526ce735f4b110722c2AdB56;

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
    address internal constant GRADUATOR_UNIV4_THIN = 0x7990C167E280CB54eAAd8Dc30AAF7bc36aFD58d4;
    address internal constant GRADUATOR_UNIV4_THIN_0P5 = 0xa13cd72870f73c76f0E2a9f97600663fA3913Cb6;
    address internal constant GRADUATOR_UNIV4_THICK = 0x1AaD3F15074fe6156AE0B2d89e5316F6f90159C5;
    address internal constant GRADUATOR_UNIV4_THICK_0P5 = 0xe926Eb8F6ba997E5b45247eCE800c0A27E539e57;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployTierLiquiditySystem`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0xc18030d76573784fff4E6365309E1acD967506ff;
    address internal constant THIN_VAULT_CURVE_5 = 0x5E8b516d97C4D9D22e070342cc39EF7De84ab412;
    address internal constant THIN_VAULT_CURVE_10 = 0x46aF9F05825459d149ed036Bb6461E1FE8fA25D8;
    address internal constant THIN_VAULT_CURVE_15 = 0xCF6910d89d052F025ed402638e4Ae78ecDCdDfA5;
    address internal constant THIN_VAULT_CURVE_20 = 0x80d97b49169067f339934C39F3ae76C50ED046a6;
    address internal constant THIN_VAULT_CURVE_25 = 0xe6872f6E326100b322bcBFb71C3627c3bEbB5C93;
    address internal constant THIN_VAULT_CURVE_30 = 0x571CD864b15275Ddd13AC100c3c07B7cb072cEFd;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x43464b991D7D54b38D68Ef20c0737c7b769843d0;
    address internal constant THICK_VAULT_CURVE_5 = 0xB4a6285136506567291F615b794b14Afc86A62a5;
    address internal constant THICK_VAULT_CURVE_10 = 0xbf3787fFBa24846DBa9B5D88fE041DE47bF3Da0d;
    address internal constant THICK_VAULT_CURVE_15 = 0x33cD2e9093a866A34d53806672E3cC4e7563CF2e;
    address internal constant THICK_VAULT_CURVE_20 = 0x1DBBD4155097e7B57f175Ba8F2610ea27922FdD3;
    address internal constant THICK_VAULT_CURVE_25 = 0xF3d529382A7ef990b3C2901Ad7Bc8339B386d2b5;
    address internal constant THICK_VAULT_CURVE_30 = 0xcb1a4F25E031837468c4929bD4a8033c06374318;

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
