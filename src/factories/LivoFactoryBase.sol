// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
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

    /// @notice Deploys a new token clone, initializes it, and registers it in the launchpad.
    ///         If `feeReceivers.length >= 2`, also deploys a `FeeSplitter` as the fee receiver.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    /// @param feeReceivers Non-empty list of fee receivers; shares must sum to 10 000 bps.
    /// @param supplyShares Required if and only if `msg.value > 0`; shares must sum to 10 000 bps.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares
    ) external payable returns (address token, address feeSplitter) {
        _validateFeeShares(feeReceivers);
        if (msg.value > 0) _validateSupplyShares(supplyShares);
        else require(supplyShares.length == 0, InvalidSupplyShares());

        address feeHandler_;
        address feeReceiver_;
        (feeHandler_, feeReceiver_, feeSplitter) = _resolveFeeRouting(feeReceivers, salt);

        token = _createAndInitializeToken(name, symbol, feeHandler_, feeReceiver_, salt);

        if (feeSplitter != address(0)) _initFeeSplitter(feeSplitter, token, feeReceivers);

        if (msg.value > 0) _buyAndDistribute(token, supplyShares);
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
