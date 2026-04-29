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
    address internal constant FEE_HANDLER = 0xc18030d76573784fff4E6365309E1acD967506ff;
    address internal constant SWAP_HOOK = 0x627FA6F76FA96b10BAe1B6Fba280A3c9264500Cc;
    address internal constant GRADUATOR_UNIV2 = 0x46aF9F05825459d149ed036Bb6461E1FE8fA25D8;
    address internal constant GRADUATOR_UNIV4 = 0xCF6910d89d052F025ed402638e4Ae78ecDCdDfA5;
    address internal constant FEE_SPLITTER_IMPL = 0x80d97b49169067f339934C39F3ae76C50ED046a6;

    /// @notice Quoter not yet deployed on mainnet — fill in after the next redeploy.
    address internal constant QUOTER = address(0);

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x758Af7bCde2875a6Aa06337125EA81335a860AC5;
    address internal constant TAXABLE_TOKEN_IMPL = 0x588951ecc682cBbe3BC4fa60F807e2Fa165255B2;

    /// @notice Sniper-protected token implementations not yet deployed on mainnet.
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = address(0);
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = address(0);

    // --- Factories ---
    address internal constant FACTORY_UNIV2 = 0x749cf5c70baAA1BCC2ACCF467F98A08a93eFb498;
    address internal constant FACTORY_UNIV4 = 0xfd68Ca33f04f6604Dad8F99F8fB31A354434a2e5;
    address internal constant FACTORY_TAX_TOKEN = 0xa13cd72870f73c76f0E2a9f97600663fA3913Cb6;

    /// @notice Sniper-protected factories not yet deployed on mainnet.
    address internal constant FACTORY_UNIV2_SNIPER_PROTECTED = address(0);
    address internal constant FACTORY_UNIV4_SNIPER_PROTECTED = address(0);
    address internal constant FACTORY_TAX_TOKEN_SNIPER_PROTECTED = address(0);

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
