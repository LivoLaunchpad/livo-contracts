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
    address internal constant MASTER_FEE_HANDLER = 0x53110c743BD7Df466F071A77B5b2cfe767F7c5B9;
    address internal constant DEPLOYERS_WHITELIST = 0xa22A3246e86B7dc841D09A0475E78Cc48A22e74c;

    address internal constant SWAP_HOOK = 0x0591a87D3a56797812C4DA164C1B005c545400Cc;
    address internal constant QUOTER = 0x288E9F2251Ea1BA930ef8D5DB654947Ece41F438;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x658b6973Ef7a35D55C3aa27d39bFcF0347f0296B;
    address internal constant TAXABLE_TOKEN_IMPL = 0xd4b5963497426799433d6fa12Eb593A85Eab6B80;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0x0c8d9185d1b3DF1Ef91225AF9Af8aca33eeD70B2;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0xBdB87abC0cf6dD723030B2f548152BA9d6af8cD8;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x80897a1CbB8F77AFf71602D8068696415A7dDf65;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0xdE465597425dd643b497F7C7dEcC3Dfec0bd9C24;

    // --- Factories (unified) ---
    address internal constant FACTORY_UNIV2_UNIFIED = 0xef8a59E8462c93EFf1d08d2A866eD56ea70A344c;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x635Bd5f3e4f464036d9eE697737FB89996f75249;

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
