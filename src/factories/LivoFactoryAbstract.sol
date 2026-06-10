// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoCreatorVaultFactory} from "src/interfaces/ILivoCreatorVaultFactory.sol";
import {ILivoTaxableToken, ILivoTaxableTokenSniperProtected, TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";

/// @notice Abstract base for Livo token factories. Holds shared state and helper logic.
/// @dev    UUPS-upgradeable. The implementation contract sets its immutables in the constructor
///         (baked into bytecode) and calls `_disableInitializers()` to prevent direct init.
///         Proxies must call `initialize()` exactly once to claim ownership. Upgrade authorisation
///         lives in `_authorizeUpgrade`.
abstract contract LivoFactoryAbstract is ILivoFactory, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Max configurable tax duration. Capped at 120 years purely to prevent overflow —
    ///         the upper bound is driven by `TaxConfigInit.taxDurationSeconds`'s `uint32` packing.
    ///         Any deployer can use any duration up to this cap; no fee-receiver or
    ///         ownership constraints are imposed beyond the standard validation.
    uint256 public constant MAX_TAX_DURATION_SECONDS = 120 * 365 days;

    /// @notice Launchpad where tokens are registered after creation
    ILivoLaunchpad public immutable LAUNCHPAD;
    /// @notice Graduator contract that handles token graduation to Uniswap
    ILivoGraduator public immutable GRADUATOR;
    /// @notice Bonding curve used for token pricing before graduation
    ILivoBondingCurve public immutable BONDING_CURVE;
    /// @notice Master fee handler for all token fee routing
    ILivoMasterFeeHandler public immutable MASTER_FEE_HANDLER;

    /// @notice Token implementation cloned when neither tax nor anti-sniper are configured.
    address public immutable TOKEN_IMPL_BASE;
    /// @notice Token implementation cloned when only anti-sniper protection is configured.
    address public immutable TOKEN_IMPL_ANTISNIPER;
    /// @notice Token implementation cloned when only tax is configured.
    address public immutable TOKEN_IMPL_TAX;
    /// @notice Token implementation cloned when both tax and anti-sniper are configured.
    address public immutable TOKEN_IMPL_TAX_ANTISNIPER;

    /// @notice Factory that deploys the per-token creator-vault clones.
    ILivoCreatorVaultFactory public immutable CREATOR_VAULT_FACTORY;

    /// @notice Bonding curves used when creator vaults lock 5%/10%/15%/20%/25%/30% of supply.
    ///         Each keeps every graduation invariant identical to `BONDING_CURVE`; only the starting
    ///         market cap is relaxed. Selected by the total locked allocation (see `_resolveBondingCurve`).
    ILivoBondingCurve public immutable VAULT_CURVE_5;
    ILivoBondingCurve public immutable VAULT_CURVE_10;
    ILivoBondingCurve public immutable VAULT_CURVE_15;
    ILivoBondingCurve public immutable VAULT_CURVE_20;
    ILivoBondingCurve public immutable VAULT_CURVE_25;
    ILivoBondingCurve public immutable VAULT_CURVE_30;

    /// @notice Cap on the aggregate fee a swapper pays (LP fee + tax), in basis points. Fixed at 5%.
    ///         Enforced per call by `_validateTotalFee`. The tax headroom is venue-dependent because
    ///         the LP fee varies: V2 has no LP fee, so tax can reach the full 5%; V4 charges 50 or
    ///         100 bps in LP fees, leaving 450 or 400 bps for tax.
    uint256 public constant MAX_TOTAL_FEE_BPS = 500;

    /// @notice Max percentage of total supply that can be purchased on token creation (applies to the
    ///         aggregate, not per recipient), in basis points. Fixed at 10%. To change this value,
    ///         deploy a new implementation with a different constant and `upgradeTo` the proxy.
    uint256 public constant maxBuyOnDeployBps = 1_000; // 10%

    /// @notice Total token supply minted per token. Mirrors `LivoToken.TOTAL_SUPPLY`; used to size
    ///         creator-vault allocations from their bps.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Max number of creator vaults a single token can have.
    uint256 public constant MAX_CREATOR_VAULTS = 5;

    /// @notice Creator-vault allocation granularity (5% in bps). Each vault must lock a multiple.
    uint256 public constant CREATOR_VAULT_BPS_STEP = 500;

    /// @notice Max total supply lockable across all creator vaults (30% in bps).
    uint256 public constant MAX_CREATOR_VAULT_TOTAL_BPS = 3_000;

    /// @notice Sets up the factory's immutables on the implementation. The implementation itself is
    ///         not meant to be used directly — `_disableInitializers()` locks its proxy storage so
    ///         only proxies pointing to this implementation can be initialized.
    /// @dev    Immutables are read from the implementation's bytecode through delegatecall, so they
    ///         work transparently behind the UUPS proxy. To change any of them, deploy a new impl
    ///         with different constructor args and call `upgradeTo` on the proxy.
    /// @param creatorVaultFactory Factory that deploys creator-vault clones
    /// @param vaultBondingCurves The six allocation-specific bonding curves, ordered
    ///        [5%, 10%, 15%, 20%, 25%, 30%]
    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory,
        address[6] memory vaultBondingCurves
    ) {
        LAUNCHPAD = ILivoLaunchpad(launchpad);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        MASTER_FEE_HANDLER = ILivoMasterFeeHandler(masterFeeHandler);
        TOKEN_IMPL_BASE = tokenImplBase;
        TOKEN_IMPL_ANTISNIPER = tokenImplAntiSniper;
        TOKEN_IMPL_TAX = tokenImplTax;
        TOKEN_IMPL_TAX_ANTISNIPER = tokenImplTaxAntiSniper;
        CREATOR_VAULT_FACTORY = ILivoCreatorVaultFactory(creatorVaultFactory);
        VAULT_CURVE_5 = ILivoBondingCurve(vaultBondingCurves[0]);
        VAULT_CURVE_10 = ILivoBondingCurve(vaultBondingCurves[1]);
        VAULT_CURVE_15 = ILivoBondingCurve(vaultBondingCurves[2]);
        VAULT_CURVE_20 = ILivoBondingCurve(vaultBondingCurves[3]);
        VAULT_CURVE_25 = ILivoBondingCurve(vaultBondingCurves[4]);
        VAULT_CURVE_30 = ILivoBondingCurve(vaultBondingCurves[5]);
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev    Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor
    ///         init-data) so no one else can front-run ownership.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS upgrade gate: only the owner can swap the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Quotes the ETH (msg.value) needed to receive ~`tokenAmount` tokens via the deployer
    ///         buy on a NON-vault token, priced against the base `BONDING_CURVE`.
    /// @param tokenAmount Amount of tokens to receive
    /// @return totalEthNeeded The msg.value to pass to createToken
    /// @dev Doesn't account for the `maxBuyOnDeployBps` cap — the caller must keep `tokenAmount`
    ///      under it.
    /// @dev IMPORTANT: this single-arg form prices ONLY the base curve. For a creator-vault token,
    ///      which is sold on a steeper-starting (allocation-specific) curve, use the two-arg overload
    ///      that takes `totalLockedInVaultsBps` — otherwise the quote under-estimates the ETH and the deployer
    ///      would receive fewer tokens than expected for the msg.value sent.
    function quoteBuyOnDeploy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded) {
        return _quoteBuyOnDeploy(tokenAmount, BONDING_CURVE);
    }

    /// @notice Quotes the ETH (msg.value) needed to receive ~`tokenAmount` tokens via the deployer
    ///         buy, priced against the curve that `totalLockedInVaultsBps` of locked supply selects in
    ///         `createToken`. Pass the SUM of `supplyBps` across the vaults you will deploy with (0
    ///         for a non-vault token); the quote then matches the curve the launchpad actually uses,
    ///         so the deployer is not mis-quoted. Only the aggregate matters — the curve is keyed off
    ///         it, not the individual vault owners/vesting — so those need not be finalized to quote.
    /// @param tokenAmount Amount of tokens to receive
    /// @param totalLockedInVaultsBps Sum of `supplyBps` across the creator vaults; must be 0 or a
    ///        multiple of `CREATOR_VAULT_BPS_STEP` (500) up to `MAX_CREATOR_VAULT_TOTAL_BPS` (3000) —
    ///        the same aggregate `_validateCreatorVaults` enforces for the array passed to `createToken`.
    /// @return totalEthNeeded The msg.value to pass to createToken
    /// @dev Doesn't account for the `maxBuyOnDeployBps` cap — the caller must keep `tokenAmount` under
    ///      it. Reverts (`InvalidCreatorVault`) on a `totalLockedInVaultsBps` no vault array could sum to.
    function quoteBuyOnDeploy(uint256 tokenAmount, uint256 totalLockedInVaultsBps)
        external
        view
        returns (uint256 totalEthNeeded)
    {
        require(
            totalLockedInVaultsBps <= MAX_CREATOR_VAULT_TOTAL_BPS
                && totalLockedInVaultsBps % CREATOR_VAULT_BPS_STEP == 0,
            InvalidCreatorVault()
        );
        // TODO this function needs to know the LPfees and taxes for correct quoting... this needs a fix
        return _quoteBuyOnDeploy(tokenAmount, _resolveBondingCurve(totalLockedInVaultsBps));
    }

    /// @dev Shared body: ETH (incl. inverse buy fee) to buy `tokenAmount` from a fresh curve.
    function _quoteBuyOnDeploy(uint256 tokenAmount, ILivoBondingCurve curve)
        internal
        view
        returns (uint256 totalEthNeeded)
    {
        (uint256 ethForReserves,) = curve.buyExactTokens(0, tokenAmount);

        // TODO(launchpad-fees step): use the createToken-provided buy fee. For now this matches the
        // V1-equivalent default the factory configures on every token in `_cloneAndCreateToken` (100 bps).
        uint256 denom = BASIS_POINTS - 100;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev Validates a FeeShare array: non-empty, no zero accounts, no duplicates, every share > 0,
    ///      sum == 10 000, and at most one entry has `directFeesEnabled = true`. The factory caps
    ///      direct receivers at 1 here as a user-surface constraint
    function _validateFeeShares(FeeShare[] memory feeReceivers) internal pure {
        uint256 len = feeReceivers.length;
        require(len > 0, InvalidFeeReceiver());

        uint256 total;
        uint256 directCount;
        for (uint256 i = 0; i < len;) {
            require(feeReceivers[i].account != address(0), InvalidFeeReceiver());
            require(feeReceivers[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len;) {
                require(feeReceivers[i].account != feeReceivers[j].account, InvalidFeeReceiver());
                unchecked {
                    ++j;
                }
            }
            total += feeReceivers[i].shares;
            if (feeReceivers[i].directFeesEnabled) {
                directCount++;
            }
            unchecked {
                ++i;
            }
        }
        require(total == BASIS_POINTS, InvalidShares());
        require(directCount <= 1, MultipleDirectFeeReceivers());
    }

    /// @dev Validates a SupplyShare array: non-empty, no zero accounts, no duplicates, every share > 0, sum == 10 000.
    function _validateSupplyShares(SupplyShare[] calldata supplyShares) internal pure {
        uint256 len = supplyShares.length;
        require(len > 0, InvalidSupplyShares());

        uint256 total;
        for (uint256 i = 0; i < len;) {
            require(supplyShares[i].account != address(0), InvalidSupplyShares());
            require(supplyShares[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len;) {
                require(supplyShares[i].account != supplyShares[j].account, InvalidSupplyShares());
                unchecked {
                    ++j;
                }
            }
            total += supplyShares[i].shares;
            unchecked {
                ++i;
            }
        }
        require(total == BASIS_POINTS, InvalidShares());
    }

    /// @dev Buys supply with `msg.value` and distributes it to `supplyShares` proportionally.
    ///      The cap is enforced on the aggregate `tokensBought`, not per recipient. Rounding dust
    ///      goes to the last recipient so no tokens remain in the factory.
    /// @dev deployer-buy receivers bypass the sniper-protection features
    function _buyAndDistribute(address token, SupplyShare[] calldata supplyShares) internal {
        uint256 tokensBought = LAUNCHPAD.buyTokensWithExactEth{value: msg.value}(token, 0, block.timestamp);

        // Floor division absorbs sub-token rounding from the bonding curve's ceiling math
        require(
            tokensBought * BASIS_POINTS / ILivoToken(token).totalSupply() <= maxBuyOnDeployBps, InvalidBuyOnDeploy()
        );

        uint256 len = supplyShares.length;
        address[] memory recipients = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        uint256 lastIdx = len - 1;
        uint256 distributed;
        for (uint256 i = 0; i < lastIdx;) {
            uint256 amount = tokensBought * supplyShares[i].shares / BASIS_POINTS;
            recipients[i] = supplyShares[i].account;
            amounts[i] = amount;
            distributed += amount;
            IERC20(token).safeTransfer(supplyShares[i].account, amount);
            unchecked {
                ++i;
            }
        }
        // last recipient absorbs rounding dust
        uint256 lastAmount = tokensBought - distributed;
        recipients[lastIdx] = supplyShares[lastIdx].account;
        amounts[lastIdx] = lastAmount;
        IERC20(token).safeTransfer(supplyShares[lastIdx].account, lastAmount);

        emit BuyOnDeploy(token, msg.sender, msg.value, tokensBought, recipients, amounts);
    }

    /// @dev Shared preamble for every factory's `createToken`: validates name/symbol and the fee
    ///      and supply share arrays. Single source of truth so both factories' `createToken`
    ///      have all input validation co-located at the top.
    function _validateInputs(
        string memory name,
        string memory symbol,
        FeeShare[] memory feeReceivers,
        SupplyShare[] calldata supplyShares
    ) internal {
        _validateNameSymbol(name, symbol);
        _validateFeeShares(feeReceivers);
        if (msg.value > 0) _validateSupplyShares(supplyShares);
        else require(supplyShares.length == 0, InvalidSupplyShares());
    }

    /// @dev Enforces anti-sniper sentinel consistency. A zero window disables anti-sniper dispatch,
    ///      so all other anti-sniper inputs must also be empty/zero.
    function _validateAntiSniperConfig(AntiSniperConfigs calldata cfg) internal pure {
        if (cfg.protectionWindowSeconds == 0) {
            require(
                cfg.maxBuyPerTxBps == 0 && cfg.maxWalletBps == 0 && cfg.whitelist.length == 0, InvalidAntiSniperConfig()
            );
        }
    }

    /// @dev Shared postamble: asks the token to self-register its fee config with the master
    ///      handler, then performs the deployer buy (if any). Event order: `SharesUpdated` fires
    ///      strictly after `TokenLaunched`, and the deployer buy events fire last.
    function _finalizeCreation(address token, FeeShare[] memory feeReceivers, SupplyShare[] calldata supplyShares)
        internal
    {
        ILivoToken(token).registerFees(feeReceivers);
        if (msg.value > 0) _buyAndDistribute(token, supplyShares);
    }

    /// @dev Single shared `createToken` body called by both `createToken` overloads on each unified
    ///      factory (legacy positional + new struct-based). Centralises validation → dispatch →
    ///      launch → finalize so both signatures emit the exact same events in the same order.
    ///      Takes structs (not flat args) so future fields can be added to `TokenSetup`/configs
    ///      without growing this function's stack frame. Callers derive `tokenOwner` per their
    ///      venue policy (V2: always `address(0)`; V4: `msg.sender` unless renounced).
    ///
    ///      `graduator` is passed in by the caller (instead of read from the `GRADUATOR` immutable)
    ///      so V4 can pick between multiple graduators per call based on `UniV4Configs.lpFeeBps`
    ///      (one graduator per hardcoded LP-fee hook variant). V2 has a single graduator and
    ///      always passes `address(GRADUATOR)`.
    /// @dev `tokenSetup` is `memory` so the legacy positional overload — whose ABI takes flat
    ///      calldata args — can build a `TokenSetup` in memory and call this same umbrella. The
    ///      string/`FeeShare[]` propagation forces `_validateInputs`/`_validateNameSymbol`/
    ///      `_validateFeeShares`/`_dispatchAndInitialize`/`_cloneAndCreateToken`/`_finalizeCreation`
    ///      to accept `memory` for those fields too. Once the legacy overload is removed, switch
    ///      `tokenSetup` (and the cascaded fields) back to `calldata` to skip the one-time copy
    ///      (~100–250 gas/deploy).
    function _createToken(
        TokenSetup memory tokenSetup,
        address tokenOwner,
        address graduator,
        SupplyShare[] calldata buyOnDeployShares,
        TaxConfigInit calldata taxConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] memory creatorVaults
    ) internal returns (address token) {
        _validateInputs(tokenSetup.name, tokenSetup.symbol, tokenSetup.feeShares, buyOnDeployShares);
        _validateAntiSniperConfig(antiSniperConfigs);
        _validateTaxConfig(taxConfigs);

        // Creator vaults: validate and pick the allocation-specific bonding curve. `vaultAllocation`
        // is minted to this factory by the token initializer; everything else (`TOTAL_SUPPLY -
        // vaultAllocation`) is minted to the launchpad and sold on the resolved curve.
        (uint256 totalLockedInVaultsBps, uint256 vaultAllocation) = _validateCreatorVaults(creatorVaults);
        ILivoBondingCurve bondingCurve = _resolveBondingCurve(totalLockedInVaultsBps);

        token = _dispatchAndInitialize(
            tokenSetup.name,
            tokenSetup.symbol,
            tokenSetup.salt,
            tokenOwner,
            graduator,
            vaultAllocation,
            taxConfigs,
            antiSniperConfigs
        );

        LAUNCHPAD.launchToken(token, bondingCurve);

        // Deploy + fund the vaults BEFORE the deployer buy so the factory ends the tx holding no
        // tokens. The factory→vault transfers are exempt from sniper caps (`from == tokenFactory`).
        if (vaultAllocation > 0) _deployAndFundVaults(token, creatorVaults, vaultAllocation);

        // buy-on-deploy executes after the vaults are deployed and funded
        _finalizeCreation(token, tokenSetup.feeShares, buyOnDeployShares);
    }

    /// @dev Validates the creator-vault array and returns the aggregate allocation.
    ///      Rules: at most `MAX_CREATOR_VAULTS` vaults; each `owner != 0`; each `supplyBps` a
    ///      non-zero multiple of `CREATOR_VAULT_BPS_STEP` (5%); the SUM `<= MAX_CREATOR_VAULT_TOTAL_BPS`
    ///      (30%). An empty array means no vaults (returns 0, 0). Cliff/vesting durations are
    ///      unconstrained here — any value is harmless and only affects the vault's own owner.
    function _validateCreatorVaults(CreatorVault[] memory creatorVaults)
        internal
        pure
        returns (uint256 totalBps, uint256 vaultAllocation)
    {
        uint256 len = creatorVaults.length;
        // exit with no-op
        if (len == 0) return (0, 0);

        require(len <= MAX_CREATOR_VAULTS, TooManyCreatorVaults());

        for (uint256 i = 0; i < len;) {
            CreatorVault memory v = creatorVaults[i];
            require(v.owner != address(0), InvalidCreatorVault());
            require(v.supplyBps != 0 && v.supplyBps % CREATOR_VAULT_BPS_STEP == 0, InvalidCreatorVault());
            totalBps += v.supplyBps;
            unchecked {
                ++i;
            }
        }

        require(totalBps <= MAX_CREATOR_VAULT_TOTAL_BPS, CreatorVaultAllocationTooHigh());
        vaultAllocation = TOTAL_SUPPLY * totalBps / BASIS_POINTS;
    }

    /// @dev Maps a total locked allocation (in bps) to the matching bonding curve. `totalBps == 0`
    ///      uses the base curve; otherwise it is guaranteed by `_validateCreatorVaults` to be a
    ///      multiple of 500 in [500, 3000]. The final `== 3000` check and `else` revert make this a
    ///      total function rather than relying on that upstream invariant, so any unexpected value
    ///      fails loudly instead of silently defaulting to `VAULT_CURVE_30`.
    function _resolveBondingCurve(uint256 totalBps) internal view returns (ILivoBondingCurve) {
        if (totalBps == 0) return BONDING_CURVE;
        if (totalBps == 500) return VAULT_CURVE_5;
        if (totalBps == 1000) return VAULT_CURVE_10;
        if (totalBps == 1500) return VAULT_CURVE_15;
        if (totalBps == 2000) return VAULT_CURVE_20;
        if (totalBps == 2500) return VAULT_CURVE_25;
        if (totalBps == 3000) return VAULT_CURVE_30;
        revert InvalidCreatorVault();
    }

    /// @dev Deploys one `LivoCreatorVault` per entry via the vault factory and funds each with its
    ///      token allocation from the supply minted to this factory during token init. Asserts the
    ///      factory ends with zero token balance, i.e. the per-vault amounts summed to exactly
    ///      `vaultAllocation` (they do by construction; the check guards against future drift).
    function _deployAndFundVaults(address token, CreatorVault[] memory creatorVaults, uint256 vaultAllocation)
        internal
    {
        uint256 len = creatorVaults.length;
        address[] memory vaults = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            CreatorVault memory v = creatorVaults[i];
            uint256 amount = TOTAL_SUPPLY * v.supplyBps / BASIS_POINTS;
            address vault = CREATOR_VAULT_FACTORY.createVault(token, v.owner, amount, v.cliffSeconds, v.vestingSeconds);
            IERC20(token).safeTransfer(vault, amount);
            vaults[i] = vault;
            amounts[i] = amount;
            unchecked {
                ++i;
            }
        }

        require(IERC20(token).balanceOf(address(this)) == 0, CreatorVaultDistributionFailed());
        emit CreatorVaultsCreated(token, vaultAllocation, vaults, amounts);
    }

    /// @dev Shared name/symbol validation. Single source of truth — called once from `_validateInputs`
    ///      for both V2 and V4 factories.
    function _validateNameSymbol(string memory name, string memory symbol) internal pure {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 96, InvalidNameOrSymbol());
    }

    /// @notice Pre-graduation LP/trading fee (bps) the launchpad charges on bonding-curve trades for a
    ///         token whose post-graduation venue is `graduator`. For V4 this equals the selected hook's
    ///         LP fee, so the rate is identical before and after graduation; V2 has no post-graduation
    ///         LP fee and returns a fixed pre-graduation rate. Split between treasury and creator by
    ///         `_launchpadTreasuryShareBps`.
    /// @dev Inverse of the concrete factory's graduator selection — keep in sync with `_resolveGraduator`.
    function _launchpadLpFeeBps(address graduator) internal view virtual returns (uint16);

    /// @notice Share of the pre-graduation LP fee routed to the treasury (bps); the remainder goes to
    ///         the creator. Venue-specific protocol policy fixed at the factory level, not deployer-set.
    function _launchpadTreasuryShareBps() internal pure virtual returns (uint16);

    /// @dev Clones the resolved token implementation deterministically, enforces the `0x1110` vanity
    ///      suffix, emits `TokenCreated`, and returns the freshly-deployed token plus a fully-populated
    ///      `InitializeParams` for the caller to pass to the impl-specific `initialize()` overload.
    ///      `TokenCreated` is emitted BEFORE `initialize()` because the indexer creates the TokenData
    ///      entity from that event; events emitted inside `initialize()` depend on it.
    function _cloneAndCreateToken(
        address impl,
        string memory name,
        string memory symbol,
        bytes32 salt,
        address tokenOwner,
        address graduator,
        uint256 vaultAllocation,
        TaxConfigInit calldata taxCfg
    ) internal returns (address token, ILivoToken.InitializeParams memory params) {
        token = Clones.cloneDeterministic(impl, salt);
        // forge-lint: disable-next-line(unsafe-typecast)
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());

        emit TokenCreated(token, name, symbol, tokenOwner, address(LAUNCHPAD), graduator, address(MASTER_FEE_HANDLER));

        params = ILivoToken.InitializeParams({
            name: name,
            symbol: symbol,
            tokenOwner: tokenOwner,
            graduator: graduator,
            launchpad: address(LAUNCHPAD),
            feeHandler: address(MASTER_FEE_HANDLER),
            vaultAllocation: vaultAllocation,
            // Pre-graduation fee policy carried by the token and read by the launchpad each trade. The
            // LP fee equals the token's post-graduation LP fee (V4: the selected hook fee; V2: a fixed
            // pre-graduation rate, as V2 has no post-graduation LP fee). The treasury/creator split is
            // venue-specific protocol policy. The creator tax mirrors the configured `TaxConfigInit` so
            // it applies identically pre- and post-graduation (0 for non-tax tokens, where taxCfg is empty).
            lpFeeBps: _launchpadLpFeeBps(graduator),
            treasuryShareBps: _launchpadTreasuryShareBps(),
            taxBuyBps: taxCfg.buyTaxBps,
            taxSellBps: taxCfg.sellTaxBps
        });
    }

    /// @dev Validates a tax config: enforces sentinel consistency (zero duration ⇒ zero bps) and
    ///      caps `taxDurationSeconds` at `MAX_TAX_DURATION_SECONDS` (120 years — an overflow-prevention
    ///      bound driven by `uint32` packing on `TaxConfigInit.taxDurationSeconds`). The tax-bps
    ///      ceiling is venue-dependent and enforced separately by `_validateTotalFee`. No fee-receiver
    ///      or ownership constraints are imposed at any duration.
    function _validateTaxConfig(TaxConfigInit calldata t) internal pure {
        if (_isTaxConfigured(t)) {
            require(t.buyTaxBps > 0 || t.sellTaxBps > 0, InvalidTaxConfig());
            require(t.taxDurationSeconds <= MAX_TAX_DURATION_SECONDS, InvalidTaxDuration());
        } else {
            require(t.buyTaxBps == 0 && t.sellTaxBps == 0, InvalidTaxConfig());
        }
    }

    /// @dev Caps the POST-graduation total fee a swapper pays (LP fee + tax) at `MAX_TOTAL_FEE_BPS`
    ///      (5%). Applied to buy and sell tax independently since a swap only ever pays one direction.
    ///      `lpFeeBps` is the venue's post-graduation LP fee — 0 for V2 (no LP fee, so tax can reach the
    ///      full 5%), 50 or 100 for V4 (leaving 450/400 bps for tax). Pre-graduation the launchpad
    ///      additionally charges its own LP fee on top of the tax; that transient total is bounded by
    ///      the launchpad's (looser) `MAX_TRADING_FEE_BPS`, not here. `taxCfg` bps are unbounded here, so
    ///      the sum is widened to `uint256` to avoid a spurious overflow revert before this check fires.
    function _validateTotalFee(uint256 lpFeeBps, TaxConfigInit calldata taxCfg) internal pure {
        require(
            lpFeeBps + taxCfg.buyTaxBps <= MAX_TOTAL_FEE_BPS && lpFeeBps + taxCfg.sellTaxBps <= MAX_TOTAL_FEE_BPS,
            InvalidTaxBps()
        );
    }

    function _isTaxConfigured(TaxConfigInit calldata t) internal pure returns (bool) {
        return t.taxDurationSeconds != 0;
    }

    function _isAntiSniperConfigured(AntiSniperConfigs calldata a) internal pure returns (bool) {
        return a.protectionWindowSeconds != 0;
    }

    /// @dev Single source of truth for which implementation `createToken` will clone for a given
    ///      `(taxCfg, antiSniperCfg)` pair. Both the public `previewTokenImplementation` (used by
    ///      frontends to mine a `0x1110`-suffixed salt) and `_dispatchAndInitialize` (the path
    ///      that actually clones the impl) read from this function — so a salt that previews to
    ///      a vanity-suffixed address is guaranteed to also produce one at create time.
    function _previewTokenImplementation(TaxConfigInit calldata taxCfg, AntiSniperConfigs calldata antiSniperCfg)
        internal
        view
        returns (address)
    {
        bool hasTax = _isTaxConfigured(taxCfg);
        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        if (hasTax) {
            return hasAntiSniper ? TOKEN_IMPL_TAX_ANTISNIPER : TOKEN_IMPL_TAX;
        }
        return hasAntiSniper ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;
    }

    /// @dev Resolves the implementation for the `(taxCfg, antiSniperCfg)` pair, clones it, and runs
    ///      the matching `initialize` overload. The four combinations dispatch across two interface
    ///      families: the tax family through the venue-agnostic `ILivoTaxableToken[SniperProtected]`
    ///      interfaces, the non-tax family through `LivoToken` / `LivoTokenSniperProtected` directly.
    ///      Impl resolution shares `_previewTokenImplementation` with the public preview, so a salt
    ///      that previews to a `0x1110` address also clones to one. Callers (`createToken` on the
    ///      derived factory) invoke `LAUNCHPAD.launchToken` and `_finalizeCreation` (which registers
    ///      the token's fee config with the master handler) after this returns.
    function _dispatchAndInitialize(
        string memory name,
        string memory symbol,
        bytes32 salt,
        address tokenOwner,
        address graduator,
        uint256 vaultAllocation,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        address impl = _previewTokenImplementation(taxCfg, antiSniperCfg);

        ILivoToken.InitializeParams memory params;
        (token, params) = _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner, graduator, vaultAllocation, taxCfg);

        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        if (_isTaxConfigured(taxCfg)) {
            // taxCfg is non-empty; the token's pre-graduation tax fields are set from it in `_cloneAndCreateToken`.
            if (hasAntiSniper) {
                ILivoTaxableTokenSniperProtected(payable(token)).initialize(params, taxCfg, antiSniperCfg);
            } else {
                ILivoTaxableToken(payable(token)).initialize(params, taxCfg);
            }
        } else {
            // non-tax path: taxCfg is empty (validated), so the pre-graduation tax fields resolve to 0.
            if (hasAntiSniper) {
                LivoTokenSniperProtected(token).initialize(params, antiSniperCfg);
            } else {
                LivoToken(token).initialize(params);
            }
        }
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades. Never reorder existing storage.
    uint256[50] private __gap;
}
