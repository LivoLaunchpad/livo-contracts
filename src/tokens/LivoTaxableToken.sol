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
/// @dev Storage layout: this contract introduces 4 packed slots-fields (buyTaxBps, sellTaxBps,
///      taxDurationSeconds, graduationTimestamp) directly after `LivoToken`'s storage. Subclasses
///      that add their own state must do so AFTER these fields to preserve clone-storage layout.
abstract contract LivoTaxableToken is LivoToken, ILivoTaxableToken {
    using SafeERC20 for IERC20;

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

    //////////////////////// Events //////////////////////

    /// @notice Emitted once during init with the dev-supplied tax config.
    event LivoTaxableTokenInitialized(uint16 buyTaxBps, uint16 sellTaxBps, uint40 taxDurationSeconds);

    //////////////////////// Errors //////////////////////

    error NotTokenOwner();
    error CannotRescueSelfToken();

    //////////////////////////////////////////////////////

    /// @notice Allows the contract to receive ETH (V2: from the router during tax swap-backs;
    ///         V4: defensive — the V4 token is not expected to hold ETH).
    receive() external payable {}

    /// @notice Marks the token as graduated and records the timestamp.
    /// @dev Can only be called by the pre-set graduator contract. Overrides `LivoToken` to add
    ///      timestamp tracking — the tax window is `[graduationTimestamp, graduationTimestamp + taxDurationSeconds]`.
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
    /// @dev Tax-bps and duration bounds are enforced upstream in the factory.
    function _initializeTaxConfig(TaxConfigInit memory cfg) internal {
        emit LivoTaxableTokenInitialized(cfg.buyTaxBps, cfg.sellTaxBps, uint40(cfg.taxDurationSeconds));

        buyTaxBps = cfg.buyTaxBps;
        sellTaxBps = cfg.sellTaxBps;
        taxDurationSeconds = uint40(cfg.taxDurationSeconds);
    }
}
