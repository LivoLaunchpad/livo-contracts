// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {SniperProtection} from "src/tokens/SniperProtection.sol";

/// @title LivoTokenSniperProtected
/// @notice Opt-in variant of LivoToken that enforces max-buy-per-tx and max-wallet caps during a
///         fixed window after creation, only on bonding-curve buys (pre-graduation).
contract LivoTokenSniperProtected is LivoToken, SniperProtection {
    function initialize(ILivoToken.InitializeParams memory params) external override initializer {
        _initializeLivoToken(params);
        _setLaunchTimestamp();
    }

    function _update(address from, address to, uint256 amount) internal override {
        _checkSniperProtection(from, to, amount, address(launchpad), graduated, balanceOf(to));
        super._update(from, to, amount);
    }
}
