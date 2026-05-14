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

    ////////////////// Errors //////////////////////

    error InvalidNameOrSymbol();
    error InvalidTokenOwner();
    error InvalidFeeReceiver();
    error InvalidSupplyShares();
    error InvalidShares();
    error InvalidTokenAddress();
    error InvalidBuyOnDeploy();
    error MultipleDirectFeeReceivers();
    error InvalidAntiSniperConfig();
    error InvalidTaxConfig();
    error InvalidTaxBps();
    error InvalidTaxDuration();
    /// @notice A tax duration above the standard cap requires "charity mode": a single fee
    ///         receiver that is not the deployer.
    /// @dev We do NOT verify on-chain that the receiver is a real charity. Deployers can fake
    ///      it by passing any non-deployer address (including addresses they control). The
    ///      only on-chain invariants we enforce for extended durations are this rule and
    ///      `CharityModeOwnerNotRenounced()`. Off-chain UI / curation is responsible for
    ///      surfacing the social trust signal.
    error CharityModeFeeReceiverInvalid();
    /// @notice A tax duration above the standard cap requires the deployed token to be
    ///         ownerless (`tokenOwner == address(0)`), i.e. ownership renounced at creation.
    error CharityModeOwnerNotRenounced();

    ////////////////// Views //////////////////////

    function quoteBuyOnDeploy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded);
}
