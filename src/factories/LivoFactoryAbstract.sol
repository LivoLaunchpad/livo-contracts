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

    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Token implementation contract used as the clone source
    ILivoToken internal _tokenImplementation;
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

    /// @notice Max percentage of total supply that can be purchased on token creation (applies to the aggregate, not per recipient), in basis points
    uint256 public maxBuyOnDeployBps = 1_000; // 10%

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
        _tokenImplementation = ILivoToken(tokenImplementation);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        FEE_HANDLER = ILivoFeeHandler(feeHandler);
        FEE_SPLITTER_IMPLEMENTATION = ILivoFeeSplitter(feeSplitterImplementation);
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Returns the token implementation contract used as the clone source
    function TOKEN_IMPLEMENTATION() public view returns (ILivoToken) {
        return _tokenImplementation;
    }

    /// @notice Updates the token implementation contract used as the clone source
    /// @param newTokenImplementation Address of the new token implementation
    function setTokenImplementation(address newTokenImplementation) external onlyOwner {
        require(newTokenImplementation != address(0), InvalidTokenImplementation());
        _tokenImplementation = ILivoToken(newTokenImplementation);
        emit TokenImplementationUpdated(newTokenImplementation);
    }

    /// @notice Updates the max aggregate buy-on-deploy percentage
    /// @param newMaxBuyOnDeployBps New max in basis points (e.g. 1000 = 10%)
    function setMaxBuyOnDeployBps(uint256 newMaxBuyOnDeployBps) external onlyOwner {
        require(newMaxBuyOnDeployBps < BASIS_POINTS, "Exceeds max bps");
        maxBuyOnDeployBps = newMaxBuyOnDeployBps;
        emit MaxBuyOnDeployBpsUpdated(newMaxBuyOnDeployBps);
    }

    /// @notice Quotes the ETH needed (msg.value) to receive exactly `tokenAmount` tokens on a new token
    /// @param tokenAmount Amount of tokens to receive
    /// @return totalEthNeeded The msg.value to pass to createToken
    function quoteBuyOnDeploy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded) {
        (uint256 ethForReserves,) = BONDING_CURVE.buyExactTokens(0, tokenAmount);

        uint16 buyFeeBps = LAUNCHPAD.baseBuyFeeBps();
        uint256 denom = BASIS_POINTS - buyFeeBps;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev Validates a FeeShare array: non-empty, no zero accounts, no duplicates, every share > 0, sum == 10 000.
    function _validateFeeShares(FeeShare[] calldata feeReceivers) internal pure {
        uint256 len = feeReceivers.length;
        require(len > 0, InvalidFeeReceiver());

        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            require(feeReceivers[i].account != address(0), InvalidFeeReceiver());
            require(feeReceivers[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len; j++) {
                require(feeReceivers[i].account != feeReceivers[j].account, InvalidFeeReceiver());
            }
            total += feeReceivers[i].shares;
        }
        require(total == BASIS_POINTS, InvalidShares());
    }

    /// @dev Validates a SupplyShare array: non-empty, no zero accounts, no duplicates, every share > 0, sum == 10 000.
    function _validateSupplyShares(SupplyShare[] calldata supplyShares) internal pure {
        uint256 len = supplyShares.length;
        require(len > 0, InvalidSupplyShares());

        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            require(supplyShares[i].account != address(0), InvalidSupplyShares());
            require(supplyShares[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len; j++) {
                require(supplyShares[i].account != supplyShares[j].account, InvalidSupplyShares());
            }
            total += supplyShares[i].shares;
        }
        require(total == BASIS_POINTS, InvalidShares());
    }

    /// @dev Resolves the (feeHandler, feeReceiver, feeSplitter) tuple for the given feeReceivers.
    ///      - len == 0 → (address(0), address(0), address(0)) — used only by UniV2
    ///      - len == 1 → (FEE_HANDLER, feeReceivers[0].account, address(0)) — no splitter deployed
    ///      - len >= 2 → (splitter, splitter, splitter) — splitter is deployed here but not yet initialized
    function _resolveFeeRouting(FeeShare[] calldata feeReceivers, bytes32 salt)
        internal
        returns (address feeHandler_, address feeReceiver_, address feeSplitter)
    {
        uint256 len = feeReceivers.length;
        if (len == 0) {
            return (address(0), address(0), address(0));
        }
        if (len == 1) {
            return (address(FEE_HANDLER), feeReceivers[0].account, address(0));
        }
        feeSplitter = _deployFeeSplitter(salt);
        return (feeSplitter, feeSplitter, feeSplitter);
    }

    /// @dev Initializes a freshly-deployed FeeSplitter for `token`. Emits `FeeSplitterCreated` BEFORE
    ///      `initialize()` so the indexer creates the splitter entity before `SharesUpdated` fires.
    function _initFeeSplitter(address feeSplitter, address token, FeeShare[] calldata feeReceivers) internal {
        uint256 len = feeReceivers.length;
        address[] memory recipients = new address[](len);
        uint256[] memory sharesBps = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            recipients[i] = feeReceivers[i].account;
            sharesBps[i] = feeReceivers[i].shares;
        }

        // IMPORTANT: FeeSplitterCreated must be emitted BEFORE initialize() because the indexer
        // creates the FeeSplitter entity from this event, and events emitted during initialize()
        // (SharesUpdated) depend on the FeeSplitter entity existing.
        emit FeeSplitterCreated(token, feeSplitter, recipients, sharesBps);
        ILivoFeeSplitter(feeSplitter).initialize(address(FEE_HANDLER), token, recipients, sharesBps);
    }

    /// @dev Buys supply with `msg.value` and distributes it to `supplyShares` proportionally.
    ///      The cap is enforced on the aggregate `tokensBought`, not per recipient. Rounding dust
    ///      goes to the last recipient so no tokens remain in the factory.
    function _buyAndDistribute(address token, SupplyShare[] calldata supplyShares) internal {
        uint256 tokensBought = LAUNCHPAD.buyTokensWithExactEth{value: msg.value}(token, 0, block.timestamp);

        // Floor division absorbs sub-token rounding from the bonding curve's ceiling math
        require(
            tokensBought * BASIS_POINTS / ILivoToken(token).totalSupply() <= maxBuyOnDeployBps, InvalidBuyOnDeploy()
        );

        uint256 len = supplyShares.length;
        address[] memory recipients = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        uint256 distributed;
        for (uint256 i = 0; i < len - 1; i++) {
            uint256 amount = tokensBought * supplyShares[i].shares / BASIS_POINTS;
            recipients[i] = supplyShares[i].account;
            amounts[i] = amount;
            distributed += amount;
            IERC20(token).safeTransfer(supplyShares[i].account, amount);
        }
        // last recipient absorbs rounding dust
        uint256 lastAmount = tokensBought - distributed;
        recipients[len - 1] = supplyShares[len - 1].account;
        amounts[len - 1] = lastAmount;
        IERC20(token).safeTransfer(supplyShares[len - 1].account, lastAmount);

        emit BuyOnDeploy(token, msg.sender, msg.value, tokensBought, recipients, amounts);
    }

    function _deployFeeSplitter(bytes32 salt) internal returns (address feeSplitter) {
        // forge-lint: disable-next-line
        bytes32 splitterSalt = keccak256(abi.encodePacked(salt, "feeSplitter"));
        feeSplitter = Clones.cloneDeterministic(address(FEE_SPLITTER_IMPLEMENTATION), splitterSalt);
    }
}
