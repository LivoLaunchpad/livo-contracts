// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LivoToken launchpad-phase fee config — base-token unit tests
/// @notice Pre-graduation LP/trading fee policy carried by the base token: a single LP fee split
///         treasury/creator by `treasuryShareBps`. The base token carries NO tax — taxable variants
///         add the creation-anchored tax (see the taxable-token tests). The LP fee is fixed at launch
///         (there is no setter; the owner cannot change LP fees).
contract LaunchpadFeesUnitTest is LaunchpadBaseTestsWithUniv2Graduator {
    LivoToken internal token;

    /// @dev Clones the base LivoToken impl and initializes it with a launchpad-phase LP-fee config.
    function _cloneAndInit(uint16 lpFee, uint16 treasuryShare, address tokenOwner_) internal returns (LivoToken t) {
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
                treasuryShareBps: treasuryShare
            })
        );
    }

    modifier initToken(uint16 lpFee, uint16 treasuryShare) {
        token = _cloneAndInit(lpFee, treasuryShare, creator);
        _;
    }

    function _fees(bool isBuy) internal view returns (ILivoToken.LaunchpadFees memory) {
        return token.getLaunchpadFees(ILivoToken.LaunchpadTrade({isBuy: isBuy, ethReserves: 0, releasedSupply: 0}));
    }

    /// @dev when a token is initialized, then the LP-fee fields are stored and launchTimestamp is set
    function test_init_assertStoresFees() public initToken(150, 4000) {
        assertEq(token.lpFeeBps(), 150, "lpFee");
        assertEq(token.treasuryShareBps(), 4000, "treasuryShare");
        assertEq(token.launchTimestamp(), uint40(block.timestamp), "launchTimestamp");
    }

    /// @dev when a token is initialized, then it emits LaunchpadFeesInitialized(lpFee, treasuryShare)
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
                treasuryShareBps: 4000
            })
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LaunchpadFeesInitialized(uint16,uint16)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == sig) {
                (uint16 a, uint16 b) = abi.decode(logs[i].data, (uint16, uint16));
                assertEq(a, 150, "lpFee");
                assertEq(b, 4000, "treasuryShare");
                found = true;
            }
        }
        assertTrue(found, "LaunchpadFeesInitialized not emitted");
    }

    /// @dev when getLaunchpadFees is queried on the base token for a buy, then it returns the LP fee and no tax
    function test_getLaunchpadFees_buy() public initToken(150, 4000) {
        ILivoToken.LaunchpadFees memory f = _fees(true);
        assertEq(f.lpFeeBps, 150, "lpFeeBps");
        assertEq(f.treasuryShareBps, 4000, "treasuryShareBps");
        assertEq(f.taxBps, 0, "taxBps");
    }

    /// @dev when getLaunchpadFees is queried on the base token for a sell, then it returns the LP fee and no tax
    function test_getLaunchpadFees_sell() public initToken(150, 4000) {
        ILivoToken.LaunchpadFees memory f = _fees(false);
        assertEq(f.lpFeeBps, 150, "lpFeeBps");
        assertEq(f.treasuryShareBps, 4000, "treasuryShareBps");
        assertEq(f.taxBps, 0, "taxBps");
    }
}
