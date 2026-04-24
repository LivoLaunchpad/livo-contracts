// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Factory for deploying sniper-protected taxable Livo tokens with Uniswap V4 hook
///         integration and dev-configurable anti-sniper settings.
contract LivoFactoryTaxTokenSniperProtected is LivoFactoryAbstract {
    error InvalidTaxBps();
    error InvalidTaxDuration();

    struct TaxCfg {
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint32 taxDurationSeconds;
    }

    /// @notice max configurable tax (buy or sell)
    uint256 public constant MAX_TAX_BPS = 400;

    /// @notice max configurable sell tax duration
    uint256 public constant MAX_SELL_TAX_DURATION_SECONDS = 14 days;

    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler,
        address feeSplitterImplementation
    )
        LivoFactoryAbstract(
            launchpad, tokenImplementation, bondingCurve, graduator, feeHandler, feeSplitterImplementation
        )
    {}

    //////////////////////// EXTERNAL FUNCTIONS ////////////////////////

    /// @notice Deploys a new sniper-protected taxable token clone with sell tax configuration.
    ///         If `feeReceivers.length >= 2`, also deploys a `FeeSplitter` as the fee receiver.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        TaxCfg calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token, address feeSplitter) {
        _validateNameSymbol(name, symbol);
        _validateTaxCfg(taxCfg);

        FeeRouting memory routing = _validateInputsAndResolveFees(feeReceivers, supplyShares, salt);

        token = _deployClone(salt);

        emit TokenCreated(
            token,
            name,
            symbol,
            msg.sender,
            address(LAUNCHPAD),
            address(GRADUATOR),
            routing.feeHandler,
            routing.feeReceiver
        );

        _initTaxToken(token, name, symbol, routing.feeHandler, routing.feeReceiver, taxCfg, antiSniperCfg);

        LAUNCHPAD.launchToken(token, BONDING_CURVE);

        _finalizeCreateToken(token, routing.feeSplitter, feeReceivers, supplyShares);
        feeSplitter = routing.feeSplitter;
    }

    /////////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _validateTaxCfg(TaxCfg calldata taxCfg) internal pure {
        require(taxCfg.buyTaxBps <= MAX_TAX_BPS && taxCfg.sellTaxBps <= MAX_TAX_BPS, InvalidTaxBps());
        require(taxCfg.taxDurationSeconds <= MAX_SELL_TAX_DURATION_SECONDS, InvalidTaxDuration());
    }

    function _deployClone(bytes32 salt) internal returns (address token) {
        token = Clones.cloneDeterministic(address(_tokenImplementation), salt);
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());
    }

    function _initTaxToken(
        address token,
        string calldata name,
        string calldata symbol,
        address feeHandler_,
        address feeReceiver,
        TaxCfg calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal {
        LivoTaxableTokenUniV4SniperProtected(payable(token))
            .initialize(
                ILivoToken.InitializeParams({
                    name: name,
                    symbol: symbol,
                    tokenOwner: msg.sender,
                    graduator: address(GRADUATOR),
                    launchpad: address(LAUNCHPAD),
                    feeHandler: feeHandler_,
                    feeReceiver: feeReceiver
                }),
                taxCfg.buyTaxBps,
                taxCfg.sellTaxBps,
                uint40(taxCfg.taxDurationSeconds),
                antiSniperCfg
            );
    }
}
