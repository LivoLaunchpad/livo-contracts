// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Factory} from "src/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {UniversalRouterVenue} from "src/libraries/UniversalRouterVenue.sol";
import {DividendRoute, DividendVenue} from "src/types/DividendRoute.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet}.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
// Aliased so the `chain-arc-*` recipe can import-swap it: on ARC the "native" leg is 18-dec native USDC
// and the V2 quote token is its 6-dec ERC-20 alias, so buying a third asset is a two-ERC20 hop.
import {UniswapV2Venue as UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";

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
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

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
        ///      then happens on the following round, against an empty pot.
        DrainResidual
    }

    //////////////////////// configuration //////////////////////

    /// @dev Stores the creation-time payout configuration. Called once, by the token, only when the
    ///      earnings allocation routes a non-zero share to dividends.
    /// @dev THE ONLY ELIGIBILITY RULE IS LIQUIDITY. There is no whitelist, no admin approval and no
    ///      curated route list anywhere in this feature: any ERC20 a creator names is accepted, provided
    ///      the pool they name for it exists and holds `MIN_DIVIDEND_POOL_LIQUIDITY` of the quote asset
    ///      right now. That check is what stops a creator from configuring a payout their own token can
    ///      never convert into — the failure mode a clone cannot be patched out of.
    function _initializeDividends(address token, DividendRoute memory route) internal {
        // Resolve the "pay in the token itself" sentinel now, so every later read is a plain address.
        if (token == DIVIDEND_SELF_TOKEN) token = address(this);

        // Native and the token itself have nothing to buy: no route, no pool, nothing to prove.
        if (token != address(0) && token != address(this)) {
            _requireDividendPoolLiquidity(token, route);
            dividendRoute = route;
        }

        dividendToken = token;
        emit DividendsInitialized(token);
    }

    /// @dev Proves, at creation time, that the payout asset can actually be bought — the whole of the
    ///      eligibility rule. Refuses a venue this chain cannot reach, then requires the named pool to
    ///      exist and to be worth swapping against.
    /// @dev The V2 and V3 checks are exact: both pool shapes hold their own tokens, so the quote-side
    ///      balance IS the depth the swap will cross. V4 is a singleton and holds every pool's funds
    ///      together, so the check there is the pool's ACTIVE liquidity being non-zero — weaker, but it
    ///      still separates "this pool exists and is swappable" from "this pool is a typo". In all three
    ///      cases what protects an individual swap is the caller's `minOut`, not this.
    function _requireDividendPoolLiquidity(address asset, DividendRoute memory route) private view {
        if (route.venue == DividendVenue.UNIV2) {
            require(
                DIVIDEND_SWAP_ROUTER != address(0) && DIVIDEND_UNIV2_FACTORY != address(0), UnsupportedDividendAsset()
            );
            address quote = UniswapV2Venue.pairToken(IUniswapV2Router(DIVIDEND_SWAP_ROUTER));
            address pair = IUniswapV2Factory(DIVIDEND_UNIV2_FACTORY).getPair(quote, asset);
            require(pair != address(0), InsufficientDividendPoolLiquidity());

            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
            uint256 quoteReserve = IUniswapV2Pair(pair).token0() == quote ? reserve0 : reserve1;
            // `QUOTE_TO_NATIVE_SCALE` lifts the pool's quote units to native 18-dec, which is what the
            // threshold is denominated in. It is 1 on ETH-family chains and 1e12 on ARC.
            require(
                quoteReserve * UniswapV2Venue.QUOTE_TO_NATIVE_SCALE >= MIN_DIVIDEND_POOL_LIQUIDITY,
                InsufficientDividendPoolLiquidity()
            );
            return;
        }

        // Both universal-router venues pay with native ETH, which ARC does not have.
        require(NATIVE_IS_ETH && DIVIDEND_UNIVERSAL_ROUTER != address(0), UnsupportedDividendAsset());

        if (route.venue == DividendVenue.UNIV3) {
            // A V3 pool is keyed by its fee tier, which is never zero.
            require(route.fee != 0 && DIVIDEND_UNIV3_FACTORY != address(0), UnsupportedDividendAsset());
            address pool = IUniswapV3Factory(DIVIDEND_UNIV3_FACTORY).getPool(DeploymentAddresses.WETH, asset, route.fee);
            require(pool != address(0), InsufficientDividendPoolLiquidity());
            require(
                IERC20(DeploymentAddresses.WETH).balanceOf(pool) >= MIN_DIVIDEND_POOL_LIQUIDITY,
                InsufficientDividendPoolLiquidity()
            );
            return;
        }

        // A V4 pool is keyed by its tick spacing, which is never zero.
        require(route.tickSpacing != 0 && DIVIDEND_UNIV4_POOL_MANAGER != address(0), UnsupportedDividendAsset());
        require(
            IPoolManager(DIVIDEND_UNIV4_POOL_MANAGER).getLiquidity(_dividendPoolKey(asset, route).toId()) != 0,
            InsufficientDividendPoolLiquidity()
        );
    }

    /// @dev The V4 pool a native -> asset conversion crosses. Native is `address(0)`, which sorts below
    ///      every real address, so the pool is always `currency0 -> currency1`.
    function _dividendPoolKey(address asset, DividendRoute memory route) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(asset),
            fee: route.fee,
            tickSpacing: route.tickSpacing,
            hooks: IHooks(route.hooks)
        });
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

        // The threshold exists so a distribution only fires when the pot is worth its gas. It has to stop
        // applying wherever the residual can no longer grow, or the last of it strands — the same drain
        // rule the V2 swap-back already uses. Two independent ways that happens:
        //   - the earnings source is provably finished (the V2 tax window closed), or
        //   - nothing has happened to this token for `STALE_ROUND_WINDOW`. This is the only escape a
        //     venue whose earnings never formally stop can have: `LivoTaxableTokenUniV4` answers `true`
        //     forever because LP fees keep arriving while the pool is live, which is right for a live
        //     token and would otherwise strand every dead one.
        bool stale = _roundIsStale();
        if (buffered < DIVIDEND_THRESHOLD && _dividendEarningsMayStillArrive() && !stale) {
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
            if (!stale || minOut != 0) return (FreezeOutcome.ConversionFailed, 0, 0);

            // An earlier round's residual is denominated in the OLD asset. Pay that out first, under the
            // asset it was bought in; the downgrade below then runs against an empty pot, so a pot never
            // mixes two assets.
            if (roundPot != 0) return (FreezeOutcome.DrainResidual, 0, 0);

            dividendToken = address(0);
            emit DividendAssetDowngradedToNative(asset);
            // Native needs no conversion, so the whole buffer becomes the pot: the freeze cap only ever
            // existed to bound a swap.
            // forge-lint: disable-next-line(unsafe-typecast)
            pendingNative = uint80(pendingNative - buffered);
            return (FreezeOutcome.Converted, buffered, buffered);
        }

        // Re-read rather than reuse `buffered`: the swap is an external call, and earnings that arrived
        // during it (`_accrueDividends` is not behind the dividend lock) must survive this write.
        // Bounded by the value read, which is already a `uint80`.
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingNative = uint80(pendingNative - spend);
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

    /// @dev The venue dispatch of `_acquireDividendAsset`, split out only to keep that function's stack
    ///      shallow. Reports failure instead of reverting; see `_freezeDividends`.
    function _swapNativeToDividendAsset(address asset, uint256 nativeIn, uint256 minOut) private returns (bool) {
        DividendRoute memory route = dividendRoute;
        if (route.venue == DividendVenue.UNIV2) {
            // The pool proven at creation is the canonical quote/asset pair, so the path is fixed. No
            // intermediate hop: an asset that cannot be reached directly from the quote token could not
            // have proven its liquidity in the first place.
            address[] memory path = new address[](2);
            path[0] = DeploymentAddresses.WETH;
            path[1] = asset;
            return UniswapV2Venue.trySwapNativeToAsset(
                IUniswapV2Router(DIVIDEND_SWAP_ROUTER), DeploymentAddresses.WETH, path, nativeIn, minOut
            );
        }
        if (route.venue == DividendVenue.UNIV3) {
            return UniversalRouterVenue.swapNativeToAssetV3(
                DIVIDEND_UNIVERSAL_ROUTER, DeploymentAddresses.WETH, asset, route.fee, nativeIn, minOut
            );
        }
        return UniversalRouterVenue.swapNativeToAssetV4(
            DIVIDEND_UNIVERSAL_ROUTER, asset, route.fee, route.tickSpacing, route.hooks, nativeIn, minOut
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
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }
}
