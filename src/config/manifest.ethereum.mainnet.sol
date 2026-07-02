// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Ethereum Mainnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 1.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives there since it is
///      consumed by core contracts at deploy time. Update this file on every redeploy
///      and run `just export-deployments` to refresh `deployments.ethereum.mainnet.md`.
library DeploymentsEthereumMainnet {
    uint256 internal constant BLOCKCHAIN_ID = 1;

    // --- Core ---
    address internal constant LAUNCHPAD = 0xaA74Aa89590E3B50BE178eA970E490c173b61110;
    address internal constant BONDING_CURVE = 0xc8aDB35992054948333486621D1891D298f050Ad;
    address internal constant GRADUATOR_UNIV2 = 0x042ed119F78b734407C6368A01D799C503df2E63;
    address internal constant GRADUATOR_UNIV4 = 0x86eDfc50E65233ff3e5b26DeeD49578a157565d7;
    /// @notice V4 graduator paired with the 50-bps `SWAP_HOOK_0P5` variant. Update after deploying.
    address internal constant GRADUATOR_UNIV4_0P5 = 0xE5C38dA8e9BB8a1d2069419606e0f04dc8c57E43;
    address internal constant MASTER_FEE_HANDLER = 0x6F0f4F70a403B9191D6adf2C10750Ab8436345cC;

    address internal constant SWAP_HOOK = 0x627FA6F76FA96b10BAe1B6Fba280A3c9264500Cc;
    address internal constant SWAP_HOOK_0P5 = 0x068241d20c59980AbEAeDED990d2441F05f5C0Cc;
    address internal constant QUOTER = 0xBd208C238Dd7895a7b94833063C2397F10E056f1;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x1002488Af3EE59871339FCe0D171e1d32F62Aa77;
    address internal constant TAXABLE_TOKEN_IMPL = 0xeD45762D25ce4CAE647bf27c8c9c6C7645498c09;

    /// @notice Sniper-protected token implementations
    address internal constant TOKEN_SNIPER_PROTECTED_IMPL = 0x35eBA2610F707B48E0e4ae66E2a0a1535d7B11Fb;
    address internal constant TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL = 0xFfb90D2d55515314210Fb0cB4BE82A6645572103;

    /// @notice V2 taxable token implementations (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x8DBdc48B8d9066983ad84be79B0382edCe390a04;
    address internal constant TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL = 0xcF816bA12a24cD9CC3297A6Ff7528cb66ea7e388;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x78Af7E41ab894fc2aCd1b1c918e3CC6d710054b9;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x9A996216c0Cd3B1cDeDC4D2A38E0ca94eBeC3565;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xBb3303bF4dA06629B9D03A35998C330edB7c1905;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x5eC54C3E5f6167a355Bf03DDf6B983738A6789F6;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xcad4C889e0897BF3fdeE367F402F728342651603;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xA06f07bf255cB63c694339F172f9459f3BF015E7;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x4b387716EbA7498Eb757467A876FAA98733A329e;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0xf5Ac0aDd4135851fb01c8529C9D99d450692aF52;
    address internal constant VAULT_CURVE_10 = 0x5d228507e31C56250fF17BbcD41eF697883F4871;
    address internal constant VAULT_CURVE_15 = 0x10f33C53FAa0C84f4F6B8fBe909cdD647d20c611;
    address internal constant VAULT_CURVE_20 = 0x00d2a5C35BC21CdB1c9E7650505f8a26E86dB592;
    address internal constant VAULT_CURVE_25 = 0xcc78F1D12AdA3F83f5A90840b937D6ed30acE6D2;
    address internal constant VAULT_CURVE_30 = 0x79f75FB3C316f873cFEC5D35a6Be7d6825A140D5;

    /// @notice The six vault curves as the `address[6]` the unified-factory constructors expect.
    function vaultBondingCurves() internal pure returns (address[6] memory c) {
        c[0] = VAULT_CURVE_5;
        c[1] = VAULT_CURVE_10;
        c[2] = VAULT_CURVE_15;
        c[3] = VAULT_CURVE_20;
        c[4] = VAULT_CURVE_25;
        c[5] = VAULT_CURVE_30;
    }

    // --- Liquidity tiers (THIN + THICK) ---
    /// @notice THIN/THICK V4 graduators, one per (tier x hook fee). The DEFAULT tier reuses
    ///         `GRADUATOR_UNIV4` / `GRADUATOR_UNIV4_0P5`. Update after deploying with
    ///         `DeployTierLiquiditySystem`.
    address internal constant GRADUATOR_UNIV4_THIN = 0x128Cb25d514511c0613d1b016ce7D8966553f551;
    address internal constant GRADUATOR_UNIV4_THIN_0P5 = 0xB140a4D912EeF48cB66092932B613807C444b1cA;
    address internal constant GRADUATOR_UNIV4_THICK = 0x75B8CA7298F4eece0E474B6c4D0827B83C3607Ac;
    address internal constant GRADUATOR_UNIV4_THICK_0P5 = 0x4e43217948094AdB6Db8D4B6788bafc2d4F5818c;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployTierLiquiditySystem`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0x1baDd69dCa006B79A95713B4e912e34cf98fe76B;
    address internal constant THIN_VAULT_CURVE_5 = 0x36Ae651E216d92b99A03ff6525951df3EC2B5DEa;
    address internal constant THIN_VAULT_CURVE_10 = 0xa3408533082e529D0Dbf740A2999E3c5f5d8dfc7;
    address internal constant THIN_VAULT_CURVE_15 = 0xd04eCB501E9a872B1C38DF94481153E23fB98690;
    address internal constant THIN_VAULT_CURVE_20 = 0x71a782D35E2dd30e4b51a52c6A8Fca98Cd98e466;
    address internal constant THIN_VAULT_CURVE_25 = 0x2429bbABb9be4E8cCE9949D7f907726b5a5472A4;
    address internal constant THIN_VAULT_CURVE_30 = 0x19655401bfa0B51b98b8E389FFf5001B0A46D3f3;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x2d6a34b7feed5dF25a73C0F0a410103aa219abb4;
    address internal constant THICK_VAULT_CURVE_5 = 0x89f1d0568Ced031D4b8f456e08ba6E9157Ab1CA0;
    address internal constant THICK_VAULT_CURVE_10 = 0x1EfEcAB686643AF69F53d1cfB7119bb93b328EE6;
    address internal constant THICK_VAULT_CURVE_15 = 0x3cba1283Bf5E74C1D8E62F12ab3b6c5df3d59036;
    address internal constant THICK_VAULT_CURVE_20 = 0xc8CFEFe3038c72E47323D126960ADc42Cf3AB866;
    address internal constant THICK_VAULT_CURVE_25 = 0xDaA320b3347149E6297918587d6E8E3814d5b4C7;
    address internal constant THICK_VAULT_CURVE_30 = 0x5779E3b9A77891BdE32B735b850a748bd33AE72c;

    /// @notice The six THIN-tier vault curves as the `address[6]` the factory tier config expects.
    function thinVaultCurves() internal pure returns (address[6] memory c) {
        c[0] = THIN_VAULT_CURVE_5;
        c[1] = THIN_VAULT_CURVE_10;
        c[2] = THIN_VAULT_CURVE_15;
        c[3] = THIN_VAULT_CURVE_20;
        c[4] = THIN_VAULT_CURVE_25;
        c[5] = THIN_VAULT_CURVE_30;
    }

    /// @notice The six THICK-tier vault curves as the `address[6]` the factory tier config expects.
    function thickVaultCurves() internal pure returns (address[6] memory c) {
        c[0] = THICK_VAULT_CURVE_5;
        c[1] = THICK_VAULT_CURVE_10;
        c[2] = THICK_VAULT_CURVE_15;
        c[3] = THICK_VAULT_CURVE_20;
        c[4] = THICK_VAULT_CURVE_25;
        c[5] = THICK_VAULT_CURVE_30;
    }

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
