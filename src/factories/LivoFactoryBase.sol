// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Factory for deploying standard (non-taxable) Livo tokens
contract LivoFactoryBase is LivoFactoryAbstract {
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

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a new token clone, initializes it, and registers it in the launchpad
    function createToken(string calldata name, string calldata symbol, address feeReceiver, bytes32 salt)
        external
        payable
        returns (address token)
    {
        require(feeReceiver != address(0), InvalidFeeReceiver());
        token = _createAndInitializeToken(name, symbol, address(FEE_HANDLER), feeReceiver, salt);
        if (msg.value > 0) _buyOnBehalf(token);
    }

    /// @notice Deploys a new token clone with a fee splitter, initializes both, and registers in the launchpad
    function createTokenWithFeeSplit(
        string calldata name,
        string calldata symbol,
        address[] calldata recipients,
        uint256[] calldata sharesBps,
        bytes32 salt
    ) external payable returns (address token, address feeSplitter) {
        feeSplitter = _deployFeeSplitter(salt);
        token = _createAndInitializeToken(name, symbol, feeSplitter, feeSplitter, salt);
        // IMPORTANT: FeeSplitterCreated must be emitted BEFORE initialize() because the indexer
        // creates the FeeSplitter entity from this event, and events emitted during initialize()
        // (SharesUpdated) depend on the FeeSplitter entity existing.
        emit FeeSplitterCreated(token, feeSplitter, recipients, sharesBps);
        ILivoFeeSplitter(feeSplitter).initialize(address(FEE_HANDLER), token, recipients, sharesBps);
        if (msg.value > 0) _buyOnBehalf(token);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _createAndInitializeToken(
        string calldata name,
        string calldata symbol,
        address feeHandler_,
        address feeReceiver,
        bytes32 salt
    ) internal returns (address token) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());

        // minimal proxy pattern to deploy a new LivoToken instance
        token = Clones.cloneDeterministic(address(_tokenImplementation), salt);
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());

        // IMPORTANT: TokenCreated must be emitted BEFORE initialize() because the indexer
        // creates the TokenData entity from this event, and events emitted during initialize()
        // (PairInitialized, PoolIdRegistered, etc.) depend on TokenData existing.
        emit TokenCreated(
            token, name, symbol, msg.sender, address(LAUNCHPAD), address(GRADUATOR), feeHandler_, feeReceiver
        );

        LivoToken(token)
            .initialize(
                ILivoToken.InitializeParams({
                    name: name,
                    symbol: symbol,
                    tokenOwner: msg.sender,
                    graduator: address(GRADUATOR),
                    launchpad: address(LAUNCHPAD),
                    feeHandler: feeHandler_,
                    feeReceiver: feeReceiver
                })
            );

        // registers token in launchpad. This will also emit an event from the launchpad
        LAUNCHPAD.launchToken(token, BONDING_CURVE);
    }
}
