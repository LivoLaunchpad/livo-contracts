// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoUniv4BuyBacks} from "src/tokens/LivoUniv4BuyBacks.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ILivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
// Self-aliased so the `chain-arc-*` recipes can import-swap it for the ARC pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet} (ARC native currency is USDC, 18-dec at msg.value).
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @notice Minimal view onto the V4 graduator: the hook it paired the token's pool with (to rebuild the
///         pool key) and the shared liquidity adder it deployed (to mint the single-sided ETH wall).
interface ILivoV4Graduator {
    function HOOK_ADDRESS() external view returns (address);
    function LIQUIDITY_ADDER() external view returns (address);
}

/// @title LivoTaxableTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks.
/// @dev Extends `LivoTaxableToken` (tax config + earnings split) and `LivoUniv4BuyBacks` (the ETH→token
///      buy-back swap). Tax accounting on swaps lives in `LivoSwapHook`; the token exposes the tax
///      config via `getTaxConfig()`. The earnings-allocation burn bucket is buffered here as ETH
///      (`burnPendingEth`) and processed out-of-band by `processBurn`, which buys back and burns tokens.
contract LivoTaxableTokenUniV4 is LivoTaxableToken, LivoUniv4BuyBacks, ReentrancyGuardTransient {
    ///////////////////////////////// uniswap v4 related /////////////////////////////////////////
    // NB : THESE ARE HARDCODED FOR MAINNET TO SAVE GAS

    /// @notice Pool manager for lock state checking
    address public constant UNIV4_POOL_MANAGER = DeploymentAddresses.UNIV4_POOL_MANAGER;

    /// @notice Max ETH a single `processBurn` / `processLiquidity` call may spend. Combined with the
    ///         once-per-block cooldown, it caps what a price-manipulation sandwich can extract from the
    ///         buffers per block (the pump must be re-paid — or held, exposed to arbitrage — every
    ///         block), while honest keepers just drain in batches. The remainder stays buffered.
    uint256 public constant MAX_EARNINGS_PER_PROCESS = DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

    /// @notice Width, in TICKS, of the single-sided ETH liquidity wall minted by `processLiquidity`. The
    ///         wall spans from just below the current price down to roughly -75%: ticks are log-price
    ///         (price = 1.0001^tick), so 14000 ticks (70 * the current 200 spacing) is a price ratio of
    ///         1.0001^14000 ≈ 4.05, i.e. the far end of the range is ~1/4.05 ≈ 0.25 of the current price
    ///         (a ~-75% drop). A given % drop maps to a CONSTANT tick width regardless of the starting
    ///         price. Derived from TICK_SPACING so the range stays spacing-aligned (and mints cleanly)
    ///         even if the spacing is ever retargeted per chain.
    int24 internal constant LIQUIDITY_WALL_TICK_WIDTH = 70 * UniswapV4PoolConstants.TICK_SPACING;

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

    // Reentrancy: `processBurn`, `processLiquidity` and `sweepStrayEth` share the inherited transient
    // `nonReentrant` lock (they make external calls that pass through `LivoSwapHook`/the fee handler and
    // could reenter). The hot-path `accrueFees` deliberately does NOT take the lock, so fee accrual
    // during a buy-back still works.

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

    error NothingToBurn();
    error NothingToAdd();
    error ProcessCooldown();

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
    ///         accruals into one swap, off the swap hot path. Spends at most
    ///         `MAX_EARNINGS_PER_PROCESS` per call, once per block (`ProcessCooldown`), so a
    ///         sandwiching manipulator's per-block take is capped; the remainder stays buffered.
    /// @param minTokensOut Slippage floor — the minimum tokens the buy-back must yield, or the swap
    ///        reverts. Callers should set this from the current price; a value of 0 invites sandwiching.
    /// @dev The buy-back is an ordinary pool swap, so `LivoSwapHook` charges its usual LP fee (and,
    ///      inside the launch tax window, tax — a fraction of which loops back into `burnPendingEth`
    ///      for the next call). This is accepted rather than special-casing the audited hook.
    function processBurn(uint256 minTokensOut) external nonReentrant {
        // Once per block + capped spend: bounds what a sandwich can extract per manipulated block.
        require(block.number > lastBurnProcessBlock, ProcessCooldown());
        lastBurnProcessBlock = uint48(block.number);

        uint256 ethIn = burnPendingEth;
        require(ethIn > 0, NothingToBurn());
        if (ethIn > MAX_EARNINGS_PER_PROCESS) ethIn = MAX_EARNINGS_PER_PROCESS;
        burnPendingEth -= ethIn;

        address hook = ILivoV4Graduator(graduator).HOOK_ADDRESS();
        uint256 balanceBefore = balanceOf(address(this));
        // Precursor marker: must stay BEFORE the swap so indexers can classify the resulting
        // `LivoSwapHook.LivoSwapBuy` as a protocol buy-back rather than a trade by `tx.origin`.
        emit BuyBackInitiated(ethIn);
        _buyBackTokensWithEth(hook, ethIn, minTokensOut);
        uint256 tokensBought = balanceOf(address(this)) - balanceBefore;

        if (tokensBought > 0) _burn(address(this), tokensBought);
        emit CreatorTaxBurn(ethIn, tokensBought);
    }

    /// @notice Routes any stray ETH — the token's balance beyond the `burnPendingEth` buy-back buffer —
    ///         back through the earnings-allocation split. Permissionless: stray ETH is not recoverable
    ///         by its sender, but instead becomes token earnings for holders (fund / dividends /
    ///         liquidity, plus its own burn slice). No-ops when there is nothing stray.
    function sweepStrayEth() external nonReentrant {
        // Stray ETH is treated as fresh V4 earnings, so carve its burn and liquidity shares on the ETH
        // side too. The burn and liquidity buffers are committed ETH, not stray, so they are excluded.
        _allocateEthEarnings(address(this).balance - burnPendingEth - liquidityPendingEth, burnBps, liquidityBps);
    }

    /// @notice Deposits the accrued liquidity ETH as a single-sided ETH position just below the current
    ///         price — a protective bid wall — via the shared `LivoUniV4LiquidityAdder`. Permissionless
    ///         and off the swap hot path, mirroring `processBurn`: the ETH is protocol-committed to
    ///         liquidity, so any keeper may trigger it. The minted NFT is held by this token and never
    ///         withdrawn, so it becomes permanent pool depth. Spends at most `MAX_EARNINGS_PER_PROCESS`
    ///         per call, once per block (`ProcessCooldown`): the wall is placed at the LIVE tick, so a
    ///         manipulator could pump the price and dump into a wall placed at the inflated level — the
    ///         cap+cooldown bounds that extraction per block (each block needs a fresh, fee-paying pump).
    /// @dev Runs out-of-band because `modifyLiquidity` cannot execute inside the swap hook's pool lock.
    ///      Batches many small accruals into one add. Guarded by the shared `nonReentrant` lock (the mint
    ///      routes through the position manager and the pool).
    function processLiquidity() external nonReentrant {
        // Once per block + capped spend: bounds what a manipulated wall placement can extract per block.
        require(block.number > lastLiquidityProcessBlock, ProcessCooldown());
        lastLiquidityProcessBlock = uint48(block.number);

        uint256 ethIn = liquidityPendingEth;
        require(ethIn > 0, NothingToAdd());
        if (ethIn > MAX_EARNINGS_PER_PROCESS) ethIn = MAX_EARNINGS_PER_PROCESS;
        liquidityPendingEth -= ethIn;

        PoolKey memory key =
            UniswapV4PoolConstants.livoPoolKey(address(this), ILivoV4Graduator(graduator).HOOK_ADDRESS());
        address adder = ILivoV4Graduator(graduator).LIQUIDITY_ADDER();
        // NFT and dust ETH both return to this token (permanent depth; dust rejoins the earnings split).
        uint128 liquidity = ILivoUniV4LiquidityAdder(adder).addSingleSidedEthBelowPrice{value: ethIn}(
            key, LIQUIDITY_WALL_TICK_WIDTH, address(this), address(this)
        );

        // Shared event signature; the token side is always 0 for the single-sided ETH wall.
        emit LiquidityAdded(ethIn, 0, liquidity);
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

    /// @dev V4 liquidity accrues ETH (earnings are ETH-native); the single-sided add happens out-of-band
    ///      in `processLiquidity`, so this stays cheap (one SSTORE) and consumes the slice fully (returns
    ///      0). Mirrors `_handleBurn`; overrides the base fund-fallback in `EarningsAllocation`.
    function _handleLiquidity(uint256 amount) internal override returns (uint256) {
        liquidityPendingEth += amount;
        return 0;
    }
}
