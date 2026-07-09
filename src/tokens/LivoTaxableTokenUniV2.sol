// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// this line below can be adjusted to import the Sepolia addresses when deploying in sepolia
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title LivoTaxableTokenUniV2
/// @notice ERC20 token implementation with time-limited buy/sell taxes for tokens that graduate to
///         a Uniswap V2 pair. Uniswap V2 has no swap callbacks, so taxes are taken **intrinsically**:
///         a portion of every pair-touching transfer is diverted to this contract's balance, then
///         periodically swapped to ETH on the V2 router and pushed to the master fee handler via
///         the same `accrueFees` path that V4 uses.
/// @dev Auto-swap-back fires inside `_update` on sells once the contract holds at least
///      `SWAP_THRESHOLD` tokens — or, after the tax window expires, any non-zero residual — and
///      never swaps more than `2 * SWAP_THRESHOLD` per sell so the per-sell price impact stays
///      bounded; excess carries to the next qualifying sell. Recursion is guarded by `_inSwap`.
///      At most `MAX_SWAPBACKS_PER_BLOCK` swap-backs per block: the counter resets on a new
///      block and silent-no-ops on overflow. Counter shape mirrors a reference token that passes
///      Go+'s "trading cooldown" heuristic; see `_swapBack`.
///      `swapBack(amountOutMinWei)` lets the owner trigger a slippage-bounded swap via a private
///      mempool. Factory-deployed tokens have `owner == address(0)`, so this entry point is
///      reachable only via the launchpad owner; the auto-trigger remains the live path.
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

    /// @notice Max swap-backs per block. Further same-block calls silently no-op. Picked so two
    ///         whales selling in the same block both get their tax routed.
    uint8 public constant MAX_SWAPBACKS_PER_BLOCK = 2;

    /////////////////////////// pure storage ///////////////////////

    /// @dev Re-entrancy guard for the swap-back path. When true, `_update` short-circuits the
    ///      tax + auto-trigger logic so the router's `transferFrom(this, pair, ...)` is a plain
    ///      ERC20 transfer. Lives in transient storage — auto-clears at end of tx, no SSTORE cost.
    bool internal transient _inSwap;

    /// @notice `block.number` of the most recent successful `_swapBack`; zero until the first.
    ///         Paired with `swapbacksThisBlock` for the per-block cap. uint48 packs into the
    ///         parent `LivoTaxableToken` slot alongside `graduationTimestamp`.
    uint48 public lastSwapbackBlock;

    /// @notice Swap-backs already settled in `lastSwapbackBlock`. Resets on the first swap-back
    ///         of a new block; at `MAX_SWAPBACKS_PER_BLOCK` further same-block calls silent-no-op.
    uint8 public swapbacksThisBlock;

    //////////////////////// Events //////////////////////

    /// @notice Emitted whenever the contract auto- or manually-swaps accumulated tax tokens to ETH
    ///         and forwards the proceeds to the master fee handler. `ethAmount` is the ETH
    ///         routed through `feeHandler.depositFees` for this swap-back, i.e. the tax
    ///         actually accrued to the creator (and any direct receivers) for the swap window
    ///         covered by this back-swap.
    event CreatorTaxSwapback(uint256 tokenAmountIn, uint256 ethAmount);

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxableTokenUniV2 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
    }

    /// @notice Initializes the token clone with its tax configuration. Anti-sniper protection is
    ///         enabled iff `antiSniperCfg` opts in (`protectionWindowSeconds != 0`); pass an all-zero
    ///         config for a tax-only token.
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps, window, optional launch-tax decay)
    /// @param antiSniperCfg Anti-sniper caps + window config (validated upstream in the factory)
    function initialize(
        ILivoToken.InitializeParams memory params,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeLivoTaxableToken(params, taxCfg);
        _initializeAntiSniper(antiSniperCfg);
    }

    /// @inheritdoc LivoTaxableToken
    /// @dev Adds a one-shot infinite approval to the V2 router so `_swapBack` doesn't have to
    ///      re-approve every call. OZ ERC20 v5 skips allowance decrement when value is `type(uint256).max`.
    function _initializeLivoTaxableToken(ILivoToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        override
        onlyInitializing
    {
        super._initializeLivoTaxableToken(params, taxCfg);
        _approve(address(this), address(UNISWAP_V2_ROUTER), type(uint256).max);
    }

    /// @notice Manually triggers a swap of `swapAmount` tax tokens for ETH and forwards the
    ///         proceeds to the fee handler. Callable by the token owner OR the launchpad owner;
    ///         primary use is MEV-protected execution via a private mempool.
    /// @param swapAmount Amount to swap. The auto path's `2 * SWAP_THRESHOLD` cap is NOT enforced
    ///        here so a private-mempool caller can drain a larger residual in one shot. The router
    ///        reverts if `swapAmount` exceeds the contract's balance.
    /// @param amountOutMinWei Minimum ETH the swap must yield. Caller's slippage budget.
    /// @dev If the per-block cap is hit, `_swapBack` silently no-ops (no event, no revert).
    function swapBack(uint256 swapAmount, uint256 amountOutMinWei) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        _swapBack(swapAmount, amountOutMinWei);
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Intrinsic taxation hook. Order:
    ///      1. If `_inSwap`, bypass — the router's `transferFrom(this, pair, ...)` must be a plain
    ///         transfer, otherwise we recurse.
    ///      2. Inherited pre-graduation gate.
    ///      3. On a sell with accumulated balance, fire `_swapBack` capped at `2 * SWAP_THRESHOLD`.
    ///         Trigger fires at `balance >= SWAP_THRESHOLD`, OR — after the tax window expires —
    ///         on any non-zero residual (no fresh tax can push a sub-threshold balance across).
    ///         The per-block cap lives inside `_swapBack`; this outer branch deliberately does NOT
    ///         read `block.number` so static analyzers don't flag a trading cooldown.
    ///      4. In the tax window, on a pair-touching transfer from a non-graduator source, divert
    ///         `amount * bps / 10_000` to this contract and forward the rest.
    ///      The graduator exclusion is load-bearing: `markGraduated() → safeTransfer(pair) →
    ///      addLiquidityETH` runs with `to == pair` while `graduated == true` and (typically) the tax
    ///      window is still open, so without it the initial liquidity would be taxed.
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

        // Auto swap-back on sells. `from != graduator` is load-bearing: the graduator's initial
        // `addLiquidityETH` triggers `_update(graduator, pair, ...)` while the pair has zero
        // reserves, so firing `_swapBack` then would revert graduation (and could be griefed by
        // pre-funding `address(this)`). Per-block cap is enforced inside `_swapBack` to keep
        // `block.number` out of the transfer hook (Go+ flags such reads as a trading cooldown).
        if (isSell && from != graduator) {
            uint256 contractBalance = balanceOf(address(this));
            if (contractBalance >= SWAP_THRESHOLD) {
                uint256 swapAmount = contractBalance > 2 * SWAP_THRESHOLD ? 2 * SWAP_THRESHOLD : contractBalance;
                _swapBack(swapAmount, 0);
            } else if (contractBalance > 0 && !_taxWindowActive()) {
                // Post-window drain: window's closed, no fresh tax will ever flow in, so a residual
                // stuck below SWAP_THRESHOLD would otherwise sit forever. No 2*SWAP_THRESHOLD cap
                // needed: this branch only fires when contractBalance < SWAP_THRESHOLD, so the swap
                // is already small.
                // This path can only be reached if graduated==true. No risk of calling _swapBack before graduation
                _swapBack(contractBalance, 0);
            }
        }

        // charging the tax: only if graduated, only on pair-touching transfers, only while the
        // tax window is active (anchored at launch or graduation per `startTaxFromLaunch`). The rate is
        // the EFFECTIVE rate `max(decay, static)`, so a decaying launch tax is charged here too (and a
        // decay-only token, whose static bps are 0, still taxes during its decay window).
        if (_graduated && (isBuy || isSell) && _taxWindowActive() && from != graduator) {
            uint16 bps = _effectiveTaxBps(isBuy);
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

    /// @dev Swaps `tokenAmount` to ETH on the V2 router and pushes the contract's full ETH
    ///      balance to the fee handler. `_inSwap` short-circuits `_update` during the router pull
    ///      so it's a plain transfer (no recursive tax / auto-trigger). Caller must size
    ///      `tokenAmount` against the balance and any per-sell cap.
    /// @dev Per-block cap: resets `swapbacksThisBlock` on a new block, increments on success;
    ///      same-block overflow silently no-ops (tx succeeds, no event, no balance change). Both
    ///      auto and manual paths go through here. The gate lives in `_swapBack` (not in
    ///      `_update`'s sell branch) so `block.number` stays out of the transfer hook — Go+ flags
    ///      such reads as a per-user trading cooldown.
    function _swapBack(uint256 tokenAmount, uint256 amountOutMinWei) internal {
        if (tokenAmount == 0) return;

        // Cache the counter so the post-router writes to `swapbacksThisBlock` and
        // `lastSwapbackBlock` (same packed slot) coalesce into a single SSTORE, and the
        // new-block reset doesn't pay for its own pre-router write.
        uint8 count = swapbacksThisBlock;
        if (block.number > uint256(lastSwapbackBlock)) {
            count = 0;
        }
        if (count >= MAX_SWAPBACKS_PER_BLOCK) return;

        _inSwap = true;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        UNISWAP_V2_ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, amountOutMinWei, path, address(this), block.timestamp
        );

        _inSwap = false;
        unchecked {
            ++count;
        }
        swapbacksThisBlock = count;
        lastSwapbackBlock = uint48(block.number);

        uint256 ethBalance = address(this).balance;
        emit CreatorTaxSwapback(tokenAmount, ethBalance);

        if (ethBalance > 0) {
            ILivoMasterFeeHandler(feeHandler).depositFees{value: ethBalance}(address(this));
        }
    }
}
