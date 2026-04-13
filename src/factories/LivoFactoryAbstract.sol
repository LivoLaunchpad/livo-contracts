// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";

/// @notice Abstract base for Livo token factories. Holds shared state and helper logic.
abstract contract LivoFactoryAbstract is ILivoFactory, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Token implementation contract used as the clone source
    ILivoToken public immutable TOKEN_IMPLEMENTATION;
    /// @notice Launchpad where tokens are registered after creation
    ILivoLaunchpad public immutable LAUNCHPAD;
    /// @notice Graduator contract that handles token graduation to Uniswap
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
        TOKEN_IMPLEMENTATION = ILivoToken(tokenImplementation);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        FEE_HANDLER = ILivoFeeHandler(feeHandler);
        FEE_SPLITTER_IMPLEMENTATION = ILivoFeeSplitter(feeSplitterImplementation);
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

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
    function quoteDeployerBuy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded) {
        (uint256 ethForReserves,) = BONDING_CURVE.buyExactTokens(0, tokenAmount);

        uint16 buyFeeBps = LAUNCHPAD.baseBuyFeeBps();
        uint256 denom = BASIS_POINTS - buyFeeBps;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _buyOnBehalf(address token) internal {
        uint256 tokensBought = LAUNCHPAD.buyTokensWithExactEth{value: msg.value}(token, 0, block.timestamp);

        // Floor division absorbs sub-token rounding from the bonding curve's ceiling math
        require(
            tokensBought * BASIS_POINTS / ILivoToken(token).totalSupply() <= maxDeployerBuyBps, InvalidDeployerBuy()
        );

        IERC20(token).safeTransfer(msg.sender, tokensBought);
        emit DeployerBuy(token, msg.sender, msg.value, tokensBought);
    }

    function _deployFeeSplitter(bytes32 salt) internal returns (address feeSplitter) {
        // forge-lint: disable-next-line
        bytes32 splitterSalt = keccak256(abi.encodePacked(salt, "feeSplitter"));
        feeSplitter = Clones.cloneDeterministic(address(FEE_SPLITTER_IMPLEMENTATION), splitterSalt);
    }
}
