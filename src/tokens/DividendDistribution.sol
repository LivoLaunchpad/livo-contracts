// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DividendRoute, DividendVenue} from "src/types/DividendRoute.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet}.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
// Aliased so the `chain-arc-*` recipe can import-swap it: on ARC the "native" leg is 18-dec native USDC
// and the V2 quote token is its 6-dec ERC-20 alias, so buying a third asset is a two-ERC20 hop.
import {UniswapV2Venue as UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";

/// @title DividendDistribution
/// @notice Trustless, push-based holder dividends for a Livo token: up to three payout assets, paid out
///         of post-graduation earnings, with a share basis no caller can manipulate.
///
/// @dev THE RULE, and the reason everything else is small:
///
///          Your share of a round is the MINIMUM balance you held at any point during that round.
///
///      A round spans the days between two distributions. An account that starts a round at zero has a
///      minimum of zero for that whole round, so a flash loan — or any mid-round buy — earns nothing, and
///      no age gate, snapshot service or trusted ticker is needed to say so. The denominator
///      (`roundTotalShares`) is decremented whenever a stored minimum falls, which is what makes a
///      borrow that inflates eligible supply at the instant a round opens self-correct inside the
///      attacking transaction when it is repaid.
///
/// @dev NO HOLDER SET. The contract never enumerates holders. `distributeDividends(address[])` takes the
///      list from the caller and computes each amount itself, so the call is idempotent and unforgeable:
///      a duplicate pays 0, a wrong address pays 0, an omission is simply paid next round. The keeper
///      sources the list from the indexer.
///
/// @dev THE HOT PATH IS THE WHOLE COST. Per account, per round: one SSTORE on the first balance change,
///      one more whenever the running minimum drops. Increases after the first touch write nothing (a
///      minimum never rises). Excluded addresses — crucially the `pair`, counterparty of every trade —
///      are never tracked at all, so a buy or a sell touches ONE account slot, not two. The cost does
///      NOT grow with the number of payout assets: `minShares` is a property of the holder's balance,
///      not of any asset, so one round and one denominator serve all three pots.
///
/// @dev ⚠️ Any future change that lets a balance INCREASE raise a holder's weight within the round it
///      happened in reintroduces just-in-time capture. The whole design rests on minima only falling.
///
/// @dev Asset-agnostic: a leg may pay native, the token itself, or a third ERC20, and the accounting
///      never knows the difference. Legs ACCRUE on independent cadences — a 10%-weighted leg crosses
///      `DIVIDEND_THRESHOLD` roughly a tenth as often as a 90%-weighted one — but a round FREEZES ONCE:
///      whichever legs qualify at that instant are paid together under a single `lastPaidRound` marker,
///      and a leg that misses simply keeps accruing into a later round. Freezing a second leg mid-round
///      would strand its pot for every holder already marked, and a round is short enough
///      (`MIN_ROUND_DURATION`) that waiting for the next one costs a laggard leg very little.
abstract contract DividendDistribution {
    /// @notice Maximum simultaneous payout assets per token. Fixed: distribution gas is linear in this
    ///         number (one ERC20 transfer per holder per leg), and it is what sets the cost of a round.
    uint256 internal constant MAX_DIVIDEND_ASSETS = 3;

    uint256 internal constant DIVIDEND_BPS_TOTAL = 10_000;

    /// @notice Minimum accrued native amount a leg must hold before `processDividends` may freeze it.
    ///         Bypassed only where no further earnings can ever arrive, so a sub-threshold residual is
    ///         not stranded in the buffer forever — see `_dividendEarningsMayStillArrive`.
    uint256 public constant DIVIDEND_THRESHOLD = DeploymentAddresses.DIVIDEND_THRESHOLD;

    /// @notice Max native a single leg may convert in ONE freeze. `processDividends` is permissionless
    ///         and takes its slippage floor from the caller, so an unbounded conversion lets anyone
    ///         sandwich their own freeze and skim the round's whole pot; what bounds the skim is swap
    ///         size against pool depth. Deliberately the SAME constant `processBurn` and
    ///         `processLiquidity` cap with, for the same reason and on the same scale — roughly 3–11%
    ///         of a graduated pool across the liquidity tiers.
    /// @dev Necessarily >= `DIVIDEND_THRESHOLD`: a cap below the floor would leave a leg that qualifies
    ///      to freeze unable to convert what qualified it. The remainder above the cap stays buffered
    ///      and freezes in a later round, so nothing is stranded — at an hourly keeper cadence this
    ///      clears ~24x the cap per day per leg, orders of magnitude above what any graduated pool can
    ///      generate in earnings.
    uint256 public constant MAX_DIVIDEND_PER_FREEZE = DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

    /// @notice Minimum age of a round before its pots may be frozen, and before an unfrozen round may be
    ///         rolled over.
    /// @dev This exists for exactly one reason: `finalizeRound` is permissionless, so an attacker
    ///      controls the moment a round OPENS — the single instant at which a balance counts. Without a
    ///      floor, open -> freeze -> pay itself all fit in one transaction, and the denominator's
    ///      self-correction (which happens on repayment) arrives after the money has already gone out.
    ///      Any non-zero floor kills that, because a flash loan cannot span two blocks.
    /// @dev Deliberately SMALL. It is an anti-flash-loan floor, not an anti-whale one, and sizing it in
    ///      days would rule out fast payout cadences for no security gain: a position held across it is
    ///      a real, unhedged position on a volatile token, whether that is 15 minutes or a week. The
    ///      economic gate on how often a round can actually pay is `DIVIDEND_THRESHOLD`, not this.
    uint256 public constant MIN_ROUND_DURATION = 15 minutes;

    /// @notice Deadline after which a frozen round may be rolled over even though its pots are NOT paid
    ///         out. Purely a liveness escape hatch, and only reachable when the normal path cannot be:
    ///         `finalizeRound` already succeeds as soon as the pots are paid down to dust, so a healthy
    ///         round never waits for this.
    /// @dev What it protects against is a round whose remainder can never be delivered — a holder whose
    ///      `receive()` reverts, an address that cannot be paid, rounding that leaves more than the dust
    ///      tolerance. Without a timeout `finalizeRound` would revert forever and the token's dividends
    ///      would freeze permanently; with it, the undeliverable remainder simply rolls into the next
    ///      round's pot. Nothing is lost either way — a holder skipped in one round keeps their weight
    ///      in the next.
    /// @dev Sized as "generously more than a keeper needs to push every holder" and no more: a longer
    ///      window only lengthens how long a stuck round blocks the next one.
    uint256 public constant PAYOUT_WINDOW = 1 days;

    /// @notice Age at which an unfrozen round is treated as belonging to a DEAD token, letting a leg
    ///         freeze below `DIVIDEND_THRESHOLD`. The escape hatch for the residual that can no longer
    ///         grow: without it, a token whose earnings stop keeps whatever sits under the threshold
    ///         (0.1 ETH on Ethereum mainnet) buffered for good, owed to holders and unreachable by them.
    /// @dev Anchored on `roundOpenedAt`, which a healthy token resets on every rollover — so a token
    ///      that is merely quiet never comes near this, and the threshold keeps behaving exactly as it
    ///      does today. Only a token nobody is trading OR finalizing ages into it.
    /// @dev Sized as "unambiguously dead", not "quiet". It is the counterweight to the one thing an open
    ///      bypass costs: freezing a dust pot stalls settlement for `PAYOUT_WINDOW`, because every
    ///      holder's share of it rounds to zero and the round cannot settle until that expires. At this
    ///      window that trade is 30 days of waiting to buy one day of stall, on a token with nothing
    ///      flowing through it — and `finalizeRound` resets the clock, so it cannot be repeated cheaply.
    uint256 public constant STALE_ROUND_WINDOW = 30 days;

    /// @notice Gas stipend for a native payout inside a KEEPER BATCH. Bounded so one holder with an
    ///         expensive (or reverting) `receive()` cannot brick or grief the rest of the batch; a plain
    ///         `receive()` and the common smart-account fallbacks fit comfortably.
    /// @dev Per-chain, because what a holder's wallet costs to pay is a property of the chain's wallet
    ///      population and not of this protocol — a future chain can raise it without a code change.
    /// @dev This is a batch-throughput knob, NOT an eligibility gate. A holder whose fallback needs more
    ///      than this is skipped by `distributeDividends` but can still be paid in full through
    ///      `claimRound()`, which forwards all remaining gas because it has no batch to protect and the
    ///      caller is spending their own gas. Without that escape hatch a stipend set too low for some
    ///      wallet would lock those holders out of every round, permanently.
    uint256 public constant NATIVE_PAYOUT_GAS = DeploymentAddresses.NATIVE_PAYOUT_GAS;

    /// @notice Relative dust floor. A holder whose share of `frozenShares` is below `1 / MIN_SHARE_DENOM`
    ///         is skipped. Relative rather than absolute because every leg is proportional to the SAME
    ///         ratio, so one floor filters dust for all three assets with no per-asset decimals handling.
    uint256 internal constant MIN_SHARE_DENOM = 1_000_000;

    /// @notice Sentinel for `tokenSpaceLeg`: no leg is buffered in token space.
    uint8 internal constant NO_TOKEN_SPACE_LEG = type(uint8).max;

    /// @notice Pass this as a payout asset to mean "the token itself". A creator configuring a token
    ///         cannot name its own address — it does not exist yet at the point the configuration is
    ///         written — so the sentinel is resolved to `address(this)` during initialization.
    address public constant DIVIDEND_SELF_TOKEN = address(type(uint160).max);

    /// @notice Router a `UNIV2` third-asset leg's native -> asset conversion goes through. Exposed so the
    ///         off-chain keeper can price its slippage floor against the same pools the swap will cross,
    ///         on BOTH venues (the V4 token has no Uniswap-V2 constant of its own).
    address public constant DIVIDEND_SWAP_ROUTER = DeploymentAddresses.UNIV2_ROUTER;

    /// @notice Router a `UNIV3` / `UNIV4` third-asset leg's conversion goes through. Same purpose as
    ///         `DIVIDEND_SWAP_ROUTER`, for the two venues that are only reachable through it.
    address public constant DIVIDEND_UNIVERSAL_ROUTER = DeploymentAddresses.UNIV4_UNIVERSAL_ROUTER;

    /// @notice Whether this chain's native currency is 18-dec ETH. False on ARC, where "native" is USDC
    ///         and the universal router's native-in swaps therefore do not apply — the reason a `UNIV3` /
    ///         `UNIV4` route is refused there while `UNIV2` (whose venue lib IS chain-swapped) is not.
    bool internal constant NATIVE_IS_ETH = UniswapV2Venue.QUOTE_TO_NATIVE_SCALE == 1;

    /// @notice Registry of protocol-curated `asset -> Uniswap-V2 swap path` entries. Not a gate: a
    ///         creator's own route is what normally funds a leg, and an entry here OVERRIDES it. It
    ///         exists as the repair hatch for a clone whose configured pool has died — without one, that
    ///         leg's buffer would be stranded forever. `address(0)` where it is not deployed.
    address public constant DIVIDEND_ROUTE_REGISTRY = DeploymentAddresses.DIVIDEND_ROUTE_REGISTRY;

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

    /// @notice The payout assets, in leg order. `address(0)` = native, `address(this)` = the token
    ///         itself, anything else = a third ERC20 bought through that leg's `dividendRoutes` entry.
    ///         Left-packed: unused legs are `address(0)` with a zero weight.
    address[3] public dividendTokens;

    /// @notice How each third-asset leg buys its payout asset. One slot per leg, written once at
    ///         creation. Ignored for the native and self-token legs, which have nothing to buy.
    DividendRoute[3] public dividendRoutes;

    /// @notice How the token's `dividendsBps` slice divides across `dividendTokens`. Sums to 10 000,
    ///         left-packed. Read only when earnings are routed or a round is processed — never on a
    ///         transfer.
    uint16[3] public dividendWeightsBps;

    /// @notice Native earnings accrued per leg, awaiting a `processDividends` freeze. Three `uint80`s in
    ///         ONE slot (≈1.2M ETH per leg, far beyond any realistic pot) so the accrual leg stays a
    ///         single SSTORE for all three assets, honouring the `EarningsAllocation` gas budget.
    uint80[3] public pendingNative;

    /// @notice Sum of every tracked account's `minShares` for the OPEN round. Seeded at round open as
    ///         `totalSupply - Σ excluded balances` and decremented whenever a stored minimum falls, so
    ///         `roundTotalShares == Σ minShares(a)` holds exactly and a pot distributes with no
    ///         systematic leakage.
    /// @dev Packed with `frozenShares` and `currentRound`: the hot path touches this ONE global slot.
    uint96 public roundTotalShares;

    /// @notice `roundTotalShares` as of the moment the round's first leg was frozen — the denominator
    ///         every payout of this round divides by. Frozen while individual minima can still only
    ///         fall, which is exactly why `Σ payouts <= roundPot` by construction.
    uint96 public frozenShares;

    /// @notice Monotonic round counter. 0 until the token graduates (the first round opens there),
    ///         which also makes `Acct.roundId == 0` an unambiguous "never touched".
    uint32 public currentRound;

    /// @notice When the open round started. Anchors `MIN_ROUND_DURATION`.
    uint40 public roundOpenedAt;

    /// @notice When the open round's first leg was frozen (0 if none yet). Anchors `PAYOUT_WINDOW`.
    uint40 public roundClosedAt;

    /// @notice Bitmask of legs frozen in the open round, i.e. the legs `distributeDividends` pays.
    ///         Cleared when the round rolls over.
    uint8 public frozenLegs;

    /// @notice The leg whose earnings are buffered in TOKEN space rather than as native, or
    ///         `NO_TOKEN_SPACE_LEG`. Only the Uniswap-V2 self-token leg uses this: a V2 pair reverts
    ///         `INVALID_TO` when asked to deliver a token to its own address, so that leg cannot be
    ///         bought back with ETH and is carved from the tax tokens instead.
    uint8 internal tokenSpaceLeg;

    /// @notice Sum of the weights of the legs that DO accrue as native — the denominator
    ///         `_accrueDividends` renormalises over once the token-space leg (if any) has been peeled
    ///         upstream. 10 000 when every leg is native-buffered.
    uint16 internal nativeWeightTotal;

    /// @notice The frozen pot of each leg for the open round, plus whatever earlier rounds left unpaid.
    ///         A leg not in `frozenLegs` is carrying a residual and is not payable yet.
    uint256[3] public roundPot;

    /// @notice How much of each frozen `roundPot` has actually been pushed out this round.
    uint256[3] public roundPaid;

    /// @dev Reentrancy guard for every dividend entry point that makes an external call: the payouts,
    ///      which send to arbitrary addresses, and the freeze, which swaps through the venue. One lock
    ///      covers both because they are not independent — a freeze reentered mid-swap sets `frozenLegs`
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
    event DividendsInitialized(address[3] dividendTokens, uint16[3] weightsBps);

    /// @notice A new round opened. `totalShares` is the authoritative opening denominator — an indexer
    ///         replicating the share accounting must seed from this, never compute it independently.
    event DividendRoundOpened(uint32 indexed roundId, uint256 totalShares);

    /// @notice A leg's pot was frozen for `roundId`. `nativeIn` is the native buffer consumed (0 for the
    ///         V2 token-space leg), `assetOut` the payable pot including any residual carried forward.
    ///         `totalShares` is the authoritative frozen denominator, and the reconciliation point for
    ///         any off-chain replica of the share accounting.
    event DividendRoundFunded(
        uint32 indexed roundId, address indexed asset, uint256 nativeIn, uint256 assetOut, uint256 totalShares
    );

    /// @notice One holder, one asset, one round.
    event DividendPaid(uint32 indexed roundId, address indexed holder, address indexed asset, uint256 amount);

    /// @notice The round rolled over. `residualRolled` is the sum, across legs, of what stayed unpaid and
    ///         now seeds the next round's pots (mixed units; per-asset detail comes from the funded/paid
    ///         events).
    event DividendRoundFinalized(uint32 indexed roundId, uint256 residualRolled);

    /// @notice A leg held enough to freeze but its conversion did not happen, so it stays unfrozen and
    ///         keeps accruing. The ONLY actionable one of the three ways a leg can decline to freeze —
    ///         an empty buffer and a below-threshold buffer are the normal quiet path and are silent, so
    ///         this firing always means something a keeper can act on: retry with a different `minOut`,
    ///         or, if it persists, the leg's pool is dead and needs a `SwapRouteRegistry` entry.
    event DividendLegConversionFailed(uint32 indexed roundId, uint256 indexed leg, address indexed asset);

    //////////////////////// Errors //////////////////////

    error InvalidDividendConfig();
    error DividendsNotActive();
    error RoundTooYoung();
    /// @notice No leg held enough to freeze. Distinct from `DividendConversionFailed`: this one means
    ///         wait for more earnings, that one means the earnings are there and the swap is the problem.
    error NoLegAboveThreshold();
    /// @notice At least one leg was fundable, but every leg that tried failed to convert, so the round
    ///         froze nothing. See the `DividendLegConversionFailed` events in the same call for which.
    error DividendConversionFailed();
    error RoundAlreadyFrozen();
    error NoFrozenRound();
    error PayoutWindowOpen();
    error DividendBufferOverflow();
    error UnsupportedDividendAsset();
    error DividendReentrancy();

    /// @dev `frozenLegs` bit for `leg`. A helper only so the shift has one home.
    function _legMask(uint256 leg) internal pure returns (uint8) {
        // `leg < MAX_DIVIDEND_ASSETS` at every call site, so the shift stays in the low 3 bits.
        // forge-lint: disable-next-line(incorrect-shift, unsafe-typecast)
        return uint8(1 << leg);
    }

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

    /// @dev Splits `amount` of native earnings across the legs that accrue as native, by weight, into the
    ///      single packed `pendingNative` slot. Consumes the whole amount (returns 0) unless every leg is
    ///      token-space buffered, in which case it consumes nothing and the caller folds it back to the
    ///      fund wallets.
    /// @dev The weights are renormalised over `nativeWeightTotal` because a token-space leg's share was
    ///      already peeled upstream, in token space, before this ETH existed. The LAST native leg takes
    ///      the rounding remainder so no wei is stranded.
    function _accrueDividends(uint256 amount) internal returns (uint256 unconsumed) {
        uint256 denom = nativeWeightTotal;
        if (denom == 0 || amount == 0) return amount;

        uint16[3] memory weights = dividendWeightsBps;
        uint8 tsLeg = tokenSpaceLeg;

        uint256 last = MAX_DIVIDEND_ASSETS;
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (weights[i] != 0 && i != tsLeg) last = i;
        }

        uint256 assigned;
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (weights[i] == 0 || i == tsLeg) continue;
            uint256 slice = i == last ? amount - assigned : amount * weights[i] / denom;
            assigned += slice;
            _addPendingNative(i, slice);
        }
        return 0;
    }

    /// @dev Adds to a leg's packed native buffer, refusing to truncate. `uint80` holds ~1.2M ETH, so this
    ///      is a bytecode-level assertion rather than a reachable path.
    function _addPendingNative(uint256 leg, uint256 slice) private {
        if (slice == 0) return;
        uint256 updated = uint256(pendingNative[leg]) + slice;
        require(updated <= type(uint80).max, DividendBufferOverflow());
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingNative[leg] = uint80(updated);
    }

    //////////////////////// views //////////////////////

    /// @notice A holder's share of the open round: their running minimum if they have moved this round,
    ///         otherwise their current balance (which, not having moved, IS their balance at the open).
    function dividendShares(address holder) public view returns (uint256) {
        if (_dividendExcluded(holder)) return 0;
        Acct storage acct = dividendAccounts[holder];
        return acct.roundId == currentRound ? acct.minShares : _dividendBalanceOf(holder);
    }

    /// @notice What `holder` would receive for `leg` if the round were paid out right now. 0 unless the
    ///         leg is frozen, the holder is above the dust floor, and they have not already been paid.
    function previewDividend(address holder, uint256 leg) external view returns (uint256) {
        if (leg >= MAX_DIVIDEND_ASSETS || frozenLegs & _legMask(leg) == 0) return 0;
        if (dividendAccounts[holder].lastPaidRound == currentRound) return 0;
        uint256 denom = frozenShares;
        if (denom == 0) return 0;
        uint256 shares = dividendShares(holder);
        if (shares * MIN_SHARE_DENOM < denom) return 0;
        return roundPot[leg] * shares / denom;
    }

    /// @notice Dividend money already committed to holders in `asset` but not yet delivered: the frozen
    ///         pots minus what has been pushed, plus residuals waiting for the next freeze.
    /// @dev THE single source of truth for "how much of this balance is not ours". Every sweep, swap-back
    ///      and rescue path subtracts this rather than open-coding its own subtraction, so a future
    ///      bucket is added in one place and every call site inherits it.
    function committedDividends(address asset) public view returns (uint256 committed) {
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (dividendTokens[i] != asset || roundPot[i] == 0) continue;
            committed += roundPot[i] - roundPaid[i];
        }
    }

    /// @notice Native earnings buffered across all legs, awaiting a freeze.
    function pendingNativeDividends() public view returns (uint256 total) {
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            total += pendingNative[i];
        }
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
        frozenLegs = 0;
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

    /// @dev Whether further earnings can still arrive for the dividend buffers. Gates the threshold
    ///      bypass, which exists only so a residual that can never grow again is not stranded. Answering
    ///      "no" while earnings still flow is what turns the bypass into a griefing tool: anyone could
    ///      freeze a dust pot whose every per-holder share rounds to zero, and a round that pays nothing
    ///      cannot settle. A venue whose earnings never stop must answer true forever.
    function _dividendEarningsMayStillArrive() internal view virtual returns (bool);

    /// @dev Where the curated `asset -> path` overrides live (see `DIVIDEND_ROUTE_REGISTRY`). A
    ///      `virtual` read of the compile-time constant rather than the constant itself, so a test
    ///      harness (or a future chain whose registry is deployed after the token implementations) can
    ///      point it elsewhere without a redeploy dance.
    function _dividendRouteRegistry() internal view virtual returns (address) {
        return DIVIDEND_ROUTE_REGISTRY;
    }

    /// @dev Whether a payout asset must be buffered in TOKEN space rather than as native. Only the
    ///      Uniswap-V2 self-token leg answers true.
    function _isTokenSpaceDividendAsset(address asset) internal view virtual returns (bool) {
        asset; // silences the unused-parameter warning without naming the arg away in overrides
        return false;
    }
}
