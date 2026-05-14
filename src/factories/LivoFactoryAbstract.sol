// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoTaxableToken, ILivoTaxableTokenSniperProtected, TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";

/// @notice Abstract base for Livo token factories. Holds shared state and helper logic.
/// @dev    UUPS-upgradeable. The implementation contract sets its immutables in the constructor
///         (baked into bytecode) and calls `_disableInitializers()` to prevent direct init.
///         Proxies must call `initialize()` exactly once to claim ownership. Upgrade authorisation
///         lives in `_authorizeUpgrade`.
abstract contract LivoFactoryAbstract is ILivoFactory, Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Max configurable tax duration for the default (non-charity) deploy path.
    uint256 public constant MAX_TAX_DURATION_SECONDS = 365 days;
    /// @notice Max configurable tax duration when the deploy opts into "charity mode": a
    ///         single fee receiver that is not the deployer and ownership renounced at
    ///         creation (`tokenOwner == address(0)`). Capped at 120 years; the upper bound is
    ///         driven by `TaxConfigInit.taxDurationSeconds`'s `uint32` packing.
    /// @dev    We do NOT verify on-chain that the fee receiver is a real charity — deployers
    ///         can fake this by passing any non-deployer address. The only invariants enforced
    ///         on chain are the single-non-deployer-receiver rule and the renounced-ownership
    ///         rule; off-chain UI / curation is responsible for the social trust layer.
    uint256 public constant MAX_CHARITY_TAX_DURATION_SECONDS = 120 * 365 days;

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

    /// @notice Max configurable tax (buy or sell). Per-venue value supplied by the derived factory
    ///         via `override`: V2 uses 5% (the swap-back path needs more headroom to amortise
    ///         per-sell router gas); V4 uses 4%.
    function MAX_TAX_BPS() public pure virtual returns (uint256);

    /// @notice Max percentage of total supply that can be purchased on token creation (applies to the
    ///         aggregate, not per recipient), in basis points. Fixed at 10%. To change this value,
    ///         deploy a new implementation with a different constant and `upgradeTo` the proxy.
    uint256 public constant maxBuyOnDeployBps = 1_000; // 10%

    /// @notice Sets up the factory's immutables on the implementation. The implementation itself is
    ///         not meant to be used directly — `_disableInitializers()` locks its proxy storage so
    ///         only proxies pointing to this implementation can be initialized.
    /// @dev    Immutables are read from the implementation's bytecode through delegatecall, so they
    ///         work transparently behind the UUPS proxy. To change any of them, deploy a new impl
    ///         with different constructor args and call `upgradeTo` on the proxy.
    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address masterFeeHandler
    ) {
        LAUNCHPAD = ILivoLaunchpad(launchpad);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        MASTER_FEE_HANDLER = ILivoMasterFeeHandler(masterFeeHandler);
        TOKEN_IMPL_BASE = tokenImplBase;
        TOKEN_IMPL_ANTISNIPER = tokenImplAntiSniper;
        TOKEN_IMPL_TAX = tokenImplTax;
        TOKEN_IMPL_TAX_ANTISNIPER = tokenImplTaxAntiSniper;
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev    Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor
    ///         init-data) so no one else can front-run ownership.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS upgrade gate: only the owner can swap the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Quotes the ETH needed (msg.value) to receive exactly `tokenAmount` tokens on a new token
    /// @param tokenAmount Amount of tokens to receive
    /// @return totalEthNeeded The msg.value to pass to createToken
    /// @dev this doesn't take into account the maxBuyOnDeployBps limit, so it is the responsibility of the caller to ensure the quoted amount doesn't exceed that limit
    function quoteBuyOnDeploy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded) {
        (uint256 ethForReserves,) = BONDING_CURVE.buyExactTokens(0, tokenAmount);

        uint16 buyFeeBps = LAUNCHPAD.baseBuyFeeBps();
        uint256 denom = BASIS_POINTS - buyFeeBps;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev Validates a FeeShare array: non-empty, no zero accounts, no duplicates, every share > 0,
    ///      sum == 10 000, and at most one entry has `directFeesEnabled = true`. The factory caps
    ///      direct receivers at 1 here as a user-surface constraint
    function _validateFeeShares(FeeShare[] calldata feeReceivers) internal pure {
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
        string calldata name,
        string calldata symbol,
        FeeShare[] calldata feeReceivers,
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
    function _finalizeCreation(address token, FeeShare[] calldata feeReceivers, SupplyShare[] calldata supplyShares)
        internal
    {
        ILivoToken(token).registerFees(feeReceivers);
        if (msg.value > 0) _buyAndDistribute(token, supplyShares);
    }

    /// @dev Shared name/symbol validation. Single source of truth — called once from `_validateInputs`
    ///      for both V2 and V4 factories.
    function _validateNameSymbol(string calldata name, string calldata symbol) internal pure {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());
    }

    /// @dev Clones the resolved token implementation deterministically, enforces the `0x1110` vanity
    ///      suffix, emits `TokenCreated`, and returns the freshly-deployed token plus a fully-populated
    ///      `InitializeParams` for the caller to pass to the impl-specific `initialize()` overload.
    ///      `TokenCreated` is emitted BEFORE `initialize()` because the indexer creates the TokenData
    ///      entity from that event; events emitted inside `initialize()` depend on it.
    function _cloneAndCreateToken(
        address impl,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner
    ) internal returns (address token, ILivoToken.InitializeParams memory params) {
        token = Clones.cloneDeterministic(impl, salt);
        // forge-lint: disable-next-line(unsafe-typecast)
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());

        emit TokenCreated(
            token, name, symbol, tokenOwner, address(LAUNCHPAD), address(GRADUATOR), address(MASTER_FEE_HANDLER)
        );

        params = ILivoToken.InitializeParams({
            name: name,
            symbol: symbol,
            tokenOwner: tokenOwner,
            graduator: address(GRADUATOR),
            launchpad: address(LAUNCHPAD),
            feeHandler: address(MASTER_FEE_HANDLER)
        });
    }

    /// @dev Validates a tax config: enforces sentinel consistency (zero duration ⇒ zero bps),
    ///      caps `buyTaxBps`/`sellTaxBps` at `MAX_TAX_BPS`, and caps `taxDurationSeconds` at
    ///      `MAX_CHARITY_TAX_DURATION_SECONDS`. A duration above the standard 365-day window
    ///      unlocks the "charity mode" path which requires:
    ///        (1) exactly one fee receiver, distinct from the deployer (`msg.sender`); and
    ///        (2) the deployed token to be ownerless (`tokenOwner == address(0)`).
    ///      The charity address is NOT verified on-chain — a deployer can pass any non-deployer
    ///      address (even one they control). Off-chain UI / curation is responsible for the
    ///      social trust signal. The on-chain rules only prevent the most trivial abuse: a lone
    ///      deployer keeping ownership and routing fees to themselves while extending the tax
    ///      window past one year.
    function _validateTaxConfig(TaxConfigInit calldata t, FeeShare[] calldata feeReceivers, address tokenOwner)
        internal
        view
    {
        if (_isTaxConfigured(t)) {
            require(t.buyTaxBps > 0 || t.sellTaxBps > 0, InvalidTaxConfig());
            uint256 maxTaxBps = MAX_TAX_BPS();
            require(t.buyTaxBps <= maxTaxBps && t.sellTaxBps <= maxTaxBps, InvalidTaxBps());
            require(t.taxDurationSeconds <= MAX_CHARITY_TAX_DURATION_SECONDS, InvalidTaxDuration());
            if (t.taxDurationSeconds > MAX_TAX_DURATION_SECONDS) {
                require(
                    feeReceivers.length == 1 && feeReceivers[0].account != msg.sender, CharityModeFeeReceiverInvalid()
                );
                require(tokenOwner == address(0), CharityModeOwnerNotRenounced());
            }
        } else {
            require(t.buyTaxBps == 0 && t.sellTaxBps == 0, InvalidTaxConfig());
        }
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

    /// @dev Resolves the implementation via `_previewTokenImplementation` and then routes to the
    ///      tax or non-tax sub-helper. Splitting by family keeps each sub-helper's stack frame
    ///      small enough to compile without `via_ir`. Callers (`createToken` on the derived
    ///      factory) are responsible for invoking `LAUNCHPAD.launchToken` and `_finalizeCreation`
    ///      (which registers the token's fee config with the master handler) after this returns.
    function _dispatchAndInitialize(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        address impl = _previewTokenImplementation(taxCfg, antiSniperCfg);
        if (_isTaxConfigured(taxCfg)) {
            token = _initializeTaxToken(impl, name, symbol, salt, tokenOwner, taxCfg, antiSniperCfg);
        } else {
            token = _initializeNonTaxToken(impl, name, symbol, salt, tokenOwner, antiSniperCfg);
        }
    }

    /// @dev Clones the resolved tax implementation (passed in by `_dispatchAndInitialize` so the
    ///      preview/create dispatch share a single source of truth) and dispatches into the 2-arg
    ///      or 3-arg `initialize` overload through the venue-agnostic
    ///      `ILivoTaxableToken[SniperProtected]` interfaces.
    function _initializeTaxToken(
        address impl,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        ILivoToken.InitializeParams memory params;
        (token, params) = _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner);

        if (_isAntiSniperConfigured(antiSniperCfg)) {
            ILivoTaxableTokenSniperProtected(payable(token)).initialize(params, taxCfg, antiSniperCfg);
        } else {
            ILivoTaxableToken(payable(token)).initialize(params, taxCfg);
        }
    }

    /// @dev Clones the resolved non-tax implementation (passed in by `_dispatchAndInitialize`) and
    ///      runs the appropriate `initialize` overload. Identical between V2 and V4 because both
    ///      venues share the same `LivoToken` / `LivoTokenSniperProtected` non-tax implementations.
    function _initializeNonTaxToken(
        address impl,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        ILivoToken.InitializeParams memory params;
        (token, params) = _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner);

        if (_isAntiSniperConfigured(antiSniperCfg)) {
            LivoTokenSniperProtected(token).initialize(params, antiSniperCfg);
        } else {
            LivoToken(token).initialize(params);
        }
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades. Never reorder existing storage.
    uint256[50] private __gap;
}
