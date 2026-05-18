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
    address internal constant MASTER_FEE_HANDLER = 0x48b3F72469cDba3986A36cE6C47e6Cb027dCCcF2;

    address internal constant SWAP_HOOK = 0x627FA6F76FA96b10BAe1B6Fba280A3c9264500Cc;
    address internal constant SWAP_HOOK_0P5 = 0x068241d20c59980AbEAeDED990d2441F05f5C0Cc;
    address internal constant QUOTER = 0x035693207fb473358b41A81FF09445dB1f3889D1;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x79E3a3473ad2d9285A7C87ACfb4A5C871396240d;
    address internal constant TAXABLE_TOKEN_IMPL = 0xF232d7D7B552B3B981FE91B13F715B3c1F075A13;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0xb9f3c1dB897F24385eEE4feD03C5cd732E9dd087;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0x9b8541B251a3ABCE6BbC5419baa478Bbc6B11E00;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0xfb536Abb27f52DBb62DD91f789C6B9a12C48441b;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0x854459b98Ef631A5D154761da705862c11AA10fc;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x78Af7E41ab894fc2aCd1b1c918e3CC6d710054b9;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x9A996216c0Cd3B1cDeDC4D2A38E0ca94eBeC3565;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xb22b28faf008C07b070311E8B9018a77c62475e1;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x99Fe2360f8121b3CE92a67612AE13Af18B738533;

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
