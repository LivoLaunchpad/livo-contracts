// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTaxableToken, TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LivoTaxableToken
/// @notice Abstract base for Livo taxable tokens shared by the Uniswap V2 and V4 variants.
///         Owns the tax-config storage, the post-graduation timestamp, the standard `markGraduated`
///         + `getTaxConfig` overrides, the dev-supplied init plumbing and the owner-only
///         `rescueTokens` path. Variant-specific behavior (intrinsic V2 taxation, V4 pool-manager
///         pair check) lives in the concrete subclasses.
/// @dev Storage layout: this contract introduces 8 packed fields (buyTaxBps, sellTaxBps,
///      taxDurationSeconds, startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps,
///      taxDecayDuration, graduationTimestamp) directly after `LivoToken`'s storage. They all pack
///      into a single slot (alongside the V2 subclass's swap-back counters), so the per-trade tax read
///      is a single warm SLOAD. Subclasses that add their own state must do so AFTER these fields to
///      preserve clone-storage layout.
abstract contract LivoTaxableToken is LivoToken, ILivoTaxableToken {
    using SafeERC20 for IERC20;

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
    ///         linearly from this value to 0 over `taxDecayDuration`, from the same anchor
    ///         `startTaxFromLaunch` selects. 0 disables buy decay. Set during init, cannot be changed.
    uint16 public buyTaxDecayStartBps;

    /// @notice Sell-tax rate at the anchor for the optional linear decay (bps). Mirror of
    ///         `buyTaxDecayStartBps` for sells. 0 disables sell decay. Set during init, cannot be changed.
    uint16 public sellTaxDecayStartBps;

    /// @notice Duration in seconds over which the decay rates fall from their start values to 0,
    ///         measured from the same anchor as the static window. 0 disables decay. The effective tax a
    ///         trade pays is `max(decay, static)` per direction, so a token may set ONLY these decay
    ///         fields (static bps + duration zero) for a pure decaying launch tax. Set during init.
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

    /// @notice Allows the token owner OR the launchpad owner to rescue stuck balances.
    /// @dev Two restrictions:
    ///      (1) Self-token rescue is disallowed — the caller must NEVER be able to siphon accrued
    ///          tax balance ahead of a swap-back.
    ///      (2) ETH stuck in the contract is treated as un-routed fees and pushed back through
    ///          `feeHandler.depositFees` so it lands on the configured fee receivers, never on
    ///          the caller. Preserves the project's pull-over-push invariant for ETH.
    /// @dev The launchpad owner is included so the protocol admin can sweep stuck balances on
    ///      factory-deployed V2 tokens, where `owner == address(0)` makes the token-owner path
    ///      unreachable. The destination is unchanged regardless of caller: ETH → fee handler,
    ///      ERC20s → `owner` (which may be `address(0)`, in which case the transfer reverts —
    ///      acceptable, as a stuck-balance rescue with no recipient is a no-op anyway).
    /// @param token Token to rescue. Pass `address(0)` for ETH.
    function rescueTokens(address token) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());

        if (token == address(0)) {
            uint256 ethBalance = address(this).balance;
            if (ethBalance > 0) {
                // deposit fees to the token account in the master fee handler
                ILivoMasterFeeHandler(feeHandler).depositFees{value: ethBalance}(address(this));
            }
        } else if (token == address(this)) {
            // disallow rescuing the token's own balance to prevent siphoning accrued taxes
            revert CannotRescueSelfToken();
        } else {
            IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
        }
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

    /// @notice Returns the effective tax configuration for the deployed `LivoSwapHook` (and off-chain
    ///         readers). Reports the CURRENT effective rates — `max(decay, static)` per direction, which
    ///         change every second while the decay window is open — so the hook, which re-reads this on
    ///         every swap, applies the right (possibly decaying) rate.
    /// @dev The hook expires tax when `block.timestamp > graduationTimestamp + taxDurationSeconds`. Both
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

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Shared initializer body for taxable tokens. Subclasses override to add variant-specific
    ///      setup (e.g. router approval for V2, pool-manager pair check for V4) by chaining via
    ///      `super._initializeLivoTaxableToken(...)`.
    function _initializeLivoTaxableToken(ILivoToken.InitializeParams memory params, TaxConfigInit memory taxCfg)
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
    function _initializeTaxConfig(TaxConfigInit memory cfg) internal {
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

    /// @dev Current effective tax for BOTH directions: `max(decay, static)` each, where the decay rate
    ///      falls linearly from its start value at the anchor to 0 at `anchor + taxDecayDuration`, and the
    ///      static rate is the flat configured rate while within `[anchor, anchor + taxDurationSeconds]`.
    ///      Single source of truth for `getLaunchpadFees` (pre-graduation launchpad), `getTaxConfig`
    ///      (post-graduation V4 hook) and the V2 intrinsic `_update`.
    /// @dev Both directions are computed together on purpose: the decay schedule (`taxDecayDuration`) and
    ///      the static window (`taxDurationSeconds`) are SHARED across buy and sell — only the per-direction
    ///      rate differs — so the anchor/elapsed/window math is done once and every storage slot is read
    ///      once, instead of twice via a per-direction helper.
    /// @dev ⚠️ ASSUMPTION baked into callers: because buy and sell share one decay schedule and one static
    ///      window, both directions reach 0 at the SAME time. `getTaxConfig` relies on this — it derives a
    ///      single window end and treats `buy == 0 && sell == 0` as "tax fully over". If a future change
    ///      gives the two directions DIFFERENT durations, revisit `getTaxConfig` (per-direction window ends)
    ///      and any "both zero ⇒ inactive" logic.
    function _effectiveTaxBps() internal view returns (uint16 buyBps, uint16 sellBps) {
        uint256 anchor = _taxAnchor();
        if (anchor == 0) return (0, 0); // graduation-anchored and not graduated yet ⇒ no tax
        uint256 elapsed = block.timestamp - anchor; // anchor is always in the past, so no underflow

        // Decay component (shared schedule; only the start rate differs per direction).
        uint256 decayDuration = taxDecayDuration;
        if (decayDuration != 0 && elapsed < decayDuration) {
            uint256 remaining = decayDuration - elapsed;
            // startBps * remaining / duration — exact at the endpoints (startBps at the anchor, 0 at the end)
            buyBps = uint16(uint256(buyTaxDecayStartBps) * remaining / decayDuration);
            sellBps = uint16(uint256(sellTaxDecayStartBps) * remaining / decayDuration);
        }

        // Static component (shared window; only the rate differs per direction). Effective = max of the two.
        if (elapsed <= taxDurationSeconds) {
            uint16 buyStatic = buyTaxBps;
            uint16 sellStatic = sellTaxBps;
            if (buyStatic > buyBps) buyBps = buyStatic;
            if (sellStatic > sellBps) sellBps = sellStatic;
        }
    }

    /// @dev Single-direction convenience over `_effectiveTaxBps()` for the launchpad / V2 `_update` paths.
    ///      Computing the unused direction is effectively free — the storage reads (which dominate) are
    ///      shared, leaving only a multiply/divide on already-loaded values.
    function _effectiveTaxBps(bool isBuy) internal view returns (uint16) {
        (uint16 buyBps, uint16 sellBps) = _effectiveTaxBps();
        return isBuy ? buyBps : sellBps;
    }
}
