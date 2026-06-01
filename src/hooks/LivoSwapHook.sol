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

/// @title LivoSwapHook
/// @notice Uniswap V4 hook that collects LP fees and time-limited sell taxes on token swaps.
/// @dev Singleton hook serving all taxable tokens graduated via LivoGraduatorUniswapV4.
/// @dev Per-token LP fee + tax rates come from `ILivoToken.getTaxConfig()`. The hook places no
///      individual cap on either; instead it reverts a swap whose combined `lpFeeBps + taxBps`
///      exceeds `MAX_OVERALL_FEE_BPS`, leaving each token free to split that budget as it likes.
///      Collected LP fees are forwarded to `LivoLpFeeRouter`, which splits them between treasury
///      and creator; the hook is unaware of the split and only forwards.
contract LivoSwapHook is BaseHook {
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

    /// @notice Cached LP fee taken from the input on a buy, carried from beforeSwap to afterSwap.
    /// @dev    Used for the router accrual (in afterSwap, when `tokensOut` is finally known) and
    ///         for the `LivoSwapBuy.ethFees` field.
    uint256 private transient _cachedBuyLpFee;

    /// @notice Cached buy tax taken from the input on a buy, carried from beforeSwap to afterSwap.
    uint256 private transient _cachedBuyTax;

    /////////////////////////// EVENTS & ERRORS ///////////////////////////

    error NoSwapsBeforeGraduation();
    /// @notice Thrown when a token's combined fee (`lpFeeBps + taxBps`) for this swap leg exceeds
    ///         `MAX_OVERALL_FEE_BPS`.
    error FeeTooHigh();

    /// @notice Emitted when creator taxes are accrued from a taxed swap.
    event CreatorTaxesAccrued(address indexed token, uint256 amount);
    /// @notice Emitted when LP fees are forwarded out of the hook on a swap leg.
    /// @dev The split is reported by the router in `LivoLpFeeRouter.LpFeesRouted`; on the fallback
    ///      path (router reverts) that event is absent, which is how indexers detect the fallback.
    ///      Signature differs from the old hook's `LpFeesAccrued` on purpose: this hook lives at a
    ///      fresh address, so legacy and new tokens never collide on the indexer.
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

    /// @notice Hook callback executed before each swap to check graduation and charge LP + buy-tax
    ///         fees on the input currency for buys. Sell-leg fees are taken in `_afterSwap`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address tokenAddress = Currency.unwrap(key.currency1);

        if (!ILivoToken(tokenAddress).graduated()) {
            revert NoSwapsBeforeGraduation();
        }

        // Sells: nothing to do here — both the fee deduction and the router accrual run in afterSwap.
        if (!params.zeroForOne) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Exact-output buys (amountSpecified > 0): the input ETH is not known here. Defer the
        // entire fee path to afterSwap, where the actual ETH consumed is read from
        // `-delta.amount0()`. Charging here would underflow `uint256(-params.amountSpecified)`.
        if (params.amountSpecified > 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // BUY exact-input: pull LP fee + (optional) buy tax out of the input ETH before the swap
        // so the swap sees a smaller effective `ethIn`. The router accrual is deferred to
        // `_afterSwap` so we can pass the avg swap price (ethNet / tokensOut) without reading
        // the pool's slot0.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absAmount = uint256(-params.amountSpecified);
        ILivoToken.TaxConfig memory cfg = ILivoToken(tokenAddress).getTaxConfig();
        (uint256 lpFee, uint256 taxAmount) = _computeFees(absAmount, cfg, true);

        uint256 totalFee = lpFee + taxAmount;
        _cachedBuyLpFee = lpFee;
        _cachedBuyTax = taxAmount;

        if (totalFee > 0) {
            poolManager.take(key.currency0, address(this), totalFee);
        }

        // Return delta: positive deltaSpecified means hook is taking from the specified (input) currency.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(totalFee)), 0), 0);
    }

    /// @notice Hook callback executed after each swap to (a) accrue buy-side fees that were
    ///         taken in `_beforeSwap` now that `tokensOut` is known, and (b) compute & take
    ///         sell-side LP + sell-tax fees on the ETH output.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        address tokenAddress = Currency.unwrap(key.currency1);

        if (params.zeroForOne) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 tokensOut = uint256(uint128(delta.amount1()));

            // BUY exact-input: fees were already taken from the input in beforeSwap. Route the
            // accrual using the avg-swap-price `(ethNet, tokensOut)`.
            if (params.amountSpecified < 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 ethIn = uint256(-params.amountSpecified);
                uint256 lpFee = _cachedBuyLpFee;
                uint256 taxAmount = _cachedBuyTax;
                uint256 totalFee = lpFee + taxAmount;
                // `ethNet` is the ETH that actually crossed into the pool (after we deducted fees).
                uint256 ethNet = ethIn - totalFee;

                _accrue(tokenAddress, lpFee, taxAmount, ethNet, tokensOut);

                emit LivoSwapBuy(tokenAddress, tx.origin, ethIn, tokensOut, totalFee);
                return (IHooks.afterSwap.selector, 0);
            }

            // BUY exact-output: pool consumed `ethInPool` against `tokensOut`. The hook fee is
            // settled separately via the afterSwap return delta, so the swapper's total ETH out
            // is `ethInPool + totalFee`. `delta.amount0()` is negative for buys (ETH paid into
            // the pool). Extracted into a helper to keep this frame under the stack limit.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 ethInPool = uint256(uint128(-delta.amount0()));
            uint256 buyTotalFee = _chargeExactOutputBuyFee(key, tokenAddress, ethInPool, tokensOut);

            // Emit the swapper's total ETH outflow (pool input + hook fee) so the event matches
            // exact-input's `ethIn` semantics (= total ETH paid by the swapper).
            emit LivoSwapBuy(tokenAddress, tx.origin, ethInPool + buyTotalFee, tokensOut, buyTotalFee);
            // forge-lint: disable-next-line(unsafe-typecast)
            return (IHooks.afterSwap.selector, int128(uint128(buyTotalFee)));
        }

        // SELL: take fees from the ETH output.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ethGross = uint256(uint128(delta.amount0()));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tokensIn = uint256(uint128(-delta.amount1()));
        ILivoToken.TaxConfig memory cfg = ILivoToken(tokenAddress).getTaxConfig();
        (uint256 sellLpFee, uint256 sellTax) = _computeFees(ethGross, cfg, false);
        uint256 sellTotalFee = sellLpFee + sellTax;

        if (sellTotalFee > 0) {
            poolManager.take(key.currency0, address(this), sellTotalFee);
        }

        // `ethNetSell` is the ETH that effectively left the pool against `tokensIn` (gross minus our fees).
        uint256 ethNetSell = ethGross - sellTotalFee;
        _accrue(tokenAddress, sellLpFee, sellTax, ethNetSell, tokensIn);

        emit LivoSwapSell(tokenAddress, tx.origin, tokensIn, ethGross, sellTotalFee);

        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.afterSwap.selector, int128(uint128(sellTotalFee)));
    }

    /// @dev Charges the LP fee (+ active buy tax) on an exact-output buy with the same effective
    ///      rate as the exact-input path. Extracted from `_afterSwap` to keep that frame within
    ///      the EVM stack limit.
    ///
    /// Parity with exact-input: the fee is `X%` of the swapper's TOTAL ETH out, not `X%` of the
    /// pool-consumed ETH. Given pool-consumed `ethInPool` and combined rate `totalBps`, the
    /// equivalent exact-input gross is `grossEth = ethInPool * 10000 / (10000 - totalBps)`. Fees
    /// are then computed on `grossEth` so the swapper pays `grossEth ≈ ethInPool + totalFee`.
    /// Without this gross-up, exact-output undercharges versus exact-input by ~feeBps² order.
    function _chargeExactOutputBuyFee(PoolKey calldata key, address tokenAddress, uint256 ethInPool, uint256 tokensOut)
        internal
        returns (uint256 totalFee)
    {
        ILivoToken.TaxConfig memory cfg = ILivoToken(tokenAddress).getTaxConfig();
        uint256 grossEth = _grossUpExactOutputBuy(ethInPool, cfg);
        (uint256 lpFee, uint256 taxAmount) = _computeFees(grossEth, cfg, true);
        totalFee = lpFee + taxAmount;

        if (totalFee > 0) {
            poolManager.take(key.currency0, address(this), totalFee);
        }

        // Pool consumed `ethInPool` against `tokensOut`; the hook fee was settled separately via
        // the afterSwap return delta and never crossed the pool. This mirrors exact-input's
        // "pool-consumed amount" semantics passed to `_accrue`.
        _accrue(tokenAddress, lpFee, taxAmount, ethInPool, tokensOut);
    }

    /// @notice Resolves the effective LP-fee and tax bps for a swap leg and enforces the overall cap.
    /// @dev    The tax is only active inside the post-graduation window; outside it `taxBps` is zero.
    ///         No individual cap is placed on either component — a token is free to split the budget
    ///         between LP fee and taxes — but the combined `lpFeeBps + taxBps` must stay within
    ///         `MAX_OVERALL_FEE_BPS` or the swap reverts with `FeeTooHigh`.
    function _resolveFeeBps(ILivoToken.TaxConfig memory cfg, bool isBuy)
        internal
        view
        returns (uint256 lpFeeBps, uint256 taxBps)
    {
        lpFeeBps = uint256(cfg.lpFeeBps);
        if (
            cfg.graduationTimestamp != 0
                && block.timestamp <= uint256(cfg.graduationTimestamp) + uint256(cfg.taxDurationSeconds)
        ) {
            taxBps = isBuy ? uint256(cfg.buyTaxBps) : uint256(cfg.sellTaxBps);
        }
        if (lpFeeBps + taxBps > MAX_OVERALL_FEE_BPS) revert FeeTooHigh();
    }

    /// @dev Grosses up the pool-consumed ETH on an exact-output buy into the equivalent
    ///      exact-input gross input. With effective LP-fee bps and active buy-tax bps summed
    ///      into `totalBps`, returns `ethInPool * 10000 / (10000 - totalBps)`.
    /// @dev Division is safe: `_resolveFeeBps` caps `totalBps` at `MAX_OVERALL_FEE_BPS` (2500),
    ///      well below `BASIS_POINTS` (10000), so the denominator never reaches zero.
    function _grossUpExactOutputBuy(uint256 ethInPool, ILivoToken.TaxConfig memory cfg)
        internal
        view
        returns (uint256)
    {
        (uint256 lpFeeBps, uint256 taxBps) = _resolveFeeBps(cfg, true);
        uint256 totalBps = lpFeeBps + taxBps;
        if (totalBps == 0) return ethInPool;
        return (ethInPool * BASIS_POINTS) / (BASIS_POINTS - totalBps);
    }

    /// @notice Computes the LP fee + tax amounts on a given gross ETH amount.
    /// @dev    Rates come from `_resolveFeeBps`, which enforces the combined `MAX_OVERALL_FEE_BPS`
    ///         cap. A zero `lpFeeBps` is taken literally (no LP fee).
    function _computeFees(uint256 grossEth, ILivoToken.TaxConfig memory cfg, bool isBuy)
        internal
        view
        returns (uint256 lpFee, uint256 taxAmount)
    {
        (uint256 lpFeeBps, uint256 taxBps) = _resolveFeeBps(cfg, isBuy);
        lpFee = (grossEth * lpFeeBps) / BASIS_POINTS;
        taxAmount = (grossEth * taxBps) / BASIS_POINTS;
    }

    /// @notice Forwards the LP fee through the router and the tax slice straight to the creator.
    /// @dev    The router call is the only place this contract trusts external code. It is
    ///         hardened against every failure mode that can come back from
    ///         `LivoLpFeeRouter.depositLpFees`:
    ///
    ///         - **Revert with revert-data** (custom error, `require`, `revert(string)`): caught
    ///           by `try/catch`; the LP fee falls through to `ILivoToken.accrueFees`.
    ///         - **Out-of-gas inside the router**: gas forwarded is capped at `ROUTER_GAS_LIMIT`,
    ///           so the post-catch frame keeps `gasleft() - ROUTER_GAS_LIMIT` to run the
    ///           `accrueFees` fallback. Defends against gas griefing by a hostile upgrade.
    ///         - **Router proxy has no code** (impl pointer points to `address(0)`): Solidity's
    ///           high-level call inserts an `extcodesize` check that reverts; caught.
    ///         - **Router exists but its current impl does not implement `depositLpFees`**: the
    ///           router contract intentionally ships without a `fallback()` function, so a call
    ///           with an unknown selector reverts at the proxy level and is caught here. *This
    ///           is a router-side invariant that future router upgrades MUST preserve* — adding
    ///           a payable fallback to the router would silently strand the LP fee on the proxy.
    ///         - **Interface return-value mismatch**: the interface declares no return values,
    ///           so there is no decode step that could mis-interpret bytes from a wrong impl.
    ///
    ///         If `accrueFees` itself also reverts the whole swap fails — by design, since a
    ///         simultaneous outage of the router AND the master fee handler is a protocol-wide
    ///         failure that warrants a clear, observable revert rather than silently stranding
    ///         ETH in this contract.
    /// @param ethSwapAmount   Net ETH that crossed the pool during this swap leg (gross minus
    ///                        fees). Together with `tokenSwapAmount` it lets the router derive
    ///                        the swap's avg price without reading slot0.
    /// @param tokenSwapAmount Token amount that crossed the pool during this swap leg.
    function _accrue(
        address tokenAddress,
        uint256 lpFee,
        uint256 taxAmount,
        uint256 ethSwapAmount,
        uint256 tokenSwapAmount
    ) internal {
        if (lpFee > 0) {
            emit LpFeesForwarded(tokenAddress, lpFee);
            try FEE_ROUTER.depositLpFees{value: lpFee, gas: ROUTER_GAS_LIMIT}(
                tokenAddress, ethSwapAmount, tokenSwapAmount
            ) {
            // happy path — router emitted its own `LpFeesRouted` with the breakdown.
            }
            catch {
                // Fallback: send through `accrueFees` so the LP fee reaches the configured fee
                // receivers even on router failure. The creator effectively receives the entire
                // LP fee in this degenerate case.
                ILivoToken(tokenAddress).accrueFees{value: lpFee}();
            }
        }
        if (taxAmount > 0) {
            emit CreatorTaxesAccrued(tokenAddress, taxAmount);
            ILivoToken(tokenAddress).accrueFees{value: taxAmount}();
        }
    }
}
