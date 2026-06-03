// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Sepolia
/// @notice Single source of truth for Livo's own deployed contracts on chain id 11155111.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury (sepolia: dev EOA) also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.sepolia.md`.
library DeploymentsSepolia {
    uint256 internal constant BLOCKCHAIN_ID = 11155111;

    // --- Core ---
    address internal constant LAUNCHPAD = 0xd9f8bbe437a3423b725c6616C1B543775ecf1110;
    address internal constant BONDING_CURVE = 0x1A7f2E2e4bdB14Dd75b6ce60ce7a6Ff7E0a3F3A5;
    address internal constant GRADUATOR_UNIV2 = 0x973B8F3b1e52244E79ecb86591C8FdA6E2D0e691;
    address internal constant GRADUATOR_UNIV4 = 0x85fE2051413a4b80b904f05841d1142FeF7f789c;
    /// @notice V4 graduator paired with the 50-bps `SWAP_HOOK_0P5` variant. Update after deploying.
    address internal constant GRADUATOR_UNIV4_0P5 = 0x3d6398E54549c5a8b88071C180509B41043Df7Da;
    address internal constant MASTER_FEE_HANDLER = 0xcA5A02C3ADcEb4f37c2Bf6c6261EaD11166fb26f;

    address internal constant SWAP_HOOK = 0x0591a87D3a56797812C4DA164C1B005c545400Cc;
    address internal constant SWAP_HOOK_0P5 = 0xC04Bb5bA43795330e54efaC7244ce40318FD80cc;
    address internal constant QUOTER = 0x288E9F2251Ea1BA930ef8D5DB654947Ece41F438;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x9e11191aC22b1C25A64e8de86dd9Db098a343e01;
    address internal constant TAXABLE_TOKEN_IMPL = 0xd9F88d337CF88126850d150651CFbCE5E5299f08;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0x4Cf6178e0953b7B9E986265A8e1848551E4a7D5F;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0xE1B8aA73d0E964B9f7Fe49A7396795D5aa288ba0;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x462a3091a108D088DFdD029ba1BDFf593A55806E;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0xFE05dA9BBd5e798B18c3a1D1ae824a4a46cC1674;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x87Dd69F8d294fA9cd704fccd38d36d6197F80868;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x2a992f6f5F7c049A165a13069BE3DbDEaa5C391b;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x11dD23Bd02eFAEC83CD4AdB2B23616A79196c107;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0xBae6fA24aF026D1309632A76308894c62B6E029E;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xe5aF8d840963060302cf5021630d6dBF41a9e07b;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x804ad45394FCF755350d924f712EC463E5E3147D;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0xcbeBF86091de0E2c5d18D6c4E3d44e44855C2C47;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0xDAB2D2a31E5d659f99E3AC786884793223bafBB4;
    address internal constant VAULT_CURVE_10 = 0xAB6161195d96A824c9cef14B1cd43455ec3cE9DA;
    address internal constant VAULT_CURVE_15 = 0x5aB30fB5453845B10239A569Cdb8199B3214339e;
    address internal constant VAULT_CURVE_20 = 0x35DC2fbD3ad6917C51658d1891859A6e9DaAc16e;
    address internal constant VAULT_CURVE_25 = 0x321A86a8b27Ff81dcdb3C5d51FF0a2936f5c2c68;
    address internal constant VAULT_CURVE_30 = 0x590e303AaaAdE7634Ec4d9d16bD135b4790FA42b;

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
