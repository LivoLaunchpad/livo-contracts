// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet}.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";

/// @title DividendDistribution
/// @notice Trustless, push-based holder dividends for a Livo token: ONE payout asset, paid out of
///         post-graduation earnings, with a share basis no caller can manipulate.
///
/// @dev THE RULE, and the reason everything else is small:
///
///          Your share of a round is the MINIMUM balance you held at any point during that round.
///
///      A round spans the time between two distributions. An account that starts a round at zero has a
///      minimum of zero for that whole round, so a flash loan — or any mid-round buy — earns nothing, and
///      no age gate, snapshot service or trusted ticker is needed to say so. The denominator
///      (`roundTotalShares`) is decremented whenever a stored minimum falls, which is what makes a
///      borrow that inflates eligible supply at the instant a round opens self-correct inside the
///      attacking transaction when it is repaid.
///
/// @dev ONE ASSET PER TOKEN, chosen at creation and permanent: native (`address(0)`), the token itself
///      (`DIVIDEND_SELF_TOKEN`), or any ERC20 with a deep enough Uniswap V2 pair. There is no whitelist
///      and no per-asset approval — what makes an ERC20 eligible is the liquidity `DIVIDEND_SWAP_REGISTRY`
///      measures at creation, nothing else.
///
/// @dev NO HOLDER SET. The contract never enumerates holders. `processRound(minOut, address[])` takes
///      the list from the caller and computes each amount itself, so the call is idempotent and
///      unforgeable: a duplicate pays 0, a wrong address pays 0, an omission is simply paid next round.
///      The keeper sources the list from the indexer.
///
/// @dev THE HOT PATH IS THE WHOLE COST. Per account, per round: one SSTORE on the first balance change,
///      one more whenever the running minimum drops. Increases after the first touch write nothing (a
///      minimum never rises). Excluded addresses — crucially the `pair`, counterparty of every trade —
///      are never tracked at all, so a buy or a sell touches ONE account slot, not two.
///
/// @dev ⚠️ Any future change that lets a balance INCREASE raise a holder's weight within the round it
///      happened in reintroduces just-in-time capture. The whole design rests on minima only falling.
///
/// @dev Asset-agnostic: the payout may be native, the token itself, or a third ERC20, and the accounting
///      never knows the difference.
abstract contract DividendDistribution {
    /// @notice Minimum accrued native amount the buffer must hold before a round may be frozen.
    ///         Bypassed only once the round has gone `STALE_ROUND_WINDOW` without rolling over, so a
    ///         sub-threshold residual on a dead token is not stranded in the buffer forever.
    uint256 public constant DIVIDEND_THRESHOLD = DeploymentAddresses.DIVIDEND_THRESHOLD;

    /// @notice Max native a token may convert in ONE freeze. `processRound` is permissionless and takes
    ///         its slippage floor from the caller, so an unbounded conversion lets anyone sandwich their
    ///         own freeze and skim the round's whole pot; what bounds the skim is swap size against pool
    ///         depth. Deliberately the SAME constant `processBurn` and `processLiquidity` cap with, for
    ///         the same reason and on the same scale — roughly 3–11% of a graduated pool across the
    ///         liquidity tiers.
    /// @dev Necessarily >= `DIVIDEND_THRESHOLD`: a cap below the floor would leave a token that
    ///      qualifies to freeze unable to convert what qualified it. The remainder above the cap stays
    ///      buffered and freezes in a later round, so nothing is stranded — at an hourly keeper cadence
    ///      this clears ~24x the cap per day, orders of magnitude above what any graduated pool can
    ///      generate in earnings.
    uint256 public constant MAX_DIVIDEND_PER_FREEZE = DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

    /// @notice Minimum age of a round before it may be frozen.
    /// @dev This exists for exactly one reason: rolling a round over is permissionless, so an attacker
    ///      controls the moment a round OPENS — the single instant at which a balance counts. Without a
    ///      floor, open -> freeze -> pay itself all fit in one transaction, and the denominator's
    ///      self-correction (which happens on repayment) arrives after the money has already gone out.
    ///      Any non-zero floor kills that, because a flash loan cannot span two blocks.
    /// @dev Deliberately SMALL. It is an anti-flash-loan floor, not an anti-whale one, and sizing it in
    ///      days would rule out fast payout cadences for no security gain: a position held across it is
    ///      a real, unhedged position on a volatile token, whether that is 15 minutes or a week. The
    ///      economic gate on how often a round can actually pay is `DIVIDEND_THRESHOLD`, not this.
    uint256 public constant MIN_ROUND_DURATION = 15 minutes;

    /// @notice Deadline after which a frozen round may be rolled over even though its pot is NOT paid
    ///         out. Purely a liveness escape hatch, and only reachable when the normal path cannot be:
    ///         a round rolls as soon as its pot is paid down to dust, so a healthy round never waits for
    ///         this.
    /// @dev What it protects against is a round whose remainder can never be delivered — a holder whose
    ///      `receive()` reverts, an address that cannot be paid, rounding that leaves more than the dust
    ///      tolerance. Without a timeout the round would never roll and the token's dividends would
    ///      freeze permanently; with it, the undeliverable remainder simply rolls into the next round's
    ///      pot. Nothing is lost either way — a holder skipped in one round keeps their weight in the
    ///      next.
    /// @dev Sized as "generously more than a keeper needs to push every holder" and no more: a longer
    ///      window only lengthens how long a stuck round blocks the next one.
    uint256 public constant PAYOUT_WINDOW = 1 days;

    /// @notice Age at which an unfrozen round is treated as belonging to a DEAD token. Two things
    ///         unlock there, both of them last resorts: freezing below `DIVIDEND_THRESHOLD`, and — if
    ///         the conversion cannot happen at any price — falling back to paying native.
    /// @dev Anchored on `roundOpenedAt`, which a healthy token resets on every rollover — so a token
    ///      that is merely quiet never comes near this, and the threshold keeps behaving exactly as it
    ///      does today. Only a token nobody is trading OR finalizing ages into it.
    /// @dev Sized as "unambiguously dead", not "quiet". It is the counterweight to the one thing an open
    ///      bypass costs: freezing a dust pot stalls settlement for `PAYOUT_WINDOW`, because every
    ///      holder's share of it rounds to zero and the round cannot settle until that expires. At this
    ///      window that trade is 30 days of waiting to buy one day of stall, on a token with nothing
    ///      flowing through it — and a rollover resets the clock, so it cannot be repeated cheaply.
    uint256 public constant STALE_ROUND_WINDOW = 30 days;

    /// @notice Gas stipend for a native payout inside a KEEPER BATCH. Bounded so one holder with an
    ///         expensive (or reverting) `receive()` cannot brick or grief the rest of the batch; a plain
    ///         `receive()` and the common smart-account fallbacks fit comfortably.
    /// @dev Per-chain, because what a holder's wallet costs to pay is a property of the chain's wallet
    ///      population and not of this protocol — a future chain can raise it without a code change.
    /// @dev This is a batch-throughput knob, NOT an eligibility gate. A holder whose fallback needs more
    ///      than this is skipped by the batch but can still be paid in full through `claimRound()`,
    ///      which forwards all remaining gas because it has no batch to protect and the caller is
    ///      spending their own gas. Without that escape hatch a stipend set too low for some wallet
    ///      would lock those holders out of every round, permanently.
    uint256 public constant NATIVE_PAYOUT_GAS = DeploymentAddresses.NATIVE_PAYOUT_GAS;

    /// @notice Relative dust floor. A holder whose share of `frozenShares` is below `1 / MIN_SHARE_DENOM`
    ///         is skipped. Relative rather than absolute so it needs no per-asset decimals handling.
    uint256 internal constant MIN_SHARE_DENOM = 1_000_000;

    /// @notice Pass this as the payout asset to mean "the token itself". A creator configuring a token
    ///         cannot name its own address — it does not exist yet at the point the configuration is
    ///         written — so the sentinel is resolved to `address(this)` during initialization.
    address public constant DIVIDEND_SELF_TOKEN = address(type(uint160).max);

    /// @notice The registry that decides whether a third payout asset is eligible, and that performs
    ///         the native -> asset conversion when a round freezes. Uniswap V2 only.
    /// @dev A PROXY, deliberately reached through a compile-time constant rather than a stored address:
    ///      tokens are unpatchable clones, so this is the only seam through which an eligibility rule or
    ///      a swap route can be fixed for tokens that are ALREADY live. Nothing about the asset choice
    ///      is curated behind it — see `ILivoDividendSwapRegistry`.
    /// @dev Exposed so an off-chain keeper can price its slippage floor against the exact pool the swap
    ///      will cross (`registry.pairFor`), which is what `minOut` has to be computed from.
    address public constant DIVIDEND_SWAP_REGISTRY = DeploymentAddresses.DIVIDEND_SWAP_REGISTRY;

    /// @notice Per-account dividend state. One slot, and the only per-account storage the feature has.
    /// @dev `minShares` is the running minimum for `roundId`. It is only meaningful while
    ///      `roundId == currentRound`; for a stale `roundId` the account has not moved this round, so its
    ///      CURRENT balance is exactly its balance at the round's open and is used instead — an exact
    ///      fallback, not an approximation. Total supply is below 2**90, so `uint192` is ample.
    struct Acct {
        uint32 roundId;
        uint32 lastPaidRound;
        uint192 minShares;
    }

    /// @notice Per-account round minimum + paid marker. See `Acct`.
    mapping(address account => Acct) public dividendAccounts;

    /// @notice Sum of every tracked account's `minShares` for the OPEN round. Seeded at round open as
    ///         `totalSupply - Σ excluded balances` and decremented whenever a stored minimum falls, so
    ///         `roundTotalShares == Σ minShares(a)` holds exactly and a pot distributes with no
    ///         systematic leakage.
    /// @dev Packed with `frozenShares` and `currentRound`: the hot path touches this ONE global slot.
    uint96 public roundTotalShares;

    /// @notice `roundTotalShares` as of the moment the round was frozen — the denominator every payout
    ///         of this round divides by. Frozen while individual minima can still only fall, which is
    ///         exactly why `Σ payouts <= roundPot` by construction.
    uint96 public frozenShares;

    /// @notice Monotonic round counter. 0 until the token graduates (the first round opens there),
    ///         which also makes `Acct.roundId == 0` an unambiguous "never touched".
    uint32 public currentRound;

    /// @notice The payout asset. `address(0)` = native, `address(this)` = the token itself, anything
    ///         else = a third ERC20 bought through `DIVIDEND_SWAP_REGISTRY`.
    /// @dev Not immutable and not a constant: tokens are clones. It is written once at creation and
    ///      only ever rewritten by the dead-pool fallback, which downgrades a third asset to native
    ///      when its pool has become unreachable (see `DividendDistributionLogic._freezeDividends`).
    address public dividendToken;

    /// @notice Native earnings accrued so far, awaiting a freeze. Sized to FILL the slot it shares with
    ///         the asset it is waiting to buy — 160 + 88 + 8 = exactly 256 bits — so the accrual stays a
    ///         single SSTORE and the headroom is whatever the slot had left rather than a round number.
    /// @dev ≈309M units of the chain's native currency. The width matters because "native" is not ETH
    ///      everywhere: on ARC it is 18-dec USDC, where `uint80` would cap the buffer at ~1.2M USDC —
    ///      large, but a dollar figure a token could conceivably reach, unlike 1.2M ETH. The spare byte
    ///      was already in the slot, so putting it out of reach costs nothing.
    uint88 public pendingNative;

    /// @notice Whether the open round's pot is fixed and payable.
    bool public roundFrozen;

    /// @notice When the open round started. Anchors `MIN_ROUND_DURATION` and `STALE_ROUND_WINDOW`.
    uint40 public roundOpenedAt;

    /// @notice When the open round was frozen (0 if not yet). Anchors `PAYOUT_WINDOW`.
    uint40 public roundClosedAt;

    /// @notice Set once the payout pool has been proven unreachable at any price and a freeze has
    ///         drained an earlier round's residual in the OLD asset. Stands in for `STALE_ROUND_WINDOW`
    ///         until the downgrade completes, so the asset falls back to native on the FOLLOWING round —
    ///         which is what the drain exists for — instead of after a second full stale window during
    ///         which every `processRound` call reverts `DividendConversionFailed`.
    /// @dev Packs into the `roundOpenedAt` / `roundClosedAt` slot, which the freeze already touches.
    ///      Cleared by whichever outcome ends the sequence: the downgrade, or a conversion that starts
    ///      working again.
    bool public dividendPoolDead;

    /// @notice The frozen pot for the open round, plus whatever earlier rounds left unpaid.
    uint256 public roundPot;

    /// @notice How much of the frozen `roundPot` has actually been pushed out this round.
    uint256 public roundPaid;

    /// @dev Reentrancy guard for every dividend entry point that makes an external call: the payouts,
    ///      which send to arbitrary addresses, and the freeze, which swaps through the venue. One lock
    ///      covers both because they are not independent — a freeze reentered mid-swap sets `roundFrozen`
    ///      under the outer call, which then overwrites it, leaving a funded pot unpayable. Transient,
    ///      so it costs no SSTORE and is independent of any guard the concrete token already uses.
    bool private transient dividendLocked;

    /// @dev Taken once per external call rather than once per holder, so a large batch pays for a single
    ///      transient write instead of one per address.
    modifier nonReentrantDividends() {
        require(!dividendLocked, DividendReentrancy());
        dividendLocked = true;
        _;
        dividendLocked = false;
    }

    //////////////////////// Events //////////////////////

    /// @notice Emitted once at creation for a token configured with a non-zero dividends allocation.
    event DividendsInitialized(address dividendToken);

    /// @notice A new round opened. `totalShares` is the authoritative opening denominator — an indexer
    ///         replicating the share accounting must seed from this, never compute it independently.
    event DividendRoundOpened(uint32 indexed roundId, uint256 totalShares);

    /// @notice The round's pot was frozen. `nativeIn` is the native buffer consumed (0 for the V2
    ///         token-space payout), `assetOut` the payable pot including any residual carried forward.
    ///         `totalShares` is the authoritative frozen denominator, and the reconciliation point for
    ///         any off-chain replica of the share accounting.
    event DividendRoundFunded(
        uint32 indexed roundId, address indexed asset, uint256 nativeIn, uint256 assetOut, uint256 totalShares
    );

    /// @notice One holder, one round.
    event DividendPaid(uint32 indexed roundId, address indexed holder, address indexed asset, uint256 amount);

    /// @notice The round rolled over. `residualRolled` is what stayed unpaid and now seeds the next
    ///         round's pot.
    event DividendRoundFinalized(uint32 indexed roundId, uint256 residualRolled);

    /// @notice The configured pool became unreachable at any price and the payout asset was permanently
    ///         downgraded to native. Only reachable on a token whose round has gone `STALE_ROUND_WINDOW`
    ///         without rolling over — the alternative is a buffer nobody can ever be paid out of.
    event DividendAssetDowngradedToNative(address indexed previousAsset);

    //////////////////////// Errors //////////////////////

    error DividendsNotActive();
    error RoundTooYoung();
    /// @notice The buffer is not yet worth a distribution. Distinct from `DividendConversionFailed`:
    ///         this one means wait for more earnings, that one means the earnings are there and the
    ///         swap is the problem.
    error BelowDividendThreshold();
    /// @notice The buffer was fundable and the conversion failed, so the round froze nothing.
    error DividendConversionFailed();
    error DividendBufferOverflow();
    /// @notice The named payout asset is not eligible. Carries the registry's own reason — no V2 pair,
    ///         not enough depth, blacklisted — so a creator learns which gate they failed rather than
    ///         just that they failed one. The whole of the payout-asset eligibility rule.
    error DividendAssetNotSupported(SwapRejection rejection);
    error DividendReentrancy();

    //////////////////////// hot path //////////////////////

    /// @dev Records the effect of a balance change on both sides' round minima. Called from the token's
    ///      `_update`, BEFORE the balances move, and only for tokens that opted into dividends.
    function _trackDividendShares(address from, address to, uint256 amount) internal {
        uint32 round = currentRound;
        // Round 0 = pre-graduation. No earnings can be routed to dividends yet, and the first real round
        // opens at graduation, so there is nothing to track.
        if (round == 0) return;

        if (from != address(0) && !_dividendExcluded(from)) {
            uint256 balanceBefore = _dividendBalanceOf(from);
            // Clamped, not unchecked: this runs BEFORE `_update` validates the balance, so an
            // over-balance transfer would panic here and lose the `ERC20InsufficientBalance` that
            // wallets, routers and aggregators decode. The revert still comes from `super._update`.
            uint256 balanceAfter = balanceBefore > amount ? balanceBefore - amount : 0;
            _trackOne(from, round, balanceBefore, balanceAfter);
        }
        if (to != address(0) && !_dividendExcluded(to)) {
            uint256 balanceBefore = _dividendBalanceOf(to);
            _trackOne(to, round, balanceBefore, balanceBefore + amount);
        }
    }

    /// @dev One account's minimum for the open round.
    ///
    ///      | case                                            | writes                              |
    ///      |-------------------------------------------------|-------------------------------------|
    ///      | first change of the round, an increase           | account slot only                   |
    ///      | first change of the round, a decrease            | account slot + the denominator      |
    ///      | later decrease below the running minimum        | account slot + the denominator      |
    ///      | any increase after the first touch              | none — a minimum never rises        |
    ///      | any decrease not below the running minimum      | none                                |
    ///
    /// @dev ⚠️ The first touch and the first drop COLLAPSE into a single account write, but that is an
    ///      account-slot optimisation only: `roundTotalShares` must still be decremented whenever the
    ///      stored minimum falls below the balance the round opened with. Swallowing that update would
    ///      leave `roundTotalShares > Σ minShares` and every round would silently under-distribute.
    function _trackOne(address account, uint32 round, uint256 balanceBefore, uint256 balanceAfter) private {
        Acct storage acct = dividendAccounts[account];
        if (acct.roundId != round) {
            uint256 newMin = balanceBefore < balanceAfter ? balanceBefore : balanceAfter;
            acct.roundId = round;
            // Balances are bounded by total supply (< 2**90).
            // forge-lint: disable-next-line(unsafe-typecast)
            acct.minShares = uint192(newMin);
            if (newMin < balanceBefore) _reduceRoundShares(balanceBefore - newMin);
        } else {
            uint256 prevMin = acct.minShares;
            if (balanceAfter < prevMin) {
                // forge-lint: disable-next-line(unsafe-typecast)
                acct.minShares = uint192(balanceAfter);
                _reduceRoundShares(prevMin - balanceAfter);
            }
        }
    }

    /// @dev Saturating on purpose. The exclusion set is fixed at compile time and the arithmetic above
    ///      cannot underflow it — but this runs inside every transfer of a non-upgradeable clone, so an
    ///      address that somehow escapes the set must degrade into under-distribution (which rolls into
    ///      the next round) rather than into a token whose transfers revert forever.
    function _reduceRoundShares(uint256 drop) private {
        uint96 total = roundTotalShares;
        // The ternary keeps the subtraction non-negative, and `total` is already a uint96.
        // forge-lint: disable-next-line(unsafe-typecast)
        roundTotalShares = drop >= total ? 0 : uint96(total - drop);
    }

    //////////////////////// accrual //////////////////////

    /// @dev Buffers `amount` of native earnings for the payout asset. Consumes the whole amount
    ///      (returns 0) unless the payout is buffered in TOKEN space, in which case it consumes nothing
    ///      and the caller folds it back to the fund wallets — that share was already peeled upstream,
    ///      in token space, before this ETH existed.
    /// @dev Refuses to truncate rather than wrapping. The branch is a bytecode-level assertion, not a
    ///      reachable path — but it is a REVERT on the earnings path, and on V2 that path runs inside a
    ///      sell, so a full buffer would brick sells until someone froze. That consequence is why
    ///      `pendingNative` is sized to fill its slot instead of to the nearest byte boundary.
    function _accrueDividends(uint256 amount) internal returns (uint256 unconsumed) {
        if (amount == 0 || _isTokenSpaceDividendAsset(dividendToken)) return amount;

        uint256 updated = uint256(pendingNative) + amount;
        require(updated <= type(uint88).max, DividendBufferOverflow());
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingNative = uint88(updated);
        return 0;
    }

    //////////////////////// views //////////////////////

    /// @notice A holder's share of the open round: their running minimum if they have moved this round,
    ///         otherwise their current balance (which, not having moved, IS their balance at the open).
    function dividendShares(address holder) public view returns (uint256) {
        if (_dividendExcluded(holder)) return 0;
        Acct storage acct = dividendAccounts[holder];
        return acct.roundId == currentRound ? acct.minShares : _dividendBalanceOf(holder);
    }

    /// @notice What `holder` would receive if the round were paid out right now. 0 unless the round is
    ///         frozen, the holder is above the dust floor, and they have not already been paid.
    function previewDividend(address holder) external view returns (uint256) {
        if (!roundFrozen) return 0;
        if (dividendAccounts[holder].lastPaidRound == currentRound) return 0;
        uint256 denom = frozenShares;
        if (denom == 0) return 0;
        uint256 shares = dividendShares(holder);
        if (shares * MIN_SHARE_DENOM < denom) return 0;
        return roundPot * shares / denom;
    }

    /// @notice Dividend money already committed to holders in `asset` but not yet delivered: the frozen
    ///         pot minus what has been pushed, plus a residual waiting for the next freeze.
    /// @dev THE single source of truth for "how much of this balance is not ours". Every sweep, swap-back
    ///      and rescue path subtracts this rather than open-coding its own subtraction, so a future
    ///      bucket is added in one place and every call site inherits it.
    function committedDividends(address asset) public view returns (uint256) {
        if (dividendToken != asset) return 0;
        return roundPot - roundPaid;
    }

    //////////////////////// internal //////////////////////

    /// @dev Opens the next round and reads a fresh denominator from live balances. The opening total is
    ///      authoritative — the emitted `totalShares` is what any off-chain replica must seed from.
    function _openDividendRound() internal {
        uint32 next = currentRound + 1;
        uint256 total = _dividendEligibleSupply();

        currentRound = next;
        // Total supply is 1e27 < 2**90, so the eligible supply always fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        roundTotalShares = uint96(total);
        frozenShares = 0;
        roundFrozen = false;
        roundOpenedAt = uint40(block.timestamp);
        roundClosedAt = 0;

        emit DividendRoundOpened(next, total);
    }

    //////////////////////// hooks the token supplies //////////////////////

    /// @dev The token's ERC20 balance of `account`.
    function _dividendBalanceOf(address account) internal view virtual returns (uint256);

    /// @dev Addresses that never earn: they hold a balance continuously across rounds but are not
    ///      holders. Everything else transient is excluded for free by the minimum rule.
    function _dividendExcluded(address account) internal view virtual returns (bool);

    /// @dev `totalSupply` minus the balances of every excluded address, read once per round open.
    function _dividendEligibleSupply() internal view virtual returns (uint256);

    /// @dev Whether the payout asset must be buffered in TOKEN space rather than as native. Only the
    ///      Uniswap-V2 self-token payout answers true.
    function _isTokenSpaceDividendAsset(address asset) internal view virtual returns (bool) {
        asset; // silences the unused-parameter warning without naming the arg away in overrides
        return false;
    }
}
