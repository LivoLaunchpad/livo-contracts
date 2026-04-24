// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Factory for deploying taxable Livo tokens with Uniswap V4 hook integration,
///         with a higher tax cap and no tax-duration ceiling. Only the factory owner
///         may deploy tokens.
contract LivoFactoryExtendedTax is LivoFactoryAbstract {
    error InvalidTaxBps();

    struct TaxCfg {
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint32 taxDurationSeconds;
    }

    /// @notice max configurable tax (buy or sell) — 10%
    uint256 public constant MAX_TAX_BPS = 1_000;

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

    /// @notice Deploys a new taxable token clone with a configurable tax period (no duration cap).
    ///         If `feeReceivers.length >= 2`, also deploys a `FeeSplitter` as the fee receiver.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        TaxCfg calldata taxCfg
    ) external payable onlyOwner returns (address token, address feeSplitter) {
        FeeRouting memory routing = _validateInputsAndResolveFees(feeReceivers, supplyShares, salt);

        token = _createAndInitializeTaxToken(name, symbol, routing.feeHandler, routing.feeReceiver, salt, taxCfg);

        _finalizeCreateToken(token, routing.feeSplitter, feeReceivers, supplyShares);
        feeSplitter = routing.feeSplitter;
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
        _validateNameSymbol(name, symbol);

        require(taxCfg.buyTaxBps <= MAX_TAX_BPS && taxCfg.sellTaxBps <= MAX_TAX_BPS, InvalidTaxBps());

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
