// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LivoToken launchpad-phase fee config — base-token unit tests
/// @notice Pre-graduation fee policy: an LP/trading fee (split treasury/creator by `treasuryShareBps`)
///         plus an optional creator tax (100% to creator). Exercises `getLaunchpadFees`, the init
///         event, and the decrease-only setter.
contract LaunchpadFeesUnitTest is LaunchpadBaseTestsWithUniv2Graduator {
    LivoToken internal token;

    /// @dev Clones the base LivoToken impl and initializes it with a launchpad-phase fee config.
    function _cloneAndInit(uint16 lpFee, uint16 treasuryShare, uint16 taxBuy, uint16 taxSell, address tokenOwner_)
        internal
        returns (LivoToken t)
    {
        t = LivoToken(Clones.clone(address(livoToken)));
        t.initialize(
            ILivoToken.InitializeParams({
                name: "FeeToken",
                symbol: "FEE",
                tokenOwner: tokenOwner_,
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
    }

    modifier initToken(uint16 lpFee, uint16 treasuryShare, uint16 taxBuy, uint16 taxSell) {
        token = _cloneAndInit(lpFee, treasuryShare, taxBuy, taxSell, creator);
        _;
    }

    function _fees(bool isBuy) internal view returns (ILivoToken.LaunchpadFees memory) {
        return token.getLaunchpadFees(
            ILivoToken.LaunchpadTrade({isBuy: isBuy, trader: address(0), ethReserves: 0, releasedSupply: 0})
        );
    }

    /// @dev when a token is initialized, then all four pre-graduation fee fields are stored
    function test_init_assertStoresFees() public initToken(150, 4000, 30, 40) {
        assertEq(token.lpFeeBps(), 150, "lpFee");
        assertEq(token.treasuryShareBps(), 4000, "treasuryShare");
        assertEq(token.taxBuyBps(), 30, "taxBuy");
        assertEq(token.taxSellBps(), 40, "taxSell");
    }

    /// @dev when a token is initialized, then it emits LaunchpadFeesInitialized with the config
    function test_init_assertEmitsLaunchpadFeesInitialized() public {
        LivoToken t = LivoToken(Clones.clone(address(livoToken)));

        vm.recordLogs();
        t.initialize(
            ILivoToken.InitializeParams({
                name: "FeeToken",
                symbol: "FEE",
                tokenOwner: creator,
                graduator: address(graduatorV2),
                launchpad: address(launchpad),
                feeHandler: address(feeHandler),
                vaultAllocation: 0,
                lpFeeBps: 150,
                treasuryShareBps: 4000,
                taxBuyBps: 30,
                taxSellBps: 40
            })
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LaunchpadFeesInitialized(uint16,uint16,uint16,uint16)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == sig) {
                (uint16 a, uint16 b, uint16 c, uint16 d) = abi.decode(logs[i].data, (uint16, uint16, uint16, uint16));
                assertEq(a, 150, "lpFee");
                assertEq(b, 4000, "treasuryShare");
                assertEq(c, 30, "taxBuy");
                assertEq(d, 40, "taxSell");
                found = true;
            }
        }
        assertTrue(found, "LaunchpadFeesInitialized not emitted");
    }

    /// @dev when getLaunchpadFees is queried for a buy, then it returns lpFee + treasuryShare + taxBuy
    function test_getLaunchpadFees_buy() public initToken(150, 4000, 30, 40) {
        ILivoToken.LaunchpadFees memory f = _fees(true);
        assertEq(f.lpFeeBps, 150, "lpFeeBps");
        assertEq(f.treasuryShareBps, 4000, "treasuryShareBps");
        assertEq(f.taxBps, 30, "taxBps");
    }

    /// @dev when getLaunchpadFees is queried for a sell, then it returns the same lpFee + treasuryShare + taxSell
    function test_getLaunchpadFees_sell() public initToken(150, 4000, 30, 40) {
        ILivoToken.LaunchpadFees memory f = _fees(false);
        assertEq(f.lpFeeBps, 150, "lpFeeBps");
        assertEq(f.treasuryShareBps, 4000, "treasuryShareBps");
        assertEq(f.taxBps, 40, "taxBps");
    }

    /// @dev when the launchpad owner lowers all rates, then storage updates and the event emits
    function test_setLaunchpadFees_byLaunchpadOwner_lowersAll() public initToken(150, 4000, 30, 40) {
        vm.expectEmit(true, true, true, true, address(token));
        emit ILivoToken.LaunchpadFeesUpdated(100, 10, 20);

        vm.prank(admin);
        token.setLaunchpadFees(100, 10, 20);

        assertEq(token.lpFeeBps(), 100, "lpFee");
        assertEq(token.taxBuyBps(), 10, "taxBuy");
        assertEq(token.taxSellBps(), 20, "taxSell");
    }

    /// @dev when the token owner lowers rates, then it succeeds
    function test_setLaunchpadFees_byTokenOwner() public initToken(150, 4000, 30, 40) {
        vm.prank(creator);
        token.setLaunchpadFees(150, 0, 0);
        assertEq(token.taxBuyBps(), 0, "taxBuy");
        assertEq(token.taxSellBps(), 0, "taxSell");
    }

    /// @dev when a non-owner calls setLaunchpadFees, then it reverts and storage is untouched
    function test_setLaunchpadFees_byNonOwner_reverts() public initToken(150, 4000, 30, 40) {
        vm.prank(alice);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        token.setLaunchpadFees(0, 0, 0);

        assertEq(token.lpFeeBps(), 150, "lpFee untouched");
    }

    /// @dev when setLaunchpadFees raises the LP fee, then it reverts (decrease-only)
    function test_setLaunchpadFees_lpIncrease_reverts() public initToken(150, 4000, 30, 40) {
        vm.prank(admin);
        vm.expectRevert(LivoToken.LaunchpadFeesCanOnlyDecrease.selector);
        token.setLaunchpadFees(151, 30, 40);
    }

    /// @dev when setLaunchpadFees raises a tax, then it reverts (decrease-only)
    function test_setLaunchpadFees_taxIncrease_reverts() public initToken(150, 4000, 30, 40) {
        vm.prank(admin);
        vm.expectRevert(LivoToken.LaunchpadFeesCanOnlyDecrease.selector);
        token.setLaunchpadFees(150, 30, 41);
    }

    /// @dev when setLaunchpadFees passes equal values, then it succeeds (no-op)
    function test_setLaunchpadFees_equal_ok() public initToken(150, 4000, 30, 40) {
        vm.prank(admin);
        token.setLaunchpadFees(150, 30, 40);
        assertEq(token.lpFeeBps(), 150, "lpFee");
    }

    /// @dev when setLaunchpadFees lowers rates, then treasuryShareBps is unchanged
    function test_setLaunchpadFees_treasuryShareUnchanged() public initToken(150, 4000, 30, 40) {
        vm.prank(admin);
        token.setLaunchpadFees(10, 0, 0);
        assertEq(token.treasuryShareBps(), 4000, "treasuryShare unchanged");
    }
}
