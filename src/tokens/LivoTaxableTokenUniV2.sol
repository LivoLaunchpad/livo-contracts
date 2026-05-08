// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
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
///      `SWAP_THRESHOLD` tokens. Recursion is guarded by `_inSwap`: when the router pulls tokens
///      from this contract during the swap, our `_update` short-circuits to a plain transfer.
///      A permissioned `swapBack(amountOutMinWei)` lets the owner trigger a slippage-bounded swap
///      via a private mempool to avoid sandwiches; on factory-deployed tokens the owner is
///      `address(0)`, so this entry point always reverts and the auto-trigger is the live path.
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

    /////////////////////////// pure storage ///////////////////////

    /// @dev Re-entrancy guard for the swap-back path. When true, `_update` short-circuits the
    ///      tax + auto-trigger logic so the router's `transferFrom(this, pair, ...)` is a plain
    ///      ERC20 transfer.
    bool internal _inSwap;

    //////////////////////// Events //////////////////////

    /// @notice Emitted whenever the contract auto- or manually-swaps accumulated tax tokens to ETH
    ///         and forwards the proceeds to the master fee handler.
    event TaxSwapped(uint256 tokenAmountIn, uint256 ethReceived);

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

    /// @notice Manually triggers a swap of accumulated tax tokens for ETH and forwards the
    ///         proceeds to the master fee handler. Callable by the token owner OR the launchpad
    ///         owner.
    /// @param amountOutMinWei Minimum ETH (in wei) the swap must yield. The caller is expected to
    ///        compute this from `router.getAmountsOut(...)` plus their own slippage budget; this
    ///        is the path used to MEV-protect a swap via a private mempool.
    /// @dev Factory-deployed tokens always have `owner == address(0)`; the launchpad-owner branch
    ///      is therefore the only reachable manual path on those deployments. The auto-trigger
    ///      inside `_update` remains the primary path regardless of caller identity. Proceeds are
    ///      forwarded to the fee handler (not the caller), so widening the caller set has no
    ///      asset-routing impact.
    function swapBack(uint256 amountOutMinWei) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        _swapBack(amountOutMinWei);
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Intrinsic taxation hook. Order of operations:
    ///      1. If `_inSwap` (we're inside `_swapBack`), bypass everything — the router's
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
        if (_inSwap) {
            super._update(from, to, amount);
            return;
        }

        if ((!graduated) && (to == pair)) {
            revert TransferToPairBeforeGraduationNotAllowed();
        }

        // Auto swap-back: only on sells, and only if the contract has enough accumulated tax to
        // make the swap worthwhile. `from != address(this)` is implied by `_inSwap` already being
        // false here (the contract only ever transfers tokens during a swap-back).
        if (to == pair && balanceOf(address(this)) >= SWAP_THRESHOLD) {
            _swapBack(0);
        }

        bool taxable = graduated && (from == pair || to == pair)
            && (block.timestamp <= uint256(graduationTimestamp) + taxDurationSeconds) && (from != graduator);

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
        // no tax applied if we reached here
        super._update(from, to, amount);
    }

    /// @dev Swaps the contract's full token balance to ETH on the V2 router and forwards the
    ///      proceeds to the master fee handler. The `_inSwap` flag short-circuits `_update` for
    ///      the duration of the swap so the router's `transferFrom(this, pair, ...)` is a plain
    ///      transfer (no recursive tax, no recursive auto-trigger).
    /// @dev `address(this).balance` is forwarded in full (not just the swap output): any ETH that
    ///      may have arrived through `receive()` between swap-backs is treated as un-routed fees
    ///      and routed through the same path. Avoids ETH ever sitting idle in the contract.
    function _swapBack(uint256 amountOutMinWei) internal {
        uint256 tokenAmount = balanceOf(address(this));
        if (tokenAmount == 0) return;

        _inSwap = true;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        UNISWAP_V2_ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, amountOutMinWei, path, address(this), block.timestamp
        );

        _inSwap = false;

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            ILivoMasterFeeHandler(feeHandler).depositFees{value: ethBalance}(address(this));
        }

        emit TaxSwapped(tokenAmount, ethBalance);
    }
}
