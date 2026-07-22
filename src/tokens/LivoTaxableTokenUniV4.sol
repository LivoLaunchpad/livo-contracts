// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoUniv4BuyBacks} from "src/tokens/LivoUniv4BuyBacks.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// this line below can be adjusted to import the Sepolia addresses when deploying in sepolia
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @notice Minimal view onto the V4 graduator: the hook it paired the token's pool with. Read by
///         `processBurn` to rebuild the exact pool key for the buy-back swap.
interface ILivoV4Graduator {
    function HOOK_ADDRESS() external view returns (address);
}

/// @title LivoTaxableTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks.
/// @dev Extends `LivoTaxableToken` (tax config + earnings split) and `LivoUniv4BuyBacks` (the ETH→token
///      buy-back swap). Tax accounting on swaps lives in `LivoSwapHook`; the token exposes the tax
///      config via `getTaxConfig()`. The earnings-allocation burn bucket is buffered here as ETH
///      (`burnPendingEth`) and processed out-of-band by `processBurn`, which buys back and burns tokens.
contract LivoTaxableTokenUniV4 is LivoTaxableToken, LivoUniv4BuyBacks {
    ///////////////////////////////// uniswap v4 related /////////////////////////////////////////
    // NB : THESE ARE HARDCODED FOR MAINNET TO SAVE GAS

    /// @notice Pool manager for lock state checking
    address public constant UNIV4_POOL_MANAGER = DeploymentAddresses.UNIV4_POOL_MANAGER;

    /////////////////////////// pure storage ///////////////////////

    /// @notice ETH accrued from the burn allocation, awaiting a `processBurn` buy-back-and-burn. Held in
    ///         the token's own balance; the rest of the balance (minus this) is stray ETH that
    ///         `sweepStrayEth` routes back into the earnings split.
    uint256 public burnPendingEth;

    /// @dev Transient reentrancy lock shared by `processBurn` and `sweepStrayEth`. Both make external
    ///      calls that pass through `LivoSwapHook`/the fee handler and could reenter; the hot-path
    ///      `accrueFees` deliberately does NOT take this lock, so fee accrual during a buy-back still
    ///      works. Transient — clears at end of tx, no SSTORE.
    bool internal transient _locked;

    //////////////////////// Events & errors //////////////////////

    /// @notice Emitted when accrued burn ETH is spent buying back and burning tokens via `processBurn`.
    event CreatorTaxBurn(uint256 ethSpent, uint256 tokensBurned);

    error NothingToBurn();
    error Reentrancy();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxableTokenUniV4 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        // Constructor body intentionally left empty
        // All initialization happens in initialize() due to minimal proxy pattern
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

    /// @notice Buys back tokens with the accrued burn ETH and burns them, reducing total supply.
    ///         Permissionless: the accrued ETH is protocol-committed to burning, so any keeper may
    ///         trigger it (holders don't depend on the creator staying active). Batches many small
    ///         accruals into one swap, off the swap hot path.
    /// @param minTokensOut Slippage floor — the minimum tokens the buy-back must yield, or the swap
    ///        reverts. Callers should set this from the current price; a value of 0 invites sandwiching.
    /// @dev The buy-back is an ordinary pool swap, so `LivoSwapHook` charges its usual LP fee (and,
    ///      inside the launch tax window, tax — a fraction of which loops back into `burnPendingEth`
    ///      for the next call). This is accepted rather than special-casing the audited hook.
    function processBurn(uint256 minTokensOut) external {
        require(!_locked, Reentrancy());
        _locked = true;

        uint256 ethIn = burnPendingEth;
        require(ethIn > 0, NothingToBurn());
        burnPendingEth = 0;

        address hook = ILivoV4Graduator(graduator).HOOK_ADDRESS();
        uint256 balanceBefore = balanceOf(address(this));
        _buyBackTokensWithEth(hook, ethIn, minTokensOut);
        uint256 tokensBought = balanceOf(address(this)) - balanceBefore;

        if (tokensBought > 0) _burn(address(this), tokensBought);
        emit CreatorTaxBurn(ethIn, tokensBought);

        _locked = false;
    }

    /// @notice Routes any stray ETH — the token's balance beyond the `burnPendingEth` buy-back buffer —
    ///         back through the earnings-allocation split. Permissionless: stray ETH is not recoverable
    ///         by its sender, but instead becomes token earnings for holders (fund / dividends /
    ///         liquidity, plus its own burn slice). No-ops when there is nothing stray.
    function sweepStrayEth() external {
        require(!_locked, Reentrancy());
        _locked = true;
        // Stray ETH is treated as fresh V4 earnings, so carve its burn share on the ETH side too.
        _allocateEthEarnings(address(this).balance - burnPendingEth, burnBps);
        _locked = false;
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @inheritdoc LivoTaxableToken
    /// @dev Adds the V4 pool-manager pair check after shared init. The graduator is expected to
    ///      have set `pair == UNIV4_POOL_MANAGER` during `LivoToken._initializeLivoToken`; if not,
    ///      revert and roll back any earlier writes (storage updates already performed are
    ///      reverted with the rest of the tx, so ordering vs `_initializeTaxConfig` is irrelevant).
    function _initializeLivoTaxableToken(ILivoToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        override
        onlyInitializing
    {
        super._initializeLivoTaxableToken(params, taxCfg);
        require(pair == UNIV4_POOL_MANAGER, "Invalid pair address");
    }

    /// @dev V4 burn accrues ETH (earnings are ETH-native); the buy-back-and-burn happens out-of-band
    ///      in `processBurn`, so this stays cheap (one SSTORE) and consumes the slice fully (returns 0,
    ///      nothing folds back to the fund wallets). Overrides the base fund-fallback in
    ///      `EarningsAllocation`.
    function _handleBurn(uint256 amount) internal override returns (uint256) {
        burnPendingEth += amount;
        return 0;
    }
}
