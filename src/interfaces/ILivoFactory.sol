// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoFactory {
    ////////////////// Events //////////////////////

    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        address tokenOwner,
        address launchpad,
        address graduator,
        address feeHandler,
        address feeReceiver
    );

    event FeeSplitterCreated(
        address indexed token, address indexed feeSplitter, address[] recipients, uint256[] sharesBps
    );

    event DeployerBuy(address indexed token, address indexed buyer, uint256 ethSpent, uint256 tokensBought);

    event MaxDeployerBuyBpsUpdated(uint256 newMaxDeployerBuyBps);

    event TokenImplementationUpdated(address newTokenImplementation);

    ////////////////// Errors //////////////////////

    error InvalidNameOrSymbol();
    error InvalidTokenOwner();
    error InvalidFeeReceiver();
    error InvalidTokenAddress();
    error InvalidDeployerBuy();
    error InvalidTokenImplementation();

    ////////////////// Views //////////////////////

    function quoteDeployerBuy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded);
}
