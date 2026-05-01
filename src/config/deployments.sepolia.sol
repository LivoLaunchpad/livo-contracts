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
    address internal constant GRADUATOR_UNIV2 = 0x9ac078c4E22917db450624632eA1997aD2ED4C73;
    address internal constant GRADUATOR_UNIV4 = 0x85fE2051413a4b80b904f05841d1142FeF7f789c;
    address internal constant FEE_HANDLER = 0xC8e37Ff6bE0f3Ad39cF7481f8D5Ec89c96Bc48EF;
    address internal constant FEE_SPLITTER_IMPL = 0xDEAA2606f3F6Ff3B4277a30B7dCD382F9BA4bdB7;

    address internal constant SWAP_HOOK = 0x0591a87D3a56797812C4DA164C1B005c545400Cc;
    address internal constant QUOTER = 0x288E9F2251Ea1BA930ef8D5DB654947Ece41F438;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x8DC0820854de7A13055D041edd859A0ce49746c7;
    address internal constant TAXABLE_TOKEN_IMPL = 0x3102B1b7b4F7e0CC32e8e50F303dd0452e1f9323;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0xBaFe48EeF04D06b4217d16Afea8ab13356ADC316;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0x90191ADfC2DfB4E49897C55fD797aa97f5710cD9;

    // --- Factories ---
    address internal constant FACTORY_UNIV2 = 0x933b7b99974bcf598c1E9abe8e513F5E08eEf11E;
    address internal constant FACTORY_UNIV4 = 0x9039E9d741cF71C522ec3407dA34FA8eccE95531;
    address internal constant FACTORY_TAX_TOKEN = 0x09af239e3FfaD62482504868c335d9e0F2eCD3be;

    address internal constant FACTORY_UNIV2_SNIPER_PROTECTED = 0x30Cb195a8b7E69636Dd5b0F99939deB6FFD5F1e1;
    address internal constant FACTORY_UNIV4_SNIPER_PROTECTED = 0xFb81a889D90A8aB35D09fC4467174B0647B65563;
    address internal constant FACTORY_TAX_TOKEN_SNIPER_PROTECTED = 0xB975497b333B64352aAc32c1431C433ea9607719;

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
