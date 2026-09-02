// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";

/// @notice A bare `DividendDistributionLogic` whose balances move through `_trackDividendShares`, the way a
///         real token's `_update` moves them. `DividendHarness` in `dividendsThirdAsset.t.sol` sets
///         balances directly and so cannot exercise the round-minimum accounting at all; this one keeps
///         a holder list so the denominator can be reconciled against the sum it claims to be.
contract SharesHarness is DividendDistributionLogic {
    mapping(address account => uint256 balance) public balances;
    uint256 public eligibleSupply;

    /// @dev Every address that has ever held a balance. Only a test harness can afford this — it is
    ///      exactly the holder set the production contract deliberately refuses to store.
    address[] public tracked;
    mapping(address account => bool) internal seen;

    address[3] internal excluded;

    function configure(address asset) external {
        _initializeDividends(asset);
    }

    function openRound() external {
        _openDividendRound();
    }

    function accrue() external payable {
        _accrueDividends(msg.value);
    }

    function exclude(uint256 index, address account) external {
        excluded[index] = account;
    }

    /// @dev Seeds a balance WITHOUT tracking, standing in for supply that existed before the round
    ///      opened (the bonding-curve distribution).
    function seed(address to, uint256 value) external {
        _remember(to);
        eligibleSupply += value;
        balances[to] += value;
    }

    /// @dev A transfer as the token performs it: track first (pre-transfer balances), then move.
    function transfer(address from, address to, uint256 amount) external {
        _trackDividendShares(from, to, amount);
        balances[from] -= amount;
        balances[to] += amount;
        _remember(to);
    }

    /// @notice `Σ dividendShares(a)` over every address that has ever held — what `roundTotalShares`
    ///         claims to be. The whole solvency argument is this identity.
    function sumOfShares() external view returns (uint256 total) {
        for (uint256 i; i < tracked.length; ++i) {
            total += dividendShares(tracked[i]);
        }
    }

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    function _remember(address account) internal {
        if (account == address(0) || seen[account]) return;
        seen[account] = true;
        tracked.push(account);
    }

    function _dividendBalanceOf(address account) internal view override returns (uint256) {
        return balances[account];
    }

    function _dividendExcluded(address account) internal view override returns (bool) {
        return account == excluded[0] || account == excluded[1] || account == excluded[2];
    }

    function _dividendEligibleSupply() internal view override returns (uint256) {
        return eligibleSupply;
    }

    receive() external payable {}
}

/// @notice Rejects every native payout. Stands in for a holder whose `receive()` reverts — the case the
///         skip-don't-revert branch and the `NATIVE_PAYOUT_GAS` stipend exist for.
contract RejectingHolder {
    receive() external payable {
        revert("no thanks");
    }
}

/// @notice Burns far more gas than `NATIVE_PAYOUT_GAS` allows, so the send fails on the stipend rather
///         than on an explicit revert. A holder must not be able to grief a batch this way either.
contract GasGuzzlingHolder {
    uint256[] internal sink;

    receive() external payable {
        for (uint256 i; i < 200; ++i) {
            sink.push(i);
        }
    }
}

/// @notice Reenters the payout entry points from inside `receive()`. The transient
///         `nonReentrantDividends` guard must make the reentrant call revert, and the outer batch must
///         still settle without paying anyone twice.
/// @dev The reentrant call is wrapped in `try` deliberately. Letting it bubble would revert this
///      `receive()`, which the payout treats as a failed send — the attacker would be skipped and the
///      test would prove nothing about the guard. Swallowing it lets the attacker be paid its honest
///      share while `blockedReentries` records that the second entry was refused.
contract ReenteringHolder {
    DividendDistributionLogic public immutable TARGET;
    bool public useClaim;
    uint256 public blockedReentries;

    constructor(DividendDistributionLogic target) {
        TARGET = target;
    }

    function setUseClaim(bool value) external {
        useClaim = value;
    }

    receive() external payable {
        if (useClaim) {
            try TARGET.claimRound() {}
            catch {
                ++blockedReentries;
            }
        } else {
            address[] memory batch = new address[](1);
            batch[0] = address(this);
            try TARGET.processRound(0, batch) {}
            catch {
                ++blockedReentries;
            }
        }
    }
}

/// @notice The dividend accounting identity and the payout-path safety properties, exercised against a
///         bare `DividendDistribution` so the assertions are about the module rather than about a pool.
contract DividendAccountingTests is Test {
    SharesHarness internal h;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant SUPPLY = 1_000_000e18;

    function setUp() public {
        h = new SharesHarness();
        h.configure(address(0));
    }

    function _nativeRound() internal {
        h.seed(alice, SUPPLY / 2);
        h.seed(bob, SUPPLY / 4);
        h.seed(carol, SUPPLY / 4);
        h.openRound();
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        h.accrue{value: amount}();
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _batch(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// @dev Freezes, pays everyone and rolls the round over — the way a keeper actually turns a round.
    function _turnRound(SharesHarness harness, address[] memory holders) internal {
        skip(harness.MIN_ROUND_DURATION() + 1);
        harness.processRound(0, holders);
    }

    receive() external payable {}

    ///////////////////////// the accounting identity /////////////////////////

    /// @dev `roundTotalShares == Σ dividendShares(a)`. Everything else in the module — that a pot can
    ///      never over-distribute, that a mid-round buyer earns nothing — is downstream of this. A drift
    ///      high silently under-distributes; a drift low over-distributes and drains the pot early.
    function test_denominatorEqualsSumOfShares_afterTransfers() public {
        _nativeRound();
        assertEq(h.roundTotalShares(), h.sumOfShares(), "identity holds at round open");

        h.transfer(alice, bob, SUPPLY / 10);
        assertEq(h.roundTotalShares(), h.sumOfShares(), "after a transfer between two holders");

        h.transfer(bob, makeAddr("newcomer"), SUPPLY / 20);
        assertEq(h.roundTotalShares(), h.sumOfShares(), "after a transfer to a fresh address");

        h.transfer(carol, alice, SUPPLY / 4);
        assertEq(h.roundTotalShares(), h.sumOfShares(), "after a holder empties out");
    }

    /// @dev The same identity under an arbitrary transfer sequence. This is the property the hand-written
    ///      cases above only sample.
    function testFuzz_denominatorEqualsSumOfShares(uint256[8] calldata seeds, uint96[8] calldata amounts) public {
        _nativeRound();

        address[4] memory actors = [alice, bob, carol, makeAddr("dave")];
        for (uint256 i; i < seeds.length; ++i) {
            address from = actors[seeds[i] % actors.length];
            address to = actors[(seeds[i] / 7 + 1) % actors.length];
            if (from == to) continue;
            uint256 balance = h.balances(from);
            if (balance == 0) continue;
            h.transfer(from, to, bound(uint256(amounts[i]), 1, balance));
            assertEq(h.roundTotalShares(), h.sumOfShares(), "identity holds after every transfer");
        }
    }

    /// @dev The identity must survive a round boundary too: `_openDividendRound` reseeds the denominator
    ///      from live balances, and every stale `Acct.roundId` has to fall back to the live balance.
    function test_denominatorEqualsSumOfShares_acrossARoundBoundary() public {
        _nativeRound();
        h.transfer(alice, bob, SUPPLY / 10);

        // A round rolls over when its pot has been paid out, which is the only way it ever rolls.
        _fund(1 ether);
        address[] memory everyone = new address[](3);
        (everyone[0], everyone[1], everyone[2]) = (alice, bob, carol);
        _turnRound(h, everyone);

        assertEq(h.currentRound(), 2, "next round open");
        assertEq(h.roundTotalShares(), h.sumOfShares(), "identity re-established on the new round");
    }

    /// @dev An excluded address contributes nothing to the denominator and is never paid, and the two
    ///      halves of that statement come from two separately-written functions in the token
    ///      (`_dividendExcluded` and `_dividendEligibleSupply`). They have to agree.
    function test_excludedAddressNeitherCountsNorEarns() public {
        h.exclude(0, carol);
        _nativeRound();
        // `seed` counts everyone, so drop the excluded balance the way the token's eligible-supply
        // accessor does, then reopen.
        h.transfer(carol, alice, SUPPLY / 4);

        assertEq(h.dividendShares(carol), 0, "an excluded address has no weight");

        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        address[] memory batch = new address[](1);
        batch[0] = carol;
        h.processRound(0, batch);
        assertEq(carol.balance, 0, "an excluded address is never paid");
    }

    ///////////////////////// the frozen denominator /////////////////////////

    /// @dev The denominator is snapshotted on the FIRST freeze of a round and reused by any leg that
    ///      freezes later in the same round. Re-snapshotting would shrink it under a partially-paid pot
    ///      and over-distribute that pot.
    function test_denominatorFrozenAtFirstFreeze_notResnapshotted() public {
        SharesHarness split = new SharesHarness();
        split.configure(address(0));
        split.seed(alice, SUPPLY);
        split.openRound();

        vm.deal(address(this), 1 ether);
        split.accrue{value: 1 ether}();
        skip(split.MIN_ROUND_DURATION() + 1);
        split.processRound(0, _noHolders());

        uint96 frozen = split.frozenShares();
        assertEq(frozen, SUPPLY, "denominator frozen at the opening total");

        // Alice dumps everything AFTER the freeze. The live denominator collapses; the frozen one must
        // not follow it, or her already-frozen pot would be divided by a smaller number.
        split.transfer(alice, bob, SUPPLY);
        assertLt(split.roundTotalShares(), frozen, "the live denominator did fall");
        assertEq(split.frozenShares(), frozen, "the frozen denominator did not");
    }

    /// @dev With a zero denominator nothing is payable, and in particular nothing divides by it. The
    ///      argument that this is unreachable is subtle enough to be worth a test rather than a comment.
    function test_zeroDenominatorIsNotPayable() public {
        h.seed(alice, SUPPLY);
        h.openRound();
        _fund(1 ether);
        // Alice empties out before any freeze, so every tracked minimum — and the denominator — is 0.
        h.transfer(alice, bob, SUPPLY);
        assertEq(h.roundTotalShares(), 0, "denominator collapsed to zero");

        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        address[] memory batch = new address[](2);
        batch[0] = alice;
        batch[1] = bob;
        h.processRound(0, batch); // must not panic on a division by zero
        assertEq(h.roundPaid(), 0, "nothing paid out against a zero denominator");
    }

    ///////////////////////// the threshold and its bypass /////////////////////////

    /// @dev Below the threshold the buffer keeps accruing rather than freezing a pot not worth its gas.
    function test_subThresholdBufferDoesNotFreeze() public {
        _nativeRound();
        _fund(h.DIVIDEND_THRESHOLD() / 2);
        skip(h.MIN_ROUND_DURATION() + 1);

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processRound(0, _noHolders());
    }

    /// @dev Staleness is the ONLY escape from the threshold: a round nobody has rolled over for
    ///      `STALE_ROUND_WINDOW` belongs to a dead token, so the threshold stops applying and the
    ///      residual can finally be paid instead of stranding. Reaching it costs 30 days of a
    ///      completely idle token, which is what stops the bypass being a free round-stall for anyone
    ///      who can push a wei into the buffer.
    function test_thresholdBypassedOnceTheRoundGoesStale() public {
        _nativeRound();
        uint256 dust = h.DIVIDEND_THRESHOLD() / 2;
        _fund(dust);
        skip(h.MIN_ROUND_DURATION() + 1);

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processRound(0, _noHolders());

        skip(h.STALE_ROUND_WINDOW());
        h.processRound(0, _noHolders());

        assertEq(h.roundPot(), dust, "the residual froze once the round went stale");
        assertEq(h.pendingNative(), 0, "buffer drained");
    }

    /// @dev The bypass must stay shut for a token that is merely QUIET. `roundOpenedAt` resets on every
    ///      rollover, so a token still turning over rounds never ages into it however small its buffer —
    ///      otherwise every live token would start freezing dust pots and stalling on them.
    function test_staleBypassStaysShutWhileRoundsKeepRollingOver() public {
        _nativeRound();
        address[] memory everyone = new address[](3);
        (everyone[0], everyone[1], everyone[2]) = (alice, bob, carol);

        // Well past the stale window in absolute time, but each round earns enough to be turned over.
        for (uint256 i; i < 3; ++i) {
            skip(h.STALE_ROUND_WINDOW() / 2);
            _fund(1 ether);
            _turnRound(h, everyone);
        }

        _fund(h.DIVIDEND_THRESHOLD() / 2);
        skip(h.MIN_ROUND_DURATION() + 1);
        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processRound(0, _noHolders());
    }

    /// @dev A round that has gone stale with NOTHING buffered rolls over instead of reverting. It is the
    ///      only call with nothing to freeze that is worth its gas: without it a token that stops earning
    ///      would keep one round open forever, and every holder's share would be their low-water mark
    ///      over that unbounded span.
    function test_anEmptyStaleRoundRollsOverInsteadOfReverting() public {
        _nativeRound();
        skip(h.MIN_ROUND_DURATION() + 1);

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processRound(0, _noHolders());

        skip(h.STALE_ROUND_WINDOW());
        h.processRound(0, _noHolders());

        assertEq(h.currentRound(), 2, "the stale round rolled over");
        assertEq(h.roundTotalShares(), h.sumOfShares(), "and reseeded its denominator");
    }

    ///////////////////////// the single entry point /////////////////////////

    /// @dev The whole point of collapsing freeze / pay / roll-over into one function: a keeper whose
    ///      holder list does not fit in one block just calls it again. The freeze happens once, the
    ///      rollover happens once, and the calls in between are pure payout batches — no separate
    ///      transactions to sequence and none to forget.
    function test_oneEntryPointFreezesOncePaysInBatchesAndRollsOnce() public {
        _nativeRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);

        // Batch 1 freezes and pays alice.
        h.processRound(0, _batch(alice));
        uint256 pot = h.roundPot();
        assertTrue(h.roundFrozen(), "the first call froze the round");
        assertEq(h.currentRound(), 1, "and did not roll it over with holders still owed");
        assertEq(alice.balance, pot / 2, "alice paid in the first batch");

        // Batch 2 skips the freeze entirely and pays the rest, which settles and rolls the round.
        h.processRound(0, _batch(bob));
        assertEq(h.currentRound(), 1, "carol is still owed, so the round stays open");
        h.processRound(0, _batch(carol));

        assertEq(bob.balance + carol.balance, pot / 2, "the remaining two split the other half");
        assertEq(h.currentRound(), 2, "draining the pot rolled the round over, in the last batch");
        assertEq(address(h).balance, 0, "and the pot went out exactly once");
    }

    /// @dev Freezing and paying in ONE transaction is what the merge relies on, and it is safe for a
    ///      reason that has nothing to do with transaction boundaries: receiving borrowed tokens is
    ///      itself a tracked balance change, so the borrower's minimum for the round is zero however the
    ///      rest of the call is arranged. Nothing the flash loan can do inside this call changes that.
    function test_aFlashLoanedBalanceEarnsNothingEvenWhenTheFreezeAndThePayoutShareATransaction() public {
        _nativeRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);

        address borrower = makeAddr("borrower");
        h.transfer(alice, borrower, SUPPLY / 2); // the "loan" lands mid-round

        address[] memory batch = new address[](2);
        batch[0] = borrower;
        batch[1] = bob;
        h.processRound(0, batch);

        assertEq(borrower.balance, 0, "a mid-round arrival is owed nothing, in the same tx as the freeze");
        assertGt(bob.balance, 0, "while a holder who was there at the open is paid");
    }

    ///////////////////////// payout-path safety /////////////////////////

    /// @dev One holder whose `receive()` reverts must not brick the batch: the others are paid, the
    ///      failed amount stays in the pot, and the holder is left UNMARKED so a later batch retries.
    function test_revertingHolderIsSkippedNotReverted() public {
        address rejecting = address(new RejectingHolder());
        h.seed(rejecting, SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.openRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        address[] memory batch = new address[](2);
        batch[0] = rejecting;
        batch[1] = bob;
        h.processRound(0, batch);

        assertEq(rejecting.balance, 0, "the rejecting holder got nothing");
        assertEq(bob.balance, h.roundPot() / 2, "the healthy holder was still paid in the same batch");
        assertEq(h.roundPaid(), h.roundPot() / 2, "only the delivered half counts as paid");
        assertGt(h.previewDividend(rejecting), 0, "left unmarked, so a later batch can retry");
    }

    /// @dev The same protection, without an explicit revert: a holder that simply burns more than
    ///      `NATIVE_PAYOUT_GAS` fails on the stipend. Without the cap it would consume the batch's gas.
    function test_gasGuzzlingHolderCannotGriefTheBatch() public {
        address guzzler = address(new GasGuzzlingHolder());
        h.seed(guzzler, SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.openRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        address[] memory batch = new address[](2);
        batch[0] = guzzler;
        batch[1] = bob;
        h.processRound(0, batch);

        assertEq(guzzler.balance, 0, "the stipend was not enough for the guzzler, so its send failed");
        assertEq(bob.balance, h.roundPot() / 2, "and the healthy holder was still paid");
    }

    /// @dev The other half of the stipend's contract. Capping the batch is only acceptable because the
    ///      holder it skips is not locked out: `claimRound` forwards all remaining gas, because it has no
    ///      batch to protect and the caller is spending their own. Without this the stipend would be a
    ///      permanent eligibility gate — a wallet costing more than `NATIVE_PAYOUT_GAS` could never be
    ///      paid, in this round or any other, and its share would roll forward forever.
    function test_gasGuzzlingHolderCanStillClaimItself() public {
        address guzzler = address(new GasGuzzlingHolder());
        h.seed(guzzler, SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.openRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        address[] memory batch = new address[](1);
        batch[0] = guzzler;
        h.processRound(0, batch);
        assertEq(guzzler.balance, 0, "skipped by the batch, as the stipend intends");

        vm.prank(guzzler);
        h.claimRound();

        assertEq(guzzler.balance, h.roundPot() / 2, "but paid in full when it claims for itself");
    }

    /// @dev A payee reentering `processRound` from `receive()` must be stopped by the transient
    ///      guard. Without it the attacker would be paid its share, reenter before `roundPaid` is
    ///      settled, and be paid it a second time out of the same pot.
    function test_reentrantDistributeCannotDoublePay() public {
        ReenteringHolder attacker = new ReenteringHolder(h);
        h.seed(address(attacker), SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.openRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        uint256 pot = h.roundPot();
        address[] memory batch = new address[](2);
        batch[0] = address(attacker);
        batch[1] = bob;
        h.processRound(0, batch);

        assertEq(attacker.blockedReentries(), 1, "the reentrant call was refused by the guard");
        assertEq(address(attacker).balance, pot / 2, "the attacker got its honest half, once");
        assertEq(bob.balance, pot / 2, "and the other half went where it was owed");
        assertEq(address(h).balance, 0, "the pot settled to exactly its size, not more");
    }

    /// @dev Same via `claimRound`, the self-serve backstop — it shares the guard for the same reason.
    function test_reentrantClaimCannotDoublePay() public {
        ReenteringHolder attacker = new ReenteringHolder(h);
        attacker.setUseClaim(true);
        h.seed(address(attacker), SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.openRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        uint256 pot = h.roundPot();
        h.processRound(0, _batch(address(attacker)));

        assertEq(attacker.blockedReentries(), 1, "the reentrant claim was refused");
        assertEq(address(attacker).balance, pot / 2, "paid once, for its own share only");
        assertLe(h.roundPaid(), pot, "the pot is never over-drawn");
    }

    /// @dev Solvency, stated directly: whatever the batch composition, the sum pushed out never exceeds
    ///      the frozen pot. Duplicates in the batch are the interesting case — each must pay once.
    function test_duplicatesInABatchCannotOverDrawThePot() public {
        _nativeRound();
        _fund(1 ether);
        skip(h.MIN_ROUND_DURATION() + 1);
        h.processRound(0, _noHolders());

        uint256 pot = h.roundPot();
        address[] memory batch = new address[](6);
        batch[0] = alice;
        batch[1] = alice;
        batch[2] = bob;
        batch[3] = bob;
        batch[4] = carol;
        batch[5] = alice;
        h.processRound(0, batch);

        assertEq(alice.balance + bob.balance + carol.balance, pot, "duplicates cannot over-draw");
        assertEq(alice.balance, pot / 2, "alice paid exactly once");
        assertEq(bob.balance, pot / 4, "bob paid exactly once");
    }
}
