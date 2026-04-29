// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

interface ILivoLaunchpad {
    function treasury() external view returns (address);
    function baseBuyFeeBps() external view returns (uint16);
    function launchToken(address token, ILivoBondingCurve curve) external;
    function buyTokensWithExactEth(address token, uint256 minTokenAmount, uint256 deadline)
        external
        payable
        returns (uint256 receivedTokens);

    function quoteBuyTokensWithExactEth(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive);

    function quoteBuyExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethFee, uint256 ethForReserves, uint256 totalEthNeeded);

    function quoteSellExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller);

    function quoteSellTokensForExactEth(address token, uint256 ethAmount)
        external
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 tokensRequired);

    function getMaxEthToSpend(address token) external view returns (uint256);

    function getTokenState(address token) external view returns (TokenState memory);

    function getTokenConfig(address token) external view returns (TokenConfig memory);
}
