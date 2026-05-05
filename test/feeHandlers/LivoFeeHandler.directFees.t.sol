// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoFeeHandler} from "src/feeHandlers/LivoFeeHandler.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoClaims} from "src/interfaces/ILivoClaims.sol";

/// @dev Mock launchpad with whitelistedFactories getter for direct-fees gating tests.
contract MockLaunchpadWithWhitelist {
    mapping(address => bool) public whitelistedFactories;

    function whitelist(address factory, bool ok) external {
        whitelistedFactories[factory] = ok;
    }
}

/// @dev Receiver that always reverts on ETH receipt — exercises the fallback-to-pending path.
contract HostileReceiver {
    receive() external payable {
        revert("rejected");
    }
}

contract LivoFeeHandlerDirectFeesTest is Test {
    LivoFeeHandler public handler;
    MockLaunchpadWithWhitelist public mockLaunchpad;

    address public factory = makeAddr("factory");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public tokenA = makeAddr("tokenA");
    address public tokenB = makeAddr("tokenB");

    function setUp() public {
        mockLaunchpad = new MockLaunchpadWithWhitelist();
        mockLaunchpad.whitelist(factory, true);
        handler = new LivoFeeHandler(address(mockLaunchpad));
        vm.deal(address(this), 100 ether);
    }

    function _toArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _toArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // ===================== registerDirectReceivers =====================

    /// @dev when called by a whitelisted factory, then the registration is stored
    function test_register_whitelistedFactory_succeeds() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));
        assertTrue(handler.isDirectReceiver(tokenA, alice));
    }

    /// @dev when called by a non-whitelisted address, then it reverts with OnlyWhitelistedFactory
    function test_register_nonWhitelisted_reverts() public {
        vm.expectRevert(ILivoFeeHandler.OnlyWhitelistedFactory.selector);
        handler.registerDirectReceivers(tokenA, _toArray(alice));
    }

    /// @dev when registering twice for the same token, then the second call adds new receivers
    ///      to the direct set without reverting
    function test_register_secondCall_addsMoreReceivers() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));

        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(bob));

        assertTrue(handler.isDirectReceiver(tokenA, alice));
        assertTrue(handler.isDirectReceiver(tokenA, bob));
    }

    /// @dev when registering different tokens, each retains its own direct set
    function test_register_perTokenIsolation() public {
        vm.startPrank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));
        handler.registerDirectReceivers(tokenB, _toArray(bob));
        vm.stopPrank();

        assertTrue(handler.isDirectReceiver(tokenA, alice));
        assertFalse(handler.isDirectReceiver(tokenA, bob));
        assertTrue(handler.isDirectReceiver(tokenB, bob));
    }

    /// @dev handler accepts multi-receiver registration even though current factories cap at 1
    function test_register_multipleReceivers_supported() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice, bob));

        assertTrue(handler.isDirectReceiver(tokenA, alice));
        assertTrue(handler.isDirectReceiver(tokenA, bob));
        assertFalse(handler.isDirectReceiver(tokenA, charlie));
    }

    /// @dev one DirectReceiverRegistered event fires per receiver in the array
    function test_register_emitsEventPerReceiver() public {
        vm.expectEmit(true, true, false, true, address(handler));
        emit ILivoFeeHandler.DirectReceiverRegistered(tokenA, alice);
        vm.expectEmit(true, true, false, true, address(handler));
        emit ILivoFeeHandler.DirectReceiverRegistered(tokenA, bob);

        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice, bob));
    }

    // ===================== depositFees direct path =====================

    /// @dev when fees deposited for a registered direct receiver, then ETH is forwarded synchronously
    function test_deposit_direct_forwardsImmediately() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));

        uint256 before = alice.balance;
        handler.depositFees{value: 1 ether}(tokenA, alice);

        assertEq(alice.balance - before, 1 ether, "alice received forwarded ETH");
        assertEq(handler.getClaimable(_toArray(tokenA), alice)[0], 0, "no pending after forward");
    }

    /// @dev when direct deposit succeeds, then both CreatorFeesDeposited and CreatorClaimed fire
    function test_deposit_direct_emitsBothEvents() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));

        vm.expectEmit(true, true, false, true, address(handler));
        emit ILivoFeeHandler.CreatorFeesDeposited(tokenA, alice, 1 ether);
        vm.expectEmit(true, true, false, true, address(handler));
        emit ILivoClaims.CreatorClaimed(tokenA, alice, 1 ether);

        handler.depositFees{value: 1 ether}(tokenA, alice);
    }

    /// @dev when the direct receiver rejects ETH, then the deposit doesn't revert and the amount is credited as pending
    function test_deposit_direct_hostileReceiver_fallbackToPending() public {
        HostileReceiver hostile = new HostileReceiver();
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(address(hostile)));

        // The hot-path deposit must NOT revert even though the receiver does — graduations and
        // swaps depend on this.
        handler.depositFees{value: 1 ether}(tokenA, address(hostile));

        // Funds remain in the handler as pending for the hostile receiver.
        assertEq(address(handler).balance, 1 ether);
        assertEq(handler.getClaimable(_toArray(tokenA), address(hostile))[0], 1 ether);
    }

    /// @dev when deposit fees with mismatched feeReceiver (not flagged as direct), then standard pending path applies
    function test_deposit_directRegistered_butWrongReceiver_pendingPath() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));

        uint256 beforeBob = bob.balance;
        // Caller passes `bob` as feeReceiver — handler doesn't auto-forward to alice; bob gets normal pending.
        handler.depositFees{value: 1 ether}(tokenA, bob);

        assertEq(bob.balance, beforeBob, "no forward to bob");
        assertEq(handler.getClaimable(_toArray(tokenA), bob)[0], 1 ether, "bob has pending");
        assertEq(handler.getClaimable(_toArray(tokenA), alice)[0], 0, "alice gets nothing");
    }

    /// @dev when zero msg.value is deposited for a direct receiver, then the forward path is skipped (no event)
    function test_deposit_direct_zeroValue_noForward() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));

        uint256 before = alice.balance;
        handler.depositFees{value: 0}(tokenA, alice);
        assertEq(alice.balance, before);
    }

    // ===================== claim after failed forward =====================

    /// @dev when the direct receiver was hostile but later becomes cooperative, they can claim the residue
    function test_claim_recoverFailedForward() public {
        HostileReceiver hostile = new HostileReceiver();
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(address(hostile)));

        // Forward fails, residue parked as pending.
        handler.depositFees{value: 1 ether}(tokenA, address(hostile));

        // Etch a cooperative receiver into the hostile address — simulates the receiver replacing
        // their contract code with a non-rejecting version. The pending balance is now claimable
        // by the original address.
        vm.etch(address(hostile), hex"");

        uint256 before = address(hostile).balance;
        vm.prank(address(hostile));
        handler.claim(_toArray(tokenA));
        assertEq(address(hostile).balance - before, 1 ether);
    }

    // ===================== setFeeReceiver-style rotation drops direct status =====================

    /// @dev simulates LivoToken.setFeeReceiver behavior: the token rotates feeReceiver but the
    ///      handler's mapping is NOT migrated. Result: deposits with the new feeReceiver address
    ///      fall through to pending (no auto-forward), preserving funds without breaking the flow.
    function test_setFeeReceiverRotation_dropsDirectStatus() public {
        vm.prank(factory);
        handler.registerDirectReceivers(tokenA, _toArray(alice));

        // Token rotates fee receiver to bob (no migration call). Now deposits target bob.
        uint256 beforeBob = bob.balance;
        handler.depositFees{value: 1 ether}(tokenA, bob);

        // bob is NOT a registered direct receiver, so the auto-forward path is skipped.
        assertEq(bob.balance, beforeBob, "no auto-forward to new receiver");
        assertEq(handler.getClaimable(_toArray(tokenA), bob)[0], 1 ether, "bob has pending");

        // alice is still flagged direct, so the registration itself is unchanged.
        assertTrue(handler.isDirectReceiver(tokenA, alice), "registration unchanged");
        assertFalse(handler.isDirectReceiver(tokenA, bob));
    }
}
