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
    address internal constant MASTER_FEE_HANDLER = 0x3dD70c06e04A10768aAd7208f119e73E4eD3e306;

    address internal constant SWAP_HOOK = 0x0591a87D3a56797812C4DA164C1B005c545400Cc;
    address internal constant SWAP_HOOK_0P5 = 0xC04Bb5bA43795330e54efaC7244ce40318FD80cc;
    address internal constant QUOTER = 0x288E9F2251Ea1BA930ef8D5DB654947Ece41F438;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x7A2F3A309f070c8F45E541e1069BaEF5dA7A1512;
    address internal constant TAXABLE_TOKEN_IMPL = 0x57Bb01ac46B9a2DfC3C05cE47d692e4b729BDCBe;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0xdF5CD2fc0078147Fce85bc2170250eC6339026a0;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0x8289D631513B3766D79820682b864a47923c60a0;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0xE9081F5db8D4ac5193eD4D987B93A54916175Fa7;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0x7bF9a2098DC5DC0bBD22552372a8DEDE37751903;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x87Dd69F8d294fA9cd704fccd38d36d6197F80868;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x2a992f6f5F7c049A165a13069BE3DbDEaa5C391b;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x63495eE6A0044F263ACA029e1432930c124e91da;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x9bd879588A942308bee973B79311680266B85707;

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
