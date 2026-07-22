// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title EarningsAllocation
/// @notice Splits a taxable token's post-graduation earnings — swap taxes AND the creator's share of
///         LP fees, which converge on the same ETH stream — into up to four buckets: the fund wallets
///         (the existing fee-handler distribution), buy-back-and-burn, holder dividends, and liquidity
///         additions.
/// @dev This is the routing PRIMITIVE only: the fund leg is live today; the other three are `virtual`
///      seams that currently FALL BACK to the fund wallets until their module ships (steps 2–4). The
///      fallback is deliberate: allocation shares are chosen at token creation, so a token launched
///      today with a non-zero `burnBps` safely routes that slice to the fund wallets now and
///      auto-activates once a concrete token overrides `_handleBurn` — no re-config, and no way to
///      create a token that bricks on its first post-graduation earnings.
///
/// @dev ⚠️ GAS BUDGET — READ BEFORE IMPLEMENTING A BUCKET. Earnings reach this split via
///      `LivoToken.accrueFees`. On the V4 LP-fee route that call is made by `LivoLpFeeRouter` from
///      inside `LivoSwapHook`'s `try { ... } { gas: ROUTER_GAS_LIMIT }` (≈1M gas) during a swap; if it
///      runs out of gas the hook drops the LP fee to the treasury. The split therefore MUST stay cheap:
///      each `_handle*` leg may only ACCRUE its slice (ideally a single SSTORE) for OUT-OF-BAND
///      processing — a keeper- or threshold-triggered swap / burn / liquidity-add in a separate tx with
///      full gas, mirroring the V2 swap-back pattern. A `_handle*` leg must NEVER perform a Uniswap
///      swap or `modifyLiquidity` synchronously: it would not fit the budget and, on the V4 route,
///      would also reenter the pool mid-swap. `_allocateEthEarnings` collapses every fund-bound slice into
///      ONE `_depositToFund`, so the whole path stays well within budget.
///
/// @dev Venue-agnostic and ETH-space: it divides whatever ETH it is handed by the configured bps and
///      dispatches each slice. Uniswap-V2/V4-specific mechanics (e.g. V2 burning tax tokens before the
///      swap-back to avoid an ETH→token round trip) live in the concrete token's override of
///      `_handle*`, not here. The fund bucket receives the integer-division remainder plus any slice a
///      leg leaves unconsumed, so no wei is ever stranded or double-counted.
/// @dev Storage: the three bps fields occupy a single dedicated slot placed before the taxable token's
///      packed tax slot, so the per-trade tax read stays a single warm SLOAD; the allocation bps are
///      only read on the (cold) earnings-routing path.
abstract contract EarningsAllocation {
    uint256 internal constant BPS_TOTAL = 10_000;

    /// @notice Post-graduation earnings share (bps) routed to buy-back-and-burn. 0 = disabled.
    ///         The fund-wallet share is the remainder after the three configurable buckets.
    uint16 public burnBps;

    /// @notice Post-graduation earnings share (bps) routed to holder dividends. 0 = disabled.
    uint16 public dividendsBps;

    /// @notice Post-graduation earnings share (bps) routed to liquidity additions. 0 = disabled.
    uint16 public liquidityBps;

    /// @notice Emitted once, at token creation, when a non-zero earnings allocation is configured.
    event EarningsAllocationInitialized(uint16 burnBps, uint16 dividendsBps, uint16 liquidityBps);

    /// @notice Thrown when the configured buckets sum to more than 100%.
    error InvalidEarningsAllocation();

    /// @dev Stores the creation-time allocation split. Called once by the token during initialization.
    ///      Validates only that the three buckets sum to at most 100%; the fund wallets take the rest.
    function _initializeEarningsAllocation(uint16 _burnBps, uint16 _dividendsBps, uint16 _liquidityBps) internal {
        require(uint256(_burnBps) + _dividendsBps + _liquidityBps <= BPS_TOTAL, InvalidEarningsAllocation());
        burnBps = _burnBps;
        dividendsBps = _dividendsBps;
        liquidityBps = _liquidityBps;
        emit EarningsAllocationInitialized(_burnBps, _dividendsBps, _liquidityBps);
    }

    /// @dev The ETH-space earnings split — the shared "phase 2" for both venues: given `amount` of ETH
    ///      and the burn share to carve FROM that ETH, it routes the burn / dividends / liquidity / fund
    ///      slices. Callers supply `burnShare`:
    ///      - V4: `burnBps` — burn is bought back from this ETH, so it's carved here and handed to
    ///        `_handleBurn` (which buffers it for the buy-back).
    ///      - V2: `0` — the burn was already taken upstream by burning tax TOKENS before the swap-back,
    ///        so this ETH is already net of it and nothing is carved here.
    ///      Dividends/liquidity are shares of the ORIGINAL earnings, but `nonBurn` is only the
    ///      `BPS_TOTAL - burnBps` fraction (whether burn left as ETH here or as tokens upstream), so they
    ///      are renormalized over that denom — making the two venues produce identical splits for the
    ///      same config. The fund wallets take the remainder plus any residual a leg leaves unconsumed,
    ///      folded into one deposit. Pre-graduation the whole amount goes to the fund wallets unchanged.
    function _allocateEthEarnings(uint256 amount, uint256 burnShare) internal {
        if (amount == 0) return;

        if (!_earningsGraduated()) {
            _depositToFund(amount);
            return;
        }

        uint256 burn = amount * burnShare / BPS_TOTAL;
        uint256 nonBurn = amount - burn;

        // `fund` accumulates the fund-wallet slice plus whatever each leg leaves unconsumed. Residuals
        // fold into FUND, never back into `nonBurn` — that would re-split them over dividends/liquidity.
        // `denom == 0` only for a 100%-burn token, where `nonBurn` is 0.
        uint256 denom = BPS_TOTAL - burnBps;
        uint256 dividends;
        uint256 liquidity;
        uint256 fund = nonBurn;
        if (denom != 0) {
            dividends = nonBurn * dividendsBps / denom;
            liquidity = nonBurn * liquidityBps / denom;
            fund = nonBurn - dividends - liquidity;
        }

        if (burn > 0) fund += _handleBurn(burn);
        if (dividends > 0) fund += _handleDividends(dividends);
        if (liquidity > 0) fund += _handleLiquidity(liquidity);
        if (fund > 0) _depositToFund(fund);
    }

    /// @dev True once the token has graduated (a live pool exists). Implemented by the token.
    function _earningsGraduated() internal view virtual returns (bool);

    /// @dev Routes the fund-wallet slice to the master fee handler. Implemented by the token.
    function _depositToFund(uint256 amount) internal virtual;

    /// @dev Buy-back-and-burn leg. Returns the amount it did NOT consume, which `_allocateEthEarnings`
    ///      folds back into the single fund deposit. The base consumes nothing (returns `amount`), so
    ///      until the burn module ships every configured burn share routes to the fund wallets. When
    ///      overridden it MUST only accrue for out-of-band processing (see the gas note above) and
    ///      return the residual it did not accrue (0 in the common full-accrual case).
    function _handleBurn(uint256 amount) internal virtual returns (uint256 unconsumed) {
        return amount;
    }

    /// @dev Holder-dividends leg. Same contract as `_handleBurn`: accrue-only, return the unconsumed
    ///      residual. Falls back to the fund wallets until the dividends module ships (step 3).
    function _handleDividends(uint256 amount) internal virtual returns (uint256 unconsumed) {
        return amount;
    }

    /// @dev Liquidity-additions leg. Same contract as `_handleBurn`: accrue-only, return the unconsumed
    ///      residual. Falls back to the fund wallets until the liquidity module ships (step 4).
    function _handleLiquidity(uint256 amount) internal virtual returns (uint256 unconsumed) {
        return amount;
    }
}
