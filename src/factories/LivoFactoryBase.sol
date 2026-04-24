// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
        FeeRouting memory routing = _validateInputsAndResolveFees(feeReceivers, supplyShares, salt);

        token = _createAndInitializeToken(name, symbol, routing.feeHandler, routing.feeReceiver, salt, msg.sender);

        _finalizeCreateToken(token, routing.feeSplitter, feeReceivers, supplyShares);
        feeSplitter = routing.feeSplitter;
    }
}
