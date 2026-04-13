// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Factory for deploying taxable Livo tokens with Uniswap V4 hook integration
contract LivoFactoryTaxToken is LivoFactoryAbstract {
    error InvalidTaxBps();
    error InvalidTaxDuration();

    /// @notice max configurable tax (buy or sell)
    uint256 public constant MAX_TAX_BPS = 500;

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

    /// @notice Deploys a new taxable token clone with sell tax configuration
    function createToken(
        string calldata name,
        string calldata symbol,
        address feeReceiver,
        bytes32 salt,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds
    ) external payable returns (address token) {
        require(feeReceiver != address(0), InvalidFeeReceiver());
        token = _createAndInitializeTaxToken(
            name, symbol, address(FEE_HANDLER), feeReceiver, salt, buyTaxBps, sellTaxBps, taxDurationSeconds
        );
        if (msg.value > 0) _buyOnBehalf(token);
    }

    /// @notice Deploys a new taxable token clone with a fee splitter
    function createTokenWithFeeSplit(
        string calldata name,
        string calldata symbol,
        address[] calldata recipients,
        uint256[] calldata sharesBps,
        bytes32 salt,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds
    ) external payable returns (address token, address feeSplitter) {
        feeSplitter = _deployFeeSplitter(salt);
        token = _createAndInitializeTaxToken(
            name, symbol, feeSplitter, feeSplitter, salt, buyTaxBps, sellTaxBps, taxDurationSeconds
        );
        // IMPORTANT: FeeSplitterCreated must be emitted BEFORE initialize() because the indexer
        // creates the FeeSplitter entity from this event, and events emitted during initialize()
        // (SharesUpdated) depend on the FeeSplitter entity existing.
        emit FeeSplitterCreated(token, feeSplitter, recipients, sharesBps);
        ILivoFeeSplitter(feeSplitter).initialize(address(FEE_HANDLER), token, recipients, sharesBps);
        if (msg.value > 0) _buyOnBehalf(token);
    }

    /////////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _createAndInitializeTaxToken(
        string calldata name,
        string calldata symbol,
        address feeHandler_,
        address feeReceiver,
        bytes32 salt,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds
    ) internal returns (address token) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());

        require(buyTaxBps <= MAX_TAX_BPS && sellTaxBps <= MAX_TAX_BPS, InvalidTaxBps());
        require(taxDurationSeconds <= MAX_SELL_TAX_DURATION_SECONDS, InvalidTaxDuration());

        // minimal proxy pattern to deploy a new LivoToken instance
        token = Clones.cloneDeterministic(address(TOKEN_IMPLEMENTATION), salt);
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
                buyTaxBps,
                sellTaxBps,
                uint40(taxDurationSeconds)
            );
        // this will emit another event (from the launchpad)
        LAUNCHPAD.launchToken(token, BONDING_CURVE);
    }
}
