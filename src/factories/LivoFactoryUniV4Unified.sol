// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V4 token family. Dispatches between four token
///         implementations based on whether `TaxConfigInit` and `AntiSniperConfigs` are
///         configured.
///
///         Replaces `LivoFactoryUniV4`, `LivoFactoryTaxToken`, `LivoFactoryUniV4SniperProtected`,
///         and `LivoFactoryTaxTokenSniperProtected`.
contract LivoFactoryUniV4Unified is LivoFactoryAbstract {
    /// @notice V4-specific config bundle for the struct-based `createToken` overload.
    /// @dev `lpFeeBps` is the per-swap LP fee `LivoSwapHook` charges. It is stored on the token (via
    ///      `InitializeParams.lpFeeBps`) and read back by the hook through `getCurrentFees`. Only
    ///      `100` (1%) and `50` (0.5%) are accepted; `_validateUniv4Configs` enforces the allowlist
    ///      so misconfiguration is loud. A single graduator/hook pair serves both fees.
    struct UniV4Configs {
        bool renounceOwnership;
        uint16 lpFeeBps;
    }

    error InvalidLpFeeBps();

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

    // V4-only event-emission rule: any event whose presence is meant to signal "this is a V4 token"
    // (today: `LpFeeBpsSet`) MUST be emitted here in the V4 factory overloads, never inside the
    // shared `_createToken` umbrella in `LivoFactoryAbstract`. The umbrella runs for V2 deploys
    // too, so emitting V4-only events from there would leak them onto V2 tokens and break indexers
    // that use the event as a V4 marker. When adding a new V4-only event, follow this same pattern
    // (emit after `_createToken(...)` returns, in both overloads below).

    /// @notice Deploys a V4-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    /// @dev DEPRECATED: legacy positional overload, kept for backwards compatibility. New
    ///      integrations should use the struct-based overload that takes `creatorVaults`.
    ///      Always deploys with the 100-bps LP fee and no creator vaults.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        bool renounceOwnership_,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        // Positional overload always uses the 100-bps LP fee — only the struct-based overload below
        // exposes the 50-bps variant. See the "V4-only event-emission rule" comment above for why
        // the emit lives here.
        _validateTotalFee(100, taxCfg);
        TokenSetup memory tokenSetup = TokenSetup({name: name, symbol: symbol, salt: salt, feeShares: feeReceivers});
        address tokenOwner = renounceOwnership_ ? address(0) : msg.sender;
        token = _createToken(tokenSetup, tokenOwner, 100, supplyShares, taxCfg, antiSniperCfg, new CreatorVault[](0));
        emit LpFeeBpsSet(token, 100);
    }

    /// @notice Struct-based overload without creator vaults. `univ4Configs.lpFeeBps` sets the
    ///         per-swap LP fee stored on the token (100 or 50).
    /// @dev DEPRECATED: kept for backwards compatibility. New integrations should use the
    ///      struct-based overload that takes `creatorVaults`. Always deploys with no creator vaults.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs
    ) external payable returns (address token) {
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, taxConfigs);
        address tokenOwner = univ4Configs.renounceOwnership ? address(0) : msg.sender;
        token = _createToken(
            tokenSetup,
            tokenOwner,
            univ4Configs.lpFeeBps,
            buyOnDeployShares,
            taxConfigs,
            antiSniperConfigs,
            new CreatorVault[](0)
        );
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    /// @notice Struct-based overload. Equivalent to the deprecated struct-based overload above, plus
    ///         the `creatorVaults` array (pass empty for none). `univ4Configs.lpFeeBps` sets the
    ///         per-swap LP fee stored on the token (100 or 50). This is the current recommended overload.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, taxConfigs);
        address tokenOwner = univ4Configs.renounceOwnership ? address(0) : msg.sender;
        token = _createToken(
            tokenSetup,
            tokenOwner,
            univ4Configs.lpFeeBps,
            buyOnDeployShares,
            taxConfigs,
            antiSniperConfigs,
            creatorVaults
        );
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev V4-specific config validation. `lpFeeBps` is the per-swap LP fee stored on the token —
    ///      only the two supported tiers (100 = 1%, 50 = 0.5%) are accepted, so a typo reverts
    ///      instead of silently storing an unsupported fee. Add further V4-only invariants here as
    ///      the struct grows.
    function _validateUniv4Configs(UniV4Configs calldata configs) internal pure {
        require(configs.lpFeeBps == 100 || configs.lpFeeBps == 50, InvalidLpFeeBps());
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the dispatch-relevant `createToken` inputs minus the identity fields (`name`,
    ///      `symbol`, `salt`) and ownership flag so the ABI stays stable when future features change
    ///      which inputs participate in dispatch. Today only `taxCfg.taxDurationSeconds` and
    ///      `antiSniperCfg.protectionWindowSeconds` matter for dispatch; disabled configs must
    ///      have all other tax/anti-sniper fields
    ///      empty/zero. Used by frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }
}
