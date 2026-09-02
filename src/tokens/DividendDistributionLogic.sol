// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoDividendSwapRegistry, SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";

/// @title DividendDistributionLogic
/// @notice The COLD half of `DividendDistribution`: the native -> payout-asset conversion, the stream
///         funding, and the per-holder push. Everything here runs out-of-band, driven by a keeper or a
///         holder — never from a transfer or a swap.
///
/// @dev ONE ENTRY POINT for the keeper. `processDividends` converts the buffer, folds the proceeds into
///      the running stream and pushes payouts, doing whichever of the three there is anything to do.
///      They were three separate transactions and a round state machine once, and there was never a
///      reason for it: the anti-flash-loan property comes from the DRIP, not from a transaction boundary
///      or a phase, so the three collapse into one call that can be made at any moment.
///
/// @dev NOTHING HERE REVERTS FOR BEING EARLY. A distribution landing mid-stream is the normal case: it
///      folds the undelivered remainder into a fresh window and changes the slope. The only reverts are
///      for a call that could accomplish NOTHING — an empty push list against an unfundable buffer —
///      and they are there so a keeper's simulation gets a reason rather than a silent success.
///
/// @dev WHY THIS IS A SEPARATE CONTRACT. Taxable tokens are CLONES of a single implementation, and that
///      implementation has to fit in EIP-170's 24,576 bytes. The dividend engine did not fit alongside
///      the rest of the token, so this half — never on a hot path — lives behind a thin `delegatecall`
///      stub per entry point (see `DividendDistribution._delegateToDividendLogic`), in a contract
///      deployed ONCE per venue per chain by the token implementation's own constructor.
///
/// @dev The delegatecall means every line below runs in the TOKEN's context: `address(this)` is the
///      token, the payouts come out of the token's own balance, the events are emitted from the token's
///      address (so indexers see no change), and the `dividendLocked` transient guard is the token's.
///      Nothing is pooled and nothing is custodied here.
///
/// @dev ⚠️ STORAGE LAYOUT. This contract writes the token's storage directly, so the two layouts must be
///      byte-identical. The concrete extensions (`LivoDividendLogicUniV2` / `...UniV4`) inherit the same
///      venue base the token does and add no state of their own, so the compiler derives the layout for
///      both — never hand-maintain it. `just check-dividend-layout` fails if they ever drift.
///      The same applies to TRANSIENT slots, which is why `dividendLocked` stays declared in
///      `DividendDistribution` rather than moving here with the modifier's users.
abstract contract DividendDistributionLogic is DividendDistribution {
    /// @notice Thrown by every TOKEN entry point on an extension. An extension is an execution body for
    ///         a token, not a token: deployed once, never cloned, holding no balance, and its own
    ///         storage never read. Anyone reaching one of those entry points here has the wrong address.
    error NotAToken();

    /// @notice A distribution would have set a stream slope wider than `dividendRate` can hold. Not
    ///         reachable with any asset the registry accepts — see `_fundDividendStream`.
    error DividendRateOverflow();

    /// @notice What `_fundDividends` found. A return value rather than a flag because the caller has to
    ///         distinguish "wait for earnings" from "the earnings are here and the swap is broken".
    enum FundOutcome {
        /// @dev Nothing buffered, or not enough of it yet. The quiet, normal answer.
        NotReady,
        /// @dev The stream is funded with `out` of the payout asset.
        Funded,
        /// @dev Enough was buffered and the conversion did not happen. The buffer is untouched.
        ConversionFailed
    }

    //////////////////////// configuration //////////////////////

    /// @dev Stores the creation-time payout configuration. Called once, by the token, only when the
    ///      earnings allocation routes a non-zero share to dividends.
    /// @dev THE REGISTRY IS THE ONLY JUDGE, and the creator never names a route: any ERC20 with a
    ///      Uniswap V2 pair deep enough to swap against is accepted with no whitelist and no per-asset
    ///      approval, and so is one a registry admin has given a curated Uniswap V4 route (the only way
    ///      an asset with no V2 pair at all — Robinhood Chain's xStocks — can be reached). Asking here
    ///      is what stops a creator from configuring a payout their own token could never convert into
    ///      — the failure mode a clone cannot be patched out of.
    /// @dev The registry is a proxy behind a constant address, so a token created today is bound to the
    ///      RULE rather than to today's version of it: raising the threshold, blacklisting an asset or
    ///      adding a venue reaches this token too, for every conversion it has not made yet.
    function _initializeDividends(address token) internal {
        // Resolve the "pay in the token itself" sentinel now, so every later read is a plain address.
        if (token == DIVIDEND_SELF_TOKEN) token = address(this);

        // Native and the token itself have nothing to buy: no pool, nothing to prove.
        if (token != address(0) && token != address(this)) {
            ILivoDividendSwapRegistry registry = ILivoDividendSwapRegistry(DIVIDEND_SWAP_REGISTRY);
            (bool supported,, SwapRejection rejection) = registry.checkSwapSupported(registry.nativeQuoteToken(), token);
            require(supported, DividendAssetNotSupported(rejection));
        }

        dividendToken = token;
        emit DividendsInitialized(token);
    }

    //////////////////////// the distribution //////////////////////

    /// @notice Converts whatever has accrued into the payout asset, folds it into the running stream,
    ///         and pushes payouts to `holders`. Permissionless, and the only entry point a keeper needs.
    ///
    /// @dev Idempotent and unforgeable in the part that matters: the amounts are read from each holder's
    ///      own accrued balance, so a duplicate pays 0, an unknown address pays 0, and an omitted holder
    ///      loses nothing at all — their accrual keeps sitting there for the next batch or for their own
    ///      `claimDividends()`. A keeper is free to push only to holders above whatever size threshold
    ///      it likes; the small ones are not forfeiting anything by being skipped.
    ///
    /// @dev What gets funded, and when, is DERIVED: a function of the buffer and the clock alone. The
    ///      only thing a caller supplies is the slippage floor for their own conversion.
    ///
    /// @param minOut Slippage floor for the conversion, in the payout asset's own decimals. Ignored when
    ///        the payout asset is native or the token itself, and by any call that does not convert.
    /// @param holders Addresses to push accrued payouts to. May be empty — a fund-only call is a normal
    ///        thing for a keeper to make.
    function processDividends(uint256 minOut, address[] calldata holders) external nonReentrantDividends {
        require(dividendPeriodFinish != 0, DividendsNotActive());

        // Before anything else, for the reason the base spells out: the accumulator has to close the
        // interval that just ended at the supply that was actually in effect for it.
        uint256 rpt = _syncDividends();

        (FundOutcome outcome, uint256 nativeIn, uint256 out) = _fundDividends(minOut);
        if (outcome == FundOutcome.Funded) {
            _fundDividendStream(out);
            // Both read AFTER the funding: a dead-pool downgrade rewrites the asset AND restarts the
            // accumulator, so the event must name the asset the stream is actually denominated in and
            // the payout loop below must measure against the accumulator the holders are now on.
            emit DividendsFunded(dividendToken, nativeIn, out, dividendRate, dividendPeriodFinish);
            rpt = rewardPerTokenStored;
        }

        if (holders.length != 0) {
            address asset = dividendToken;
            uint256 paid;
            for (uint256 i; i < holders.length; ++i) {
                paid += _payHolder(holders[i], asset, rpt, NATIVE_PAYOUT_GAS);
            }
            _reduceDividendsOwed(paid);
        } else if (outcome == FundOutcome.NotReady) {
            // Two different situations, two different errors: a keeper that sees `BelowDividendThreshold`
            // has to wait for earnings, one that sees `DividendConversionFailed` has the earnings and a
            // swap problem — a `minOut` the pool has moved past, or a pool that is gone.
            revert BelowDividendThreshold();
        } else if (outcome == FundOutcome.ConversionFailed) {
            revert DividendConversionFailed();
        }
        // A call carrying holders never reverts for the buffer being short or the swap being broken: it
        // asked to push payouts, and it pushed them.
    }

    /// @notice Self-serve payout of everything the caller has accrued.
    /// @dev Forwards ALL remaining gas to a native payout instead of `NATIVE_PAYOUT_GAS`. The stipend
    ///      exists to stop one expensive fallback from starving the REST of a keeper batch; a self-serve
    ///      claim has no rest of a batch, and the caller is spending their own gas on their own payout.
    ///      This is what keeps the stipend a throughput knob rather than a permanent eligibility gate —
    ///      a holder whose wallet costs more than a batch will spend can still always be paid here.
    function claimDividends() external nonReentrantDividends {
        require(dividendPeriodFinish != 0, DividendsNotActive());
        uint256 rpt = _syncDividends();
        _reduceDividendsOwed(_payHolder(msg.sender, dividendToken, rpt, gasleft()));
    }

    //////////////////////// internal //////////////////////

    /// @dev Folds `amount` into the stream: whatever the running one still had to deliver is added to
    ///      it, and the sum is re-spread over a fresh full `DIVIDEND_DRIP_DURATION`. The slope changes;
    ///      nothing is ever rejected, delayed or carried over.
    ///
    /// @dev THE WHOLE POINT of re-spreading rather than appending: a stream that merely extended would
    ///      let a large distribution land at the old (small) slope, and the money would take
    ///      proportionally longer to reach holders the more of it there was. Re-spreading keeps the
    ///      delivery time constant and puts the size into the slope, which is the only variable a
    ///      flash-loan attacker cannot integrate against.
    function _fundDividendStream(uint256 amount) private {
        uint256 finish = dividendPeriodFinish;
        uint256 remaining = finish > block.timestamp ? (finish - block.timestamp) * dividendRate : 0;

        uint256 rate = (amount + remaining) / DIVIDEND_DRIP_DURATION;
        // Unreachable for any asset the registry accepts: `uint96` holds 7.9e28 units per second, i.e.
        // 7.1e31 units — 71 trillion whole tokens of an 18-decimal asset — inside one 15-minute window.
        // A revert here is a cold-path failure that leaves the buffer untouched, never a stuck token.
        require(rate <= type(uint96).max, DividendRateOverflow());

        // Owed grows by the whole distribution. Integer division leaves a sub-`DIVIDEND_DRIP_DURATION`
        // residue the stream cannot deliver, which stays owed and simply never leaves the balance —
        // dust, and dust that errs towards holders rather than towards a sweep.
        // `uint160` holds 1.5e48 payout-asset units; `amount` is bounded by the conversion cap.
        // forge-lint: disable-next-line(unsafe-typecast)
        dividendsOwed = uint160(uint256(dividendsOwed) + amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        dividendRate = uint96(rate);
        // forge-lint: disable-next-line(unsafe-typecast)
        dividendPeriodFinish = uint40(block.timestamp + DIVIDEND_DRIP_DURATION);
        // The caller synced first, so this only ever moves the clock FORWARD across a gap between
        // streams — seconds in which the rate was zero and nothing could have accrued.
        // forge-lint: disable-next-line(unsafe-typecast)
        lastDividendUpdate = uint40(block.timestamp);
    }

    /// @dev Saturating on purpose. The accumulator truncates in the holders' favour at every step, so
    ///      `Σ payouts <= dividendsOwed` holds by construction — but this runs in a non-upgradeable
    ///      clone, and a rounding surprise must degrade into a stale counter rather than into payouts
    ///      that revert forever.
    function _reduceDividendsOwed(uint256 paid) private {
        if (paid == 0) return;
        uint256 owed = dividendsOwed;
        // forge-lint: disable-next-line(unsafe-typecast)
        dividendsOwed = paid >= owed ? 0 : uint160(owed - paid);
    }

    /// @dev Turns the accrued buffer into payout-asset units, or reports why it could not. Overridable
    ///      so a venue can source the payout from somewhere other than the native buffer (the V2
    ///      self-token payout, which is carved from tax tokens).
    function _fundDividends(uint256 minOut) internal virtual returns (FundOutcome, uint256 nativeIn, uint256 out) {
        uint256 buffered = pendingNative;
        if (buffered == 0) return (FundOutcome.NotReady, 0, 0);

        // The threshold exists so a distribution only fires when it is worth its gas, and staleness is
        // its ONLY bypass: a residual below the threshold on a token nobody has traded for
        // `STALE_DIVIDEND_WINDOW` would otherwise strand forever. There is nothing to grief here any
        // more — a dust distribution just sets a dust slope, it cannot stall anything.
        bool stale = dividendsStale();
        if (buffered < DIVIDEND_THRESHOLD && !stale) return (FundOutcome.NotReady, 0, 0);

        address asset = dividendToken;
        // Only a payout that SWAPS is capped. Native is already denominated in the payout asset, so it
        // has no swap to sandwich, and throttling it would delay real money for no security gain.
        uint256 spend =
            (asset != address(0) && buffered > MAX_DIVIDEND_PER_CONVERSION) ? MAX_DIVIDEND_PER_CONVERSION : buffered;
        out = _acquireDividendAsset(asset, spend, minOut);

        if (out == 0) {
            // A conversion that did not happen must leave the buffer untouched, not burn it: the swap can
            // fail for reasons outside anyone's control, and the next call simply tries again. The escape
            // below exists for the one case where "try again" never terminates — the pool is gone and the
            // buffer would be owed to holders forever.
            //
            // Not reachable on a live token and not manufacturable: it needs `STALE_DIVIDEND_WINDOW`
            // without a single distribution AND `minOut == 0`, meaning the swap could not execute at ANY
            // price. A caller passing a floor the pool has merely moved past gets `ConversionFailed`.
            if (!stale || minOut != 0) return (FundOutcome.ConversionFailed, 0, 0);

            _downgradeDividendAsset(asset);
            // Native needs no conversion, so the whole buffer funds the stream: the conversion cap only
            // ever existed to bound a swap.
            // forge-lint: disable-next-line(unsafe-typecast)
            pendingNative = uint88(pendingNative - buffered);
            return (FundOutcome.Funded, buffered, buffered);
        }

        // Re-read rather than reuse `buffered`: the swap is an external call, and earnings that arrived
        // during it (`_accrueDividends` is not behind the dividend lock) must survive this write.
        // Bounded by the value read, which is already a `uint88`.
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingNative = uint88(pendingNative - spend);
        return (FundOutcome.Funded, spend, out);
    }

    /// @dev Permanently repoints the payout at native and writes off every unclaimed accrual in the old
    ///      asset by bumping `dividendEpoch` — each account rebases to zero on its next touch.
    /// @dev The write-off is the only coherent answer, not a shortcut. `Acct.rewards` is a bare number
    ///      of units with no asset attached, so carrying it across the downgrade would pay an old-asset
    ///      debt out of a new-asset balance, at a 1:1 unit ratio between two assets that may not even
    ///      share decimals. Claiming never depended on the pool being alive, so every holder had the
    ///      full `STALE_DIVIDEND_WINDOW` — thirty days after the last distribution — to take theirs.
    ///      What is left of the dead asset stops being `committedDividends` and becomes rescuable, which
    ///      is the only way it is ever recoverable at all.
    function _downgradeDividendAsset(address previous) private {
        dividendToken = address(0);
        dividendsOwed = 0;
        // Restart the accumulator with the epoch. An account still on the old epoch is read as
        // "checkpointed at zero", so this is what makes the write-off consistent for accounts that have
        // not been touched since — and what lets them accrue normally in the new asset from here.
        rewardPerTokenStored = 0;
        ++dividendEpoch;
        emit DividendAssetDowngradedToNative(previous);
    }

    /// @dev Converts `nativeIn` into `asset`. Native needs no conversion; a third ERC20 is bought on the
    ///      pool the creator named for it. The token itself is venue-specific, handled by an override.
    /// @dev The route is the creator's, fixed at creation, and never the caller's: `processDividends` is
    ///      permissionless, so a route supplied there would let any caller send the token's earnings
    ///      through a pool they control.
    /// @return out asset actually received, measured as a balance delta so a fee-on-transfer asset is
    ///         counted for what it delivered. 0 when the conversion did not happen — see
    ///         `_fundDividends`.
    function _acquireDividendAsset(address asset, uint256 nativeIn, uint256 minOut)
        internal
        virtual
        returns (uint256 out)
    {
        if (asset == address(0)) return nativeIn; // native: the buffer already IS the payout asset

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        if (!_swapNativeToDividendAsset(asset, nativeIn, minOut)) return 0;
        return IERC20(asset).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Hands the conversion to the registry, which re-checks eligibility, swaps and forwards the
    ///      asset back here in one call. Nothing about the route is stored on the token any more: the
    ///      registry resolves it, so a token created before a venue existed can still use it.
    /// @dev A LOW-LEVEL call, on purpose. The registry reverts on a dead pair, a missed floor or an
    ///      asset blacklisted since creation, and this caller is a distribution that must not lose its
    ///      buffer to any of those — a reverted call leaves the native exactly where it was, and
    ///      `false` here becomes `ConversionFailed` rather than a reverted distribution.
    function _swapNativeToDividendAsset(address asset, uint256 nativeIn, uint256 minOut) private returns (bool ok) {
        (ok,) = DIVIDEND_SWAP_REGISTRY.call{value: nativeIn}(
            abi.encodeCall(ILivoDividendSwapRegistry.swapNativeToAsset, (asset, minOut, address(this)))
        );
    }

    /// @dev Pays one holder everything they have accrued, or nothing.
    /// @dev The banked accrual is zeroed AFTER the send succeeds, never before. A failed send therefore
    ///      costs the holder nothing — the amount stays accrued and the next batch (or their own claim)
    ///      pays it. This is what a reverting `receive()` or a payout-asset blacklist degrades into.
    /// @dev Settling before reading is not optional: the caller has already advanced the accumulator, so
    ///      this holder's share of the interval that just closed is only in `Acct.rewards` after this.
    /// @param gasStipend Gas forwarded to a native payout: `NATIVE_PAYOUT_GAS` from a keeper batch,
    ///        `gasleft()` from `claimDividends` (which, under EIP-150's 63/64 rule, is an uncapped call).
    /// @return The amount actually delivered, 0 if the holder was skipped or the send failed.
    function _payHolder(address holder, address asset, uint256 rpt, uint256 gasStipend) private returns (uint256) {
        // An excluded address never accrues, so its `Acct` is a stale checkpoint against a live balance
        // — settling it would mint a phantom claim out of the accumulator's whole history.
        if (_dividendExcluded(holder)) return 0;

        _settleDividends(holder, rpt);
        uint256 amount = dividendAccounts[holder].rewards;
        if (amount == 0) return 0;

        if (!_payDividend(asset, holder, amount, gasStipend)) return 0;

        dividendAccounts[holder].rewards = 0;
        emit DividendPaid(holder, asset, amount);
        return amount;
    }

    /// @dev Delivers one payout, reporting failure instead of reverting — for BOTH shapes. Native goes
    ///      out with a bounded stipend. A third asset is the creator's choice, and a creator's choice can
    ///      blacklist addresses, so a reverting `safeTransfer` on ONE holder would take down the whole
    ///      batch and `claimDividends` for everyone.
    function _payDividend(address asset, address to, uint256 amount, uint256 gasStipend) private returns (bool) {
        if (asset == address(0)) {
            (bool sent,) = to.call{value: amount, gas: gasStipend}("");
            return sent;
        }
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        // `SafeERC20`'s success test minus the revert: empty returndata is success (non-standard ERC20s),
        // and anything too short to decode is failure rather than a panic. `asset` is known to be a
        // contract — its pot could only have been funded through a `balanceOf` call on it.
        // Decoded as a WORD, not a `bool`: `abi.decode(_, (bool))` reverts on any value above 1, which a
        // non-standard ERC20 may legally return — and reverting here is precisely what this function
        // exists not to do (it would brick the batch and `claimDividends`).
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) != 0));
    }
}
