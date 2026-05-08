// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV2.sol";
import {IDeployersWhitelist} from "src/interfaces/IDeployersWhitelist.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V2 token family. Dispatches between four token
///         implementations based on whether `TaxConfigInit` and `AntiSniperConfigs` are
///         configured.
///
///         Replaces `LivoFactoryUniV2` and `LivoFactoryUniV2SniperProtected`, and now also
///         covers the new tax variants (`LivoTaxableTokenUniV2`, `LivoTaxableTokenUniV2SniperProtected`).
///
///         Ownership rule: all V2-family tokens are deployed with `tokenOwner = address(0)`.
contract LivoFactoryUniV2Unified is LivoFactoryAbstract {
    error InvalidTaxBps();
    error InvalidTaxDuration();
    error DeployerNotWhitelisted();

    /// @notice Max configurable tax (buy or sell). 5% on V2 — higher than V4's 4% because the
    ///         V2 swap-back path needs more headroom to amortise gas: the auto-swap is paid by
    ///         the user whose sell crossed the threshold, so a slightly higher cap keeps the tax
    ///         slice meaningful relative to per-swap router overhead.
    uint256 public constant MAX_TAX_BPS = 500;

    /// @notice Max configurable tax duration without deployer whitelist approval
    uint256 public constant MAX_SELL_TAX_DURATION_SECONDS = 14 days;
    /// @notice Max configurable tax duration for whitelisted deployers
    uint256 public constant MAX_EXTENDED_TAX_DURATION_SECONDS = 2 * 365 days;

    /// @notice Token implementation cloned when neither tax nor anti-sniper are configured.
    address public immutable TOKEN_IMPL_BASE;
    /// @notice Token implementation cloned when only anti-sniper protection is configured.
    address public immutable TOKEN_IMPL_ANTISNIPER;
    /// @notice Token implementation cloned when only tax is configured.
    address public immutable TOKEN_IMPL_TAX;
    /// @notice Token implementation cloned when both tax and anti-sniper are configured.
    address public immutable TOKEN_IMPL_TAX_ANTISNIPER;
    /// @notice Whitelist checked when a deployer configures tax duration above 14 days.
    IDeployersWhitelist public immutable DEPLOYERS_WHITELIST;

    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address deployersWhitelist
    ) LivoFactoryAbstract(launchpad, bondingCurve, graduator, masterFeeHandler) {
        TOKEN_IMPL_BASE = tokenImplBase;
        TOKEN_IMPL_ANTISNIPER = tokenImplAntiSniper;
        TOKEN_IMPL_TAX = tokenImplTax;
        TOKEN_IMPL_TAX_ANTISNIPER = tokenImplTaxAntiSniper;
        DEPLOYERS_WHITELIST = IDeployersWhitelist(deployersWhitelist);
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a V2-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        _validateTaxConfig(taxCfg);
        _validateAntiSniperConfig(antiSniperCfg);
        _validateInputs(feeReceivers, supplyShares);

        token = _dispatchAndInitialize(name, symbol, salt, address(0), taxCfg, antiSniperCfg);

        LAUNCHPAD.launchToken(token, BONDING_CURVE);
        _finalizeCreation(token, feeReceivers, supplyShares);
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
        _validateTaxConfig(taxCfg);
        _validateAntiSniperConfig(antiSniperCfg);
        return _resolveImpl(_isTaxConfigured(taxCfg), _isAntiSniperConfigured(antiSniperCfg));
    }

    /////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _validateTaxConfig(TaxConfigInit calldata t) internal view {
        if (_isTaxConfigured(t)) {
            require(t.buyTaxBps > 0 || t.sellTaxBps > 0, InvalidTaxConfig());
            require(t.buyTaxBps <= MAX_TAX_BPS && t.sellTaxBps <= MAX_TAX_BPS, InvalidTaxBps());
            require(t.taxDurationSeconds <= MAX_EXTENDED_TAX_DURATION_SECONDS, InvalidTaxDuration());
            if (t.taxDurationSeconds > MAX_SELL_TAX_DURATION_SECONDS) {
                require(DEPLOYERS_WHITELIST.isWhitelisted(msg.sender), DeployerNotWhitelisted());
            }
        } else {
            require(t.buyTaxBps == 0 && t.sellTaxBps == 0, InvalidTaxConfig());
        }
    }

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
    ///      (`createToken`) is responsible for invoking `LAUNCHPAD.launchToken` and
    ///      `_finalizeCreation` (which registers the token's fee config with the master handler)
    ///      after this returns.
    function _dispatchAndInitialize(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        if (_isTaxConfigured(taxCfg)) {
            token = _initializeTaxToken(name, symbol, salt, tokenOwner, taxCfg, antiSniperCfg);
        } else {
            token = _initializeNonTaxToken(name, symbol, salt, tokenOwner, antiSniperCfg);
        }
    }

    function _initializeTaxToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        address impl = hasAntiSniper ? TOKEN_IMPL_TAX_ANTISNIPER : TOKEN_IMPL_TAX;

        ILivoToken.InitializeParams memory params;
        (token, params) = _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner);

        if (hasAntiSniper) {
            LivoTaxableTokenUniV2SniperProtected(payable(token)).initialize(params, taxCfg, antiSniperCfg);
        } else {
            LivoTaxableTokenUniV2(payable(token)).initialize(params, taxCfg);
        }
    }

    function _initializeNonTaxToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        address impl = hasAntiSniper ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;

        ILivoToken.InitializeParams memory params;
        (token, params) = _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner);

        if (hasAntiSniper) {
            LivoTokenSniperProtected(token).initialize(params, antiSniperCfg);
        } else {
            LivoToken(token).initialize(params);
        }
    }
}
