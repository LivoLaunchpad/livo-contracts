// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LivoToken launchpad-phase fee config — base-token unit tests
/// @notice Exercises the per-token pre-graduation fee policy that the launchpad reads each trade:
///         the `getLaunchpadFees` view, the init-time config + event, and the decrease-only setter.
contract LaunchpadFeesUnitTest is LaunchpadBaseTestsWithUniv2Graduator {
    LivoToken internal token;

    /// @dev Clones the base LivoToken impl and initializes it with a launchpad-phase fee config.
    ///      Direct clone+init (no factory) so arbitrary fee configs can be exercised in isolation.
    function _cloneAndInit(uint16 buyFee, uint16 sellFee, uint16 treasuryShare, address tokenOwner_)
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
                buyFeeBps: buyFee,
                sellFeeBps: sellFee,
                treasuryShareBps: treasuryShare
            })
        );
    }

    modifier initToken(uint16 buyFee, uint16 sellFee, uint16 treasuryShare) {
        token = _cloneAndInit(buyFee, sellFee, treasuryShare, creator);
        _;
    }

    function _trade(bool isBuy) internal pure returns (ILivoToken.LaunchpadTrade memory) {
        return ILivoToken.LaunchpadTrade({
            isBuy: isBuy, trader: address(0), ethAmount: 1 ether, tokenAmount: 0, ethReserves: 0, releasedSupply: 0
        });
    }

    /// @dev when a token is initialized with a fee config, then the fee fields are stored
    function test_init_assertStoresLaunchpadFees() public initToken(150, 200, 4000) {
        assertEq(token.buyFeeBps(), 150, "buyFeeBps");
        assertEq(token.sellFeeBps(), 200, "sellFeeBps");
        assertEq(token.treasuryShareBps(), 4000, "treasuryShareBps");
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
                buyFeeBps: 150,
                sellFeeBps: 200,
                treasuryShareBps: 4000
            })
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LaunchpadFeesInitialized(uint16,uint16,uint16)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == sig) {
                (uint16 b, uint16 s, uint16 ts) = abi.decode(logs[i].data, (uint16, uint16, uint16));
                assertEq(b, 150, "event buyFeeBps");
                assertEq(s, 200, "event sellFeeBps");
                assertEq(ts, 4000, "event treasuryShareBps");
                found = true;
            }
        }
        assertTrue(found, "LaunchpadFeesInitialized not emitted");
    }

    /// @dev when getLaunchpadFees is queried for a buy, then it returns the buy fee + treasury share
    function test_getLaunchpadFees_buy_assertReturnsBuyFee() public initToken(150, 200, 4000) {
        ILivoToken.LaunchpadFees memory f = token.getLaunchpadFees(_trade(true));
        assertEq(f.feeBps, 150, "buy feeBps");
        assertEq(f.treasuryShareBps, 4000, "treasuryShareBps");
    }

    /// @dev when getLaunchpadFees is queried for a sell, then it returns the sell fee + treasury share
    function test_getLaunchpadFees_sell_assertReturnsSellFee() public initToken(150, 200, 4000) {
        ILivoToken.LaunchpadFees memory f = token.getLaunchpadFees(_trade(false));
        assertEq(f.feeBps, 200, "sell feeBps");
        assertEq(f.treasuryShareBps, 4000, "treasuryShareBps");
    }

    /// @dev when the launchpad owner lowers both fee rates, then storage updates and the event emits
    function test_setLaunchpadFees_byLaunchpadOwner_assertLowersBoth() public initToken(150, 200, 4000) {
        // token owned by `creator`; launchpad owner is `admin`. Both auth branches are valid; test admin.
        vm.expectEmit(true, true, true, true, address(token));
        emit ILivoToken.LaunchpadFeesUpdated(100, 120);

        vm.prank(admin);
        token.setLaunchpadFees(100, 120);

        assertEq(token.buyFeeBps(), 100, "buyFeeBps");
        assertEq(token.sellFeeBps(), 120, "sellFeeBps");
    }

    /// @dev when the token owner lowers a fee rate, then it succeeds
    function test_setLaunchpadFees_byTokenOwner_assertLowers() public initToken(150, 200, 4000) {
        vm.prank(creator);
        token.setLaunchpadFees(150, 100);
        assertEq(token.sellFeeBps(), 100, "sellFeeBps");
    }

    /// @dev when a non-owner calls setLaunchpadFees, then it reverts and storage is untouched
    function test_setLaunchpadFees_byNonOwner_assertReverts() public initToken(150, 200, 4000) {
        vm.prank(alice);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        token.setLaunchpadFees(0, 0);

        assertEq(token.buyFeeBps(), 150, "buyFeeBps untouched");
        assertEq(token.sellFeeBps(), 200, "sellFeeBps untouched");
    }

    /// @dev when setLaunchpadFees raises the buy fee, then it reverts (decrease-only)
    function test_setLaunchpadFees_buyIncrease_assertReverts() public initToken(150, 200, 4000) {
        vm.prank(admin);
        vm.expectRevert(LivoToken.LaunchpadFeesCanOnlyDecrease.selector);
        token.setLaunchpadFees(151, 200);

        assertEq(token.buyFeeBps(), 150, "untouched");
    }

    /// @dev when setLaunchpadFees raises the sell fee, then it reverts (decrease-only)
    function test_setLaunchpadFees_sellIncrease_assertReverts() public initToken(150, 200, 4000) {
        vm.prank(admin);
        vm.expectRevert(LivoToken.LaunchpadFeesCanOnlyDecrease.selector);
        token.setLaunchpadFees(150, 201);
    }

    /// @dev when setLaunchpadFees passes equal values, then it succeeds (no-op per side)
    function test_setLaunchpadFees_equalValues_assertSucceeds() public initToken(150, 200, 4000) {
        vm.prank(admin);
        token.setLaunchpadFees(150, 200);
        assertEq(token.buyFeeBps(), 150);
        assertEq(token.sellFeeBps(), 200);
    }

    /// @dev when setLaunchpadFees lowers rates, then treasuryShareBps is left unchanged
    function test_setLaunchpadFees_assertTreasuryShareUnchanged() public initToken(150, 200, 4000) {
        vm.prank(admin);
        token.setLaunchpadFees(10, 10);
        assertEq(token.treasuryShareBps(), 4000, "treasuryShareBps unchanged");
    }
}
