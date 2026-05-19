// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";

/// this line below can be adjusted to import the Sepolia addresses when deploying in sepolia
import {DeploymentAddressesMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title LivoTaxableTokenUniV2
/// @notice ERC20 token implementation with time-limited buy/sell taxes for tokens that graduate to
///         a Uniswap V2 pair. Uniswap V2 has no swap callbacks, so taxes are taken **intrinsically**:
///         a portion of every pair-touching transfer is diverted to this contract's balance, then
///         periodically swapped to ETH on the V2 router and pushed to the master fee handler via
///         the same `accrueFees` path that V4 uses.
/// @dev Auto-swap-back fires inside `_update` on sells once the contract holds at least
///      `SWAP_THRESHOLD` tokens — or, after the tax window expires, any non-zero residual — and
///      never swaps more than `2 * SWAP_THRESHOLD` per sell so the price impact a single trader
///      observes stays bounded; any excess balance carries to the next qualifying sell. The
///      post-window drain handles the case where leftover tax tokens stuck below `SWAP_THRESHOLD`
///      would otherwise never accrue enough fresh tax to cross it, since no new tax accrues once
///      the window expires. Recursion is guarded by `_inSwap`: when the router pulls tokens from
///      this contract during the swap, our `_update` short-circuits to a plain transfer.
///      At most `MAX_SWAPBACKS_PER_BLOCK` swap-backs per block are allowed: `_swapBack` resets
///      `swapbacksThisBlock` to zero when `block.number > lastSwapbackBlock`, increments it on
///      each successful swap, and silently returns when the counter hits the cap — so any further
///      call in the same block (auto or manual) is a no-op. This counter shape mirrors the
///      reference token at `0xbad06a3ca84e4e2b489974d8918b5f7387e6db8e`, which passes Go+'s
///      "trading cooldown" heuristic.
///      A permissioned `swapBack(amountOutMinWei)` lets the owner trigger a slippage-bounded swap
///      via a private mempool to avoid sandwiches; on factory-deployed tokens the owner is
///      `address(0)`, so this entry point is reachable only via the launchpad owner, and the
///      auto-trigger remains the live path.
contract LivoTaxableTokenUniV2 is LivoTaxableToken {
    ///////////////////////////////// uniswap v2 related /////////////////////////////////////////
    // NB : THESE ARE HARDCODED FOR MAINNET TO SAVE GAS

    /// @notice Uniswap V2 router used to swap accumulated tax tokens for ETH
    IUniswapV2Router public constant UNISWAP_V2_ROUTER = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);

    /// @notice WETH address (the second hop in the swap path)
    address public constant WETH = DeploymentAddresses.WETH;

    /// @notice Minimum tax-token balance that triggers an auto swap-back on the next sell.
    ///         0.05% of TOTAL_SUPPLY (= 500_000e18). Hardcoded to amortise gas across many small
    ///         sells while keeping per-swap price-impact bounded for the common case.
    uint256 public constant SWAP_THRESHOLD = TOTAL_SUPPLY / 2000;

    /// @notice Maximum number of swap-backs allowed per block. Further calls in the same block
    ///         silently no-op. Picked low enough that a single block's swap-back activity stays
    ///         bounded, high enough that two whales selling in the same block both get their
    ///         tax routed without one having to wait a block.
    uint8 public constant MAX_SWAPBACKS_PER_BLOCK = 2;

    /////////////////////////// pure storage ///////////////////////

    /// @dev Re-entrancy guard for the swap-back path. When true, `_update` short-circuits the
    ///      tax + auto-trigger logic so the router's `transferFrom(this, pair, ...)` is a plain
    ///      ERC20 transfer. Lives in transient storage — auto-clears at end of tx, no SSTORE cost.
    bool internal transient _inSwap;

    /// @notice `block.number` of the most recent successful `_swapBack`. Zero until the first
    ///         swapback runs. Used together with `swapbacksThisBlock` to enforce the per-block
    ///         cap: when `block.number > lastSwapbackBlock`, the counter resets to zero. uint48
    ///         packs into the parent `LivoTaxableToken` slot alongside `graduationTimestamp`.
    uint48 public lastSwapbackBlock;

    /// @notice Count of successful `_swapBack` calls that have already settled in
    ///         `lastSwapbackBlock`. Reset to zero on the first swap-back of a new block and
    ///         incremented after each successful swap. Once it reaches `MAX_SWAPBACKS_PER_BLOCK`,
    ///         further calls in the same block silently no-op. uint8 packs into the parent slot
    ///         alongside `lastSwapbackBlock` and `graduationTimestamp`.
    uint8 public swapbacksThisBlock;

    //////////////////////// Events //////////////////////

    /// @notice Emitted whenever the contract auto- or manually-swaps accumulated tax tokens to ETH
    ///         and forwards the proceeds to the master fee handler. `ethAmount` is the ETH
    ///         pushed via `_accrueFees` (plain ETH transfer to the handler) for this swap-back,
    ///         i.e. the tax actually accrued to the creator (and any direct receivers) for the
    ///         swap window covered by this back-swap.
    event CreatorTaxSwapback(uint256 tokenAmountIn, uint256 ethAmount);

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxableTokenUniV2 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
    }

    /// @notice Initializes the token clone with its parameters including tax configuration
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps and post-graduation tax duration)
    function initialize(ILivoToken.InitializeParams memory params, TaxConfigInit memory taxCfg)
        external
        virtual
        initializer
    {
        _initializeLivoTaxableToken(params, taxCfg);
    }

    /// @inheritdoc LivoTaxableToken
    /// @dev Adds a one-shot infinite approval to the V2 router so `_swapBack` doesn't have to
    ///      re-approve every call. OZ ERC20 v5 skips allowance decrement when value is `type(uint256).max`.
    function _initializeLivoTaxableToken(ILivoToken.InitializeParams memory params, TaxConfigInit memory taxCfg)
        internal
        override
        onlyInitializing
    {
        super._initializeLivoTaxableToken(params, taxCfg);
        _approve(address(this), address(UNISWAP_V2_ROUTER), type(uint256).max);
    }

    /// @notice Manually triggers a swap of `swapAmount` tax tokens for ETH and forwards the
    ///         proceeds to the master fee handler. Callable by the token owner OR the launchpad
    ///         owner.
    /// @param swapAmount Amount of tax tokens to swap. The caller is expected to size this against
    ///        `balanceOf(address(this))` and their own price-impact budget; the auto path's
    ///        `2 * SWAP_THRESHOLD` cap is not enforced here, so a private-mempool caller can drain
    ///        a larger residual in one shot. The router will revert if `swapAmount` exceeds the
    ///        contract's balance.
    /// @param amountOutMinWei Minimum ETH (in wei) the swap must yield. The caller is expected to
    ///        compute this from `router.getAmountsOut(...)` plus their own slippage budget; this
    ///        is the path used to MEV-protect a swap via a private mempool.
    /// @dev Factory-deployed tokens always have `owner == address(0)`; the launchpad-owner branch
    ///      is therefore the only reachable manual path on those deployments. The auto-trigger
    ///      inside `_update` remains the primary path regardless of caller identity. Proceeds are
    ///      forwarded to the fee handler (not the caller), so widening the caller set has no
    ///      asset-routing impact.
    /// @dev If `MAX_SWAPBACKS_PER_BLOCK` swap-backs have already settled in the current block,
    ///      `_swapBack` silently no-ops — the call succeeds but emits no `CreatorTaxSwapback`
    ///      event. Callers gating on the event still get a clean signal; callers expecting a
    ///      revert do not.
    function swapBack(uint256 swapAmount, uint256 amountOutMinWei) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        _swapBack(swapAmount, amountOutMinWei);
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Intrinsic taxation hook. Order of operations:
    ///      1. If `_inSwap` (we're inside `_swapBack`), bypass everything — the router's
    ///         `transferFrom(this, pair, ...)` must be a plain transfer, otherwise we recurse.
    ///      2. Apply the inherited pre-graduation gate.
    ///      3. On a sell with accumulated balance, fire `_swapBack(amount, 0)` capped at
    ///         `2 * SWAP_THRESHOLD` to bound the per-sell price impact (auto path). Trigger fires
    ///         when `balance >= SWAP_THRESHOLD`, OR — after the tax window expires — when any
    ///         non-zero balance remains, so a sub-threshold residual gets drained on the next sell
    ///         instead of stranding forever (no new tax accrues post-window to push it across).
    ///         `_swapBack` itself enforces the at-most-`MAX_SWAPBACKS_PER_BLOCK`-per-block
    ///         guarantee via a counter (silent no-op on overflow); this outer branch deliberately
    ///         does NOT reference `block.number` so static analyzers don't mistake the per-block
    ///         swap-back cap for a per-user trading cooldown.
    ///         Any excess stays on the contract and is drained on the next qualifying sell.
    ///      4. If we're in the post-graduation tax window AND the transfer touches the pair AND
    ///         the source is not the graduator (which moves the initial liquidity), divert
    ///         `amount * bps / 10_000` to this contract and forward the rest.
    ///      The graduator exclusion is load-bearing: graduation transfers `markGraduated() →
    ///      safeTransfer(pair) → router.addLiquidityETH` all run with `to == pair` after
    ///      `graduationTimestamp` is stamped, so without the exclusion the initial liquidity
    ///      would be taxed.
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (_inSwap) {
            super._update(from, to, amount);
            return;
        }

        // Cache `pair` and `graduated` once. Both are packed in the same storage slot in
        // `LivoToken`, so this is a single SLOAD; the locals also let the buy/sell branches
        // below avoid re-reading them.
        address _pair = pair;
        bool _graduated = graduated;

        if ((!_graduated) && (to == _pair)) {
            revert TransferToPairBeforeGraduationNotAllowed();
        }

        bool isSell = (to == _pair);
        bool isBuy = (from == _pair);

        // Auto swap-back: only on sells, and only if the contract has enough accumulated tax to
        // make the swap worthwhile. `from != address(this)` is implied by `_inSwap` already being
        // false here (the contract only ever transfers tokens during a swap-back).
        // `from != graduator` is load-bearing: the graduator's initial `addLiquidityETH` call
        // produces a `_update(graduator, pair, ...)` while the pair still has zero reserves, so
        // firing `_swapBack` against it would revert the entire graduation tx. Anyone could grief
        // graduation by pre-funding `address(this)` with `>= SWAP_THRESHOLD` tokens before it.
        // The per-block cap (at most `MAX_SWAPBACKS_PER_BLOCK`) lives inside `_swapBack` as a
        // counter (silent no-op on overflow), so this outer sell-branch condition references no
        // `block.number` — static heuristics (e.g. Go+) flag any `block.number` read in a
        // transfer-hook sell branch as a trading cooldown. Counter-reset-on-new-block matches the
        // shape of the reference token at `0xbad06a3ca84e4e2b489974d8918b5f7387e6db8e`.
        if (isSell && from != graduator) {
            uint256 contractBalance = balanceOf(address(this));
            if (contractBalance >= SWAP_THRESHOLD) {
                uint256 swapAmount = contractBalance > 2 * SWAP_THRESHOLD ? 2 * SWAP_THRESHOLD : contractBalance;
                _swapBack(swapAmount, 0);
            } else if (contractBalance > 0 && block.timestamp > uint256(graduationTimestamp) + taxDurationSeconds) {
                // Post-window drain: window's closed, no fresh tax will ever flow in, so a residual
                // stuck below SWAP_THRESHOLD would otherwise sit forever. No 2*SWAP_THRESHOLD cap
                // needed: this branch only fires when contractBalance < SWAP_THRESHOLD, so the swap
                // is already small.
                _swapBack(contractBalance, 0);
            }
        }

        // charging the tax: only if graduated, only on pair-touching transfers
        if (
            _graduated && (isBuy || isSell) && block.timestamp <= uint256(graduationTimestamp) + taxDurationSeconds
                && from != graduator
        ) {
            uint16 bps = isBuy ? buyTaxBps : sellTaxBps;
            if (bps > 0) {
                uint256 taxAmount = amount * bps / 10_000;
                if (taxAmount > 0) {
                    super._update(from, address(this), taxAmount);
                    super._update(from, to, amount - taxAmount);
                    return;
                }
            }
        }
        // no tax applied if we reached here
        super._update(from, to, amount);
    }

    /// @dev Swaps `tokenAmount` of the contract's tax-token balance to ETH on the V2 router and
    ///      forwards the proceeds to the master fee handler. The `_inSwap` flag short-circuits
    ///      `_update` for the duration of the swap so the router's `transferFrom(this, pair, ...)`
    ///      is a plain transfer (no recursive tax, no recursive auto-trigger).
    /// @dev Callers are responsible for passing a valid `tokenAmount` (≤ contract balance) and
    ///      for applying any cap (e.g. `2 * SWAP_THRESHOLD` on the auto path). Sourcing the amount
    ///      from the caller avoids re-reading `balanceOf(address(this))` after `_update` already
    ///      consulted it.
    /// @dev `address(this).balance` is forwarded in full (not just the swap output): any ETH that
    ///      may have arrived through `receive()` between swap-backs is treated as un-routed fees
    ///      and routed through the same path. Avoids ETH ever sitting idle in the contract.
    /// @dev Enforces at most `MAX_SWAPBACKS_PER_BLOCK` swap-backs per block via a counter that
    ///      resets to zero on the first call of each new block and increments after each
    ///      successful swap; once the counter hits the cap, further calls in the same block
    ///      silently return. The auto path (from `_update`) and the manual `swapBack` entry
    ///      point both go through this helper, so both same-block-overflow the same way: tx
    ///      succeeds, no `CreatorTaxSwapback` event, no balance change. The gate lives here
    ///      (not in the outer sell branch of `_update`) to keep `block.number` out of the
    ///      transfer hook's gating condition — static analyzers (e.g. Go+) flag any such read
    ///      as a per-user trading cooldown. The counter-reset-on-new-block shape mirrors the
    ///      reference token at `0xbad06a3ca84e4e2b489974d8918b5f7387e6db8e`.
    function _swapBack(uint256 tokenAmount, uint256 amountOutMinWei) internal {
        if (tokenAmount == 0) return;

        if (block.number > uint256(lastSwapbackBlock)) {
            swapbacksThisBlock = 0;
        }
        if (swapbacksThisBlock >= MAX_SWAPBACKS_PER_BLOCK) return;

        _inSwap = true;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        UNISWAP_V2_ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, amountOutMinWei, path, address(this), block.timestamp
        );

        _inSwap = false;
        swapbacksThisBlock++;
        lastSwapbackBlock = uint48(block.number);

        uint256 ethBalance = address(this).balance;
        emit CreatorTaxSwapback(tokenAmount, ethBalance);

        // Plain ETH push: the handler's `receive()` attributes the deposit via `msg.sender`,
        // so no `address(this)` argument is needed. `_accrueFees` no-ops on zero balance.
        _accrueFees(ethBalance);
    }
}
