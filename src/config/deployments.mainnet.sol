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
    address internal constant LAUNCHPAD = 0xd9f8bbe437a3423b725c6616C1B543775ecf1110;
    address internal constant BONDING_CURVE = 0x3faCE9330730fB6f2a9Bb5994cDC882F21ee0A23;
    address internal constant GRADUATOR_UNIV2 = 0x7cC6AC0aa4130A5dFe7d00C85645f6Cd2bd7e1cC;
    address internal constant GRADUATOR_UNIV4 = 0x3b6f7a54F3225B9D1B546E0138a2e3D140D89944;
    address internal constant MASTER_FEE_HANDLER = 0x6F0f4F70a403B9191D6adf2C10750Ab8436345cC;

    address internal constant SWAP_HOOK = 0x9cd5577f3A749dE70B13A676F4D56BD6fD6C00cc;
    address internal constant QUOTER = 0x035693207fb473358b41A81FF09445dB1f3889D1;

    /// @notice LP fee router proxy (UUPS) consumed by `LivoSwapHook`. Splits LP fees between the
    ///         protocol treasury and the per-token creator using a marketcap-tiered policy.
    address internal constant LP_FEE_ROUTER = 0x8fC6Fd4F06e00041242321B986aE5e7aE4a87635;
    /// @notice Implementation currently set behind `LP_FEE_ROUTER`. Tracked for verification only.
    address internal constant LP_FEE_ROUTER_IMPL = 0x97E94b79b4E9d8338CD1aCaF152B8a690Be2C54C;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x7F485770f390f8E98584B820d3e2C8d2091F9eE5;
    address internal constant TAXABLE_TOKEN_IMPL = 0x88138021037Fb70921FcBC4183d151381BC434Cb;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0xA096628577928A8983eC3322904aC2aD5ba69a60;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0x2C10542B7d974b72128e5dca0Ac86d63d0322479;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x8b153fD7Ec69CCc48E7078BbC89abe2aF5497891;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0x3cb88096DE522cb022d213e83669E6c362fa06e4;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x78Af7E41ab894fc2aCd1b1c918e3CC6d710054b9;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x9A996216c0Cd3B1cDeDC4D2A38E0ca94eBeC3565;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x863A2754ceb1489876bE421E1322dDF25eA82Df6;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x3bF1f7c0361b8d61537Cbf816f3f02c69FeFe6c3;

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
