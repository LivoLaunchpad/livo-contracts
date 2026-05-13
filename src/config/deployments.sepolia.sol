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
    address internal constant MASTER_FEE_HANDLER = 0xcA5A02C3ADcEb4f37c2Bf6c6261EaD11166fb26f;

    address internal constant SWAP_HOOK = 0x0591a87D3a56797812C4DA164C1B005c545400Cc;
    address internal constant QUOTER = 0x288E9F2251Ea1BA930ef8D5DB654947Ece41F438;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x2C0a167A0f83E7969cA22B386Fe72BA608af9B4a;
    address internal constant TAXABLE_TOKEN_IMPL = 0xCcc99765d31A6023E279b98f19e3dFB8430D401f;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0x237EB36efFBc522a19FD8A5581e74661C484Dfe0;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0xfe587A3397e43a92C5bacEBE4bED4bF1e9f8344F;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x3D98c7902d664458015666a92826cb638a015527;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0xd853e420ab0beF122633374ECb6846ABAeCBD143;

    // --- Factories (unified) ---
    address internal constant FACTORY_UNIV2_UNIFIED = 0x4D8d61Ab475B62fA94209339e5033dCb652b6563;
    address internal constant FACTORY_UNIV4_UNIFIED = 0xc79A0c341B50e6Ca62c2C534d94F1A9d8293A4E5;

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
