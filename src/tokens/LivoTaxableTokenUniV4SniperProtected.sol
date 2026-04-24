// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @title LivoTaxableTokenUniV4SniperProtected
/// @notice Opt-in variant of LivoTaxableTokenUniV4 that enforces configurable max-buy-per-tx and
///         max-wallet caps during a configurable window after creation, only on bonding-curve buys
///         (pre-graduation).
contract LivoTaxableTokenUniV4SniperProtected is LivoTaxableTokenUniV4, SniperProtection {
    function initialize(
        ILivoToken.InitializeParams memory params,
        uint16 buyTaxBps_,
        uint16 sellTaxBps_,
        uint40 taxDurationSeconds_,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeLivoTaxableTokenUniV4(params, buyTaxBps_, sellTaxBps_, taxDurationSeconds_);
        _initializeSniperProtection(antiSniperCfg);
    }

    function _update(address from, address to, uint256 amount) internal override {
        _checkSniperProtection(from, to, amount, address(launchpad), factory, graduated, balanceOf(to));
        super._update(from, to, amount);
    }
}
