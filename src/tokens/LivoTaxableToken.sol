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
/// @dev Storage layout: this contract introduces 5 packed fields (buyTaxBps, sellTaxBps,
///      taxDurationSeconds, startTaxFromLaunch, graduationTimestamp) directly after `LivoToken`'s
///      storage. Subclasses that add their own state must do so AFTER these fields to preserve
///      clone-storage layout.
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

    /////////////////////////// pure storage ///////////////////////

    /// @notice Timestamp when token graduated (0 if not graduated)
    uint40 public graduationTimestamp;

    //////////////////////// Events //////////////////////

    /// @notice Emitted once during init with the dev-supplied tax config. `startTaxFromLaunch` selects
    ///         the tax-window anchor (creation vs graduation). The three `*Decay*` fields are reserved
    ///         for the upcoming linear tax-decay feature and are always emitted as 0 until it ships.
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

    /// @notice Pre-graduation fee policy. Same LP fee as the base, plus the tax for the active window
    ///         (0 outside it). For `startTaxFromLaunch == true` tokens the launchpad charges the exact
    ///         tax rate the V4 hook / V2 `_update` apply post-graduation; for graduation-anchored
    ///         tokens the window has not started pre-graduation, so the tax here is 0.
    function getLaunchpadFees(ILivoToken.LaunchpadTrade calldata trade)
        external
        view
        override(ILivoToken, LivoToken)
        returns (ILivoToken.LaunchpadFees memory)
    {
        uint16 taxBps = _taxWindowActive() ? (trade.isBuy ? buyTaxBps : sellTaxBps) : 0;
        return ILivoToken.LaunchpadFees({lpFeeBps: lpFeeBps, treasuryShareBps: treasuryShareBps, taxBps: taxBps});
    }

    /// @notice Returns the effective tax configuration. The tax window is anchored per
    ///         `startTaxFromLaunch`: at `launchTimestamp` (spans graduation) or at `graduationTimestamp`.
    /// @dev Once the window closes (or before it opens, for graduation-anchored tokens) this returns a
    ///      fully-zeroed tax (both rates AND `taxDurationSeconds`), so the `LivoSwapHook` — which
    ///      computes `block.timestamp > graduationTimestamp + taxDurationSeconds` and reads the rates —
    ///      correctly stops taxing. For creation-anchored tokens the zeroed `taxDurationSeconds` collapses
    ///      the hook's graduation-anchored check onto the creation-anchored expiry, and the zeroed rates
    ///      also cover the edge where the window expires before graduation and a swap lands in the
    ///      graduation block. Within the window it returns the stored rates and duration.
    function getTaxConfig() external view override(ILivoToken, LivoToken) returns (TaxConfig memory config) {
        if (!_taxWindowActive()) {
            // window closed: report no active tax. `graduationTimestamp` is still surfaced for reference.
            return
                TaxConfig({
                    buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, graduationTimestamp: graduationTimestamp
                });
        }
        config = TaxConfig({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: taxDurationSeconds,
            graduationTimestamp: graduationTimestamp
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

    /// @notice Internal helper to store tax configuration.
    /// @dev Tax-bps and duration bounds are enforced upstream in the factory. The
    ///      `LivoTaxableTokenInitialized` event carries `startTaxFromLaunch` plus three placeholder
    ///      `*Decay*` fields (emitted as 0) reserved for the upcoming linear tax-decay feature, so the
    ///      indexer schema is forward-compatible and won't need another signature change when it ships.
    function _initializeTaxConfig(TaxConfigInit memory cfg) internal {
        emit LivoTaxableTokenInitialized(
            cfg.buyTaxBps,
            cfg.sellTaxBps,
            uint40(cfg.taxDurationSeconds),
            cfg.startTaxFromLaunch,
            0, // buyTaxDecayStartBps: reserved for the upcoming linear tax-decay feature
            0, // sellTaxDecayStartBps: reserved (see above)
            0 // taxDecayDuration: reserved (see above)
        );

        buyTaxBps = cfg.buyTaxBps;
        sellTaxBps = cfg.sellTaxBps;
        taxDurationSeconds = uint40(cfg.taxDurationSeconds);
        startTaxFromLaunch = cfg.startTaxFromLaunch;
    }

    /// @dev True while the tax window is open. The anchor is `startTaxFromLaunch`-dependent:
    ///      - `true`: `[launchTimestamp, launchTimestamp + taxDurationSeconds]` (creation-anchored,
    ///        spans graduation). `launchTimestamp` is non-zero after init, so the window is always live.
    ///      - `false`: `[graduationTimestamp, graduationTimestamp + taxDurationSeconds]`
    ///        (graduation-anchored). Before graduation `graduationTimestamp == 0`, so this returns
    ///        false and no tax is charged pre-graduation.
    function _taxWindowActive() internal view returns (bool) {
        uint256 anchor = startTaxFromLaunch ? launchTimestamp : graduationTimestamp;
        if (anchor == 0) return false;
        return block.timestamp <= anchor + taxDurationSeconds;
    }
}
