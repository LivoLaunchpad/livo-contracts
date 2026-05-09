// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {IDeployersWhitelist} from "src/interfaces/IDeployersWhitelist.sol";
import {ILivoTaxableToken, ILivoTaxableTokenSniperProtected, TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";

/// @notice Abstract base for Livo token factories. Holds shared state and helper logic.
abstract contract LivoFactoryAbstract is ILivoFactory, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Max configurable tax duration without deployer-whitelist approval.
    uint256 public constant MAX_SELL_TAX_DURATION_SECONDS = 14 days;
    /// @notice Max configurable tax duration for whitelisted deployers.
    uint256 public constant MAX_EXTENDED_TAX_DURATION_SECONDS = 2 * 365 days;

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
    /// @notice Whitelist checked when a deployer configures tax duration above 14 days.
    IDeployersWhitelist public immutable DEPLOYERS_WHITELIST;

    /// @notice Max configurable tax (buy or sell). Per-venue value supplied by the derived factory
    ///         via `override`: V2 uses 5% (the swap-back path needs more headroom to amortise
    ///         per-sell router gas); V4 uses 4%.
    function MAX_TAX_BPS() public pure virtual returns (uint256);

    /// @notice Max percentage of total supply that can be purchased on token creation (applies to the aggregate, not per recipient), in basis points
    uint256 public maxBuyOnDeployBps = 1_000; // 10%

    /// @notice Initializes the factory with its immutable dependencies
    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address deployersWhitelist
    ) Ownable(msg.sender) {
        LAUNCHPAD = ILivoLaunchpad(launchpad);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        MASTER_FEE_HANDLER = ILivoMasterFeeHandler(masterFeeHandler);
        TOKEN_IMPL_BASE = tokenImplBase;
        TOKEN_IMPL_ANTISNIPER = tokenImplAntiSniper;
        TOKEN_IMPL_TAX = tokenImplTax;
        TOKEN_IMPL_TAX_ANTISNIPER = tokenImplTaxAntiSniper;
        DEPLOYERS_WHITELIST = IDeployersWhitelist(deployersWhitelist);
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Updates the max aggregate buy-on-deploy percentage
    /// @param newMaxBuyOnDeployBps New max in basis points (e.g. 1000 = 10%)
    /// @dev setting 0 here will make deployments revert, as msg.value > 0 is required to trigger the buy-on-deploy logic
    function setMaxBuyOnDeployBps(uint256 newMaxBuyOnDeployBps) external onlyOwner {
        require(newMaxBuyOnDeployBps < BASIS_POINTS, InvalidMaxBuyOnDeployBps());
        maxBuyOnDeployBps = newMaxBuyOnDeployBps;
        emit MaxBuyOnDeployBpsUpdated(newMaxBuyOnDeployBps);
    }

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
        for (uint256 i = 0; i < len; i++) {
            require(feeReceivers[i].account != address(0), InvalidFeeReceiver());
            require(feeReceivers[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len; j++) {
                require(feeReceivers[i].account != feeReceivers[j].account, InvalidFeeReceiver());
            }
            total += feeReceivers[i].shares;
            if (feeReceivers[i].directFeesEnabled) {
                directCount++;
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
        for (uint256 i = 0; i < len; i++) {
            require(supplyShares[i].account != address(0), InvalidSupplyShares());
            require(supplyShares[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len; j++) {
                require(supplyShares[i].account != supplyShares[j].account, InvalidSupplyShares());
            }
            total += supplyShares[i].shares;
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

        uint256 distributed;
        for (uint256 i = 0; i < len - 1; i++) {
            uint256 amount = tokensBought * supplyShares[i].shares / BASIS_POINTS;
            recipients[i] = supplyShares[i].account;
            amounts[i] = amount;
            distributed += amount;
            IERC20(token).safeTransfer(supplyShares[i].account, amount);
        }
        // last recipient absorbs rounding dust
        uint256 lastAmount = tokensBought - distributed;
        recipients[len - 1] = supplyShares[len - 1].account;
        amounts[len - 1] = lastAmount;
        IERC20(token).safeTransfer(supplyShares[len - 1].account, lastAmount);

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
    ///      caps `buyTaxBps`/`sellTaxBps` at `MAX_TAX_BPS`, caps `taxDurationSeconds` at the
    ///      extended ceiling, and requires whitelist approval to exceed the standard 14-day window.
    function _validateTaxConfig(TaxConfigInit calldata t) internal view {
        if (_isTaxConfigured(t)) {
            require(t.buyTaxBps > 0 || t.sellTaxBps > 0, InvalidTaxConfig());
            require(t.buyTaxBps <= MAX_TAX_BPS() && t.sellTaxBps <= MAX_TAX_BPS(), InvalidTaxBps());
            require(t.taxDurationSeconds <= MAX_EXTENDED_TAX_DURATION_SECONDS, InvalidTaxDuration());
            if (t.taxDurationSeconds > MAX_SELL_TAX_DURATION_SECONDS) {
                require(DEPLOYERS_WHITELIST.isWhitelisted(msg.sender), DeployerNotWhitelisted());
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

    /// @dev Picks the implementation address for the (tax, anti-sniper) pair. Mirrors the dispatch
    ///      table used by `_dispatchAndInitialize` so `previewTokenImplementation` returns the same
    ///      address that `createToken` would clone for identical inputs.
    function _resolveImpl(bool hasTax, bool hasAntiSniper) internal view returns (address) {
        if (hasTax) {
            return hasAntiSniper ? TOKEN_IMPL_TAX_ANTISNIPER : TOKEN_IMPL_TAX;
        }
        return hasAntiSniper ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;
    }

    /// @dev Routes to the tax or non-tax sub-helper based on `taxCfg`. Splitting by family keeps
    ///      each sub-helper's stack frame small enough to compile without `via_ir`. Callers
    ///      (`createToken` on the derived factory) are responsible for invoking
    ///      `LAUNCHPAD.launchToken` and `_finalizeCreation` (which registers the token's fee config
    ///      with the master handler) after this returns.
    function _dispatchAndInitialize(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        if (_isTaxConfigured(taxCfg)) {
            token = _initializeTaxToken(name, symbol, salt, tokenOwner, taxCfg, antiSniperCfg);
        } else {
            token = _initializeNonTaxToken(name, symbol, salt, tokenOwner, antiSniperCfg);
        }
    }

    /// @dev Clones the appropriate tax implementation and dispatches into the 2-arg or 3-arg
    ///      `initialize` overload through the venue-agnostic `ILivoTaxableToken[SniperProtected]`
    ///      interfaces. The same body works for both V2 and V4 factories because the signatures
    ///      are byte-identical on `LivoTaxableTokenUniV{2,4}` and their sniper-protected variants.
    function _initializeTaxToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        address impl = hasAntiSniper ? TOKEN_IMPL_TAX_ANTISNIPER : TOKEN_IMPL_TAX;

        ILivoToken.InitializeParams memory params;
        (token, params) = _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner);

        if (hasAntiSniper) {
            ILivoTaxableTokenSniperProtected(payable(token)).initialize(params, taxCfg, antiSniperCfg);
        } else {
            ILivoTaxableToken(payable(token)).initialize(params, taxCfg);
        }
    }

    /// @dev Clones the non-tax implementation (base or anti-sniper) and runs the appropriate
    ///      `initialize` overload. Identical between V2 and V4 because both venues share the
    ///      same `LivoToken` / `LivoTokenSniperProtected` non-tax implementations.
    function _initializeNonTaxToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address tokenOwner,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool hasAntiSniper = _isAntiSniperConfigured(antiSniperCfg);
        address impl = hasAntiSniper ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;

        ILivoToken.InitializeParams memory params;
        (token, params) = _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner);

        if (hasAntiSniper) {
            LivoTokenSniperProtected(token).initialize(params, antiSniperCfg);
        } else {
            LivoToken(token).initialize(params);
        }
    }
}
