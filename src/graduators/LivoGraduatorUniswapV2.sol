// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

contract LivoGraduatorUniswapV2 is ILivoGraduator {
    using SafeERC20 for ILivoToken;

    /// @notice Graduation ETH fee (creator compensation + treasury fee)
    uint256 public constant GRADUATION_ETH_FEE = 0.25 ether;

    /// @notice ETH compensation paid to token creator at graduation (half of the fee)
    /// @dev this is part of the GRADUATION_ETH_FEE
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = GRADUATION_ETH_FEE / 2;

    /// @notice ETH compensation paid to `tx.origin` for triggering graduation, to offset the
    ///         extra gas spent deploying the UniswapV2 pair lazily inside `graduateToken()`.
    uint256 public constant TRIGGERER_GRADUATION_COMPENSATION = 0.002 ether;

    /// @notice Where LP tokens are sent at graduation, effectively locking the liquidity
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    /// @notice Address of the LivoLaunchpad contract
    address public immutable LIVO_LAUNCHPAD;

    /// @notice Uniswap V2 router contract
    IUniswapV2Router internal immutable UNISWAP_ROUTER;

    /// @notice Uniswap V2 factory contract
    IUniswapV2Factory internal immutable UNISWAP_FACTORY;

    /// @notice Wrapped ETH address
    address internal immutable WETH;

    /// @notice Init code hash of the Uniswap V2 pair contract used by the configured factory.
    ///         Required to predict the CREATE2 pair address without deploying the pair upfront.
    /// @dev Stock UniswapV2 mainnet/Sepolia value is `0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f`.
    bytes32 internal immutable PAIR_INIT_CODE_HASH;
    //////////////////////// EVENTS ////////////////////////

    event SweepedRemainingEth(address graduatedToken, uint256 amount);

    //////////////////////// ERRORS ////////////////////////

    error NotEnoughEthForGraduation();
    error EtherTransferFailed();

    ////////////////////////////////////////////////////////

    /// @notice Initializes the Uniswap V2 graduator
    /// @param _uniswapRouter Address of the Uniswap V2 router
    /// @param _launchpad Address of the LivoLaunchpad contract
    /// @param _pairInitCodeHash keccak256 of the pair contract creation code used by the configured factory
    constructor(address _uniswapRouter, address _launchpad, bytes32 _pairInitCodeHash) {
        LIVO_LAUNCHPAD = _launchpad;
        UNISWAP_ROUTER = IUniswapV2Router(_uniswapRouter);

        WETH = UNISWAP_ROUTER.WETH();
        UNISWAP_FACTORY = IUniswapV2Factory(UNISWAP_ROUTER.factory());
        PAIR_INIT_CODE_HASH = _pairInitCodeHash;
    }

    /// @notice Returns the deterministic CREATE2 address that the Uniswap V2 pair for `<token, WETH>` will have.
    /// @dev Pure prediction; pair contract is deployed lazily at graduation. Token's transfer gate keys off this address.
    /// @param tokenAddress Address of the token
    /// @return pair Address of the (future or existing) Uniswap V2 pair
    function initialize(address tokenAddress) external override returns (address pair) {
        pair = _pairFor(tokenAddress);
        emit PairInitialized(tokenAddress, pair);
    }

    /// @dev Standard UniswapV2Library-style CREATE2 prediction for the `<token, WETH>` pair.
    function _pairFor(address tokenAddress) internal view returns (address pair) {
        address weth = WETH;
        (address token0, address token1) = tokenAddress < weth ? (tokenAddress, weth) : (weth, tokenAddress);
        // forge-lint: disable-next-line(unsafe-typecast)
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(UNISWAP_FACTORY),
                            keccak256(abi.encodePacked(token0, token1)),
                            PAIR_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    /// @notice Graduates a token by adding liquidity to Uniswap V2
    /// @param tokenAddress Address of the token to graduate
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable override {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        ILivoToken token = ILivoToken(tokenAddress);
        require(tokenAmount > 0, NoTokensToGraduate());
        require(msg.value > 0, NoETHToGraduate());

        // 1. Handle fee split and payments
        uint256 ethForLiquidity = _handleGraduationFees(tokenAddress);

        // 2. Mark graduated and add liquidity
        // Pair was not deployed at token creation (only its CREATE2 address was reserved).
        // Deploy it now if nobody else has yet — `createPair` is permissionless on UniV2 so an
        // outside actor may have front-run us; in that case `getPair` returns the pre-existing pair
        // and we use it directly.
        address pair = UNISWAP_FACTORY.getPair(tokenAddress, WETH);
        if (pair == address(0)) {
            pair = UNISWAP_FACTORY.createPair(tokenAddress, WETH);
        }
        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        uint256 tokensForLiquidity = tokenAmount;
        token.safeIncreaseAllowance(address(UNISWAP_ROUTER), tokensForLiquidity);

        uint256 ethReserve = _syncedEthReserves(pair, tokenAddress);

        uint256 amountToken;
        uint256 amountEth;
        uint256 liquidity;
        if (ethReserve == 0) {
            (amountToken, amountEth, liquidity) =
                _naiveLiquidityAddition(tokenAddress, tokensForLiquidity, ethForLiquidity);
        } else {
            (amountToken, amountEth, liquidity) =
                _addLiquidityWithPriceMatching(tokenAddress, ethReserve, tokensForLiquidity, ethForLiquidity, pair);
        }

        _cleanup(tokenAddress);
        emit TokenGraduated(tokenAddress, amountToken, amountEth, liquidity);
    }

    /// @dev Reads the actual eth reserves after syncing
    function _syncedEthReserves(address pair, address tokenAddress) internal returns (uint256 ethReserve) {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        pairContract.sync();

        (uint112 reserve0, uint112 reserve1,) = pairContract.getReserves();

        // Determine which reserve corresponds to which token
        address token0 = pairContract.token0();

        if (token0 == tokenAddress) {
            ethReserve = reserve1;
        } else {
            ethReserve = reserve0;
        }
    }

    /// @dev Adds liquidity trying to match the intended price (derived from the ratio of eth/tokens for graduation)
    /// @dev The number one priority is that liquidity addition doesn't revert
    /// @dev The number two priority is that the resulting price in the pool is GREATER than the last price given by the launchpad before graduation
    function _addLiquidityWithPriceMatching(
        address tokenAddress,
        uint256 ethReserve,
        uint256 tokenBalance,
        uint256 ethValue,
        address pair
    ) internal returns (uint256 amountToken, uint256 amountEth, uint256 liquidity) {
        // Calculate tokens needed to match target price
        uint256 tokensToTransfer = (tokenBalance * ethReserve) / (ethValue + ethReserve);

        // Note: tokensToTransfer is always < tokenBalance due to (ethReserve < ethValue + ethReserve)
        ILivoToken(tokenAddress).safeTransfer(pair, tokensToTransfer);
        IUniswapV2Pair(pair).sync();

        // Add remaining tokens and ETH as liquidity
        uint256 remainingTokens = tokenBalance - tokensToTransfer;
        (amountToken, amountEth, liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethValue}(
            tokenAddress, remainingTokens, 0, 0, DEAD_ADDRESS, block.timestamp
        );
        // the tokens sent as sync also count as liquidity added ofc
        amountToken += tokensToTransfer;
    }

    /// @dev This blindly adds the liquidity, accepting any LPs, so accepting whatever price ratio is in the pair already
    function _naiveLiquidityAddition(address tokenAddress, uint256 tokenBalance, uint256 ethValue)
        internal
        returns (uint256 amountToken, uint256 amountEth, uint256 liquidity)
    {
        (amountToken, amountEth, liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethValue}(
            tokenAddress, tokenBalance, 0, 0, DEAD_ADDRESS, block.timestamp
        );
    }

    function _handleGraduationFees(address tokenAddress) internal returns (uint256 ethForLiquidity) {
        require(msg.value > GRADUATION_ETH_FEE, NotEnoughEthForGraduation());

        ethForLiquidity = msg.value - GRADUATION_ETH_FEE;
        uint256 treasuryShare = GRADUATION_ETH_FEE - CREATOR_GRADUATION_COMPENSATION - TRIGGERER_GRADUATION_COMPENSATION;

        // Creator share routed through token -> feeHandler -> feeReceiver
        emit CreatorGraduationFeeCollected(tokenAddress, CREATOR_GRADUATION_COMPENSATION);
        ILivoToken(tokenAddress).accrueFees{value: CREATOR_GRADUATION_COMPENSATION}();

        // Best-effort triggerer compensation. If `tx.origin` cannot receive ETH the amount
        // stays in the contract and is swept to the treasury by `_cleanup()`.
        // slither-disable-next-line tx-origin,unchecked-low-level,arbitrary-send-eth
        (bool triggererPaid,) = tx.origin.call{value: TRIGGERER_GRADUATION_COMPENSATION}("");
        triggererPaid; // intentionally ignored: failure path is handled by `_cleanup()`

        // Treasury share sent directly
        address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
        (bool success,) = treasury.call{value: treasuryShare}("");
        require(success, EtherTransferFailed());
        emit TreasuryGraduationFeeCollected(tokenAddress, treasuryShare);
    }

    function _cleanup(address tokenAddress) internal {
        uint256 remainingTokenBalance = ILivoToken(tokenAddress).balanceOf(address(this));
        // burn any remaining tokens
        if (remainingTokenBalance > 0) {
            ILivoToken(tokenAddress).safeTransfer(DEAD_ADDRESS, remainingTokenBalance);
        }

        // send any remaining ETH to the owner (launchpad)
        uint256 remainingEth = address(this).balance;
        if (remainingEth > 0) {
            address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
            (bool success,) = treasury.call{value: remainingEth}("");
            require(success, EtherTransferFailed());

            // for transparency, to be able to detect if some graduation went completely wrong
            emit SweepedRemainingEth(tokenAddress, remainingEth);
        }
    }
}
