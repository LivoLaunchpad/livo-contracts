// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Factory for deploying sniper-protected non-taxable Livo tokens with dev-configurable
///         max-buy-per-tx, max-wallet, and protection-window settings plus an immutable
///         bypass whitelist.
contract LivoFactorySniperProtected is LivoFactoryAbstract {
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

    /// @notice Deploys a new sniper-protected token clone, initializes it, and registers it in the launchpad.
    ///         If `feeReceivers.length >= 2`, also deploys a `FeeSplitter` as the fee receiver.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token, address feeSplitter) {
        FeeRouting memory routing = _validateInputsAndResolveFees(feeReceivers, supplyShares, salt);

        token = _createAndInitializeSniperProtectedToken(
            name, symbol, routing.feeHandler, routing.feeReceiver, salt, msg.sender, antiSniperCfg
        );

        _finalizeCreateToken(token, routing.feeSplitter, feeReceivers, supplyShares);
        feeSplitter = routing.feeSplitter;
    }

    /////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _createAndInitializeSniperProtectedToken(
        string calldata name,
        string calldata symbol,
        address feeHandler_,
        address feeReceiver,
        bytes32 salt,
        address tokenOwner,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        _validateNameSymbol(name, symbol);

        token = Clones.cloneDeterministic(address(_tokenImplementation), salt);
        // forge-lint: disable-next-line(unsafe-typecast)
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());

        emit TokenCreated(
            token, name, symbol, tokenOwner, address(LAUNCHPAD), address(GRADUATOR), feeHandler_, feeReceiver
        );

        LivoTokenSniperProtected(token)
            .initialize(
                ILivoToken.InitializeParams({
                    name: name,
                    symbol: symbol,
                    tokenOwner: tokenOwner,
                    graduator: address(GRADUATOR),
                    launchpad: address(LAUNCHPAD),
                    feeHandler: feeHandler_,
                    feeReceiver: feeReceiver
                }),
                antiSniperCfg
            );

        LAUNCHPAD.launchToken(token, BONDING_CURVE);
    }
}
