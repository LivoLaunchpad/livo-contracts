// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";

interface ILivoLaunchpad {
    function treasury() external view returns (address);
    function baseBuyFeeBps() external view returns (uint16);
    function launchToken(address token, ILivoBondingCurve curve) external;
    function buyTokensWithExactEth(address token, uint256 minTokenAmount, uint256 deadline)
        external
        payable
        returns (uint256 receivedTokens);
}
