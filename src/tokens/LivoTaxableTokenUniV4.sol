// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// this line below can be adjusted to import the Sepolia addresses when deploying in sepolia
import {DeploymentAddressesMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title LivoTaxableTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks
/// @dev Extends `LivoTaxableToken` to add the V4 pool-manager pair check. All tax accounting
///      lives outside the token itself, in `LivoSwapHook`; the token simply exposes the tax config
///      via `getTaxConfig()`.
contract LivoTaxableTokenUniV4 is LivoTaxableToken {
    ///////////////////////////////// uniswap v4 related /////////////////////////////////////////
    // NB : THESE ARE HARDCODED FOR MAINNET TO SAVE GAS

    /// @notice Pool manager for lock state checking
    address public constant UNIV4_POOL_MANAGER = DeploymentAddresses.UNIV4_POOL_MANAGER;

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxableTokenUniV4 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        // Constructor body intentionally left empty
        // All initialization happens in initialize() due to minimal proxy pattern
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
    }

    /// @notice Initializes the token clone with its parameters including tax configuration
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps and post-graduation tax duration)
    function initialize(ILivoToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        external
        virtual
        initializer
    {
        _initializeLivoTaxableToken(params, taxCfg);
    }

    /// @notice Initializes the token clone with tax config AND anti-sniper protection.
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps, window, optional launch-tax decay)
    /// @param antiSniperCfg Anti-sniper caps + window config (validated upstream in the factory)
    function initialize(
        ILivoToken.InitializeParams memory params,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeLivoTaxableToken(params, taxCfg);
        _initializeSniperProtectionGated(antiSniperCfg);
    }

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
}
