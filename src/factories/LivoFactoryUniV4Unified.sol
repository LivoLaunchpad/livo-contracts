// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V4 token family. Dispatches between four token
///         implementations based on whether `TaxConfigInit` and `AntiSniperConfigs` are
///         configured.
///
///         Replaces `LivoFactoryUniV4`, `LivoFactoryTaxToken`, `LivoFactoryUniV4SniperProtected`,
///         and `LivoFactoryTaxTokenSniperProtected`.
contract LivoFactoryUniV4Unified is LivoFactoryAbstract {
    error InvalidTaxBps();
    error InvalidTaxDuration();

    /// @notice max configurable tax (buy or sell)
    uint256 public constant MAX_TAX_BPS = 400;

    /// @notice max configurable sell tax duration
    uint256 public constant MAX_SELL_TAX_DURATION_SECONDS = 14 days;

    /// @notice Token implementation cloned when neither tax nor anti-sniper are configured.
    address public immutable TOKEN_IMPL_BASE;
    /// @notice Token implementation cloned when only anti-sniper protection is configured.
    address public immutable TOKEN_IMPL_ANTISNIPER;
    /// @notice Token implementation cloned when only tax is configured.
    address public immutable TOKEN_IMPL_TAX;
    /// @notice Token implementation cloned when both tax and anti-sniper are configured.
    address public immutable TOKEN_IMPL_TAX_ANTISNIPER;

    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address feeHandler,
        address feeSplitterImplementation
    ) LivoFactoryAbstract(launchpad, bondingCurve, graduator, feeHandler, feeSplitterImplementation) {
        TOKEN_IMPL_BASE = tokenImplBase;
        TOKEN_IMPL_ANTISNIPER = tokenImplAntiSniper;
        TOKEN_IMPL_TAX = tokenImplTax;
        TOKEN_IMPL_TAX_ANTISNIPER = tokenImplTaxAntiSniper;
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a V4-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         If `feeReceivers.length >= 2`, also deploys a `FeeSplitter` as the fee receiver.
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
    ) external payable returns (address token, address feeSplitter) {
        // Tax block — only validated if tax is configured. Anti-sniper validation lives inside
        // `SniperProtection._initializeSniperProtection`, called from the token's initializer.
        if (_isTaxConfigured(taxCfg)) {
            require(taxCfg.buyTaxBps <= MAX_TAX_BPS && taxCfg.sellTaxBps <= MAX_TAX_BPS, InvalidTaxBps());
            require(taxCfg.taxDurationSeconds <= MAX_SELL_TAX_DURATION_SECONDS, InvalidTaxDuration());
        }

        // common validations from abstract factory
        FeeRouting memory routing = _validateInputsAndResolveFees(feeReceivers, supplyShares, salt);

        // Deploy the token and initialize the token proxy contract with specific configs (no
        // `LAUNCHPAD.launchToken` yet). `tokenOwner` is computed inline (rather than a local) to
        // keep the stack frame within the EVM limit without needing `via_ir`.
        token = _dispatchAndInitialize(
            name, symbol, salt, renounceOwnership_ ? address(0) : msg.sender, routing, taxCfg, antiSniperCfg
        );

        // Register the direct fee receiver against the singleton handler before fees can flow.
        // No-op for the splitter path (splitter manages its own direct set) or when no entry has
        // `directFeesEnabled = true`. Done here rather than inside `_dispatchAndInitialize` to keep
        // that helper's stack frame small enough to compile without `via_ir`.
        _registerDirectReceivers(token, routing, feeReceivers);

        LAUNCHPAD.launchToken(token, BONDING_CURVE);

        // Wrapping up: Handle fee splitter deployment, creator buy, etc.
        _finalizeCreation(token, routing, feeReceivers, supplyShares);
        feeSplitter = routing.feeSplitter;
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the full `createToken` input set minus the identity fields (`name`, `symbol`,
    ///      `salt`) so the ABI stays stable when future features change which inputs participate in
    ///      dispatch. Today only `taxCfg.taxDurationSeconds` and `antiSniperCfg.protectionWindowSeconds`
    ///      matter; the other params are ignored. Used by frontends to compute the initcode hash
    ///      before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        bool, /* renounceOwnership_ */
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        return _resolveImpl(_isTaxConfigured(taxCfg), _isAntiSniperConfigured(antiSniperCfg));
    }

    /////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _isTaxConfigured(TaxConfigInit calldata t) internal pure returns (bool) {
        return t.taxDurationSeconds != 0;
    }

    function _isAntiSniperConfigured(AntiSniperConfigs calldata a) internal pure returns (bool) {
        return a.protectionWindowSeconds != 0;
    }

    function _resolveImpl(bool hasTax, bool hasAntiSniper) internal view returns (address) {
        if (hasTax) {
            return hasAntiSniper ? TOKEN_IMPL_TAX_ANTISNIPER : TOKEN_IMPL_TAX;
        }
        return hasAntiSniper ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;
    }

    /// @dev Routes to the tax or non-tax sub-helper based on `taxCfg`. Splitting by family keeps each
    ///      sub-helper's stack frame small enough to compile without `via_ir`. The caller
    ///      (`createToken`) is responsible for invoking `_registerDirectReceivers` and
    ///      `LAUNCHPAD.launchToken` after this returns.
    function _dispatchAndInitialize(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        FeeRouting memory routing,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        if (_isTaxConfigured(taxCfg)) {
            token = _initializeTaxToken(name, symbol, salt, tokenOwner, routing, taxCfg, antiSniperCfg);
        } else {
            token = _initializeNonTaxToken(name, symbol, salt, tokenOwner, routing, antiSniperCfg);
        }
    }

    function _initializeTaxToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        FeeRouting memory routing,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        address impl = hasAntiSniper ? TOKEN_IMPL_TAX_ANTISNIPER : TOKEN_IMPL_TAX;

        ILivoToken.InitializeParams memory params;
        (token, params) =
            _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner, routing.feeHandler, routing.feeReceiver);

        if (hasAntiSniper) {
            LivoTaxableTokenUniV4SniperProtected(payable(token)).initialize(params, taxCfg, antiSniperCfg);
        } else {
            LivoTaxableTokenUniV4(payable(token)).initialize(params, taxCfg);
        }
    }

    function _initializeNonTaxToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        FeeRouting memory routing,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        address impl = hasAntiSniper ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;

        ILivoToken.InitializeParams memory params;
        (token, params) =
            _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner, routing.feeHandler, routing.feeReceiver);

        if (hasAntiSniper) {
            LivoTokenSniperProtected(token).initialize(params, antiSniperCfg);
        } else {
            LivoToken(token).initialize(params);
        }
    }
}
