// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLpFeeRouter} from "src/interfaces/ILivoLpFeeRouter.sol";

/// @title LivoSwapHookImproved
/// @notice Uniswap V4 hook that collects LP fees and time-limited buy/sell taxes on swaps of
///         tokens graduated via LivoGraduatorUniswapV4.
/// @dev Singleton, ownerless hook shared by every taxable token. Per-token LP-fee + tax rates come
///      from `ILivoToken.getCurrentFees()`, which already windows the tax (zero outside the
///      post-graduation period), so the hook stays agnostic to the tax schedule. It places no cap
///      on either component individually; instead it reverts a swap whose combined
///      `lpFeeBps + taxBps` for the leg exceeds `MAX_OVERALL_FEE_BPS`, leaving each token free to
///      split that budget as it likes. Collected LP fees are forwarded to `LivoLpFeeRouter` (which
///      splits them between treasury and creator); taxes go straight to the creator via
///      `ILivoToken.accrueFees`. The hook is unaware of the LP split and only forwards.
///
/// @dev Fees are always charged on the ETH side (currency0), but where depends on the leg:
///      - exact-input buy:  withheld from the ETH input in `beforeSwap` (input is known there).
///      - exact-output buy: settled from the ETH input in `afterSwap` (input unknown until then).
///      - sell:             withheld from the ETH output in `afterSwap`.
contract LivoSwapHookImproved is BaseHook {
    /// @notice LP fee router that splits forwarded fees between treasury and creator.
    /// @dev Resolved at swap time; upgrade the router via its own UUPS proxy without redeploying
    ///      this hook.
    ILivoLpFeeRouter public immutable FEE_ROUTER;

    /// @notice Basis points denominator (10000 = 100%).
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Hard ceiling on the COMBINED fee (LP fee + active tax) charged on a single swap leg,
    ///         so a misconfigured token can never overcharge users. The swap reverts if the token's
    ///         `lpFeeBps + taxBps` exceeds this; the hook stays agnostic to how the token splits the
    ///         budget between LP fee and taxes. Well above the factory's `MAX_TOTAL_FEE_BPS` (500),
    ///         which is the real configuration bound — this is only a runtime backstop.
    uint16 private constant MAX_OVERALL_FEE_BPS = 2500; // 25%

    /// @notice Gas budget forwarded to the router on `depositLpFees`. Sized to cover the router's
    ///         worst-case path with margin, then capped so a misbehaving router cannot drain the
    ///         remaining gas and starve the fallback path.
    /// @dev Worst-case router work: one `treasury.call` (recipient gets the 2300-gas stipend) +
    ///      `token.accrueFees` → `LivoMasterFeeHandler.depositFees` → optional direct-receiver
    ///      forward (handler caps that branch at `DIRECT_FORWARD_GAS = 100_000`). 300k provides
    ///      a comfortable ceiling. The remainder of the tx's gas stays available for the
    ///      `accrueFees` fallback if the router reverts.
    uint256 private constant ROUTER_GAS_LIMIT = 300_000;

    /// @notice LP fee withheld from the input on an exact-input buy, carried from `beforeSwap` to
    ///         `afterSwap`.
    /// @dev Routed (and reported in `LivoSwapBuy.ethFees`) in `afterSwap`, once `tokensOut` is known.
    uint256 private transient _cachedBuyLpFee;

    /// @notice Buy tax withheld from the input on an exact-input buy, carried from `beforeSwap` to
    ///         `afterSwap`.
    uint256 private transient _cachedBuyTax;

    /////////////////////////// ERRORS & EVENTS ///////////////////////////

    error NoSwapsBeforeGraduation();
    /// @notice Thrown when a token's combined fee (`lpFeeBps + taxBps`) for this swap leg exceeds
    ///         `MAX_OVERALL_FEE_BPS`.
    error FeeTooHigh();

    /// @notice Emitted when creator taxes are accrued from a taxed swap.
    event CreatorTaxesAccrued(address indexed token, uint256 amount);
    /// @notice Emitted when LP fees are forwarded out of the hook on a swap leg.
    /// @dev The split is reported by the router in `LivoLpFeeRouter.LpFeesRouted`; on the fallback
    ///      path (router reverts) that event is absent, which is how indexers detect the fallback.
    event LpFeesForwarded(address indexed token, uint256 amount);
    /// @notice Emitted on every buy for off-chain indexing.
    event LivoSwapBuy(
        address indexed token, address indexed txOrigin, uint256 ethIn, uint256 tokensOut, uint256 ethFees
    );
    /// @notice Emitted on every sell for off-chain indexing.
    event LivoSwapSell(
        address indexed token, address indexed txOrigin, uint256 tokensIn, uint256 ethOut, uint256 ethFees
    );

    //////////////////////////////////////////////////////////////////////

    /// @notice Initializes the hook with the pool manager and LP fee router addresses.
    constructor(IPoolManager _poolManager, address _router) BaseHook(_poolManager) {
        FEE_ROUTER = ILivoLpFeeRouter(_router);
    }

    /// @notice Allows contract to receive ETH from `poolManager.take()`.
    /// @dev ETH should never remain in this contract between transactions. If it does, it is
    ///      accepted as stuck. Adding a rescue mechanism would require `Ownable`, which is
    ///      avoided to keep this singleton hook minimal and ownerless.
    receive() external payable {}

    /// @notice Returns the hook permissions indicating which callbacks are implemented.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    //////////////////////////// SWAP CALLBACKS ///////////////////////////

    /// @notice Enforces graduation and, for exact-input buys, withholds the LP + buy-tax fee from
    ///         the ETH input. Sell and exact-output-buy fees are settled in `_afterSwap`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address token = Currency.unwrap(key.currency1);
        if (!ILivoToken(token).graduated()) revert NoSwapsBeforeGraduation();

        // Only exact-input buys are charged here. Sells take their fee from the ETH output in
        // afterSwap; exact-output buys (amountSpecified > 0) don't know the ETH input yet, so they
        // also defer to afterSwap — charging here would underflow `uint256(-params.amountSpecified)`.
        bool isExactInputBuy = params.zeroForOne && params.amountSpecified < 0;
        if (!isExactInputBuy) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Pull the fee out of the input ETH before the swap so the pool sees a smaller effective
        // `ethIn`. The router accrual is deferred to `_afterSwap`, where `tokensOut` is known and
        // we can pass the avg swap price `(ethNet, tokensOut)` without reading the pool's slot0.
        uint256 ethIn = _exactInputAmount(params.amountSpecified);
        (uint256 lpFee, uint256 tax) = _computeFees(ethIn, token, true);
        uint256 totalFee = lpFee + tax;

        _cachedBuyLpFee = lpFee;
        _cachedBuyTax = tax;

        if (totalFee > 0) poolManager.take(key.currency0, address(this), totalFee);

        // Positive deltaSpecified means the hook is taking from the specified (input) currency.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(totalFee), 0), 0);
    }

    /// @notice Settles fees once swap amounts are known: routes the buy fee withheld in
    ///         `_beforeSwap`, or takes the sell / exact-output-buy fee from the ETH leg here.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        address token = Currency.unwrap(key.currency1);

        // SELL: fee comes off the ETH the pool paid out.
        if (!params.zeroForOne) {
            return (IHooks.afterSwap.selector, _settleSell(key, token, delta));
        }

        // BUY: currency1 (token) is the output. `delta.amount1()` is the tokens received.
        uint256 tokensOut = _abs(delta.amount1());
        int128 feeDelta = params.amountSpecified < 0
            ? _settleBuyExactInput(token, _exactInputAmount(params.amountSpecified), tokensOut)
            : _settleBuyExactOutput(key, token, delta, tokensOut);
        return (IHooks.afterSwap.selector, feeDelta);
    }

    ////////////////////////// FEE SETTLEMENT (PER LEG) ///////////////////////

    /// @dev Exact-input buy: the fee was already withheld from the input in `_beforeSwap`, so here
    ///      we only route it and emit. Returns a zero afterSwap delta (nothing left to settle).
    function _settleBuyExactInput(address token, uint256 ethIn, uint256 tokensOut) private returns (int128) {
        uint256 lpFee = _cachedBuyLpFee;
        uint256 tax = _cachedBuyTax;
        uint256 totalFee = lpFee + tax;

        // `ethIn - totalFee` is the ETH that actually crossed into the pool against `tokensOut`.
        _route(token, lpFee, tax, ethIn - totalFee, tokensOut);
        emit LivoSwapBuy(token, tx.origin, ethIn, tokensOut, totalFee);
        return 0;
    }

    /// @dev Exact-output buy: the pool consumed `ethInPool` to produce `tokensOut`; the fee is
    ///      settled separately via the returned afterSwap delta, so the swapper's total ETH out is
    ///      `ethInPool + totalFee`.
    ///
    ///      Parity with exact-input: the fee must be `X%` of the swapper's TOTAL ETH out, not `X%`
    ///      of the pool-consumed ETH. So we gross `ethInPool` up to the equivalent exact-input
    ///      input `grossEth = ethInPool * 10000 / (10000 - totalBps)` and charge the fee on that;
    ///      without the gross-up, exact-output undercharges versus exact-input by ~feeBps² order.
    function _settleBuyExactOutput(PoolKey calldata key, address token, BalanceDelta delta, uint256 tokensOut)
        private
        returns (int128)
    {
        // `delta.amount0()` is negative for buys (ETH paid into the pool).
        uint256 ethInPool = _abs(delta.amount0());
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(token, true);
        uint256 grossEth = _grossUp(ethInPool, lpFeeBps + taxBps);
        (uint256 lpFee, uint256 tax) = _feeAmounts(grossEth, lpFeeBps, taxBps);
        uint256 totalFee = lpFee + tax;

        if (totalFee > 0) poolManager.take(key.currency0, address(this), totalFee);

        // The fee never crossed the pool, so route the avg price on the pool-consumed amount only,
        // mirroring exact-input's "pool-consumed amount" semantics.
        _route(token, lpFee, tax, ethInPool, tokensOut);

        // Report the swapper's total ETH outflow (pool input + hook fee) so the event matches
        // exact-input's `ethIn` semantics.
        emit LivoSwapBuy(token, tx.origin, ethInPool + totalFee, tokensOut, totalFee);
        return _toInt128(totalFee);
    }

    /// @dev Sell: the pool paid out `ethGross` for `tokensIn`; the fee is taken from that output
    ///      and returned as the afterSwap delta. The swapper nets `ethGross - totalFee`.
    function _settleSell(PoolKey calldata key, address token, BalanceDelta delta) private returns (int128) {
        // On a sell, `delta.amount0()` is positive (ETH out) and `delta.amount1()` negative (tokens in).
        uint256 ethGross = _abs(delta.amount0());
        uint256 tokensIn = _abs(delta.amount1());
        (uint256 lpFee, uint256 tax) = _computeFees(ethGross, token, false);
        uint256 totalFee = lpFee + tax;

        if (totalFee > 0) poolManager.take(key.currency0, address(this), totalFee);

        // `ethGross` is the ETH the pool actually paid out for `tokensIn`; the hook fee is skimmed
        // from it *after* the swap and never changed the pool's execution price. Feed the full
        // `ethGross` (the pool-side ETH the buy legs also forward) so the router reads the same avg
        // price a buy at this pool state would, not an under-stated net-of-fee one.
        _route(token, lpFee, tax, ethGross, tokensIn);
        emit LivoSwapSell(token, tx.origin, tokensIn, ethGross, totalFee);
        return _toInt128(totalFee);
    }

    ////////////////////////////////// FEE MATH ///////////////////////////////

    /// @notice Resolves the LP-fee and tax bps the token charges on this leg and enforces the cap.
    /// @dev `getCurrentFees()` already windows the tax (zero outside the post-graduation period).
    ///      No individual cap is placed on either component — a token is free to split the budget —
    ///      but the combined `lpFeeBps + taxBps` must stay within `MAX_OVERALL_FEE_BPS` or the swap
    ///      reverts with `FeeTooHigh`. The token's `uint16` rates are widened to `uint256` so a
    ///      misreporting token reverts with `FeeTooHigh` rather than an arithmetic panic.
    function _currentFeeBps(address token, bool isBuy) private view returns (uint256 lpFeeBps, uint256 taxBps) {
        (uint16 buyTaxBps, uint16 sellTaxBps, uint16 lpBps) = ILivoToken(token).getCurrentFees();
        lpFeeBps = lpBps;
        taxBps = isBuy ? buyTaxBps : sellTaxBps;
        if (lpFeeBps + taxBps > MAX_OVERALL_FEE_BPS) revert FeeTooHigh();
    }

    /// @notice Resolves the rates (enforcing the cap) and splits `grossEth` into LP fee + tax.
    function _computeFees(uint256 grossEth, address token, bool isBuy)
        private
        view
        returns (uint256 lpFee, uint256 tax)
    {
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(token, isBuy);
        return _feeAmounts(grossEth, lpFeeBps, taxBps);
    }

    /// @dev Splits a gross ETH amount into the LP fee and tax slices at the given bps.
    function _feeAmounts(uint256 grossEth, uint256 lpFeeBps, uint256 taxBps)
        private
        pure
        returns (uint256 lpFee, uint256 tax)
    {
        lpFee = (grossEth * lpFeeBps) / BASIS_POINTS;
        tax = (grossEth * taxBps) / BASIS_POINTS;
    }

    /// @dev Grosses up the pool-consumed ETH on an exact-output buy into the equivalent
    ///      exact-input gross input: `ethInPool * 10000 / (10000 - totalBps)`. Division is safe:
    ///      `_currentFeeBps` caps `totalBps` at `MAX_OVERALL_FEE_BPS` (2500), well below
    ///      `BASIS_POINTS` (10000), so the denominator never reaches zero.
    function _grossUp(uint256 ethInPool, uint256 totalBps) private pure returns (uint256) {
        if (totalBps == 0) return ethInPool;
        return (ethInPool * BASIS_POINTS) / (BASIS_POINTS - totalBps);
    }

    ///////////////////////////////// FEE ROUTING /////////////////////////////

    /// @notice Forwards the LP fee through the router and the tax slice straight to the creator.
    /// @dev The router call is the only place this contract trusts external code. It is hardened
    ///      against every failure mode `LivoLpFeeRouter.depositLpFees` can return:
    ///      - **Revert with data** (custom error, `require`, `revert(string)`): caught; the LP fee
    ///        falls through to `ILivoToken.accrueFees`.
    ///      - **Out-of-gas inside the router**: forwarded gas is capped at `ROUTER_GAS_LIMIT`, so
    ///        the post-catch frame keeps `gasleft() - ROUTER_GAS_LIMIT` for the fallback. Defends
    ///        against gas griefing by a hostile upgrade.
    ///      - **Router proxy has no code / impl missing `depositLpFees`**: the high-level call's
    ///        `extcodesize` check (or the router shipping without a `fallback()`) reverts and is
    ///        caught. *Router upgrades MUST keep shipping without a payable fallback* — adding one
    ///        would silently strand the LP fee on the proxy.
    ///
    ///      If `accrueFees` itself also reverts the whole swap fails — by design: a simultaneous
    ///      outage of the router AND the master fee handler is a protocol-wide failure that warrants
    ///      a clear revert rather than silently stranding ETH in this contract.
    /// @param ethSwapAmount   ETH the pool exchanged on this leg: the input net of the pre-pool fee
    ///                        on a buy, the full ETH output on a sell (the hook fee is skimmed after
    ///                        the pool and excluded). With `tokenSwapAmount` it lets the router
    ///                        derive the avg price without reading slot0.
    /// @param tokenSwapAmount Token amount that crossed the pool during this leg.
    function _route(address token, uint256 lpFee, uint256 tax, uint256 ethSwapAmount, uint256 tokenSwapAmount) private {
        if (lpFee > 0) {
            emit LpFeesForwarded(token, lpFee);
            try FEE_ROUTER.depositLpFees{value: lpFee, gas: ROUTER_GAS_LIMIT}(token, ethSwapAmount, tokenSwapAmount) {
            // happy path — router emitted its own `LpFeesRouted` with the breakdown.
            }
            catch {
                // Fallback: send through `accrueFees` so the LP fee still reaches the configured fee
                // receivers. The creator effectively receives the entire LP fee in this case.
                ILivoToken(token).accrueFees{value: lpFee}();
            }
        }
        if (tax > 0) {
            emit CreatorTaxesAccrued(token, tax);
            ILivoToken(token).accrueFees{value: tax}();
        }
    }

    //////////////////////////////// CASTING UTILS ////////////////////////////

    /// @dev Magnitude of a swap-delta component. Each call site knows the component's sign from the
    ///      swap direction; centralizing the unsafe int→uint cast here keeps the call sites clean.
    function _abs(int128 x) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(x < 0 ? -x : x));
    }

    /// @dev Unsigned size of an exact-input swap, whose `amountSpecified` is negative by convention.
    function _exactInputAmount(int256 amountSpecified) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(-amountSpecified);
    }

    /// @dev Narrows a fee (always ≤ the swap amount, far below int128 max) to the signed delta the
    ///      pool-manager callbacks return.
    function _toInt128(uint256 fee) private pure returns (int128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(uint128(fee));
    }
}
