// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

/// @title Launchpad pre-graduation fee routing — LP-fee split + creator tax
/// @notice The launchpad reads `getLaunchpadFees` per trade. The LP fee is split treasury/creator by
///         `treasuryShareBps`; the tax goes 100% to the creator. Events (`LpFeesAccrued`,
///         `CreatorTaxesAccrued`) mirror the post-graduation `LivoSwapHook` for accounting parity.
contract LaunchpadFeeSplitTest is LaunchpadBaseTestsWithUniv2Graduator {
    event LpFeesAccrued(address indexed token, uint256 creatorShare, uint256 treasuryShare);
    event CreatorTaxesAccrued(address indexed token, uint256 amount);

    LivoToken internal feeToken;

    /// @dev Creates a fully-wired, tradeable token with a custom fee config: clone + initialize +
    ///      registerFees(creator) + launchToken (pranked as a whitelisted factory). Bypasses the
    ///      factory's currently-hardcoded default so arbitrary fee/tax configs can be exercised.
    function _wireToken(uint16 lpFee, uint16 treasuryShare, uint16 taxBuy, uint16 taxSell)
        internal
        returns (LivoToken t)
    {
        t = LivoToken(Clones.clone(address(livoToken)));
        t.initialize(
            ILivoToken.InitializeParams({
                name: "SplitToken",
                symbol: "SPLIT",
                tokenOwner: creator,
                graduator: address(graduatorV2),
                launchpad: address(launchpad),
                feeHandler: address(feeHandler),
                vaultAllocation: 0,
                lpFeeBps: lpFee,
                treasuryShareBps: treasuryShare,
                taxBuyBps: taxBuy,
                taxSellBps: taxSell
            })
        );
        // Register the creator as the sole (claimable) fee receiver so creator-share routing works.
        t.registerFees(_fs(creator));

        vm.prank(address(factoryV2Unified));
        launchpad.launchToken(address(t), ILivoBondingCurve(address(bondingCurve)));
    }

    function _buy(LivoToken t, uint256 value) internal returns (uint256) {
        vm.deal(buyer, value);
        vm.prank(buyer);
        return launchpad.buyTokensWithExactEth{value: value}(address(t), 0, DEADLINE);
    }

    function _creatorClaimable(LivoToken t) internal view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        return feeHandler.getClaimable(tokens, creator)[0];
    }

    /// @dev when treasuryShareBps is 100% and there's no tax, then the whole LP fee goes to treasury
    function test_buy_fullTreasuryShare_noTax() public {
        feeToken = _wireToken(100, 10_000, 0, 0);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;

        _buy(feeToken, value);

        assertEq(treasury.balance - t0, lpFee, "treasury gets full LP fee");
        assertEq(_creatorClaimable(feeToken), 0, "creator zero");
    }

    /// @dev when treasuryShareBps is 40% and there's no tax, then the LP fee splits 40/60 and emits LpFeesAccrued
    function test_buy_partialShare_noTax() public {
        feeToken = _wireToken(100, 4_000, 0, 0);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;
        uint256 treasuryShare = lpFee * 4_000 / 10_000;
        uint256 creatorShare = lpFee - treasuryShare;

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit LpFeesAccrued(address(feeToken), creatorShare, treasuryShare);
        _buy(feeToken, value);

        assertEq(treasury.balance - t0, treasuryShare, "treasury share");
        assertEq(_creatorClaimable(feeToken), creatorShare, "creator share");
    }

    /// @dev when a tax is configured, then it goes 100% to the creator and emits CreatorTaxesAccrued
    function test_buy_withTax_taxAllToCreator() public {
        // 1% LP (100% treasury) + 2% creator tax
        feeToken = _wireToken(100, 10_000, 200, 200);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;
        uint256 tax = value * 200 / 10_000;

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit CreatorTaxesAccrued(address(feeToken), tax);
        _buy(feeToken, value);

        assertEq(treasury.balance - t0, lpFee, "treasury gets LP fee");
        assertEq(_creatorClaimable(feeToken), tax, "creator gets tax");
    }

    /// @dev when both LP split and tax apply, then creator gets LP-creator-share + full tax
    function test_buy_splitPlusTax() public {
        feeToken = _wireToken(100, 4_000, 200, 200);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;
        uint256 tax = value * 200 / 10_000;
        uint256 treasuryShare = lpFee * 4_000 / 10_000;
        uint256 creatorShare = lpFee - treasuryShare;

        _buy(feeToken, value);

        assertEq(treasury.balance - t0, treasuryShare, "treasury share");
        assertEq(_creatorClaimable(feeToken), creatorShare + tax, "creator gets lp creator share + tax");
    }

    /// @dev when the LP fee rate is lowered between trades, then the launchpad charges the new rate
    function test_buy_perTradeRead() public {
        feeToken = _wireToken(300, 10_000, 0, 0); // 3%
        uint256 value = 1 ether;

        uint256 t0 = treasury.balance;
        _buy(feeToken, value);
        assertEq(treasury.balance - t0, value * 300 / 10_000, "first trade 3%");

        vm.prank(admin); // launchpad owner lowers the LP fee to 1%
        feeToken.setLaunchpadFees(100, 0, 0);

        uint256 t1 = treasury.balance;
        _buy(feeToken, value);
        assertEq(treasury.balance - t1, value * 100 / 10_000, "second trade 1% after lowering");
    }

    /// @dev when the total fee (LP + tax) exceeds the launchpad's per-trade backstop, the trade reverts
    function test_buy_totalFeeAboveCap_reverts() public {
        // buy total = 2000 + 600 = 2600 > MAX_TRADING_FEE_BPS (2500). This config is only reachable by
        // wiring the token directly; the factory caps real tokens far below this backstop.
        feeToken = _wireToken(2000, 10_000, 600, 0);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(LivoLaunchpad.InvalidLaunchpadFee.selector);
        launchpad.buyTokensWithExactEth{value: 1 ether}(address(feeToken), 0, DEADLINE);
    }
}
