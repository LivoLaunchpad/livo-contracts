// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Factory for deploying taxable Livo tokens with Uniswap V4 hook integration
contract LivoFactoryTaxToken is LivoFactoryAbstract {
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

    /// @notice Deploys a new taxable token clone with sell tax configuration.
    ///         If `feeReceivers.length >= 2`, also deploys a `FeeSplitter` as the fee receiver.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        TaxCfg calldata taxCfg
    ) external payable returns (address token, address feeSplitter) {
        _validateFeeShares(feeReceivers);
        if (msg.value > 0) _validateSupplyShares(supplyShares);
        else require(supplyShares.length == 0, InvalidSupplyShares());

        if (feeReceivers.length == 1) {
            token = _createAndInitializeTaxToken(
                name, symbol, address(FEE_HANDLER), feeReceivers[0].account, salt, taxCfg
            );
        } else {
            feeSplitter = _deployFeeSplitter(salt);
            token = _createAndInitializeTaxToken(name, symbol, feeSplitter, feeSplitter, salt, taxCfg);
            _initFeeSplitter(feeSplitter, token, feeReceivers);
        }

        if (msg.value > 0) _buyAndDistribute(token, supplyShares);
    }

    /////////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _createAndInitializeTaxToken(
        string calldata name,
        string calldata symbol,
        address feeHandler_,
        address feeReceiver,
        bytes32 salt,
        TaxCfg calldata taxCfg
    ) internal returns (address token) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());

        require(taxCfg.buyTaxBps <= MAX_TAX_BPS && taxCfg.sellTaxBps <= MAX_TAX_BPS, InvalidTaxBps());
        require(taxCfg.taxDurationSeconds <= MAX_SELL_TAX_DURATION_SECONDS, InvalidTaxDuration());

        // minimal proxy pattern to deploy a new LivoToken instance
        token = Clones.cloneDeterministic(address(_tokenImplementation), salt);
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());

        emit TokenCreated(
            token, name, symbol, msg.sender, address(LAUNCHPAD), address(GRADUATOR), feeHandler_, feeReceiver
        );

        LivoTaxableTokenUniV4(payable(token))
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
                uint40(taxCfg.taxDurationSeconds)
            );
        // this will emit another event (from the launchpad)
        LAUNCHPAD.launchToken(token, BONDING_CURVE);
    }
}
