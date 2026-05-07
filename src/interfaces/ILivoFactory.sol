// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoFactory {
    ////////////////// Structs //////////////////////

    /// @notice A single fee-receiver entry: account + shares in basis points (sum must == 10 000).
    /// @dev If `directFeesEnabled` is true, fees for this account are forwarded automatically on every
    ///      accrual instead of being held for `claim()`. A failed forward (malicious receiver) falls back
    ///      to the existing claimable accounting so swaps and graduation can never be DoS'd.
    struct FeeShare {
        address account;
        uint256 shares;
        bool directFeesEnabled;
    }

    /// @notice A single supply-share entry: account + shares in basis points (sum must == 10 000).
    struct SupplyShare {
        address account;
        uint256 shares;
    }

    ////////////////// Events //////////////////////

    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        address tokenOwner,
        address launchpad,
        address graduator,
        address feeHandler
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

    ////////////////// Errors //////////////////////

    error InvalidNameOrSymbol();
    error InvalidTokenOwner();
    error InvalidFeeReceiver();
    error InvalidSupplyShares();
    error InvalidShares();
    error InvalidTokenAddress();
    error InvalidBuyOnDeploy();
    error InvalidMaxBuyOnDeployBps();
    error MultipleDirectFeeReceivers();
    error InvalidAntiSniperConfig();
    error InvalidTaxConfig();

    ////////////////// Views //////////////////////

    function quoteBuyOnDeploy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded);
}
