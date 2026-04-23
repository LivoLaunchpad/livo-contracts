// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Factory for deploying standard Livo tokens on Uniswap V2 with ownership renounced at creation
contract LivoFactoryUniV2 is LivoFactoryAbstract {
    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler
    ) LivoFactoryAbstract(launchpad, tokenImplementation, bondingCurve, graduator, feeHandler, address(0)) {}

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a new token clone with ownership renounced, initializes it, and registers it in the launchpad
    /// @dev `feeReceiver` defaults to `msg.sender` — the deployer collects post-graduation fees
    function createToken(string calldata name, string calldata symbol, bytes32 salt)
        external
        payable
        returns (address token)
    {
        token = _createAndInitializeToken(name, symbol, msg.sender, salt);
        if (msg.value > 0) _buyOnBehalf(token);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _createAndInitializeToken(string calldata name, string calldata symbol, address feeReceiver, bytes32 salt)
        internal
        returns (address token)
    {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());

        // minimal proxy pattern to deploy a new LivoToken instance
        token = Clones.cloneDeterministic(address(_tokenImplementation), salt);
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());

        // IMPORTANT: TokenCreated must be emitted BEFORE initialize() because the indexer
        // creates the TokenData entity from this event, and events emitted during initialize()
        // (PairInitialized, PoolIdRegistered, etc.) depend on TokenData existing.
        emit TokenCreated(
            token, name, symbol, address(0), address(LAUNCHPAD), address(GRADUATOR), address(FEE_HANDLER), feeReceiver
        );

        LivoToken(token)
            .initialize(
                ILivoToken.InitializeParams({
                    name: name,
                    symbol: symbol,
                    tokenOwner: address(0),
                    graduator: address(GRADUATOR),
                    launchpad: address(LAUNCHPAD),
                    feeHandler: address(FEE_HANDLER),
                    feeReceiver: feeReceiver
                })
            );

        // registers token in launchpad. This will also emit an event from the launchpad
        LAUNCHPAD.launchToken(token, BONDING_CURVE);
    }
}
