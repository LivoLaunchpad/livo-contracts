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
    /// @dev `lpFeeBps` is reserved for future use — today the LP fee is a constant in
    ///      `LivoSwapHook` (100 bps). The field is accepted for ABI forward-compatibility but is
    ///      not wired through; `_validateUniv4Configs` enforces `lpFeeBps == 100` so misuse is loud
    ///      until the field is honoured by the hook.
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
        address masterFeeHandler
    )
        LivoFactoryAbstract(
            launchpad,
            tokenImplBase,
            tokenImplAntiSniper,
            tokenImplTax,
            tokenImplTaxAntiSniper,
            bondingCurve,
            graduator,
            masterFeeHandler
        )
    {}

    /// @inheritdoc LivoFactoryAbstract
    function MAX_TAX_BPS() public pure override returns (uint256) {
        return 400;
    }

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
        // Routes through the shared `_createToken` umbrella so this overload and the struct-based
        // overload below share the same internal flow. `lpFeeBps = 100` matches the value hardcoded
        // in `LivoSwapHook` today; the struct overload reads it from `UniV4Configs` instead.
        // See the "V4-only event-emission rule" comment above for why the emit lives here.
        TokenSetup memory tokenSetup = TokenSetup({name: name, symbol: symbol, salt: salt, feeShares: feeReceivers});
        address tokenOwner = renounceOwnership_ ? address(0) : msg.sender;
        token = _createToken(tokenSetup, tokenOwner, supplyShares, taxCfg, antiSniperCfg);
        emit LpFeeBpsSet(token, 100);
    }

    /// @notice Struct-based overload. Equivalent to the positional `createToken` above; exists to
    ///         keep the ABI extensible without hitting stack-too-deep when new features add inputs.
    ///         `univ4Configs.lpFeeBps` is reserved for future use (see `UniV4Configs`).
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs
    ) external payable returns (address token) {
        _validateUniv4Configs(univ4Configs);
        address tokenOwner = univ4Configs.renounceOwnership ? address(0) : msg.sender;
        token = _createToken(tokenSetup, tokenOwner, buyOnDeployShares, taxConfigs, antiSniperConfigs);
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev V4-specific config validation. Today only pins `lpFeeBps == 100` because the LP fee is
    ///      still hardcoded in `LivoSwapHook`; reject anything else so misconfiguration is loud
    ///      instead of silently ignored. Add further V4-only invariants here as the struct grows.
    function _validateUniv4Configs(UniV4Configs calldata configs) internal pure {
        require(configs.lpFeeBps == 100, InvalidLpFeeBps());
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
