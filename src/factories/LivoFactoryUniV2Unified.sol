// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V2 token family. Dispatches between four token
///         implementations based on whether `TaxConfigInit` and `AntiSniperConfigs` are
///         configured.
///
///         Replaces `LivoFactoryUniV2` and `LivoFactoryUniV2SniperProtected`, and now also
///         covers the new tax variants (`LivoTaxableTokenUniV2`, `LivoTaxableTokenUniV2SniperProtected`).
///
///         Ownership rule: all V2-family tokens are deployed with `tokenOwner = address(0)`.
///         Tax cap: the full 5% aggregate fee cap (`MAX_TOTAL_FEE_BPS`) — V2 has no LP fee, so the
///         tax can use all of it (vs V4, where the LP fee eats 50–100 bps of the budget).
contract LivoFactoryUniV2Unified is LivoFactoryAbstract {
    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory,
        address[6] memory vaultBondingCurves
    )
        LivoFactoryAbstract(
            launchpad,
            tokenImplBase,
            tokenImplAntiSniper,
            tokenImplTax,
            tokenImplTaxAntiSniper,
            bondingCurve,
            graduator,
            masterFeeHandler,
            creatorVaultFactory,
            vaultBondingCurves
        )
    {}

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a V2-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    /// @dev DEPRECATED: legacy positional overload, kept for backwards compatibility. New
    ///      integrations should use the struct-based overload that takes `creatorVaults`.
    ///      Always deploys with no creator vaults.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        // V2-family tokens are always deployed ownerless. Routes through the shared `_createToken`
        // umbrella so this overload and the struct-based overload below share the same internal flow.
        // `LpFeeBpsSet` is emitted only by the V4 factory — V2 has no LP-fee concept.
        _validateTotalFee(0, taxCfg);
        TokenSetup memory tokenSetup = TokenSetup({name: name, symbol: symbol, salt: salt, feeShares: feeReceivers});
        token = _createToken(
            tokenSetup, address(0), address(GRADUATOR), supplyShares, taxCfg, antiSniperCfg, new CreatorVault[](0)
        );
    }

    /// @notice Struct-based overload without creator vaults. Keeps the ABI extensible without
    ///         hitting stack-too-deep when new features add inputs.
    /// @dev DEPRECATED: kept for backwards compatibility. New integrations should use the
    ///      struct-based overload that takes `creatorVaults`. Always deploys with no creator vaults.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs
    ) external payable returns (address token) {
        // V2-family tokens are always deployed ownerless; V2 never emits `LpFeeBpsSet`.
        _validateTotalFee(0, taxConfigs);
        token = _createToken(
            tokenSetup,
            address(0),
            address(GRADUATOR),
            buyOnDeployShares,
            taxConfigs,
            antiSniperConfigs,
            new CreatorVault[](0)
        );
    }

    /// @notice Struct-based overload. Equivalent to the deprecated struct-based overload above, plus
    ///         the `creatorVaults` array (pass empty for none). This is the current recommended overload.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        // V2-family tokens are always deployed ownerless; V2 never emits `LpFeeBpsSet`.
        _validateTotalFee(0, taxConfigs);
        token = _createToken(
            tokenSetup, address(0), address(GRADUATOR), buyOnDeployShares, taxConfigs, antiSniperConfigs, creatorVaults
        );
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the full `createToken` input set minus the identity fields (`name`, `symbol`,
    ///      `salt`) so the ABI stays stable when future features change which inputs participate in
    ///      dispatch. Today only `taxCfg.taxDurationSeconds` and `antiSniperCfg.protectionWindowSeconds`
    ///      matter for dispatch; disabled configs must have all other tax/anti-sniper fields
    ///      empty/zero. Used by frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        _validateTotalFee(0, taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }
}
