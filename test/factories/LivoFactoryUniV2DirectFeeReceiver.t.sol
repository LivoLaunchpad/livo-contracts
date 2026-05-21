// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @notice Coverage for the V2 taxable + single-direct-receiver path in `LivoFactoryUniV2Unified`.
///         The factory's `_resolveFeeHandlerForInit` override sets `token.feeHandler = receiver`
///         (bypassing the master fee handler) and emits `DirectSingleFeeReceiver`. Negative paths
///         assert all other configurations still register with the master handler.
contract LivoFactoryUniV2DirectFeeReceiverTest is LaunchpadBaseTests {
    AcceptingReceiver internal smartReceiver;
    RejectingReceiver internal rejectingReceiver;

    function setUp() public virtual override {
        super.setUp();
        smartReceiver = new AcceptingReceiver();
        rejectingReceiver = new RejectingReceiver();
    }

    // ============================================================
    // Happy path — V2 taxable + single direct receiver
    // ============================================================

    function test_v2Taxable_singleDirectEOA_pointsFeeHandlerAtReceiver() public {
        ILivoFactory.FeeShare[] memory fs = _fsDirect(alice);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));

        vm.recordLogs();
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "Direct", "DR", salt, fs, _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );

        assertEq(ILivoToken(token).feeHandler(), alice, "feeHandler should be the EOA receiver");

        // Master handler is NOT registered for this token (registerFees was skipped).
        assertFalse(feeHandler.isDirectReceiver(token, alice), "alice should not be in master.isDirectReceiver");
        assertEq(feeHandler.getDirectReceivers(token).length, 0, "no direct receivers on master");
        (address[] memory addrs,) = feeHandler.getRecipients(token);
        assertEq(addrs.length, 0, "no recipients registered with master");

        // DirectSingleFeeReceiver(token, alice) was emitted.
        _assertDirectSingleFeeReceiverEmitted(token, alice);
    }

    function test_v2Taxable_singleDirectEOA_accrueFeesLandsAtReceiver() public {
        ILivoFactory.FeeShare[] memory fs = _fsDirect(alice);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "Route", "RT", salt, fs, _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );

        uint256 aliceBefore = alice.balance;
        uint256 handlerBefore = address(feeHandler).balance;
        vm.deal(buyer, 0.5 ether);
        vm.prank(buyer);
        ILivoToken(token).accrueFees{value: 0.5 ether}();

        assertEq(alice.balance, aliceBefore + 0.5 ether, "alice gets the full fee directly");
        assertEq(address(feeHandler).balance, handlerBefore, "master handler balance unchanged");
    }

    function test_v2Taxable_singleDirect_smartWalletReceiver_isAllowed() public {
        // User chose to allow contract receivers (no EOA gate). The direct path still applies and
        // ETH lands at the contract.
        ILivoFactory.FeeShare[] memory fs = _fsDirect(address(smartReceiver));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "Smart", "SM", salt, fs, _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );

        assertEq(ILivoToken(token).feeHandler(), address(smartReceiver), "feeHandler is the smart wallet");
        uint256 before = address(smartReceiver).balance;
        vm.deal(buyer, 0.3 ether);
        vm.prank(buyer);
        ILivoToken(token).accrueFees{value: 0.3 ether}();
        assertEq(address(smartReceiver).balance, before + 0.3 ether, "smart wallet receives fees");
    }

    function test_v2Taxable_singleDirect_rejectingReceiver_keepsEthInToken() public {
        // `_accrueFees` swallows transfer failures (no revert): a receiver reverting on
        // `receive()` no longer DoSes accrueFees / swap-backs. The ETH stays on the token contract
        // and rolls into the next swap-back via `address(this).balance`.
        ILivoFactory.FeeShare[] memory fs = _fsDirect(address(rejectingReceiver));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "Reject", "RJ", salt, fs, _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );

        uint256 receiverBefore = address(rejectingReceiver).balance;
        uint256 tokenBefore = token.balance;
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        ILivoToken(token).accrueFees{value: 1 ether}();

        assertEq(address(rejectingReceiver).balance, receiverBefore, "rejecting receiver got nothing");
        assertEq(token.balance, tokenBefore + 1 ether, "ETH stays on the token contract");
    }

    // ============================================================
    // Negative paths — master handler must still be used
    // ============================================================

    function test_v2Taxable_singleClaimable_usesMasterHandler() public {
        // Single receiver but directFeesEnabled=false → not the direct path.
        ILivoFactory.FeeShare[] memory fs = _fs(alice);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "Claim", "CL", salt, fs, _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );

        assertEq(ILivoToken(token).feeHandler(), address(feeHandler), "feeHandler is master");
        (address[] memory addrs, uint256[] memory bps) = feeHandler.getRecipients(token);
        assertEq(addrs.length, 1, "1 recipient registered with master");
        assertEq(addrs[0], alice, "alice registered as recipient");
        assertEq(bps[0], 10_000, "alice gets 10000 bps");
        assertFalse(feeHandler.isDirectReceiver(token, alice), "non-direct (claimable) entry");
    }

    function test_v2Taxable_multiRecipient_oneDirect_usesMasterHandler() public {
        // Two receivers (one direct) → resolver requires length==1, so this falls back to master.
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = ILivoFactory.FeeShare({account: alice, shares: 6_000, directFeesEnabled: true});
        fs[1] = ILivoFactory.FeeShare({account: bob, shares: 4_000, directFeesEnabled: false});

        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "Multi", "MX", salt, fs, _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );

        assertEq(ILivoToken(token).feeHandler(), address(feeHandler), "multi-recipient stays on master");
        assertTrue(feeHandler.isDirectReceiver(token, alice), "alice still registered as direct");
    }

    function test_v2NonTaxable_singleDirect_usesMasterHandler() public {
        // Non-taxable V2 impl → resolver hook requires the taxable impls, so master handler wins.
        ILivoFactory.FeeShare[] memory fs = _fsDirect(alice);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoToken));
        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("Plain", "PL", salt, fs, _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertEq(ILivoToken(token).feeHandler(), address(feeHandler), "non-taxable V2 uses master");
        assertTrue(feeHandler.isDirectReceiver(token, alice), "alice registered with master");
    }

    function test_v4Taxable_singleDirect_usesMasterHandler() public {
        // V4 factory keeps the default `_resolveFeeHandlerForInit` → master handler always used.
        ILivoFactory.FeeShare[] memory fs = _fsDirect(alice);
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(livoTaxToken));
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "V4Tax", "V4", salt, fs, _noSs(), false, _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );

        assertEq(ILivoToken(token).feeHandler(), address(feeHandler), "V4 always uses master");
        assertTrue(feeHandler.isDirectReceiver(token, alice), "V4 direct receiver registered with master");
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev Scans recorded logs for `DirectSingleFeeReceiver(token, receiver)` and asserts both fields.
    function _assertDirectSingleFeeReceiverEmitted(address expectedToken, address expectedReceiver) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = ILivoFactory.DirectSingleFeeReceiver.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == sig) {
                address loggedToken = address(uint160(uint256(logs[i].topics[1])));
                if (loggedToken != expectedToken) continue;
                address receiver = abi.decode(logs[i].data, (address));
                assertEq(receiver, expectedReceiver, "DirectSingleFeeReceiver receiver mismatch");
                return;
            }
        }
        revert("DirectSingleFeeReceiver event not found in logs");
    }
}

contract AcceptingReceiver {
    receive() external payable {}
}

contract RejectingReceiver {
    receive() external payable {
        revert("nope");
    }
}
