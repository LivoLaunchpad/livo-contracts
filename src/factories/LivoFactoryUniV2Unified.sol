// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V2 token family. Dispatches between four token
///         implementations based on whether `TaxConfigInit` and `AntiSniperConfigs` are
///         configured.
///
///         Replaces `LivoFactoryUniV2` and `LivoFactoryUniV2SniperProtected`, and now also
///         covers the new tax variants (`LivoTaxableTokenUniV2`, `LivoTaxableTokenUniV2SniperProtected`).
///
///         Ownership rule: all V2-family tokens are deployed with `tokenOwner = address(0)`.
///         Tax cap: 5% (vs V4's 4%) — the V2 swap-back path needs more headroom to amortise per-sell
///         router gas, so a slightly higher cap keeps the tax slice meaningful.
contract LivoFactoryUniV2Unified is LivoFactoryAbstract {
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
        return 500;
    }

    /// @inheritdoc LivoFactoryAbstract
    /// @dev When a V2 *taxable* token is deployed with exactly one fee receiver whose
    ///      `directFeesEnabled` is true, point `token.feeHandler` straight at the receiver. The
    ///      swapback path's `_accrueFees` then becomes a plain ETH transfer to that address, so
    ///      Dexscreener-style scanners no longer flag the swap-back transfer as an external call
    ///      into an unknown contract. The master handler is never registered for these tokens
    ///      (`_finalizeCreation` skips `registerFees`); the receiver baked in at init time is
    ///      immutable for the life of the token.
    ///
    ///      Trade-offs:
    ///      - No fallback like the master handler's pending-claims path: a malicious contract
    ///        receiver that reverts on `receive()` can DoS swap-backs.
    ///      - `setShares` is unavailable: routing is locked to a single receiver address.
    function _resolveFeeHandlerForInit(address impl, FeeShare[] calldata feeReceivers)
        internal
        view
        override
        returns (address)
    {
        bool isTaxableImpl = impl == TOKEN_IMPL_TAX || impl == TOKEN_IMPL_TAX_ANTISNIPER;
        if (isTaxableImpl && feeReceivers.length == 1 && feeReceivers[0].directFeesEnabled) {
            return feeReceivers[0].account;
        }
        return address(MASTER_FEE_HANDLER);
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a V2-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time,
    ///         UNLESS the V2 taxable + single-direct-receiver path is taken (see
    ///         `_resolveFeeHandlerForInit`), in which case `token.feeHandler` points at the
    ///         receiver and `DirectSingleFeeReceiver` is emitted instead.
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
        // V2-family tokens are always deployed ownerless.
        address tokenOwner = address(0);

        _validateInputs(name, symbol, feeReceivers, supplyShares);
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);

        token = _dispatchAndInitialize(name, symbol, salt, tokenOwner, feeReceivers, taxCfg, antiSniperCfg);

        // Emit DirectSingleFeeReceiver iff the resolver picked the direct path. Reading the
        // initialized `feeHandler` keeps the hook as the single source of truth (no risk of the
        // event drifting from what was actually baked into the token).
        if (ILivoToken(token).feeHandler() != address(MASTER_FEE_HANDLER)) {
            emit DirectSingleFeeReceiver(token, feeReceivers[0].account);
        }

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
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }
}
