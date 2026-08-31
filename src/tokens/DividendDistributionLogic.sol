// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {ISwapRouteRegistry} from "src/interfaces/ISwapRouteRegistry.sol";
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
/// @notice The COLD half of `DividendDistribution`: the round machinery (freeze, pay, roll over), the
///         native -> payout-asset conversion, and the per-holder push. Everything here runs out-of-band,
///         driven by a keeper or a holder — never from a transfer or a swap.
///
/// @dev WHY THIS IS A SEPARATE CONTRACT. Taxable tokens are CLONES of a single implementation, and that
///      implementation has to fit in EIP-170's 24,576 bytes. The dividend engine costs ~12.9 KB of
///      runtime bytecode, which pushed both venue implementations ~5 KB over the limit. This half is
///      ~8.6 KB of it and is never on a hot path, so the token keeps a thin `delegatecall` stub per
///      entry point (see `DividendDistribution._delegateToDividendLogic`) and the bodies live here, in a
///      contract deployed ONCE per venue per chain by the token implementation's own constructor.
///
/// @dev The delegatecall means every line below runs in the TOKEN's context: `address(this)` is the
///      token, the pots are paid out of the token's own balance, the events are emitted from the token's
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

    /// @dev Helper for the left-packing check: the number of non-zero weights strictly before `i` must
    ///      equal `i`, i.e. there is no gap.
    function _filledLegsBefore(uint16[3] memory weights, uint256 i) private pure returns (uint256 filled) {
        for (uint256 j; j < i; ++j) {
            if (weights[j] != 0) ++filled;
        }
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

    //////////////////////// internal //////////////////////

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
}
