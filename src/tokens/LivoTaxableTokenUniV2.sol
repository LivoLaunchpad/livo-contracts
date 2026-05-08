// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTaxableTokenUniV2, TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV2.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// this line below can be adjusted to import the Sepolia addresses when deploying in sepolia
import {DeploymentAddressesMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title LivoTaxableTokenUniV2
/// @notice ERC20 token implementation with time-limited buy/sell taxes for tokens that graduate to
///         a Uniswap V2 pair. Uniswap V2 has no swap callbacks, so taxes are taken **intrinsically**:
///         a portion of every pair-touching transfer is diverted to this contract's balance, then
///         periodically swapped to ETH on the V2 router and pushed to the master fee handler via
///         the same `accrueFees` path that V4 uses.
/// @dev Auto-swap-back fires inside `_update` on sells once the contract holds at least
///      `SWAP_THRESHOLD` tokens. Recursion is guarded by `inSwap`: when the router pulls tokens
///      from this contract during the swap, our `_update` short-circuits to a plain transfer.
///      A permissioned `swapBack(amountOutMinWei)` lets the owner trigger a slippage-bounded swap
///      via a private mempool to avoid sandwiches.
contract LivoTaxableTokenUniV2 is LivoToken, ILivoTaxableTokenUniV2 {
    using SafeERC20 for IERC20;

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

    //////////////////////// potentially immutable //////////////////

    /// @notice Buy tax rate in basis points (set during initialization, cannot be changed)
    uint16 public buyTaxBps;

    /// @notice Sell tax rate in basis points (set during initialization, cannot be changed)
    uint16 public sellTaxBps;

    /// @notice Duration in seconds after graduation during which taxes apply (set during initialization, cannot be changed)
    uint40 public taxDurationSeconds;

    /////////////////////////// pure storage ///////////////////////

    /// @notice Timestamp when token graduated (0 if not graduated)
    uint40 public graduationTimestamp;

    /// @dev Re-entrancy guard for the swap-back path. When true, `_update` short-circuits the
    ///      tax + auto-trigger logic so the router's `transferFrom(this, pair, ...)` is a plain
    ///      ERC20 transfer.
    bool internal inSwap;

    //////////////////////// Events //////////////////////

    /// @notice Emitted once during init with the dev-supplied tax config.
    event LivoTaxableTokenInitialized(uint16 buyTaxBps, uint16 sellTaxBps, uint40 taxDurationSeconds);

    /// @notice Emitted whenever the contract auto- or manually-swaps accumulated tax tokens to ETH
    ///         and forwards the proceeds to the master fee handler.
    event TaxSwapped(uint256 tokenAmountIn, uint256 ethReceived);

    //////////////////////// Errors //////////////////////

    error NotTokenOwner();
    error CannotRescueSelfToken();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxableTokenUniV2 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
    }

    /// @notice Allows contract to receive ETH from the V2 router during tax swaps
    receive() external payable {}

    /// @notice Initializes the token clone with its parameters including tax configuration
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps and post-graduation tax duration)
    function initialize(ILivoToken.InitializeParams memory params, TaxConfigInit memory taxCfg)
        external
        virtual
        initializer
    {
        _initializeLivoTaxableTokenUniV2(params, taxCfg);
    }

    /// @dev Internal initializer body; callable from child `initializer`-gated functions.
    function _initializeLivoTaxableTokenUniV2(ILivoToken.InitializeParams memory params, TaxConfigInit memory taxCfg)
        internal
        onlyInitializing
    {
        _initializeLivoToken(params);
        _initializeTaxConfig(taxCfg);

        // One-shot infinite approval to the router so `_swapBack` doesn't have to re-approve every
        // call. OZ ERC20 v5 skips allowance decrement when the value is `type(uint256).max`.
        _approve(address(this), address(UNISWAP_V2_ROUTER), type(uint256).max);
    }

    /// @notice Marks the token as graduated and records the timestamp
    /// @dev Can only be called by the pre-set graduator contract. Overrides LivoToken to add
    ///      timestamp tracking — the tax window is `[graduationTimestamp, graduationTimestamp + taxDurationSeconds]`.
    function markGraduated() external override(ILivoToken, LivoToken) {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        graduationTimestamp = uint40(block.timestamp);
        emit Graduated();
    }

    /// @notice Manually triggers a swap of accumulated tax tokens for ETH and forwards the
    ///         proceeds to the master fee handler. Owner-only.
    /// @param amountOutMinWei Minimum ETH (in wei) the swap must yield. The caller is expected to
    ///        compute this from `router.getAmountsOut(...)` plus their own slippage budget; this
    ///        is the path used to MEV-protect a swap via a private mempool.
    function swapBack(uint256 amountOutMinWei) external {
        require(msg.sender == owner, NotTokenOwner());
        _swapBack(amountOutMinWei);
    }

    /// @notice Allows the token owner to rescue stuck balances. Two restrictions:
    ///         (1) Self-token rescue is disallowed — the owner must NEVER be able to siphon
    ///             accrued tax balance ahead of a swap-back.
    ///         (2) ETH stuck in the contract is treated as un-routed fees and pushed back through
    ///             `feeHandler.depositFees` so it lands on the configured fee receivers, never
    ///             on the owner. Preserves the project's pull-over-push invariant for ETH.
    /// @param token Token to rescue. Pass `address(0)` for ETH.
    function rescueTokens(address token) external {
        require(msg.sender == owner, NotTokenOwner());

        if (token == address(0)) {
            uint256 ethBalance = address(this).balance;
            if (ethBalance > 0) {
                ILivoMasterFeeHandler(feeHandler).depositFees{value: ethBalance}(address(this));
            }
        } else if (token == address(this)) {
            revert CannotRescueSelfToken();
        } else {
            IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
        }
    }

    //////////////////////// VIEW FUNCTIONS //////////////////////

    /// @notice Returns the tax configuration for this taxable token
    function getTaxConfig() external view override(ILivoToken, LivoToken) returns (TaxConfig memory config) {
        config = TaxConfig({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: taxDurationSeconds,
            graduationTimestamp: graduationTimestamp
        });
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @notice Internal helper to store tax configuration
    /// @dev Tax-bps and duration bounds are enforced upstream in `LivoFactoryUniV2Unified`.
    function _initializeTaxConfig(TaxConfigInit memory cfg) internal {
        emit LivoTaxableTokenInitialized(cfg.buyTaxBps, cfg.sellTaxBps, uint40(cfg.taxDurationSeconds));

        buyTaxBps = cfg.buyTaxBps;
        sellTaxBps = cfg.sellTaxBps;
        taxDurationSeconds = uint40(cfg.taxDurationSeconds);
    }

    /// @dev Intrinsic taxation hook. Order of operations:
    ///      1. If `inSwap` (we're inside `_swapBack`), bypass everything — the router's
    ///         `transferFrom(this, pair, ...)` must be a plain transfer, otherwise we recurse.
    ///      2. Apply the inherited pre-graduation gate.
    ///      3. On a sell with sufficient accumulated balance, fire `_swapBack(0)` (auto path).
    ///      4. If we're in the post-graduation tax window AND the transfer touches the pair AND
    ///         the source is not the graduator (which moves the initial liquidity), divert
    ///         `amount * bps / 10_000` to this contract and forward the rest.
    ///      The graduator exclusion is load-bearing: graduation transfers `markGraduated() →
    ///      safeTransfer(pair) → router.addLiquidityETH` all run with `to == pair` after
    ///      `graduationTimestamp` is stamped, so without the exclusion the initial liquidity
    ///      would be taxed.
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (inSwap) {
            super._update(from, to, amount);
            return;
        }

        if ((!graduated) && (to == pair)) {
            revert TransferToPairBeforeGraduationNotAllowed();
        }

        // Auto swap-back: only on sells, and only if the contract has enough accumulated tax to
        // make the swap worthwhile. `from != address(this)` is implied by `inSwap` already being
        // false here (the contract only ever transfers tokens during a swap-back).
        if (to == pair && balanceOf(address(this)) >= SWAP_THRESHOLD) {
            _swapBack(0);
        }

        bool taxable = graduated && (from != graduator) && (from == pair || to == pair)
            && block.timestamp <= uint256(graduationTimestamp) + taxDurationSeconds;

        if (taxable) {
            uint16 bps = (from == pair) ? buyTaxBps : sellTaxBps;
            if (bps > 0) {
                uint256 taxAmount = amount * bps / 10_000;
                if (taxAmount > 0) {
                    super._update(from, address(this), taxAmount);
                    super._update(from, to, amount - taxAmount);
                    return;
                }
            }
        }
        super._update(from, to, amount);
    }

    /// @dev Swaps the contract's full token balance to ETH on the V2 router and forwards the
    ///      proceeds to the master fee handler. The `inSwap` flag short-circuits `_update` for
    ///      the duration of the swap so the router's `transferFrom(this, pair, ...)` is a plain
    ///      transfer (no recursive tax, no recursive auto-trigger).
    /// @dev `address(this).balance` is forwarded in full (not just the swap output): any ETH that
    ///      may have arrived through `receive()` between swap-backs is treated as un-routed fees
    ///      and routed through the same path. Avoids ETH ever sitting idle in the contract.
    function _swapBack(uint256 amountOutMinWei) internal {
        uint256 tokenAmount = balanceOf(address(this));
        if (tokenAmount == 0) return;

        inSwap = true;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        UNISWAP_V2_ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, amountOutMinWei, path, address(this), block.timestamp
        );

        inSwap = false;

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            ILivoMasterFeeHandler(feeHandler).depositFees{value: ethBalance}(address(this));
        }

        emit TaxSwapped(tokenAmount, ethBalance);
    }
}
