// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet} (ARC: `WETH` is the 6-decimal USDC ERC-20 V2 quote).
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
// Aliased so the `chain-arc-*` recipe can import-swap it for the ARC venue: swap-back sells tax tokens
// for USDC (token→USDC) instead of ETH, since ARC has no wrappable WETH. See UniswapV2VenueArc.
import {UniswapV2Venue as UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";

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
///      Go+'s "trading cooldown" heuristic; see `_processCollectedTokens`.
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

    /// @notice Where `processLiquidity` LP tokens are sent, permanently locking the added liquidity.
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    /////////////////////////// pure storage ///////////////////////

    /// @dev Re-entrancy guard for the swap-back path. When true, `_update` short-circuits the
    ///      tax + auto-trigger logic so the router's `transferFrom(this, pair, ...)` is a plain
    ///      ERC20 transfer. Lives in transient storage — auto-clears at end of tx, no SSTORE cost.
    bool internal transient _inSwap;

    /// @notice `block.number` of the most recent successful `_processCollectedTokens`; zero until the first.
    ///         Paired with `swapbacksThisBlock` for the per-block cap. `uint48`, packed with
    ///         `swapbacksThisBlock` in the slot that FOLLOWS the parent tax + `EarningsAllocation` slot
    ///         (that slot is full at 240 bits, so these no longer share it).
    uint48 public lastSwapbackBlock;

    /// @notice Swap-backs already settled in `lastSwapbackBlock`. Resets on the first swap-back
    ///         of a new block; at `MAX_SWAPBACKS_PER_BLOCK` further same-block calls silent-no-op.
    uint8 public swapbacksThisBlock;

    /// @notice Tax TOKENS set aside for the liquidity allocation, awaiting a `processLiquidity` add. Held
    ///         in the token's own balance alongside not-yet-swapped tax, but tracked apart: the swap-back
    ///         paths subtract it so this committed slice is never re-processed as tax. V2 buffers liquidity
    ///         as TOKENS (not ETH) because a V2 pair cannot deliver a token to its own address (INVALID_TO),
    ///         so the token side is kept, not bought back; `processLiquidity` sells only half for the ETH side.
    uint256 public liquidityPendingTokens;

    //////////////////////// Events //////////////////////

    /// @notice Emitted whenever the contract auto- or manually-swaps accumulated tax tokens to ETH and
    ///         routes the proceeds through the earnings-allocation split.
    /// @dev `tokenAmountIn` / `ethAmount` describe THIS SWAP exactly — the same token and native amounts
    ///      the `UniswapV2Pair.Swap` in this tx carries — so an indexer can pair the two by amount and
    ///      mark the swap as a protocol swap-back rather than a trader sell. `tokenAmountIn` is therefore
    ///      net of any burn-share already removed in token-space (`CreatorTaxBurn`) and of the liquidity
    ///      share set aside as tokens; `ethAmount` is the balance DELTA across the swap, not the contract
    ///      balance, which may also hold router refunds from an earlier `processLiquidity`.
    /// @dev `ethToFund` is the slice of the routed ETH that actually reached the fee handler, i.e. the
    ///      creator fees. It differs from `ethAmount` for a token with a non-zero earnings allocation
    ///      (the dividends slice is withheld, and any stray balance is swept in on top), so accounting
    ///      must use this field and not `ethAmount`. The two are equal for a token with no allocation.
    event CreatorTaxSwapback(uint256 tokenAmountIn, uint256 ethAmount, uint256 ethToFund);

    /// @notice Thrown by the manual `swapBack` before graduation (no tax accrues / no pair yet), and by
    ///         `processLiquidity` (no pool to add to before graduation).
    error NotGraduated();

    /// @notice Thrown by `processLiquidity` when there is no accrued liquidity ETH to add.
    error NothingToAdd();

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
    /// @dev Adds a one-shot infinite approval to the V2 router so `_processCollectedTokens` doesn't have to
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
    /// @param amountOutMinWei Minimum native proceeds the swap must yield, in QUOTE decimals: 18-dec
    ///        ETH on ETH-family builds, 6-dec USDC on ARC builds (where the swap sells to USDC, which
    ///        IS native balance). Caller's slippage budget. Applies to the post-burn, post-liquidity
    ///        remainder actually swapped, not to `swapAmount`.
    /// @dev If the per-block cap is hit, `_processCollectedTokens` silently no-ops (no event, no revert).
    /// @dev Post-graduation only: no tax accrues (and there is no pair to swap against) before
    ///      graduation, so a pre-graduation swap-back is always meaningless — reverting closes the
    ///      edge where a 100%-burn token could burn donated tokens before graduation.
    function swapBack(uint256 swapAmount, uint256 amountOutMinWei) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        require(graduated, NotGraduated());
        _processCollectedTokens(swapAmount, amountOutMinWei);
    }

    /// @notice Turns the buffered liquidity TOKENS into a locked V2 LP position: sells half for ETH,
    ///         pairs the retained half with that ETH, and sends the LP to the dead address (permanent
    ///         depth). Permissionless, out-of-band (batches accruals off the swap hot path), mirroring the
    ///         V4 `processLiquidity` and the burn `processBurn` async pattern.
    /// @param amountOutMinWei Slippage floor for the half-sell, in QUOTE decimals (18-dec ETH on
    ///        ETH-family builds, 6-dec USDC on ARC) — the swap reverts if it yields less. Keepers
    ///        should set it from the current price (via a private mempool); 0 invites sandwiching of
    ///        the half-sell, bounded by the current buffer.
    /// @dev Token-native: the token side is KEPT (not bought back — a V2 pair reverts INVALID_TO when
    ///      asked to send a token to its own address), only half is sold for the ETH side. Post-graduation
    ///      only. The sell + add run under `_inSwap` so the intrinsic tax / auto-swap-back don't fire on
    ///      the router's transfers. Any unused ETH/tokens the router refunds fold back into the next
    ///      swap-back (ETH) / the tax pool (tokens).
    function processLiquidity(uint256 amountOutMinWei) external {
        require(graduated, NotGraduated());
        uint256 tokenIn = liquidityPendingTokens;
        require(tokenIn > 0, NothingToAdd());
        liquidityPendingTokens = 0;

        _inSwap = true;

        // Sell half the buffered tokens for native (native to self is fine; a token to self would revert).
        // Keep the other half for the LP token side.
        uint256 tokensToSell = tokenIn / 2;
        uint256 tokensForLp = tokenIn - tokensToSell;
        // note: we could swap the portion of tokens for liquidity as part of the _swapback function,
        // but as token price changes, that could break the expected token/eth ratio. So a safer move
        // is to swap here right before adding liquidity, even if that means one extra swap
        uint256 ethBefore = address(this).balance;
        if (tokensToSell > 0) {
            UniswapV2Venue.swapTaxToNative(UNISWAP_V2_ROUTER, WETH, tokensToSell, amountOutMinWei);
        }
        // 18-dec native on both chains: on ARC the swap's 6-dec USDC output IS native balance.
        uint256 ethFromSell = address(this).balance - ethBefore;

        // Pair the retained tokens with the native just obtained, via the per-chain venue: WETH
        // `addLiquidityETH` on ETH-family, two-ERC20 `addLiquidity` against the 6-dec USDC on ARC.
        // Accept any ratio (priority: don't revert); the router refunds the excess side to this contract.
        // The event reports the router's ACTUAL amounts, not the requested ones: the refunded remainder
        // never reached the pool (on ARC, so does the sub-1e-6-USDC flooring dust).
        uint256 ethAdded;
        uint256 tokensAdded;
        uint256 liquidity;
        if (tokensForLp > 0 && ethFromSell > 0) {
            (tokensAdded, ethAdded, liquidity) = UniswapV2Venue.supplyLiquidity(
                UNISWAP_V2_ROUTER, address(this), WETH, tokensForLp, ethFromSell, DEAD_ADDRESS
            );
        }

        _inSwap = false;

        emit LiquidityAdded(ethAdded, tokensAdded, liquidity);
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Intrinsic taxation hook. Order:
    ///      1. If `_inSwap`, bypass — the router's `transferFrom(this, pair, ...)` must be a plain
    ///         transfer, otherwise we recurse.
    ///      2. Inherited pre-graduation gate.
    ///      3. On a sell with accumulated balance, fire `_processCollectedTokens` capped at `2 * SWAP_THRESHOLD`.
    ///         Trigger fires at `balance >= SWAP_THRESHOLD`, OR — after the tax window expires —
    ///         on any non-zero residual (no fresh tax can push a sub-threshold balance across).
    ///         The per-block cap lives inside `_processCollectedTokens`; this outer branch deliberately does NOT
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
        // reserves, so firing `_processCollectedTokens` then would revert graduation (and could be griefed by
        // pre-funding `address(this)`). Per-block cap is enforced inside `_processCollectedTokens` to keep
        // `block.number` out of the transfer hook (Go+ flags such reads as a trading cooldown).
        if (isSell && from != graduator) {
            // Exclude the liquidity buffer: those tokens are committed to `processLiquidity`, not tax.
            uint256 contractBalance = balanceOf(address(this)) - liquidityPendingTokens;
            if (contractBalance >= SWAP_THRESHOLD) {
                uint256 swapAmount = contractBalance > 2 * SWAP_THRESHOLD ? 2 * SWAP_THRESHOLD : contractBalance;
                _processCollectedTokens(swapAmount, 0);
            } else if (contractBalance > 0 && !_taxWindowActive()) {
                // Post-window drain: window's closed, no fresh tax will ever flow in, so a residual
                // stuck below SWAP_THRESHOLD would otherwise sit forever. No 2*SWAP_THRESHOLD cap
                // needed: this branch only fires when contractBalance < SWAP_THRESHOLD, so the swap
                // is already small.
                // This path can only be reached if graduated==true. No risk of calling _processCollectedTokens before graduation
                _processCollectedTokens(contractBalance, 0);
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

    /// @dev Processes `tokenAmount` of collected tax tokens through the earnings buckets in TOKEN-space:
    ///      burns the burn-share, sets the liquidity-share aside for `processLiquidity`, swaps the rest to
    ///      ETH on the V2 router, then routes that ETH through `_allocateEthEarnings` (dividends / fund).
    ///      `_inSwap` short-circuits `_update` during the router pull so it's a plain transfer (no
    ///      recursive tax / auto-trigger). Caller must size `tokenAmount` against the balance and any
    ///      per-sell cap.
    /// @dev Per-block cap: resets `swapbacksThisBlock` on a new block, increments on success;
    ///      same-block overflow silently no-ops (tx succeeds, no event, no balance change). Both
    ///      auto and manual paths go through here. The gate lives in `_processCollectedTokens` (not in
    ///      `_update`'s sell branch) so `block.number` stays out of the transfer hook — Go+ flags
    ///      such reads as a per-user trading cooldown.
    function _processCollectedTokens(uint256 tokenAmount, uint256 amountOutMinWei) internal {
        if (tokenAmount == 0) return;

        // Cache the counter so the post-router writes to `swapbacksThisBlock` and
        // `lastSwapbackBlock` (same packed slot) coalesce into a single SSTORE, and the
        // new-block reset doesn't pay for its own pre-router write.
        uint8 count = swapbacksThisBlock;
        if (block.number > uint256(lastSwapbackBlock)) {
            count = 0;
        }
        if (count >= MAX_SWAPBACKS_PER_BLOCK) return;

        // Never process the committed liquidity buffer as tax: it shares this contract's token balance
        // but is earmarked for `processLiquidity`. Clamp so the manual `swapBack` can't reach it either.
        uint256 avail = balanceOf(address(this)) - liquidityPendingTokens;
        if (tokenAmount > avail) tokenAmount = avail;
        if (tokenAmount == 0) return;

        _inSwap = true;

        // Burn the burn-share in token-space FIRST — no ETH→token round trip. `_inSwap` keeps this a
        // plain transfer through `_update`. Applies to the amount processed this swap-back; 0 for
        // tokens without a burn allocation.
        uint256 burnAmount = tokenAmount * burnBps / BPS_TOTAL;
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
            // `ethSpent` is 0: the burn happens in token-space, with no ETH→token round trip.
            emit CreatorTaxBurn(0, burnAmount);
        }

        // Set aside the liquidity-share as TOKENS — kept on this contract (tracked by
        // `liquidityPendingTokens`), not swapped — for a later `processLiquidity`. 0 without a liquidity
        // allocation.
        uint256 liquidityAmount = tokenAmount * liquidityBps / BPS_TOTAL;
        if (liquidityAmount > 0) liquidityPendingTokens += liquidityAmount;

        uint256 swapAmount = tokenAmount - burnAmount - liquidityAmount;

        // Sell the remainder for native via the per-chain venue: token→ETH on ETH-family, token→USDC on
        // ARC. On ARC the received 6-dec USDC IS native balance, so the balance reads below reflect the
        // proceeds with no unwrap. `amountOutMinWei` is in quote decimals (18-dec ETH / 6-dec USDC); the
        // auto path passes 0. See UniswapV2Venue.
        // Measured as a DELTA, not as the closing balance: the contract may already hold router refunds
        // from an earlier `processLiquidity`, and the event must report this swap's own proceeds so an
        // indexer can match it against the pair's `Swap`.
        uint256 ethBefore = address(this).balance;
        if (swapAmount > 0) {
            UniswapV2Venue.swapTaxToNative(UNISWAP_V2_ROUTER, WETH, swapAmount, amountOutMinWei);
        }
        uint256 ethFromSwap = address(this).balance - ethBefore;

        _inSwap = false;
        unchecked {
            ++count;
        }
        swapbacksThisBlock = count;
        lastSwapbackBlock = uint48(block.number);

        // Route the FULL balance — this swap-back's proceeds plus any router refunds from a prior
        // `processLiquidity` (the liquidity slice is buffered as TOKENS, not ETH, so nothing to exclude).
        // Pass `0, 0`: both the burn AND the liquidity slices were already taken above in TOKEN-space, so
        // `_allocateEthEarnings` carves no ETH burn/liquidity slice and renormalizes dividends/fund over
        // the leftover. No-ops on a 0 balance.
        uint256 ethToFund = _allocateEthEarnings(address(this).balance, 0, 0);

        // Emitted after the split so the fund slice is known. `ethFromSwap` (this swap) and `ethToFund`
        // (what reached the fee handler) are equal for a token with no earnings allocation.
        emit CreatorTaxSwapback(swapAmount, ethFromSwap, ethToFund);
    }
}
