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

    /// @notice Token-identity bundle for the struct-based `createToken` overload. Groups the inputs
    ///         that define the token itself (name, symbol, deterministic salt) and its fee receivers.
    ///         `feeShares` must be non-empty — every token has at least one receiver.
    struct TokenSetup {
        string name;
        string symbol;
        bytes32 salt;
        FeeShare[] feeShares;
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

    /// @notice Per-token Uniswap V4 LP fee in basis points. Emitted only by the V4 unified factory
    ///         (V2 has no LP-fee concept). Today the V4 hook hardcodes 100 bps; this event lets
    ///         indexers attach the value as a per-token attribute ahead of the field being honoured.
    event LpFeeBpsSet(address indexed token, uint16 lpFeeBps);

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

    ////////////////// Views //////////////////////

    function quoteBuyOnDeploy(uint256 tokenAmount) external view returns (uint256 totalEthNeeded);
}
