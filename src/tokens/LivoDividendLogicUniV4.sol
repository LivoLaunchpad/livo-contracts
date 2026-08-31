// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableTokenUniV4Base, ILivoV4Graduator} from "src/tokens/LivoTaxableTokenUniV4Base.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {DividendRoute} from "src/types/DividendRoute.sol";

/// @title LivoDividendLogicUniV4
/// @notice The dividend extension `LivoTaxableTokenUniV4` `delegatecall`s its four out-of-band entry
///         points into: the round machinery, the native -> payout-asset conversion, and the per-holder
///         push. Deployed once, by the token implementation's own constructor.
/// @dev It shares `LivoTaxableTokenUniV4Base` with the token and adds NO state of its own, so the
///      compiler derives the same storage layout for both — the property the delegatecall depends on.
///      Pinned by `just check-dividend-layout`.
contract LivoDividendLogicUniV4 is LivoTaxableTokenUniV4Base, DividendDistributionLogic {
    /// @dev Adds the SELF-TOKEN payout shape: V4 is ETH-native, so a leg paying the token itself buys it
    ///      back on the token's own pool, reusing the same primitive `processBurn` uses. Native and
    ///      third-token legs fall through to the base.
    /// @dev The precursor event must stay BEFORE the swap: an indexer has to classify the resulting
    ///      `LivoSwapHook.LivoSwapBuy` as protocol-internal as it arrives, whereas anything emitted after
    ///      the swap lands once the keeper's PnL has already been updated.
    function _acquireDividendAsset(address asset, uint256 leg, uint256 nativeIn, uint256 minOut)
        internal
        override
        returns (uint256)
    {
        if (asset != address(this)) return super._acquireDividendAsset(asset, leg, nativeIn, minOut);

        address hook = ILivoV4Graduator(graduator).HOOK_ADDRESS();
        uint256 balanceBefore = balanceOf(address(this));
        emit DividendBuyBackInitiated(nativeIn);
        _buyBackTokensWithEth(hook, nativeIn, minOut);
        return balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Creation-time dividend configuration, executed here on the token's storage. Guarded by
    ///         the transient `tokenFactory`, which the `delegatecall` shares with the token.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address[3] calldata _dividendTokens,
        uint16[3] calldata _dividendWeightsBps,
        DividendRoute[3] calldata _dividendRoutes
    ) external override {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
        if (_dividendsBps != 0) {
            _initializeDividends(_dividendTokens, _dividendWeightsBps, _dividendRoutes);
            hasDividends = true;
        }
    }

    ////////////////// NOT A TOKEN //////////////////
    // An extension is only ever reached through a `delegatecall` from a token, so its own copy of the
    // token's behaviour is dead weight — and, at ~7.4 KB, dead weight it cannot afford: the extension is
    // bound by the same EIP-170 limit as the token it serves. Reverting each entry point makes the
    // machinery behind it unreachable and the compiler drops it: the transfer hook with its anti-sniper
    // and dividend tracking, the tax-config views and their decay arithmetic, the earnings split and the
    // fee-handler deposit. Measured on the V2 extension: 19,748 -> 12,322 bytes of inherited surface,
    // which is what buys the cold half its room. The reverts are also the honest answer — none of these
    // has anything to act on here.

    /// @dev Kills the transfer hook, and with it `SniperProtection` and the dividend share tracking —
    ///      the single largest saving. An extension's own balances are never moved.
    function _update(address, address, uint256) internal pure override {
        revert NotAToken();
    }

    /// @dev Only here because `ILivoTaxableToken` declares it. The storage every entry point touches
    ///      belongs to the token that `delegatecall`s in, so there is nothing here to initialize.
    function initialize(ILivoToken.InitializeParams memory, TaxConfigs memory, AntiSniperConfigs memory) external pure {
        revert NotAToken();
    }

    function markGraduated() external pure override {
        revert NotAToken();
    }

    function rescueTokens(address) external pure override {
        revert NotAToken();
    }

    function setTaxBps(uint16, uint16) external pure override {
        revert NotAToken();
    }

    function accrueFees() external payable override {
        revert NotAToken();
    }

    /// @dev The second entry point into the earnings split, stubbed for the same reason `accrueFees` is:
    ///      an extension holds no balance, so it has no stray native — and leaving it live would link
    ///      `_allocateEthEarnings` and everything under it back into this contract's bytecode.
    function sweepStrayEth() external pure override {
        revert NotAToken();
    }

    function getLaunchpadFees(ILivoToken.LaunchpadTrade calldata)
        external
        pure
        override
        returns (ILivoToken.LaunchpadFees memory)
    {
        revert NotAToken();
    }

    function getTaxConfig() external pure override returns (TaxConfig memory) {
        revert NotAToken();
    }

    function getSwapFees(bool) external pure override returns (ILivoToken.LivoTradeFees memory) {
        revert NotAToken();
    }

    function initializeEarningsAllocation(uint16, uint16, uint16) external pure override {
        revert NotAToken();
    }

    /// @dev The cold half is already inline here, so the token stubs this contract inherits would
    ///      `delegatecall` into itself if they were ever reached. They are not: `DividendDistributionLogic`
    ///      carries the real bodies.
    function dividendLogic() public view override returns (address) {
        return address(this);
    }
}
