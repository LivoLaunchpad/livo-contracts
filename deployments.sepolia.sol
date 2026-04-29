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
    address internal constant FEE_HANDLER = 0xC8e37Ff6bE0f3Ad39cF7481f8D5Ec89c96Bc48EF;
    address internal constant SWAP_HOOK = 0x0591a87D3a56797812C4DA164C1B005c545400Cc;
    address internal constant GRADUATOR_UNIV2 = 0x9ac078c4E22917db450624632eA1997aD2ED4C73;
    address internal constant GRADUATOR_UNIV4 = 0xc304593F9297f4f67E07cc7cAf3128F9027A2A3d;
    address internal constant FEE_SPLITTER_IMPL = 0xDEAA2606f3F6Ff3B4277a30B7dCD382F9BA4bdB7;
    address internal constant QUOTER = 0x288E9F2251Ea1BA930ef8D5DB654947Ece41F438;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x06089fc51A93A5045C168E9A317951Cec757e0d7;
    address internal constant TAXABLE_TOKEN_IMPL = 0x05fB9128dC50D3a3dB1F0d040bbe54b1e63B7e4f;

    /// @notice Sniper-protected token implementations: deployed on sepolia but
    ///         their addresses are not currently recorded — fill in after the
    ///         next redeploy.
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = address(0);
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = address(0);

    // --- Factories ---
    address internal constant FACTORY_UNIV2 = 0xe8E755b829d7B742b400fEe4DB733d1dfEf65747;
    address internal constant FACTORY_UNIV4 = 0xc16f3d74533C2bAe4c769c92ff199e9Ba06f564a;
    address internal constant FACTORY_TAX_TOKEN = 0xa35E637097c14ea3Ac2099FC4AF9A141A7d9C23a;
    address internal constant FACTORY_UNIV2_SNIPER_PROTECTED = 0x356265534805cED5295b4f174Eb6e2F99d8941Ae;
    address internal constant FACTORY_UNIV4_SNIPER_PROTECTED = 0x39701732aC4c25771Ec00baEF20f4875c00f1cA9;
    address internal constant FACTORY_TAX_TOKEN_SNIPER_PROTECTED = 0x11f257d99f11679fFbF3A35E7D7917C2a87E41b7;

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
