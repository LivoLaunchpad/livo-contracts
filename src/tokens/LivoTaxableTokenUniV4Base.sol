// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoUniv4BuyBacks} from "src/tokens/LivoUniv4BuyBacks.sol";

/// @notice Minimal view onto the V4 graduator: the hook it paired the token's pool with (to rebuild the
///         pool key) and the shared liquidity adder it deployed (to mint the single-sided ETH wall).
interface ILivoV4Graduator {
    function HOOK_ADDRESS() external view returns (address);
    function LIQUIDITY_ADDER() external view returns (address);
}

/// @title LivoTaxableTokenUniV4Base
/// @notice Everything the Uniswap-V4 taxable token and its dividend extension must AGREE on: the token's
///         own storage, the buy-back precursor events, and the small reads either side may perform.
/// @dev This exists so `LivoTaxableTokenUniV4` and `LivoDividendLogicUniV4` derive an IDENTICAL storage
///      layout from the same declarations — including the inheritance ORDER below, which is what places
///      them. The extension is `delegatecall`ed with the token's storage, so a layout that drifts would
///      have it writing the wrong slots; splitting the declarations out here makes that structurally
///      impossible rather than merely tested (it is tested too — see
///      `just check-dividend-layout`). Nothing behavioural belongs here: put a function in
///      this base only when BOTH sides need it, and everything else in the contract that uses it.
abstract contract LivoTaxableTokenUniV4Base is LivoTaxableToken, LivoUniv4BuyBacks {
    /////////////////////////// pure storage ///////////////////////

    /// @notice ETH accrued from the burn allocation, awaiting a `processBurn` buy-back-and-burn. Held in
    ///         the token's own balance; the rest of the balance (minus this and `liquidityPendingEth`) is
    ///         stray ETH that `sweepStrayEth` routes back into the earnings split.
    uint256 public burnPendingEth;

    /// @notice ETH accrued from the liquidity allocation, awaiting a `processLiquidity` single-sided add.
    ///         Held in the token's own balance and, like `burnPendingEth`, excluded from the stray sweep.
    uint256 public liquidityPendingEth;

    /// @notice `block.number` of the last `processBurn` — enforces its once-per-block cooldown
    ///         (see `MAX_EARNINGS_PER_PROCESS`). Packed with `lastLiquidityProcessBlock`.
    uint48 public lastBurnProcessBlock;

    /// @notice `block.number` of the last `processLiquidity` — enforces its once-per-block cooldown.
    uint48 public lastLiquidityProcessBlock;

    // Reentrancy: `processBurn` and `processLiquidity` share the transient `nonReentrant` lock that
    // `LivoTaxableToken` inherits for `sweepStrayEth` (they make external calls that pass through
    // `LivoSwapHook`/the fee handler and could reenter). The hot-path `accrueFees` deliberately does
    // NOT take the lock, so fee accrual during a buy-back still works.

    //////////////////////// Events & errors //////////////////////

    /// @notice Emitted immediately BEFORE `processBurn`'s buy-back swap, as a precursor marker.
    /// @dev The buy-back is an ordinary pool swap, so `LivoSwapHook` emits a normal `LivoSwapBuy`
    ///      carrying `tx.origin` — the keeper that triggered the call, not a trader. Without a marker an
    ///      indexer credits that keeper with a buy it never made: the tokens go to this contract and are
    ///      burned in the same call. Emitting BEFORE the swap is what makes it usable — the indexer can
    ///      flag the buy as protocol-internal as it arrives, whereas `CreatorTaxBurn` lands after the
    ///      swap, once the PnL update has already been applied. Mirrors the V2 swap-back, which is
    ///      pre-flagged by the token's transfer to the pair.
    event BuyBackInitiated(uint256 ethIn);

    /// @notice Emitted immediately BEFORE the buy-back swap that funds a SELF-TOKEN dividend pot. Same
    ///         job as `BuyBackInitiated`, for the same reason: the swap is an ordinary pool swap, so
    ///         `LivoSwapHook` emits a `LivoSwapBuy` carrying `tx.origin` — the keeper that called
    ///         `processDividends` — and without a precursor marker an indexer credits that keeper with a
    ///         buy it never made. Kept as its own event rather than reusing `BuyBackInitiated` so the two
    ///         protocol buy-backs stay distinguishable off-chain (one shrinks supply, one pays holders).
    event DividendBuyBackInitiated(uint256 ethIn);

    /// @dev The burn and liquidity buffers are committed ETH, not stray, and neither is the dividend
    ///      money the base already accounts for.
    function _reservedNative() internal view override returns (uint256) {
        return super._reservedNative() + burnPendingEth + liquidityPendingEth;
    }
}
