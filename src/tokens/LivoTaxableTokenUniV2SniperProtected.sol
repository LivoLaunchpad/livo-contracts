// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTaxableTokenSniperProtected, TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @title LivoTaxableTokenUniV2SniperProtected
/// @notice Opt-in variant of `LivoTaxableTokenUniV2` that also enforces the standard anti-sniper
///         per-tx and per-wallet caps during a configurable window after creation, on
///         bonding-curve buys (pre-graduation).
/// @dev `_update` runs the sniper-cap check first, then delegates to
///      `LivoTaxableTokenUniV2._update` (tax + auto-swap). The two checks don't overlap in time:
///      sniper-protection is pre-graduation only, taxes are post-graduation only. So the tax
///      tokens that accumulate on `address(this)` post-graduation are never subject to the
///      `maxWalletBps` cap — no explicit exemption for the token contract's own balance needed.
contract LivoTaxableTokenUniV2SniperProtected is
    LivoTaxableTokenUniV2,
    SniperProtection,
    ILivoTaxableTokenSniperProtected
{
    function initialize(
        ILivoToken.InitializeParams memory params,
        TaxConfigInit memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeLivoTaxableToken(params, taxCfg);
        _initializeSniperProtection(antiSniperCfg);
    }

    function _update(address from, address to, uint256 amount) internal override {
        _checkSniperProtection(
            from, to, amount, address(launchpad), tokenFactory, address(graduator), graduated, balanceOf(to)
        );
        super._update(from, to, amount);
    }

    function maxTokenPurchase(address buyer) external view override(LivoToken, ILivoToken) returns (uint256) {
        return _maxTokenPurchase(buyer, balanceOf(buyer), graduated);
    }
}
