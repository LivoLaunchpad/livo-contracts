// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoFeeSplitter} from "src/feeSplitters/LivoFeeSplitter.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {ILivoClaims} from "src/interfaces/ILivoClaims.sol";
import {LivoFeeHandler} from "src/feeHandlers/LivoFeeHandler.sol";

contract MockTokenLite {
    address public owner;
    address public feeHandler;
    address public feeReceiver;

    constructor(address _owner, address _feeHandler) {
        owner = _owner;
        feeHandler = _feeHandler;
    }

    function setFeeReceiver(address r) external {
        feeReceiver = r;
    }
}

contract HostileReceiver {
    receive() external payable {
        revert("rejected");
    }
}

contract LivoFeeSplitterDirectFeesTest is Test {
    LivoFeeSplitter public implementation;
    LivoFeeSplitter public splitter;
    LivoFeeHandler public feeHandler;
    MockTokenLite public token;

    address public tokenOwner = makeAddr("tokenOwner");
    address public alice = makeAddr("alice"); // direct receiver
    address public bob = makeAddr("bob"); // claimable
    address public charlie = makeAddr("charlie"); // claimable

    function setUp() public {
        feeHandler = new LivoFeeHandler(address(0));
        token = new MockTokenLite(tokenOwner, address(feeHandler));

        implementation = new LivoFeeSplitter();
        splitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));

        // alice gets 40% direct, bob gets 60% claimable
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = ILivoFactory.FeeShare({account: alice, shares: 4_000, directFeesEnabled: true});
        fs[1] = ILivoFactory.FeeShare({account: bob, shares: 6_000, directFeesEnabled: false});

        splitter.initialize(address(token), fs);
        token.setFeeReceiver(address(splitter));

        vm.deal(address(this), 100 ether);
    }

    function _fs(address a, uint256 s, bool direct) internal pure returns (ILivoFactory.FeeShare memory) {
        return ILivoFactory.FeeShare({account: a, shares: s, directFeesEnabled: direct});
    }

    function _tokens() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(token);
    }

    // ===================== initialization =====================

    /// @dev when initialized with one direct receiver, then directReceivers list and totalDirectBps are stored
    function test_initialize_storesDirectSet() public view {
        address[] memory directs = splitter.getDirectReceivers();
        assertEq(directs.length, 1);
        assertEq(directs[0], alice);
        assertEq(splitter.totalDirectBps(), 4_000);
    }

    /// @dev when initialized with no direct receivers, then totalDirectBps is zero (claimable-only mode)
    function test_initialize_zeroDirect_claimableOnly() public {
        LivoFeeSplitter s = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(bob, 6_000, false);
        fs[1] = _fs(charlie, 4_000, false);
        s.initialize(address(token), fs);
        assertEq(s.getDirectReceivers().length, 0);
        assertEq(s.totalDirectBps(), 0);
    }

    /// @dev splitter accepts multiple direct receivers (factory caps at 1, splitter is generic)
    function test_initialize_multipleDirectReceivers_supported() public {
        LivoFeeSplitter s = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](3);
        fs[0] = _fs(alice, 3_000, true);
        fs[1] = _fs(bob, 4_000, true);
        fs[2] = _fs(charlie, 3_000, false);
        s.initialize(address(token), fs);

        address[] memory directs = s.getDirectReceivers();
        assertEq(directs.length, 2);
        assertEq(s.totalDirectBps(), 7_000);

        // Deposit fees: alice gets 30%, bob gets 40%, charlie's 30% accumulates
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        s.depositFees{value: 10 ether}(address(token), address(s));

        assertEq(alice.balance - aliceBefore, 3 ether, "alice direct");
        assertEq(bob.balance - bobBefore, 4 ether, "bob direct");
        assertEq(s.getClaimable(_tokens(), charlie)[0], 3 ether, "charlie claimable");
    }

    // ===================== _accrueBalance forward =====================

    /// @dev when 10 ETH deposited, then alice receives 4 ETH directly and bob's claimable is 6 ETH
    function test_deposit_forwardsToDirectAndAccumulatesRest() public {
        uint256 aliceBefore = alice.balance;

        splitter.depositFees{value: 10 ether}(address(token), address(splitter));

        assertEq(alice.balance - aliceBefore, 4 ether, "alice forwarded");
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 6 ether, "bob accumulator share");
        assertEq(splitter.getClaimable(_tokens(), alice)[0], 0, "alice has no pending");
    }

    /// @dev when bob claims, then bob receives the full 6 ETH (not diluted by direct slice)
    function test_claim_bobReceivesFullClaimableShare() public {
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));

        uint256 before = bob.balance;
        vm.prank(bob);
        splitter.claim(_tokens());
        assertEq(bob.balance - before, 6 ether);
    }

    /// @dev when direct receiver is hostile, deposit doesn't revert and pending is credited
    function test_deposit_hostileDirect_fallbackToPending() public {
        HostileReceiver hostile = new HostileReceiver();
        LivoFeeSplitter s = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(address(hostile), 4_000, true);
        fs[1] = _fs(bob, 6_000, false);
        s.initialize(address(token), fs);

        s.depositFees{value: 10 ether}(address(token), address(s));

        assertEq(s.getClaimable(_tokens(), address(hostile))[0], 4 ether, "hostile pending");
        assertEq(s.getClaimable(_tokens(), bob)[0], 6 ether, "bob accumulator");
        assertEq(address(s).balance, 10 ether, "all funds remain in splitter");
    }

    /// @dev FeesAccrued fires before CreatorClaimed when direct forward succeeds
    function test_deposit_eventOrder_accrueBeforeClaim() public {
        vm.expectEmit(false, false, false, true, address(splitter));
        emit ILivoFeeSplitter.FeesAccrued(10 ether);
        vm.expectEmit(true, true, false, true, address(splitter));
        emit ILivoClaims.CreatorClaimed(address(token), alice, 4 ether);

        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
    }

    // ===================== setShares with mutable direct set =====================

    /// @dev setShares can rebalance the direct receiver's BPS without changing the direct set
    function test_setShares_changesDirectBps() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(alice, 3_000, true);
        fs[1] = _fs(bob, 7_000, false);

        vm.prank(tokenOwner);
        splitter.setShares(fs);

        assertEq(splitter.totalDirectBps(), 3_000);
        address[] memory directs = splitter.getDirectReceivers();
        assertEq(directs[0], alice);

        uint256 aliceBefore = alice.balance;
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
        assertEq(alice.balance - aliceBefore, 3 ether);
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 7 ether);
    }

    /// @dev setShares can remove the direct receiver entirely; new claimable-only set works
    function test_setShares_removingDirect_succeeds() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(bob, 6_000, false);
        fs[1] = _fs(charlie, 4_000, false);

        vm.prank(tokenOwner);
        splitter.setShares(fs);

        assertEq(splitter.totalDirectBps(), 0);
        assertEq(splitter.getDirectReceivers().length, 0);

        uint256 aliceBefore = alice.balance;
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
        // alice no longer receives anything; bob and charlie split per new BPS via accumulator
        assertEq(alice.balance - aliceBefore, 0, "alice no longer direct");
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 6 ether);
        assertEq(splitter.getClaimable(_tokens(), charlie)[0], 4 ether);
        assertEq(splitter.getClaimable(_tokens(), alice)[0], 0, "alice has no residue");
    }

    /// @dev setShares can promote a previously-claimable address to direct; bob's prior accrual
    ///      is snapshotted into pending so it isn't lost across the transition.
    function test_setShares_promotingToDirect_succeeds() public {
        // pre-deposit so bob accrues claimable
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 6 ether, "bob accrued before promotion");

        // promote bob to direct (alice stays direct)
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(alice, 4_000, true);
        fs[1] = _fs(bob, 6_000, true);
        vm.prank(tokenOwner);
        splitter.setShares(fs);

        // bob's prior 6 ETH accrual is preserved as pending
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 6 ether, "bob's pre-promotion accrual preserved");
        assertEq(splitter.totalDirectBps(), 10_000);

        // next deposit: bob's slice forwards synchronously
        uint256 bobBefore = bob.balance;
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
        assertEq(bob.balance - bobBefore, 6 ether, "bob receives via direct forward");
        // bob's claimable still shows the pre-promotion 6 ETH residue (not double-credited)
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 6 ether, "residue still claimable");
    }

    /// @dev setShares can demote a direct address to claimable; future deposits credit via
    ///      accumulator only, and any pre-existing failed-forward residue stays claimable.
    function test_setShares_demotingDirect_succeeds() public {
        // demote alice to claimable
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(alice, 4_000, false);
        fs[1] = _fs(bob, 6_000, false);
        vm.prank(tokenOwner);
        splitter.setShares(fs);

        assertEq(splitter.totalDirectBps(), 0);
        assertEq(splitter.getDirectReceivers().length, 0);

        uint256 aliceBefore = alice.balance;
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
        // alice is no longer direct: nothing forwarded synchronously, balance unchanged.
        assertEq(alice.balance - aliceBefore, 0, "alice no longer direct");
        // alice and bob each accrue per their new claimable BPS.
        assertEq(splitter.getClaimable(_tokens(), alice)[0], 4 ether);
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 6 ether);
    }

    /// @dev setShares can add a third claimable shareholder while preserving direct slot
    function test_setShares_addsClaimableShareholder() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](3);
        fs[0] = _fs(alice, 4_000, true);
        fs[1] = _fs(bob, 3_000, false);
        fs[2] = _fs(charlie, 3_000, false);

        vm.prank(tokenOwner);
        splitter.setShares(fs);

        uint256 aliceBefore = alice.balance;
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
        assertEq(alice.balance - aliceBefore, 4 ether, "alice forwarded");
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 3 ether);
        assertEq(splitter.getClaimable(_tokens(), charlie)[0], 3 ether);
    }

    /// @dev setShares can add a brand-new direct receiver alongside the existing one
    function test_setShares_addsNewDirect() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](3);
        fs[0] = _fs(alice, 3_000, true);
        fs[1] = _fs(charlie, 2_000, true); // new direct
        fs[2] = _fs(bob, 5_000, false);

        vm.prank(tokenOwner);
        splitter.setShares(fs);

        assertEq(splitter.totalDirectBps(), 5_000);
        assertEq(splitter.getDirectReceivers().length, 2);

        uint256 aliceBefore = alice.balance;
        uint256 charlieBefore = charlie.balance;
        splitter.depositFees{value: 10 ether}(address(token), address(splitter));
        assertEq(alice.balance - aliceBefore, 3 ether, "alice forwarded");
        assertEq(charlie.balance - charlieBefore, 2 ether, "charlie forwarded");
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 5 ether);
    }

    /// @dev when a hostile direct accrues residue and is then removed entirely, the residue
    ///      remains recoverable via claim()
    function test_setShares_removesDirectEntirely_residueClaimable() public {
        HostileReceiver hostile = new HostileReceiver();
        LivoFeeSplitter s = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        ILivoFactory.FeeShare[] memory fsInit = new ILivoFactory.FeeShare[](2);
        fsInit[0] = _fs(address(hostile), 4_000, true);
        fsInit[1] = _fs(bob, 6_000, false);
        s.initialize(address(token), fsInit);

        // Override token's owner-driven setShares: point token at the new splitter
        token.setFeeReceiver(address(s));

        // Deposit accrues 4 ETH residue under hostile (forward fails)
        s.depositFees{value: 10 ether}(address(token), address(s));
        assertEq(s.getClaimable(_tokens(), address(hostile))[0], 4 ether);

        // Remove hostile entirely
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](1);
        fs[0] = _fs(bob, 10_000, false);
        vm.prank(tokenOwner);
        s.setShares(fs);

        assertEq(s.getDirectReceivers().length, 0);
        // residue still visible
        assertEq(s.getClaimable(_tokens(), address(hostile))[0], 4 ether, "residue preserved");

        // hostile cannot pull (revert), but a non-reverting recipient with the same residue could.
        // Simulate by reading the pending state: total accounted equals everything still in splitter.
        // The hostile would need a non-reverting fallback to actually claim — out of scope here.
    }

    /// @dev promotion emits DirectReceiverRegistered for the newly-direct address
    function test_setShares_emitsDirectReceiverRegistered_onPromotion() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(alice, 4_000, true);
        fs[1] = _fs(bob, 6_000, true); // promotion

        vm.expectEmit(true, true, false, false, address(splitter));
        emit ILivoFeeSplitter.DirectReceiverRegistered(address(token), bob);
        vm.prank(tokenOwner);
        splitter.setShares(fs);
    }

    /// @dev demotion emits DirectReceiverRemoved for the demoted address
    function test_setShares_emitsDirectReceiverRemoved_onDemotion() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(alice, 4_000, false); // demotion
        fs[1] = _fs(bob, 6_000, false);

        vm.expectEmit(true, true, false, false, address(splitter));
        emit ILivoFeeSplitter.DirectReceiverRemoved(address(token), alice);
        vm.prank(tokenOwner);
        splitter.setShares(fs);
    }

    /// @dev simultaneous demotion + promotion emits both events
    function test_setShares_emitsBoth_onSwap() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(alice, 4_000, false); // alice demoted
        fs[1] = _fs(bob, 6_000, true); // bob promoted

        vm.expectEmit(true, true, false, false, address(splitter));
        emit ILivoFeeSplitter.DirectReceiverRemoved(address(token), alice);
        vm.expectEmit(true, true, false, false, address(splitter));
        emit ILivoFeeSplitter.DirectReceiverRegistered(address(token), bob);
        vm.prank(tokenOwner);
        splitter.setShares(fs);
    }

    /// @dev pure BPS rebalance (no direct-set change) emits neither Registered nor Removed
    function test_setShares_noDirectChange_emitsNeitherDirectEvent() public {
        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = _fs(alice, 3_000, true); // BPS change only
        fs[1] = _fs(bob, 7_000, false);

        // Record logs and assert no DirectReceiverRegistered/Removed events fire
        vm.recordLogs();
        vm.prank(tokenOwner);
        splitter.setShares(fs);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 registeredSig = keccak256("DirectReceiverRegistered(address,address)");
        bytes32 removedSig = keccak256("DirectReceiverRemoved(address,address)");
        for (uint256 i = 0; i < entries.length; i++) {
            // Only check logs from the splitter itself
            if (entries[i].emitter != address(splitter)) continue;
            assertTrue(entries[i].topics[0] != registeredSig, "no DirectReceiverRegistered");
            assertTrue(entries[i].topics[0] != removedSig, "no DirectReceiverRemoved");
        }
    }

    // ===================== getClaimable view =====================

    /// @dev when fees sit unaccounted in the splitter, claimable shareholders see their net-of-direct slice
    function test_getClaimable_includesUnaccounted_excludesDirectSlice() public {
        // Direct ETH transfer — lands in the splitter without triggering depositFees, so it is
        // unaccounted until the next accrual.
        (bool ok,) = address(splitter).call{value: 5 ether}("");
        require(ok);
        // bob gets 60% claimable; direct slice (40%) goes to alice on next accrual.
        assertEq(splitter.getClaimable(_tokens(), bob)[0], 3 ether);
        assertEq(splitter.getClaimable(_tokens(), alice)[0], 0);
    }
}
