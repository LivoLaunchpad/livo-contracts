// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {EarningsAllocation} from "src/tokens/EarningsAllocation.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTaxableToken, TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LivoTaxableToken
/// @notice Abstract base for Livo taxable tokens shared by the Uniswap V2 and V4 variants.
///         Owns the tax-config storage, the post-graduation timestamp, the standard `markGraduated`
///         + `getTaxConfig` overrides, the dev-supplied init plumbing and the owner-only
///         `rescueTokens` path. Variant-specific behavior (intrinsic V2 taxation, V4 pool-manager
///         pair check) lives in the concrete subclasses.
/// @dev Storage layout: this contract's 8 packed tax fields (buyTaxBps, sellTaxBps, taxDurationSeconds,
///      startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps, taxDecayDuration,
///      graduationTimestamp) share one slot with the three `EarningsAllocation` bps that inheritance
///      lays out just before them (48 + 192 = 240 bits), so the per-trade tax read stays a single warm
///      SLOAD — and the earnings-split read hits the same (warm) slot. That fills the slot enough that
///      the V2 subclass's swap-back counters now occupy the FOLLOWING slot (a negligible extra cold
///      SLOAD only in the swap-back path). Subclasses that add their own state must do so AFTER these
///      fields to preserve clone-storage layout.
/// @dev ⚠️ `DividendDistribution` is listed BEFORE `EarningsAllocation` on purpose: inheritance lays
///      base storage out in declaration order, so putting it after would wedge its state between the
///      allocation bps and the tax fields and break the packing described above.
abstract contract LivoTaxableToken is LivoToken, ILivoTaxableToken, DividendDistribution, EarningsAllocation {
    using SafeERC20 for IERC20;

    /// @notice Where `processLiquidity` locks LP tokens, and an address users sometimes send tokens to by
    ///         hand. Excluded from dividends for the latter reason only — the token's own burns go to
    ///         `address(0)` via `_burn`, so this is not a burn sink.
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    //////////////////////// potentially immutable //////////////////

    /// @notice Buy tax rate in basis points. Set during initialization; the owner can lower it later
    ///         via `setTaxBps` (decrease-only — increases revert).
    uint16 public buyTaxBps;

    /// @notice Sell tax rate in basis points. Set during initialization; the owner can lower it later
    ///         via `setTaxBps` (decrease-only — increases revert).
    uint16 public sellTaxBps;

    /// @notice Duration in seconds of the tax window, measured from the anchor selected by
    ///         `startTaxFromLaunch` (`launchTimestamp` if true, else `graduationTimestamp`). Set
    ///         during initialization, cannot be changed.
    uint40 public taxDurationSeconds;

    /// @notice Anchor for the tax window. `true`: the window starts at token creation
    ///         (`launchTimestamp`) and spans graduation transparently. `false`: the window starts at
    ///         graduation (`graduationTimestamp`) and no tax is charged before graduation. Set during
    ///         initialization, cannot be changed.
    bool public startTaxFromLaunch;

    /// @notice Buy-tax rate at the anchor for the optional linear decay (bps). The buy decay rate falls
    ///         linearly from this value to the long-term static `buyTaxBps` (0 for a decay-only token) over
    ///         `taxDecayDuration`, from the same anchor `startTaxFromLaunch` selects. 0 disables buy decay.
    ///         Set during init, cannot be changed.
    uint16 public buyTaxDecayStartBps;

    /// @notice Sell-tax rate at the anchor for the optional linear decay (bps). Mirror of
    ///         `buyTaxDecayStartBps` for sells. 0 disables sell decay. Set during init, cannot be changed.
    uint16 public sellTaxDecayStartBps;

    /// @notice Duration in seconds over which the decay rates fall from their start values to the
    ///         long-term static rates (0 for a decay-only token), measured from the same anchor as the
    ///         static window. 0 disables decay. The effective tax a trade pays is `max(decay, static)` per
    ///         direction, so a token may set ONLY these decay fields (static bps + duration zero) for a
    ///         pure decaying launch tax. Set during init.
    uint40 public taxDecayDuration;

    /////////////////////////// pure storage ///////////////////////

    /// @notice Timestamp when token graduated (0 if not graduated)
    uint40 public graduationTimestamp;

    //////////////////////// Events //////////////////////

    /// @notice Emitted once during init with the dev-supplied tax config. `startTaxFromLaunch` selects
    ///         the tax-window anchor (creation vs graduation). The three `*Decay*` fields configure the
    ///         optional linear launch-tax decay (start rate + duration, anchored as `startTaxFromLaunch`
    ///         selects); all 0 when no decay is configured.
    event LivoTaxableTokenInitialized(
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint40 taxDurationSeconds,
        bool startTaxFromLaunch,
        uint16 buyTaxDecayStartBps,
        uint16 sellTaxDecayStartBps,
        uint40 taxDecayDuration
    );

    /// @notice Emitted whenever `setTaxBps` successfully updates the buy/sell tax rates. Only the
    ///         new values are carried; indexers can resolve old values from the prior
    ///         `LivoTaxableTokenInitialized` event or the most recent prior `TaxBpsUpdated`.
    event TaxBpsUpdated(uint16 newBuyTaxBps, uint16 newSellTaxBps);

    /// @notice Emitted when a token's liquidity earnings allocation is turned into a locked LP position by
    ///         `processLiquidity`. Shared by both venues; a few fields carry a slightly venue-specific
    ///         meaning:
    ///         - V4: `ethIn` is the ETH deposited single-sided just below the price, `tokensAdded` is
    ///           always 0 (an ETH-only bid wall), and `liquidity` is the Uniswap-V4 liquidity units minted.
    ///         - V2: `ethIn`/`tokensAdded` are the ETH and tokens paired into the V2 LP (half the buffered
    ///           tokens are sold for the ETH side), and `liquidity` is the V2 LP tokens minted (locked at
    ///           the dead address).
    event LiquidityAdded(uint256 ethIn, uint256 tokensAdded, uint256 liquidity);

    /// @notice Emitted when a token's burn earnings allocation removes supply. Shared by both venues;
    ///         `ethSpent` is venue-specific:
    ///         - V4: the buffered ETH spent buying the tokens back before burning them (`processBurn`).
    ///         - V2: always 0 — the burn share is taken in TOKEN-space during the swap-back, before the
    ///           sell, so no ETH round trip happens and no ETH is spent to burn.
    ///         Summing `ethSpent` across both venues therefore gives the protocol-wide ETH actually
    ///         spent on buy-backs.
    event CreatorTaxBurn(uint256 ethSpent, uint256 tokensBurned);

    //////////////////////// Errors //////////////////////

    error NotTokenOwner();
    error CannotRescueSelfToken();
    error TaxBpsCanOnlyDecrease();

    //////////////////////////////////////////////////////

    /// @notice Allows the contract to receive ETH (V2: from the router during tax swap-backs;
    ///         V4: defensive — the V4 token is not expected to hold ETH).
    receive() external payable {}

    /// @notice Marks the token as graduated and records the timestamp.
    /// @dev Can only be called by the pre-set graduator contract. Overrides `LivoToken` to add
    ///      timestamp tracking. `graduationTimestamp` is the tax-window anchor for tokens configured
    ///      with `startTaxFromLaunch == false`; for `startTaxFromLaunch == true` tokens it is only the
    ///      V4 hook's "has graduated?" guard via `getTaxConfig` (the window is creation-anchored).
    function markGraduated() external override(ILivoToken, LivoToken) {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        graduationTimestamp = uint40(block.timestamp);
        emit Graduated();
    }

    /// @notice Allows the token owner OR the launchpad owner to rescue stuck ERC20 balances (never the
    ///         token's own balance; ETH is intentionally not rescuable — see below).
    /// @dev Two rules:
    ///      (1) Self-token rescue is disallowed — the caller must NEVER siphon accrued tax balance
    ///          ahead of a swap-back.
    ///      (2) ETH is intentionally NOT rescuable. The token legitimately holds ETH (e.g. the V4 burn
    ///          buffer awaiting `processBurn`), and dropping the sweep path avoids racing that buffer;
    ///          any stray ETH is simply left in the contract, effectively benefiting holders. Passing
    ///          `address(0)` reverts.
    /// @dev The launchpad owner is included so the protocol admin can sweep stuck ERC20s on
    ///      factory-deployed tokens where `owner == address(0)` makes the token-owner path unreachable.
    ///      Rescued ERC20s go to `owner` (which may be `address(0)`, in which case the transfer reverts —
    ///      acceptable, as a stuck-balance rescue with no recipient is a no-op anyway).
    /// @param token ERC20 to rescue. `address(this)` and `address(0)` both revert.
    /// @dev ⚠️ Rescues only what `_sweepableAsset` says is unclaimed. A dividend payout asset sits in
    ///      this same balance, and handing an undistributed pot to the owner would not lose it — it would
    ///      TRANSFER it from holders to the owner, which is worse. Never open-code
    ///      `IERC20(token).balanceOf(address(this))` on a sweep path.
    function rescueTokens(address token) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        // disallow rescuing the token's own balance to prevent siphoning accrued taxes
        require(token != address(this), CannotRescueSelfToken());
        IERC20(token).safeTransfer(owner, _sweepableAsset(token));
    }

    /// @notice Updates `buyTaxBps` and/or `sellTaxBps`. Today this is decrease-only — any attempt
    ///         to raise either rate reverts with `TaxBpsCanOnlyDecrease`. Passing a value equal to
    ///         the current one is allowed (no-op for that side). `taxDurationSeconds` and
    ///         `graduationTimestamp` are untouched.
    /// @dev The function name is intentionally generic (`setTaxBps`) even though the body enforces
    ///      a narrower decrease-only rule. This keeps the ABI stable if the policy is ever relaxed.
    /// @dev Callable by the token owner OR the launchpad owner — same dual-auth pattern as
    ///      `swapBack` / `rescueTokens`. On factory-deployed tokens (`owner == address(0)`) only
    ///      the launchpad-owner branch is reachable, which is intentional.
    /// @param newBuyTaxBps New buy tax rate in basis points. Must be `<= buyTaxBps`.
    /// @param newSellTaxBps New sell tax rate in basis points. Must be `<= sellTaxBps`.
    function setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        require(newBuyTaxBps <= buyTaxBps && newSellTaxBps <= sellTaxBps, TaxBpsCanOnlyDecrease());

        emit TaxBpsUpdated(newBuyTaxBps, newSellTaxBps);

        buyTaxBps = newBuyTaxBps;
        sellTaxBps = newSellTaxBps;
    }

    //////////////////////// EARNINGS ALLOCATION //////////////////////

    /// @notice Factory-only, creation-time setter for the earnings-allocation split (burn / dividends /
    ///         liquidity bps; the fund wallets take the remainder). Callable exactly once, during the
    ///         deploy tx, by the factory that initialized this token — guarded by the transient
    ///         `tokenFactory`, which is zero outside that tx (same pattern as `registerFees`).
    function initializeEarningsAllocation(uint16 _burnBps, uint16 _dividendsBps, uint16 _liquidityBps) external {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
    }

    /// @notice Same as the three-bps overload, plus the dividend payout configuration: which assets the
    ///         dividends slice buys and how it divides across them. Kept as a separate overload so the
    ///         original signature stays untouched.
    /// @dev `hasDividends` is what actually turns the feature on. It lives on `LivoToken`, packed into
    ///      the `pair` slot `_update` already loads, so a token that leaves `_dividendsBps` at 0 pays
    ///      nothing for the feature on any transfer.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address[3] calldata _dividendTokens,
        uint16[3] calldata _dividendWeightsBps
    ) external {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
        if (_dividendsBps != 0) {
            _initializeDividends(_dividendTokens, _dividendWeightsBps);
            hasDividends = true;
        }
    }

    /// @notice Routes ETH earnings (post-graduation swap tax + LP-fee creator share) through the
    ///         earnings-allocation split before they reach the fund wallets. Overrides the base
    ///         passthrough; see `EarningsAllocation`.
    function accrueFees() external payable override(ILivoToken, LivoToken) {
        // V4 is ETH-native, so it carves both the burn and liquidity slices from this ETH. (On V2 this
        // path is only hit pre-graduation — where it short-circuits to the fund wallets — or by stray ETH,
        // which with no ETH-side burn/liquidity handlers simply folds to the fund wallets.)
        _allocateEthEarnings(msg.value, burnBps, liquidityBps);
    }

    /// @dev Earnings split routes each slice post-graduation only; pre-graduation the whole amount
    ///      goes to the fund wallets. Reads the base `LivoToken.graduated` flag.
    function _earningsGraduated() internal view override returns (bool) {
        return graduated;
    }

    /// @dev Routes the fund-wallet slice to this token's master fee handler — the same path all
    ///      earnings took before the allocation split was introduced.
    function _depositToFund(uint256 amount) internal override {
        ILivoMasterFeeHandler(feeHandler).depositFees{value: amount}(address(this));
    }

    /// @dev Dividends accrue as native into the packed per-leg buffer — one SSTORE for all three legs,
    ///      well inside the router gas budget — and are converted out-of-band by `processDividends`.
    ///      A token with no dividend configuration has a zero native weight total, so this consumes
    ///      nothing and the slice folds back to the fund wallets.
    function _handleDividends(uint256 amount) internal override returns (uint256 unconsumed) {
        return _accrueDividends(amount);
    }

    /// @inheritdoc EarningsAllocation
    /// @dev Opens the token's FIRST dividend round, on the first earnings it ever routes — not at
    ///      creation, and not at graduation:
    ///        - creation is too early: the launchpad holds the whole supply then, so the round would
    ///          open with an almost-empty denominator and every bonding-curve buyer would look like a
    ///          mid-round arrival worth zero.
    ///        - `markGraduated()` is too early too, less obviously. It runs while the GRADUATOR still
    ///          holds the entire graduating supply, so the opening denominator would count a bag handed
    ///          to the pool moments later in the same transaction. Excluding the graduator would fix
    ///          that — at the price of an `SLOAD` on every transfer for the life of the token, to
    ///          neutralise an address that can never be paid anyway (it ends graduation at 0 on V2 and
    ///          at a few thousand wei on V4, far under the dust floor). Not worth it.
    ///      By the time earnings arrive the graduation transaction is over and the token is in its
    ///      steady state, so the snapshot is clean and the hot path never learns the graduator exists.
    /// @dev Hooked HERE rather than in `_handleDividends` so the Uniswap-V2 self-token leg is covered
    ///      too: that leg is carved in token space and never reaches `_handleDividends`, so a token
    ///      paying only in itself would otherwise never open a round.
    /// @dev One-off cost: four `balanceOf` reads and two SSTOREs, once per token, inside the router's
    ///      gas budget. If it ever ran out of gas the fee falls through to the treasury and the next
    ///      accrual opens the round instead — self-healing, not a one-shot.
    function _onGraduatedEarnings() internal override {
        if (hasDividends && currentRound == 0) _openDividendRound();
    }

    //////////////////////// DIVIDEND HOOKS //////////////////////

    /// @inheritdoc LivoToken
    function _onBalanceChange(address from, address to, uint256 amount) internal override {
        _trackDividendShares(from, to, amount);
    }

    /// @inheritdoc DividendDistribution
    function _dividendBalanceOf(address account) internal view override returns (uint256) {
        return balanceOf(account);
    }

    /// @inheritdoc DividendDistribution
    /// @dev Exactly four addresses, and every one of them is either free to test (`address(this)`, the
    ///      `DEAD_ADDRESS` constant) or already in the warm slot `_update` loads (`pair`). Nothing here
    ///      costs a cold read.
    /// @dev Nothing else needs listing, and that is the minimum rule paying for itself: the V4 position
    ///      manager, the routers, the liquidity adder and the GRADUATOR all hold a balance only within a
    ///      single transaction, and an address that is empty when a round opens is worth zero for that
    ///      whole round however much it holds in between. The exclusion list only has to name addresses
    ///      that hold a balance CONTINUOUSLY across a round. (This is also why the first round opens on
    ///      the first earnings rather than inside `markGraduated()` — see `_handleDividends`.)
    /// @dev Creator vaults are deliberately NOT here: they hold a real, merely-vested team allocation
    ///      continuously across rounds, so they are ordinary holders (and `LivoCreatorVault` accepts and
    ///      can sweep whatever it is paid).
    function _dividendExcluded(address account) internal view override returns (bool) {
        return account == address(this) || account == pair || account == address(launchpad) || account == DEAD_ADDRESS;
    }

    /// @inheritdoc DividendDistribution
    function _dividendEligibleSupply() internal view override returns (uint256) {
        return totalSupply() - balanceOf(pair) - balanceOf(address(this)) - balanceOf(address(launchpad))
            - balanceOf(DEAD_ADDRESS);
    }

    /// @inheritdoc DividendDistribution
    /// @dev Swap tax is the one earnings source guaranteed to stop, so the base answer is the tax
    ///      window. A venue with a second, unending source overrides this.
    function _dividendEarningsMayStillArrive() internal view virtual override returns (bool) {
        return _taxWindowActive();
    }

    //////////////////////// COMMITTED FUNDS //////////////////////

    /// @notice Native balance that is genuinely stray — not owed to anyone — and may therefore be swept
    ///         back through the earnings split.
    /// @dev Every sweep and swap-back path MUST route through this instead of reading
    ///      `address(this).balance`. Three call sites used to subtract their own buckets by hand; a
    ///      fourth bucket (the dividend pots) is exactly the kind of addition that gets forgotten in one
    ///      of them, and the failure mode is not a lost balance but a silent transfer of holders' money
    ///      to the creator's fee receivers.
    function _sweepableNative() internal view returns (uint256) {
        uint256 reserved = _reservedNative();
        uint256 balance = address(this).balance;
        return balance > reserved ? balance - reserved : 0;
    }

    /// @notice ERC20 balance of `asset` that is not owed to dividend holders.
    function _sweepableAsset(address asset) internal view virtual returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (!hasDividends) return balance;
        uint256 reserved = committedDividends(asset);
        return balance > reserved ? balance - reserved : 0;
    }

    /// @dev Native this contract holds on someone else's behalf. Venues extend it with their own
    ///      buffers; the base covers the dividend buffers and the undelivered dividend pots.
    function _reservedNative() internal view virtual returns (uint256) {
        if (!hasDividends) return 0;
        return pendingNativeDividends() + committedDividends(address(0));
    }

    //////////////////////// VIEW FUNCTIONS //////////////////////

    /// @notice Pre-graduation fee policy. Same LP fee as the base, plus the effective tax for this
    ///         direction — `max(decay, static)` — which is 0 outside both windows. For
    ///         `startTaxFromLaunch == true` tokens the launchpad charges the exact rate the V4 hook /
    ///         V2 `_update` apply post-graduation; for graduation-anchored tokens neither window has
    ///         started pre-graduation, so the tax here is 0.
    function getLaunchpadFees(ILivoToken.LaunchpadTrade calldata trade)
        external
        view
        override(ILivoToken, LivoToken)
        returns (ILivoToken.LaunchpadFees memory)
    {
        uint16 taxBps = _effectiveTaxBps(trade.isBuy);
        return ILivoToken.LaunchpadFees({lpFeeBps: lpFeeBps, treasuryShareBps: treasuryShareBps, taxBps: taxBps});
    }

    /// @notice Returns the effective tax configuration for the PREVIOUSLY-deployed `LivoSwapHook` (and
    ///         off-chain readers). Reports the CURRENT effective rates — `max(decay, static)` per direction,
    ///         which change every second while the decay window is open — so that hook, which re-reads this
    ///         on every swap, applies the right (possibly decaying) rate.
    /// @dev LEGACY, kept for backwards compatibility — do not remove. The CURRENT `LivoSwapHook` reads
    ///      `getSwapFees(isBuy)` below instead. This stays live for two readers that cannot be migrated:
    ///      off-chain integrators, and the older hook still serving every token already graduated onto it
    ///      (dropping this would break their swaps). That older hook applies the tax expiry itself, hence
    ///      the both-directions + synthetic-duration shape retained here.
    /// @dev That hook expires tax when `block.timestamp > graduationTimestamp + taxDurationSeconds`. Both
    ///      windows are anchored per `startTaxFromLaunch` (at `launchTimestamp` or `graduationTimestamp`),
    ///      so the returned `taxDurationSeconds` is SYNTHETIC: the seconds from `graduationTimestamp` to
    ///      the latest window end (`anchor + max(static, decay) duration`), keeping the hook open for the
    ///      whole effective window regardless of anchor. Once both windows close this returns a fully
    ///      zeroed tax (rates AND duration), so the hook stops taxing; the zeroed rates also cover the
    ///      edge where the window expires before graduation and a swap lands in the graduation block.
    function getTaxConfig() external view override(ILivoToken, LivoToken) returns (TaxConfig memory config) {
        uint40 graduationTs = graduationTimestamp;
        (uint16 effBuy, uint16 effSell) = _effectiveTaxBps();

        // No active tax — both windows closed, not yet anchored, or the decay floored to 0 at its tail.
        // Report zeros so the deployed hook stops taxing; `graduationTimestamp` is surfaced for reference.
        // Both directions share one decay schedule and one static window (see `_effectiveTaxBps`), so a
        // single `effBuy == 0 && effSell == 0` check settles "is anything still owed" for the whole token.
        if (effBuy == 0 && effSell == 0) {
            return TaxConfig({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, graduationTimestamp: graduationTs});
        }

        // Active: report a duration that, added to `graduationTimestamp`, lands exactly on the latest
        // window end — so the deployed hook's `block.timestamp > graduationTimestamp + taxDurationSeconds`
        // expiry tracks the true window even for a decay-only token (whose static `taxDurationSeconds` is
        // 0). Before graduation the hook is never invoked (swaps revert), and `graduationTimestamp == 0`,
        // so the tax anchor stands in as the reference — a creation-anchored token then reports its
        // configured duration (`windowEnd - launchTimestamp`). A non-zero effective rate implies the
        // window is open, so `windowEnd >= block.timestamp >= referenceTime` and the subtraction cannot
        // underflow.
        uint256 anchor = _taxAnchor();
        uint256 referenceTime = graduationTs != 0 ? graduationTs : anchor;
        config = TaxConfig({
            buyTaxBps: effBuy,
            sellTaxBps: effSell,
            taxDurationSeconds: uint40(anchor + _maxWindowDuration() - referenceTime),
            graduationTimestamp: graduationTs
        });
    }

    /// @notice Returns the fees `LivoSwapHook` charges on a V4 swap in direction `isBuy` right now (see
    ///         `ILivoToken`): the always-on post-graduation LP fee, plus the CURRENT effective tax —
    ///         `max(decay, static)` for that direction, which changes every second while the decay window
    ///         is open — so the hook, which re-reads this on every swap, applies the right (possibly
    ///         decaying) rate.
    /// @dev The tax-window (and decay) logic lives here, in `_effectiveTaxBps(isBuy)`, so the hook stays
    ///      agnostic to the schedule: it gets zero tax once the window closes (or before a
    ///      graduation-anchored token graduates). The LP fee is always effective.
    function getSwapFees(bool isBuy)
        external
        view
        override(ILivoToken, LivoToken)
        returns (ILivoToken.LivoTradeFees memory)
    {
        return ILivoToken.LivoTradeFees({taxBps: _effectiveTaxBps(isBuy), lpFeeBps: swapLpFeeBps});
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Shared initializer body for taxable tokens. Subclasses override to add variant-specific
    ///      setup (e.g. router approval for V2, pool-manager pair check for V4) by chaining via
    ///      `super._initializeLivoTaxableToken(...)`.
    function _initializeLivoTaxableToken(ILivoToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        virtual
        onlyInitializing
    {
        // Initialize the LivoToken state, and the graduator
        _initializeLivoToken(params);
        // there are no requirements at the token level. They are imposed at the factory level, so that this token implementation stays flexible
        _initializeTaxConfig(taxCfg);
    }

    /// @notice Internal helper to store tax configuration (static rates + window, anchor, and the
    ///         optional linear-decay rates + duration).
    /// @dev Tax-bps and duration bounds are enforced upstream in the factory. The
    ///      `LivoTaxableTokenInitialized` event carries `startTaxFromLaunch` plus the three `*Decay*`
    ///      fields configuring the linear launch-tax decay.
    function _initializeTaxConfig(TaxConfigs memory cfg) internal {
        emit LivoTaxableTokenInitialized(
            cfg.buyTaxBps,
            cfg.sellTaxBps,
            uint40(cfg.taxDurationSeconds),
            cfg.startTaxFromLaunch,
            cfg.buyTaxDecayStartBps,
            cfg.sellTaxDecayStartBps,
            uint40(cfg.taxDecayDuration)
        );

        buyTaxBps = cfg.buyTaxBps;
        sellTaxBps = cfg.sellTaxBps;
        taxDurationSeconds = uint40(cfg.taxDurationSeconds);
        startTaxFromLaunch = cfg.startTaxFromLaunch;
        buyTaxDecayStartBps = cfg.buyTaxDecayStartBps;
        sellTaxDecayStartBps = cfg.sellTaxDecayStartBps;
        taxDecayDuration = uint40(cfg.taxDecayDuration);
    }

    /// @dev True while EITHER the static or the decay window is open. Used by the V2 `_update` swap-back
    ///      drain to detect that no further tax can ever flow. The anchor is `startTaxFromLaunch`-dependent:
    ///      - `true`: anchored at `launchTimestamp` (creation-anchored, spans graduation). Non-zero after
    ///        init, so the window is live from launch.
    ///      - `false`: anchored at `graduationTimestamp` (graduation-anchored). Before graduation
    ///        `graduationTimestamp == 0`, so this returns false and no tax is charged pre-graduation.
    ///      The window length is the longer of the static and decay durations.
    function _taxWindowActive() internal view returns (bool) {
        uint256 anchor = _taxAnchor();
        if (anchor == 0) return false;
        return block.timestamp <= anchor + _maxWindowDuration();
    }

    /// @dev Anchor timestamp shared by both the static and decay windows: `launchTimestamp` if
    ///      `startTaxFromLaunch`, else `graduationTimestamp` (0 before graduation ⇒ no tax yet).
    function _taxAnchor() internal view returns (uint256) {
        return startTaxFromLaunch ? launchTimestamp : graduationTimestamp;
    }

    /// @dev The longer of the static and decay window durations (seconds).
    function _maxWindowDuration() internal view returns (uint256) {
        uint256 staticDuration = taxDurationSeconds;
        uint256 decayDuration = taxDecayDuration;
        return staticDuration > decayDuration ? staticDuration : decayDuration;
    }

    /// @dev Effective tax (bps) for ONE direction — the hot path. `getLaunchpadFees` (pre-graduation
    ///      launchpad) and the V2 intrinsic `_update` both know the trade direction, so they read and
    ///      compute ONLY the side they need: the opposite direction's `*TaxDecayStartBps` / `*TaxBps` are
    ///      never touched and its decay arithmetic is never run. `max(decay, static)`, with the decay
    ///      falling linearly from `*TaxDecayStartBps` at the anchor to the long-term `*TaxBps` at
    ///      `elapsed == taxDecayDuration` (decay-only token: `*TaxBps == 0`, the familiar start->0 ramp).
    /// @dev Curve is intentionally inlined rather than shared with `_effectiveTaxBps()` below via a helper:
    ///      a non-inlined internal helper costs call/arg overhead on every trade, so both readers keep their
    ///      own copy. ⚠️ KEEP THE TWO IN SYNC — any change to the `max(decay, static)` formula here must be
    ///      mirrored in `_effectiveTaxBps()` (covered by the `test/tokens/taxDecay.t.sol` curve tests).
    function _effectiveTaxBps(bool isBuy) internal view returns (uint16 bps) {
        uint256 anchor = _taxAnchor();
        if (anchor == 0) return 0; // graduation-anchored and not graduated yet ⇒ no tax
        uint256 elapsed = block.timestamp - anchor; // anchor is always in the past, so no underflow

        // Read only the requested direction's rates.
        (uint16 decayStartBps, uint16 staticBps) =
            isBuy ? (buyTaxDecayStartBps, buyTaxBps) : (sellTaxDecayStartBps, sellTaxBps);

        uint256 decayDuration = taxDecayDuration;
        if (decayDuration != 0 && elapsed < decayDuration) {
            uint256 remaining = decayDuration - elapsed;
            // (start*remaining + static*elapsed) / duration — exact at both endpoints
            bps = uint16((uint256(decayStartBps) * remaining + uint256(staticBps) * elapsed) / decayDuration);
        }
        if (elapsed <= taxDurationSeconds && staticBps > bps) bps = staticBps;
    }

    /// @dev Effective tax for BOTH directions, for `getTaxConfig` (the V4 hook read, which must surface buy
    ///      AND sell). Same `max(decay, static)` curve as `_effectiveTaxBps(bool)` above, run for each side
    ///      with the shared anchor/elapsed and decay/static DURATIONS read once. ⚠️ KEEP IN SYNC with the
    ///      single-direction reader above.
    /// @dev ⚠️ ASSUMPTION baked into `getTaxConfig`: buy and sell share one decay schedule
    ///      (`taxDecayDuration`) and one static window (`taxDurationSeconds`) — only the rate differs — so
    ///      both directions reach 0 at the SAME time. `getTaxConfig` relies on this: it derives a single
    ///      window end and treats `buy == 0 && sell == 0` as "tax fully over". If a future change gives the
    ///      two directions DIFFERENT durations, revisit `getTaxConfig` (per-direction window ends) and any
    ///      "both zero ⇒ inactive" logic.
    function _effectiveTaxBps() internal view returns (uint16 buyBps, uint16 sellBps) {
        uint256 anchor = _taxAnchor();
        if (anchor == 0) return (0, 0); // graduation-anchored and not graduated yet ⇒ no tax
        uint256 elapsed = block.timestamp - anchor; // anchor is always in the past, so no underflow

        // Static rates double as the decay's floor/target (the decay interpolates DOWN to them).
        uint16 buyStatic = buyTaxBps;
        uint16 sellStatic = sellTaxBps;

        uint256 decayDuration = taxDecayDuration;
        if (decayDuration != 0 && elapsed < decayDuration) {
            uint256 remaining = decayDuration - elapsed;
            buyBps = uint16((uint256(buyTaxDecayStartBps) * remaining + uint256(buyStatic) * elapsed) / decayDuration);
            sellBps =
                uint16((uint256(sellTaxDecayStartBps) * remaining + uint256(sellStatic) * elapsed) / decayDuration);
        }
        // After the decay window the static rate holds for the rest of its window; the max() also guards
        // the degenerate config where the start rate is below the static rate.
        if (elapsed <= taxDurationSeconds) {
            if (buyStatic > buyBps) buyBps = buyStatic;
            if (sellStatic > sellBps) sellBps = sellStatic;
        }
    }
}
