// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @title LivoTaxableTokenUniV4SniperProtected
/// @notice Opt-in variant of LivoTaxableTokenUniV4 that enforces configurable max-buy-per-tx and
///         max-wallet caps during a configurable window after creation, only on bonding-curve buys
///         (pre-graduation).
contract LivoTaxableTokenUniV4SniperProtected is LivoTaxableTokenUniV4, SniperProtection {
    function initialize(
        ILivoToken.InitializeParams memory params,
        TaxConfigInit memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeLivoTaxableTokenUniV4(params, taxCfg);
        _initializeSniperProtection(antiSniperCfg);
    }

    function _update(address from, address to, uint256 amount) internal override {
        _checkSniperProtection(
            from, to, amount, address(launchpad), factory, address(graduator), graduated, balanceOf(to)
        );
        super._update(from, to, amount);
    }

    function maxTokenPurchase(address buyer) external view override(LivoToken, ILivoToken) returns (uint256) {
        return _maxTokenPurchase(buyer, balanceOf(buyer), graduated);
    }
}
