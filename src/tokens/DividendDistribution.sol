// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {ISwapRouteRegistry} from "src/interfaces/ISwapRouteRegistry.sol";
import {UniversalRouterVenue} from "src/libraries/UniversalRouterVenue.sol";
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

    uint256 private constant DIVIDEND_BPS_TOTAL = 10_000;

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

    /// @notice Gas stipend for a native payout. Bounded so one holder with an expensive (or reverting)
    ///         `receive()` cannot brick or grief a whole batch; a plain `receive()` and the common
    ///         smart-account fallbacks fit comfortably.
    uint256 internal constant NATIVE_PAYOUT_GAS = 50_000;

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

    //////////////////////// Errors //////////////////////

    error InvalidDividendConfig();
    error DividendsNotActive();
    error RoundTooYoung();
    error NoLegAboveThreshold();
    error RoundAlreadyFrozen();
    error NoFrozenRound();
    error PayoutWindowOpen();
    error DividendBufferOverflow();
    error UnsupportedDividendAsset();
    error DividendReentrancy();

    //////////////////////// configuration //////////////////////

    /// @dev Stores the creation-time payout configuration. Called once, by the token, only when the
    ///      earnings allocation routes a non-zero share to dividends.
    /// @dev Validation is limited to what would make the configuration functionally broken: the weights
    ///      must sum to 100%, they must be left-packed (so the rounding remainder always has leg 0 to
    ///      land in), the assets must be distinct (each leg's unpaid pot is reconciled against that
    ///      asset's balance, which only works one-to-one), and a third-token asset must name a venue this
    ///      chain can actually reach (`_validateDividendRoute`). WHICH asset a creator picks, and which
    ///      pool they point at, is their choice.
    function _initializeDividends(address[3] memory tokens, uint16[3] memory weights, DividendRoute[3] memory routes)
        internal
    {
        uint256 sum;
        uint8 tsLeg = NO_TOKEN_SPACE_LEG;
        uint256 nativeWeights;
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (weights[i] == 0) {
                // Left-packed: once a leg is empty every later leg must be too, and its asset unset.
                require(tokens[i] == address(0), InvalidDividendConfig());
                continue;
            }
            require(i == _filledLegsBefore(weights, i), InvalidDividendConfig());
            // Resolve the "pay in the token itself" sentinel now, so every later read is a plain address.
            if (tokens[i] == DIVIDEND_SELF_TOKEN) tokens[i] = address(this);
            for (uint256 j; j < i; ++j) {
                require(tokens[j] != tokens[i], InvalidDividendConfig());
            }
            // A third asset's route is checked HERE rather than in the factory: this contract is the one
            // that knows which venues its chain can reach, and a creator who names an unreachable one
            // would otherwise own a leg that can never be funded.
            if (tokens[i] != address(0) && tokens[i] != address(this)) {
                _validateDividendRoute(routes[i]);
                dividendRoutes[i] = routes[i];
            }
            sum += weights[i];
            if (_isTokenSpaceDividendAsset(tokens[i])) {
                // `i < MAX_DIVIDEND_ASSETS == 3`.
                // forge-lint: disable-next-line(unsafe-typecast)
                tsLeg = uint8(i);
            } else {
                nativeWeights += weights[i];
            }
        }
        require(sum == DIVIDEND_BPS_TOTAL && weights[0] != 0, InvalidDividendConfig());

        dividendTokens = tokens;
        dividendWeightsBps = weights;
        tokenSpaceLeg = tsLeg;
        // Bounded by the 10 000 total the loop just asserted.
        // forge-lint: disable-next-line(unsafe-typecast)
        nativeWeightTotal = uint16(nativeWeights);

        emit DividendsInitialized(tokens, weights);
    }

    /// @dev Rejects a third-asset route this chain could never execute — the only class of route error
    ///      worth a revert, since the token is a clone and the leg would accrue forever. What is NOT
    ///      checked is whether the pool exists or holds liquidity: that is a live property, not a
    ///      creation-time one, and a route that stops working is handled by the freeze skipping the leg
    ///      (and, if it never comes back, by a registry override) rather than by bricking the token.
    /// ponytail: no pool-existence probe, which would need a factory address per venue per chain; the
    ///           creator's own route is theirs to get right, and a wrong one costs only that leg.
    function _validateDividendRoute(DividendRoute memory route) private pure {
        if (route.venue == DividendVenue.UNIV2) {
            require(DIVIDEND_SWAP_ROUTER != address(0), UnsupportedDividendAsset());
        } else {
            // Both universal-router venues pay with native ETH, which ARC does not have.
            require(NATIVE_IS_ETH && DIVIDEND_UNIVERSAL_ROUTER != address(0), UnsupportedDividendAsset());
            // A V3 pool is keyed by its fee tier and a V4 pool by its tick spacing; neither is ever zero,
            // so a zero here is a route that can only ever miss.
            if (route.venue == DividendVenue.UNIV3) require(route.fee != 0, UnsupportedDividendAsset());
            else require(route.tickSpacing != 0, UnsupportedDividendAsset());
        }
    }

    /// @dev `frozenLegs` bit for `leg`. A helper only so the shift has one home.
    function _legMask(uint256 leg) private pure returns (uint8) {
        // `leg < MAX_DIVIDEND_ASSETS` at every call site, so the shift stays in the low 3 bits.
        // forge-lint: disable-next-line(incorrect-shift, unsafe-typecast)
        return uint8(1 << leg);
    }

    /// @dev Helper for the left-packing check: the number of non-zero weights strictly before `i` must
    ///      equal `i`, i.e. there is no gap.
    function _filledLegsBefore(uint16[3] memory weights, uint256 i) private pure returns (uint256 filled) {
        for (uint256 j; j < i; ++j) {
            if (weights[j] != 0) ++filled;
        }
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

    //////////////////////// rounds //////////////////////

    /// @notice Converts every leg currently over `DIVIDEND_THRESHOLD` into its payout asset, fixes those
    ///         pots and the shared denominator, and opens the payout window. Permissionless.
    /// @dev The set of legs frozen is DERIVED, never chosen by the caller: letting a caller pick would
    ///      let anyone freeze a dust leg every round and force dust payouts on every holder. A leg whose
    ///      conversion is not viable simply stays unfrozen and keeps accruing, so one illiquid asset
    ///      cannot brick a token's dividends.
    /// @dev ONE FREEZE PER ROUND, and the denominator is snapshotted with it. A leg frozen later in the
    ///      same round would be unpayable to every holder already marked for that round: their pot would
    ///      sit undeliverable until `PAYOUT_WINDOW` expired, blocking the round from settling. A leg that
    ///      misses the freeze keeps accruing and qualifies in a later round instead — cheap, because a
    ///      round is only `MIN_ROUND_DURATION` long, and a leg that keeps missing eventually clears the
    ///      threshold at every instant, including the earliest one anyone can freeze at.
    /// @param minOut Per-leg slippage floor, in each asset's own decimals. Ignored by native legs.
    function processDividends(uint256[3] calldata minOut) external nonReentrantDividends {
        uint32 round = currentRound;
        require(round != 0, DividendsNotActive());
        require(frozenLegs == 0, RoundAlreadyFrozen());
        require(block.timestamp >= uint256(roundOpenedAt) + MIN_ROUND_DURATION, RoundTooYoung());

        uint96 denom = roundTotalShares;

        uint8 legs;
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (dividendWeightsBps[i] == 0) break;
            address asset = dividendTokens[i];
            (uint256 nativeIn, uint256 out) = _freezeLeg(i, asset, minOut[i]);
            if (out == 0) continue;
            roundPot[i] += out; // adds to whatever earlier rounds left unpaid
            legs |= _legMask(i);
            emit DividendRoundFunded(round, asset, nativeIn, roundPot[i], denom);
        }
        require(legs != 0, NoLegAboveThreshold());

        frozenLegs = legs;
        frozenShares = denom;
        roundClosedAt = uint40(block.timestamp);
    }

    /// @notice Pushes this round's payouts to `holders`. Permissionless, idempotent and unforgeable: the
    ///         amounts are computed here from each holder's own round minimum, so a duplicate address
    ///         pays 0, an unknown address pays 0, and an omitted holder is simply paid next round.
    function distributeDividends(address[] calldata holders) external nonReentrantDividends {
        uint8 legs = frozenLegs;
        require(legs != 0, NoFrozenRound());

        uint32 round = currentRound;
        uint256 denom = frozenShares;
        uint256[3] memory paid;

        for (uint256 i; i < holders.length; ++i) {
            _payHolder(holders[i], round, legs, denom, paid);
        }

        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (paid[i] != 0) roundPaid[i] += paid[i];
        }
    }

    /// @notice Self-serve backstop for a holder the keeper missed. Same formula, same paid marker.
    function claimRound() external nonReentrantDividends {
        uint8 legs = frozenLegs;
        require(legs != 0, NoFrozenRound());

        uint256[3] memory paid;
        _payHolder(msg.sender, currentRound, legs, frozenShares, paid);
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (paid[i] != 0) roundPaid[i] += paid[i];
        }
    }

    /// @notice Rolls the open round over: whatever stayed unpaid seeds the next round's pots, and a fresh
    ///         denominator is read from live balances. Permissionless.
    /// @dev Allowed once the frozen pots are paid out to within dust, or once `PAYOUT_WINDOW` has
    ///         elapsed. A round that never froze anything still has to reach `MIN_ROUND_DURATION`, so
    ///         rounds cannot be churned to re-snapshot everybody's minimum on demand.
    function finalizeRound() external {
        uint32 round = currentRound;
        require(round != 0, DividendsNotActive());

        uint8 legs = frozenLegs;
        if (legs != 0) {
            bool windowElapsed = block.timestamp >= uint256(roundClosedAt) + PAYOUT_WINDOW;
            require(windowElapsed || _roundSettled(legs), PayoutWindowOpen());
        } else {
            require(block.timestamp >= uint256(roundOpenedAt) + MIN_ROUND_DURATION, RoundTooYoung());
        }

        uint256 residual;
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            uint256 pot = roundPot[i];
            if (pot == 0) continue;
            uint256 alreadyPaid = roundPaid[i];
            if (alreadyPaid != 0) {
                pot -= alreadyPaid;
                roundPot[i] = pot;
                roundPaid[i] = 0;
            }
            residual += pot;
        }

        emit DividendRoundFinalized(round, residual);
        _openDividendRound();
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

    /// @dev Turns one leg's accrued buffer into a payable pot, or reports that it is not ready.
    ///      Overridable so a venue can source a leg from somewhere other than the native buffer (the V2
    ///      self-token leg, which is carved from tax tokens).
    /// @return nativeIn native consumed, `out` payout asset acquired. `(0, 0)` = not ready.
    function _freezeLeg(uint256 leg, address asset, uint256 minOut)
        internal
        virtual
        returns (uint256 nativeIn, uint256 out)
    {
        uint256 buffered = pendingNative[leg];
        if (buffered == 0) return (0, 0);
        // The threshold exists so a distribution only fires when the pot is worth its gas. Where no
        // further earnings can ever arrive it must stop applying, or the last residual strands — the
        // same drain rule the V2 swap-back already uses.
        if (buffered < DIVIDEND_THRESHOLD && _dividendEarningsMayStillArrive()) return (0, 0);

        // Only a leg that SWAPS is capped. A native leg is already denominated in the payout asset, so
        // it has no swap to sandwich, and throttling it would delay real money for no security gain.
        uint256 spend = (asset != address(0) && buffered > MAX_DIVIDEND_PER_FREEZE) ? MAX_DIVIDEND_PER_FREEZE : buffered;
        out = _acquireDividendAsset(asset, leg, spend, minOut);
        // A conversion that did not happen must leave the buffer untouched, not burn it: the swap can
        // fail for reasons outside anyone's control (a dead pool, a floor the pool moved past), and the
        // leg simply stays unfrozen and tries again next round.
        if (out == 0) return (0, 0);
        // Re-read rather than reuse `buffered`: the swap is an external call, and earnings that arrived
        // during it (`_accrueDividends` is not behind the dividend lock) must survive this write.
        // Bounded by the value read, which is already a `uint80`.
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingNative[leg] = uint80(pendingNative[leg] - spend);
        return (spend, out);
    }

    /// @dev Converts `nativeIn` into `asset`. Native needs no conversion; a third ERC20 is bought on the
    ///      pool the creator named for that leg. The token itself is venue-specific, handled by an
    ///      override.
    /// @dev The route is the creator's, fixed at creation, and never the caller's: `processDividends` is
    ///      permissionless, so a route supplied there would let any caller send the token's earnings
    ///      through a pool they control. Picking the asset already picks its pool, so nothing is gained
    ///      by curating the route once the asset itself is unrestricted — the swap is bounded by `minOut`
    ///      either way.
    /// @dev A registry entry for the asset OVERRIDES the creator's route. That is the escape hatch for a
    ///      clone whose pool has died: without it the leg's buffer would be stranded for good.
    /// @return out asset actually received, measured as a balance delta so a fee-on-transfer asset is
    ///         counted for what it delivered. 0 when the conversion did not happen — see `_freezeLeg`.
    function _acquireDividendAsset(address asset, uint256 leg, uint256 nativeIn, uint256 minOut)
        internal
        virtual
        returns (uint256 out)
    {
        if (asset == address(0)) return nativeIn; // native: the buffer already IS the payout asset

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        if (!_swapNativeToDividendAsset(asset, leg, nativeIn, minOut)) return 0;
        return IERC20(asset).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev The venue dispatch of `_acquireDividendAsset`, split out only to keep that function's stack
    ///      shallow. Reports failure instead of reverting; see `_freezeLeg`.
    function _swapNativeToDividendAsset(address asset, uint256 leg, uint256 nativeIn, uint256 minOut)
        private
        returns (bool)
    {
        address registry = _dividendRouteRegistry();
        // ponytail: the override is V2-only, matching the registry's own `address[] path` shape. A V3/V4
        //           pool that dies can still be repaired by pointing the asset at any V2 pair.
        if (registry != address(0)) {
            address[] memory curated = ISwapRouteRegistry(registry).getRoute(asset);
            if (curated.length >= 2) {
                return UniswapV2Venue.trySwapNativeToAsset(
                    IUniswapV2Router(DIVIDEND_SWAP_ROUTER), DeploymentAddresses.WETH, curated, nativeIn, minOut
                );
            }
        }

        DividendRoute memory route = dividendRoutes[leg];
        if (route.venue == DividendVenue.UNIV2) {
            return UniswapV2Venue.trySwapNativeToAsset(
                IUniswapV2Router(DIVIDEND_SWAP_ROUTER),
                DeploymentAddresses.WETH,
                _v2Path(asset, route.aux),
                nativeIn,
                minOut
            );
        }
        if (route.venue == DividendVenue.UNIV3) {
            return UniversalRouterVenue.swapNativeToAssetV3(
                DIVIDEND_UNIVERSAL_ROUTER, DeploymentAddresses.WETH, asset, route.fee, nativeIn, minOut
            );
        }
        return UniversalRouterVenue.swapNativeToAssetV4(
            DIVIDEND_UNIVERSAL_ROUTER, asset, route.fee, route.tickSpacing, route.aux, nativeIn, minOut
        );
    }

    /// @dev `quote -> [hop] -> asset`. One optional hop is all a V2 route gets: it covers the direct pair
    ///      and the usual detour through a stable, and the alternative is a dynamic array in a clone's
    ///      storage for a shape nobody has needed.
    /// ponytail: one hop, add a second when a real asset needs three legs to reach the quote.
    function _v2Path(address asset, address hop) private pure returns (address[] memory path) {
        if (hop == address(0)) {
            path = new address[](2);
            path[0] = DeploymentAddresses.WETH;
            path[1] = asset;
        } else {
            path = new address[](3);
            path[0] = DeploymentAddresses.WETH;
            path[1] = hop;
            path[2] = asset;
        }
    }

    /// @dev Pays one holder every frozen leg, or nothing. The caller holds `nonReentrantDividends`, so
    ///      nothing can revisit this holder mid-payout and the marker is safe to write at the END —
    ///      which is what lets it record whether anything actually went out.
    function _payHolder(address holder, uint32 round, uint8 legs, uint256 denom, uint256[3] memory paid) private {
        Acct storage acct = dividendAccounts[holder];
        if (acct.lastPaidRound == round || _dividendExcluded(holder)) return;

        uint256 shares = acct.roundId == round ? acct.minShares : _dividendBalanceOf(holder);
        // One relative floor filters dust for every asset at once: all legs divide the same ratio.
        if (shares == 0 || shares * MIN_SHARE_DENOM < denom) return;

        bool paidAny;
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (legs & _legMask(i) == 0) continue;
            uint256 amount = roundPot[i] * shares / denom;
            if (amount == 0) continue;
            address asset = dividendTokens[i];
            // A failed send is skipped, not reverted: one holder with a reverting `receive()` — or one
            // blacklisted by a payout asset — must not brick the batch. The amount stays in the pot and
            // rolls to the next round.
            if (_payDividend(asset, holder, amount)) {
                paid[i] += amount;
                paidAny = true;
                emit DividendPaid(round, holder, asset, amount);
            }
        }

        // Marking a holder who received NOTHING would forfeit their round outright: `claimRound` would
        // find the marker set and pay 0, for that round and every future one it happened in. Leaving
        // them unmarked costs a retried (and gas-capped) send per batch instead.
        if (paidAny) acct.lastPaidRound = round;
    }

    /// @dev Delivers one payout, reporting failure instead of reverting — for BOTH shapes. Native goes
    ///      out with a bounded stipend. An ERC20 leg is protocol-curated, but curated does not mean
    ///      always-transferable: the obvious registry candidates blacklist addresses, and a reverting
    ///      `safeTransfer` on ONE holder would take down the whole batch, `claimRound` for everyone, and
    ///      with them the round's ability to settle.
    function _payDividend(address asset, address to, uint256 amount) private returns (bool) {
        if (asset == address(0)) {
            (bool sent,) = to.call{value: amount, gas: NATIVE_PAYOUT_GAS}("");
            return sent;
        }
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        // `SafeERC20`'s success test minus the revert: empty returndata is success (non-standard ERC20s),
        // and anything too short to decode is failure rather than a panic. `asset` is known to be a
        // contract — its pot could only have been funded through a `balanceOf` call on it.
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// @dev True when every frozen leg has been paid down to within 0.01% of its pot.
    function _roundSettled(uint8 legs) private view returns (bool) {
        for (uint256 i; i < MAX_DIVIDEND_ASSETS; ++i) {
            if (legs & _legMask(i) == 0) continue;
            uint256 pot = roundPot[i];
            if ((pot - roundPaid[i]) * 10_000 > pot) return false;
        }
        return true;
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
