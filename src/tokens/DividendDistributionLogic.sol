// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoDividendSwapRegistry, SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";

/// @title DividendDistributionLogic
/// @notice The COLD half of `DividendDistribution`: the round machinery, the native -> payout-asset
///         conversion, and the per-holder push. Everything here runs out-of-band, driven by a keeper or
///         a holder — never from a transfer or a swap.
///
/// @dev ONE ENTRY POINT. `processRound` freezes, pays and rolls over, in that order, doing whichever of
///      the three the round is due for. They were three separate transactions once, and there was never
///      a reason for it: they are strictly sequential, and the safety of freezing and paying in the same
///      transaction comes from the minimum-balance rule, not from a transaction boundary — receiving
///      borrowed tokens IS a tracked balance change, so a borrower's minimum for the round is zero
///      however the rest of the call is arranged. `MIN_ROUND_DURATION` guards the other instant, the
///      round's OPEN, and it still does.
///
/// @dev WHY THIS IS A SEPARATE CONTRACT. Taxable tokens are CLONES of a single implementation, and that
///      implementation has to fit in EIP-170's 24,576 bytes. The dividend engine did not fit alongside
///      the rest of the token, so this half — never on a hot path — lives behind a thin `delegatecall`
///      stub per entry point (see `DividendDistribution._delegateToDividendLogic`), in a contract
///      deployed ONCE per venue per chain by the token implementation's own constructor.
///
/// @dev The delegatecall means every line below runs in the TOKEN's context: `address(this)` is the
///      token, the pot is paid out of the token's own balance, the events are emitted from the token's
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

    /// @notice `processRound` was called with nothing to freeze and no frozen round to pay.
    error NoFrozenRound();

    /// @notice What `_freezeDividends` found. A return value rather than a flag because the caller has
    ///         to distinguish four outcomes, three of which carry no amounts.
    enum FreezeOutcome {
        /// @dev Nothing buffered, or not enough of it yet. The quiet, normal answer.
        NotReady,
        /// @dev The pot is funded with `out` of the payout asset.
        Converted,
        /// @dev Enough was buffered and the conversion did not happen. The buffer is untouched.
        ConversionFailed,
        /// @dev The conversion is permanently impossible AND an earlier round left a residual in the
        ///      old asset. Freeze on that residual alone so it reaches holders; the asset downgrade
        ///      then happens on the following round, against an empty pot — the `dividendPoolDead`
        ///      flag this outcome sets is what keeps that "following round" from meaning "another
        ///      `STALE_ROUND_WINDOW` from now".
        DrainResidual
    }

    //////////////////////// configuration //////////////////////

    /// @dev Stores the creation-time payout configuration. Called once, by the token, only when the
    ///      earnings allocation routes a non-zero share to dividends.
    /// @dev THE ONLY ELIGIBILITY RULE IS LIQUIDITY, and the registry is the one that measures it: any
    ///      ERC20 with a Uniswap V2 pair deep enough to swap against is accepted, with no whitelist, no
    ///      per-asset approval and no route for the creator to name. Asking here is what stops a creator
    ///      from configuring a payout their own token could never convert into — the failure mode a
    ///      clone cannot be patched out of.
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

    //////////////////////// the round //////////////////////

    /// @notice Advances the token's dividend round by everything it is due for: freezes the pot if the
    ///         round is unfrozen and the buffer has cleared its threshold, pushes payouts to `holders`,
    ///         and rolls the round over once the pot is drained (or its payout window has expired).
    ///         Permissionless, and the only entry point a keeper needs.
    ///
    /// @dev Idempotent and unforgeable in the part that matters: the amounts are computed here from each
    ///      holder's own round minimum, so a duplicate address pays 0, an unknown address pays 0, and an
    ///      omitted holder is simply paid next round. Callers with a holder list too long for one block
    ///      call it again with the next batch — the freeze happens once, the rollover happens once, and
    ///      the calls in between are pure payout batches.
    ///
    /// @dev The freeze is DERIVED, never chosen by the caller: which round freezes, and on what, is a
    ///      function of the buffer and the clock alone. The only thing a caller supplies is the slippage
    ///      floor for their own conversion.
    ///
    /// @param minOut Slippage floor for the conversion, in the payout asset's own decimals. Ignored when
    ///        the payout asset is native or the token itself, and by any call that does not freeze.
    /// @param holders Addresses to push this round's payouts to. May be empty — a freeze-only or
    ///        rollover-only call is a normal thing for a keeper to make.
    function processRound(uint256 minOut, address[] calldata holders) external nonReentrantDividends {
        uint32 round = currentRound;
        require(round != 0, DividendsNotActive());

        if (!roundFrozen) {
            // The one instant an attacker would want to control is the round's OPEN, because that is
            // where balances are read live and rolling over is permissionless. A floor here is what
            // stops open -> freeze -> pay fitting inside one flash loan.
            require(block.timestamp >= uint256(roundOpenedAt) + MIN_ROUND_DURATION, RoundTooYoung());

            (FreezeOutcome outcome, uint256 nativeIn, uint256 out) = _freezeDividends(minOut);
            // Two different situations, two different errors: a keeper that sees `BelowDividendThreshold`
            // has to wait for earnings, one that sees `DividendConversionFailed` has the earnings and a
            // swap problem — a `minOut` the pool has moved past, or a pool that is gone. Reporting the
            // first for the second sends it away to wait for money that already arrived.
            if (outcome == FreezeOutcome.NotReady) {
                // A STALE ROUND ALWAYS MAKES PROGRESS. Reaching here with nothing buffered at all means
                // a token that has not earned in a month, and leaving its round open forever would
                // measure every holder's share against their low-water mark over that whole span. Roll
                // it over instead: it resets the stale clock, and it is the only case where a call with
                // nothing to freeze is worth its gas.
                if (!_roundIsStale()) revert BelowDividendThreshold();
                _finalizeRound(round);
                return;
            }
            if (outcome == FreezeOutcome.ConversionFailed) revert DividendConversionFailed();

            uint96 denom = roundTotalShares;
            uint256 pot = roundPot + out; // adds to whatever earlier rounds left unpaid
            roundPot = pot;
            roundFrozen = true;
            frozenShares = denom;
            roundClosedAt = uint40(block.timestamp);
            // Read AFTER the freeze: a dead-pool downgrade rewrites it, and the event must name the
            // asset the pot is actually denominated in.
            emit DividendRoundFunded(round, dividendToken, nativeIn, pot, denom);
        }

        if (holders.length != 0) {
            uint256 denom = frozenShares;
            address asset = dividendToken;
            uint256 paid;
            for (uint256 i; i < holders.length; ++i) {
                paid += _payHolder(holders[i], round, asset, denom, NATIVE_PAYOUT_GAS);
            }
            if (paid != 0) roundPaid += paid;
        }

        // Rolls as soon as the pot is drained to dust. The window is the escape hatch for a pot that
        // CANNOT be drained — a holder whose `receive()` reverts, an address a payout asset blacklists —
        // without which the round would never roll and the token's dividends would stop for good.
        if (_roundSettled() || block.timestamp >= uint256(roundClosedAt) + PAYOUT_WINDOW) {
            _finalizeRound(round);
        }
    }

    /// @notice Self-serve backstop for a holder the keeper missed. Same formula, same paid marker.
    /// @dev Forwards ALL remaining gas to a native payout instead of `NATIVE_PAYOUT_GAS`. The stipend
    ///      exists to stop one expensive fallback from starving the REST of a keeper batch; a self-serve
    ///      claim has no rest of a batch, and the caller is spending their own gas on their own payout.
    ///      This is what keeps the stipend a throughput knob rather than a permanent eligibility gate —
    ///      a holder whose wallet costs more than a batch will spend can still always be paid here.
    function claimRound() external nonReentrantDividends {
        require(roundFrozen, NoFrozenRound());
        uint256 paid = _payHolder(msg.sender, currentRound, dividendToken, frozenShares, gasleft());
        if (paid != 0) roundPaid += paid;
    }

    //////////////////////// internal //////////////////////

    /// @dev Rolls the round over: whatever stayed unpaid seeds the next round's pot, and a fresh
    ///      denominator is read from live balances.
    function _finalizeRound(uint32 round) private {
        uint256 pot = roundPot;
        uint256 alreadyPaid = roundPaid;
        if (alreadyPaid != 0) {
            pot -= alreadyPaid;
            roundPot = pot;
            roundPaid = 0;
        }

        emit DividendRoundFinalized(round, pot);
        _openDividendRound();
    }

    /// @dev Whether the open round has aged past `STALE_ROUND_WINDOW`, i.e. the token has not had a
    ///      rollover in a month. Only read while the round is UNFROZEN, so `roundOpenedAt` is always the
    ///      right anchor here.
    function _roundIsStale() private view returns (bool) {
        return block.timestamp >= uint256(roundOpenedAt) + STALE_ROUND_WINDOW;
    }

    /// @dev True when the frozen pot has been paid down to within 0.01%.
    function _roundSettled() private view returns (bool) {
        uint256 pot = roundPot;
        return (pot - roundPaid) * 10_000 <= pot;
    }

    /// @dev Turns the accrued buffer into a payable pot, or reports why it could not. Overridable so a
    ///      venue can source the payout from somewhere other than the native buffer (the V2 self-token
    ///      payout, which is carved from tax tokens).
    function _freezeDividends(uint256 minOut)
        internal
        virtual
        returns (FreezeOutcome outcome, uint256 nativeIn, uint256 out)
    {
        uint256 buffered = pendingNative;
        if (buffered == 0) return (FreezeOutcome.NotReady, 0, 0);

        // The threshold exists so a distribution only fires when the pot is worth its gas, and staleness
        // is its ONLY bypass: a residual below the threshold on a token nobody has traded or finalized
        // for `STALE_ROUND_WINDOW` would otherwise strand forever.
        //
        // There used to be a second bypass — "the earnings source is provably finished", i.e. the V2 tax
        // window has closed — and it was a free grief. `accrueFees` and `sweepStrayEth` are both
        // permissionless, so anyone could push a wei into `pendingNative` after the window, freeze a pot
        // every holder's share rounds to zero out of, and stall settlement for a whole `PAYOUT_WINDOW`,
        // repeatably, for gas. Staleness costs 30 days of a completely idle token to reach, which is the
        // price that makes the bypass safe; nothing else was buying anything the stale clock does not
        // already deliver, only later.
        bool stale = _roundIsStale();
        if (buffered < DIVIDEND_THRESHOLD && !stale) {
            return (FreezeOutcome.NotReady, 0, 0);
        }

        address asset = dividendToken;
        // Only a payout that SWAPS is capped. Native is already denominated in the payout asset, so it
        // has no swap to sandwich, and throttling it would delay real money for no security gain.
        uint256 spend = (asset != address(0) && buffered > MAX_DIVIDEND_PER_FREEZE) ? MAX_DIVIDEND_PER_FREEZE : buffered;
        out = _acquireDividendAsset(asset, spend, minOut);

        if (out == 0) {
            // A conversion that did not happen must leave the buffer untouched, not burn it: the swap can
            // fail for reasons outside anyone's control, and the round simply stays unfrozen and tries
            // again. The two escapes below exist for the one case where "try again" never terminates —
            // the pool is gone and the buffer would be owed to holders forever.
            //
            // Neither is reachable on a live token, and neither can be manufactured: they need the round
            // to have gone `STALE_ROUND_WINDOW` without a rollover (a traded token rolls constantly) AND
            // `minOut == 0`, meaning the swap could not execute at ANY price. A caller passing a floor
            // the pool has merely moved past gets `ConversionFailed`, not a downgrade.
            // `dividendPoolDead` short-circuits the clock on the SECOND pass: the first pass already
            // proved the pool unreachable, and its residual drain rolled the round over — which reset
            // `roundOpenedAt` and would otherwise make the downgrade wait out another
            // `STALE_ROUND_WINDOW`, reverting every call in between.
            if (!(stale || dividendPoolDead) || minOut != 0) return (FreezeOutcome.ConversionFailed, 0, 0);

            // An earlier round's residual is denominated in the OLD asset. Pay that out first, under the
            // asset it was bought in; the downgrade below then runs against an empty pot, so a pot never
            // mixes two assets.
            if (roundPot != 0) {
                dividendPoolDead = true;
                return (FreezeOutcome.DrainResidual, 0, 0);
            }

            dividendPoolDead = false;
            dividendToken = address(0);
            emit DividendAssetDowngradedToNative(asset);
            // Native needs no conversion, so the whole buffer becomes the pot: the freeze cap only ever
            // existed to bound a swap.
            // forge-lint: disable-next-line(unsafe-typecast)
            pendingNative = uint88(pendingNative - buffered);
            return (FreezeOutcome.Converted, buffered, buffered);
        }

        // Re-read rather than reuse `buffered`: the swap is an external call, and earnings that arrived
        // during it (`_accrueDividends` is not behind the dividend lock) must survive this write.
        // Bounded by the value read, which is already a `uint88`.
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingNative = uint88(pendingNative - spend);
        // The pool converted again, so it was not dead after all — drop the downgrade short-circuit.
        if (dividendPoolDead) dividendPoolDead = false;
        return (FreezeOutcome.Converted, spend, out);
    }

    /// @dev Converts `nativeIn` into `asset`. Native needs no conversion; a third ERC20 is bought on the
    ///      pool the creator named for it. The token itself is venue-specific, handled by an override.
    /// @dev The route is the creator's, fixed at creation, and never the caller's: `processRound` is
    ///      permissionless, so a route supplied there would let any caller send the token's earnings
    ///      through a pool they control.
    /// @return out asset actually received, measured as a balance delta so a fee-on-transfer asset is
    ///         counted for what it delivered. 0 when the conversion did not happen — see
    ///         `_freezeDividends`.
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
    ///      asset blacklisted since creation, and this caller is a dividend freeze that must not lose
    ///      its buffer to any of those — a reverted call leaves the native exactly where it was, and
    ///      `false` here becomes `ConversionFailed` rather than a reverted round.
    function _swapNativeToDividendAsset(address asset, uint256 nativeIn, uint256 minOut) private returns (bool ok) {
        (ok,) = DIVIDEND_SWAP_REGISTRY.call{value: nativeIn}(
            abi.encodeCall(ILivoDividendSwapRegistry.swapNativeToAsset, (asset, minOut, address(this)))
        );
    }

    /// @dev Pays one holder, or nothing. The caller holds `nonReentrantDividends`, so nothing can revisit
    ///      this holder mid-payout and the marker is safe to write at the END — which is what lets it
    ///      record whether anything actually went out.
    /// @dev Marking a holder who received NOTHING would forfeit their round outright: `claimRound` would
    ///      find the marker set and pay 0, for that round and every future one it happened in. Leaving
    ///      them unmarked costs a retried (and gas-capped) send per batch instead.
    /// @param gasStipend Gas forwarded to a native payout: `NATIVE_PAYOUT_GAS` from a keeper batch,
    ///        `gasleft()` from `claimRound` (which, under EIP-150's 63/64 rule, is an uncapped call).
    /// @return The amount actually delivered, 0 if the holder was skipped or the send failed.
    function _payHolder(address holder, uint32 round, address asset, uint256 denom, uint256 gasStipend)
        private
        returns (uint256)
    {
        // Only reachable if the saturating `_reduceRoundShares` ever fires, which needs an exclusion set
        // this contract does not have. Guarded anyway: the alternative is a division panic that would
        // brick every payout of the round, in a clone nobody can patch.
        if (denom == 0) return 0;

        Acct storage acct = dividendAccounts[holder];
        if (acct.lastPaidRound == round || _dividendExcluded(holder)) return 0;

        uint256 shares = acct.roundId == round ? acct.minShares : _dividendBalanceOf(holder);
        if (shares == 0 || shares * MIN_SHARE_DENOM < denom) return 0;

        uint256 amount = roundPot * shares / denom;
        if (amount == 0) return 0;

        // A failed send is skipped, not reverted: one holder with a reverting `receive()` — or one
        // blacklisted by the payout asset — must not brick the batch. The amount stays in the pot and
        // rolls to the next round.
        if (!_payDividend(asset, holder, amount, gasStipend)) return 0;

        acct.lastPaidRound = round;
        emit DividendPaid(round, holder, asset, amount);
        return amount;
    }

    /// @dev Delivers one payout, reporting failure instead of reverting — for BOTH shapes. Native goes
    ///      out with a bounded stipend. A third asset is the creator's choice, and a creator's choice can
    ///      blacklist addresses, so a reverting `safeTransfer` on ONE holder would take down the whole
    ///      batch, `claimRound` for everyone, and with them the round's ability to settle.
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
        // exists not to do (it would brick the batch, `claimRound`, and the round's ability to settle).
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) != 0));
    }
}
