// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Ethereum Mainnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 1.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives there since it is
///      consumed by core contracts at deploy time. Update this file on every redeploy
///      and run `just export-deployments` to refresh `deployments.mainnet.md`.
library DeploymentsMainnet {
    uint256 internal constant BLOCKCHAIN_ID = 1;

    // --- Core ---
    address internal constant LAUNCHPAD = 0xaA74Aa89590E3B50BE178eA970E490c173b61110;
    address internal constant BONDING_CURVE = 0x3faCE9330730fB6f2a9Bb5994cDC882F21ee0A23;
    address internal constant GRADUATOR_UNIV2 = 0x042ed119F78b734407C6368A01D799C503df2E63;
    address internal constant GRADUATOR_UNIV4 = 0x86eDfc50E65233ff3e5b26DeeD49578a157565d7;
    /// @notice V4 graduator paired with the 50-bps `SWAP_HOOK_0P5` variant. Update after deploying.
    address internal constant GRADUATOR_UNIV4_0P5 = 0xE5C38dA8e9BB8a1d2069419606e0f04dc8c57E43;
    address internal constant MASTER_FEE_HANDLER = 0x6F0f4F70a403B9191D6adf2C10750Ab8436345cC;

    address internal constant SWAP_HOOK = 0x627FA6F76FA96b10BAe1B6Fba280A3c9264500Cc;
    address internal constant SWAP_HOOK_0P5 = 0x068241d20c59980AbEAeDED990d2441F05f5C0Cc;
    address internal constant QUOTER = 0xBd208C238Dd7895a7b94833063C2397F10E056f1;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x1002488Af3EE59871339FCe0D171e1d32F62Aa77;
    address internal constant TAXABLE_TOKEN_IMPL = 0xeD45762D25ce4CAE647bf27c8c9c6C7645498c09;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0x35eBA2610F707B48E0e4ae66E2a0a1535d7B11Fb;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0xFfb90D2d55515314210Fb0cB4BE82A6645572103;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x8DBdc48B8d9066983ad84be79B0382edCe390a04;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0xcF816bA12a24cD9CC3297A6Ff7528cb66ea7e388;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x78Af7E41ab894fc2aCd1b1c918e3CC6d710054b9;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x9A996216c0Cd3B1cDeDC4D2A38E0ca94eBeC3565;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xaB56c5f8E111f6420277063E2E406Fd25159db97;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x8B770A483894ce7C1Eb91f7E1a33Bb040Fd4fA1C;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xcad4C889e0897BF3fdeE367F402F728342651603;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xA06f07bf255cB63c694339F172f9459f3BF015E7;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x4b387716EbA7498Eb757467A876FAA98733A329e;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0xa284c9B990bEF46d391aCB49a0d61dE1FD4269B5;
    address internal constant VAULT_CURVE_10 = 0x97f50A854258Bd5ec9B4841B33f4A55Be776A0Cb;
    address internal constant VAULT_CURVE_15 = 0x28cBC163704aCc3e262325D266A1072111d3e373;
    address internal constant VAULT_CURVE_20 = 0xe749FE88361c637f3553E64FcA59D08734D0cED2;
    address internal constant VAULT_CURVE_25 = 0xd919428D5c2c618795C687C2357254c9e084ceaC;
    address internal constant VAULT_CURVE_30 = 0x8cF38ee3a4206D4808D3730d2DC7E4dE47b8f316;

    /// @notice The six vault curves as the `address[6]` the unified-factory constructors expect.
    function vaultBondingCurves() internal pure returns (address[6] memory c) {
        c[0] = VAULT_CURVE_5;
        c[1] = VAULT_CURVE_10;
        c[2] = VAULT_CURVE_15;
        c[3] = VAULT_CURVE_20;
        c[4] = VAULT_CURVE_25;
        c[5] = VAULT_CURVE_30;
    }

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
