// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTaxableTokenUniV4} from "src/interfaces/ILivoTaxableTokenUniV4.sol";

import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";

/// @notice This can be used for univ2 or univ4 tokens. Just with different graduators
contract LivoFactoryTaxToken is ILivoFactory, Ownable2Step {
    using SafeERC20 for IERC20;

    error InvalidTaxBps();
    error InvalidTaxDuration();

    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice max configurable tax (buy or sell)
    uint256 public constant MAX_TAX_BPS = 500;

    /// @notice max configurable sell tax duration
    uint256 public constant MAX_SELL_TAX_DURATION_SECONDS = 14 days;

    /// @notice Taxable token implementation contract used as the clone source
    ILivoTaxableTokenUniV4 public immutable TOKEN_IMPLEMENTATION;
    /// @notice Launchpad where tokens are registered after creation
    ILivoLaunchpad public immutable LAUNCHPAD;
    /// @notice Graduator contract that handles token graduation to Uniswap V4
    ILivoGraduator public immutable GRADUATOR;
    /// @notice Bonding curve used for token pricing before graduation
    ILivoBondingCurve public immutable BONDING_CURVE;
    /// @notice Fee handler contract for managing creator and treasury fees
    ILivoFeeHandler public immutable FEE_HANDLER;
    /// @notice Fee splitter implementation contract used as the clone source
    ILivoFeeSplitter public immutable FEE_SPLITTER_IMPLEMENTATION;

    /// @notice Max percentage of total supply the deployer can buy on token creation (in basis points)
    uint256 public maxDeployerBuyBps = 1_000; // 10%

    /// @notice Initializes the factory with its immutable dependencies
    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler,
        address feeSplitterImplementation
    ) Ownable(msg.sender) {
        LAUNCHPAD = ILivoLaunchpad(launchpad);
        TOKEN_IMPLEMENTATION = ILivoTaxableTokenUniV4(tokenImplementation);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        FEE_HANDLER = ILivoFeeHandler(feeHandler);
        FEE_SPLITTER_IMPLEMENTATION = ILivoFeeSplitter(feeSplitterImplementation);
    }

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

    /// @notice Updates the max deployer buy percentage
    /// @param newMaxDeployerBuyBps New max in basis points (e.g. 1000 = 10%)
    function setMaxDeployerBuyBps(uint256 newMaxDeployerBuyBps) external onlyOwner {
        require(newMaxDeployerBuyBps < BASIS_POINTS, "Exceeds max bps");
        maxDeployerBuyBps = newMaxDeployerBuyBps;
        emit MaxDeployerBuyBpsUpdated(newMaxDeployerBuyBps);
    }

    /// @notice Quotes the ETH needed (msg.value) for a deployer to receive exactly `tokenAmount` tokens on a new token
    /// @param tokenAmount Amount of tokens the deployer wants to receive
    /// @return totalEthNeeded The msg.value to pass to createToken/createTokenWithFeeSplit
    /// @return ethFee The fee portion taken by the launchpad
    /// @return ethForReserves The portion that goes into the bonding curve reserves
    function quoteDeployerBuy(uint256 tokenAmount)
        external
        view
        returns (uint256 totalEthNeeded, uint256 ethFee, uint256 ethForReserves)
    {
        (ethForReserves,) = BONDING_CURVE.buyExactTokens(0, tokenAmount);

        uint16 buyFeeBps = LAUNCHPAD.baseBuyFeeBps();
        uint256 denom = BASIS_POINTS - buyFeeBps;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
        ethFee = totalEthNeeded - ethForReserves;
    }

    /////////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _buyOnBehalf(address token) internal {
        uint256 tokensBought =
            LAUNCHPAD.buyTokensWithExactEth{value: msg.value}(token, 0, block.timestamp);

        // Floor division absorbs sub-token rounding from the bonding curve's ceiling math
        require(tokensBought * BASIS_POINTS / ILivoToken(token).totalSupply() <= maxDeployerBuyBps, InvalidDeployerBuy());

        IERC20(token).safeTransfer(msg.sender, tokensBought);
        emit DeployerBuy(token, msg.sender, msg.value, tokensBought);
    }

    function _deployFeeSplitter(bytes32 salt) internal returns (address feeSplitter) {
        // forge-lint: disable-next-line
        bytes32 splitterSalt = keccak256(abi.encodePacked(salt, "feeSplitter"));
        feeSplitter = Clones.cloneDeterministic(address(FEE_SPLITTER_IMPLEMENTATION), splitterSalt);
    }

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
