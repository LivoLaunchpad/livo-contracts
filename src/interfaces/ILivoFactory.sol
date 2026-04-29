// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoFactory {
    ////////////////// Structs //////////////////////

    /// @notice A single fee-receiver entry: account + shares in basis points (sum must == 10 000).
    struct FeeShare {
        address account;
        uint256 shares;
    }

    /// @notice A single supply-share entry: account + shares in basis points (sum must == 10 000).
    struct SupplyShare {
        address account;
        uint256 shares;
    }

    /// @notice Resolved fee routing returned from `_validateInputsAndResolveFees`. Bundling the three
    ///         addresses into a memory struct keeps `createToken` bodies within the EVM stack limit.
    struct FeeRouting {
        address feeHandler;
        address feeReceiver;
        address feeSplitter;
    }

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

    event BuyOnDeploy(
        address indexed token,
        address indexed buyer,
        uint256 ethSpent,
        uint256 tokensBought,
        address[] recipients,
        uint256[] amounts
    );

    event MaxBuyOnDeployBpsUpdated(uint256 newMaxBuyOnDeployBps);

    event TokenImplementationUpdated(address newTokenImplementation);

    ////////////////// Errors //////////////////////

    error InvalidNameOrSymbol();
    error InvalidTokenOwner();
    error InvalidFeeReceiver();
    error InvalidSupplyShares();
    error InvalidShares();
    error InvalidTokenAddress();
    error InvalidBuyOnDeploy();
    error InvalidTokenImplementation();
    error InvalidMaxBuyOnDeployBps();

    ////////////////// Views //////////////////////

    function quoteBuyOnDeploy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded);
}
