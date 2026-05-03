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
    address internal constant FEE_HANDLER = 0xc18030d76573784fff4E6365309E1acD967506ff;
    address internal constant FEE_SPLITTER_IMPL = 0x80d97b49169067f339934C39F3ae76C50ED046a6;

    address internal constant SWAP_HOOK = 0x627FA6F76FA96b10BAe1B6Fba280A3c9264500Cc;
    address internal constant QUOTER = 0x035693207fb473358b41A81FF09445dB1f3889D1;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x51fD501d1D866177E209eAa357C515578Df1C766;
    address internal constant TAXABLE_TOKEN_IMPL = 0x4AdcBa218E3F6615C642B4eDe6c22A7229330e33;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0x5AD0311eD744fe0a43C244E44E2075758a924F36;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0xf8c0796B6500309f9b08163e33F16F2448254A29;

    // --- Factories ---
    address internal constant FACTORY_UNIV2 = 0x474D8aF8f3B7003BE53ad1B9266cea074060B7aF;
    address internal constant FACTORY_UNIV4 = 0xD2c2af16c76f2640fDF1208B6fEA107059079ffc;
    address internal constant FACTORY_TAX_TOKEN = 0x57aA990063b49cABf3EE9FeB49dca8DADc9511cD;

    /// @notice Sniper-protected factories
    address internal constant FACTORY_UNIV2_SNIPER_PROTECTED = 0xef4EE2b87A7EAb545395E3dD4bF5931f51d39A34;
    address internal constant FACTORY_UNIV4_SNIPER_PROTECTED = 0x8f8142E3438bF05e50F8322ce159C507Cc21A577;
    address internal constant FACTORY_TAX_TOKEN_SNIPER_PROTECTED = 0x1F630Ae795353Dbee4E8a48ce242Fb18479A9333;

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
