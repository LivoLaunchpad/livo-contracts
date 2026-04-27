// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @title LivoTokenSniperProtected
/// @notice Opt-in variant of LivoToken that enforces configurable max-buy-per-tx and max-wallet
///         caps during a configurable window after creation, only on bonding-curve buys
///         (pre-graduation).
contract LivoTokenSniperProtected is LivoToken, SniperProtection {
    function initialize(ILivoToken.InitializeParams memory params, AntiSniperConfigs memory antiSniperCfg)
        external
        virtual
        initializer
    {
        _initializeLivoToken(params);
        _initializeSniperProtection(antiSniperCfg);
    }

    function _update(address from, address to, uint256 amount) internal override {
        _checkSniperProtection(
            from, to, amount, address(launchpad), factory, address(graduator), graduated, balanceOf(to)
        );
        super._update(from, to, amount);
    }

    function maxTokenPurchaseNow(address buyer) external view override(LivoToken) returns (uint256) {
        return _maxTokenPurchaseNow(buyer, balanceOf(buyer), graduated);
    }
}
