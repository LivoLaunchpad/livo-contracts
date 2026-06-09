// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

interface ILivoToken is IERC20 {
    //////////////////////// Events //////////////////////

    event Graduated();
    event NewOwnerProposed(address owner, address proposedOwner, address caller);
    event OwnershipTransferred(address newOwner);

    /// @notice Emitted once during init with the pre-graduation fee config the token carries.
    event LaunchpadFeesInitialized(uint16 buyFeeBps, uint16 sellFeeBps, uint16 treasuryShareBps);

    /// @notice Emitted when `setLaunchpadFees` lowers the buy/sell fee rates (decrease-only). Only
    ///         the new values are carried; old values resolve from the prior `LaunchpadFeesInitialized`
    ///         or the most recent prior `LaunchpadFeesUpdated`.
    event LaunchpadFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);

    /// @notice Shared initialization parameters for Livo token clones
    /// @dev `vaultAllocation` is the amount of supply that is minted to the factory (`msg.sender` of
    ///      `initialize`) instead of the launchpad, so the factory can lock it in creator vaults.
    ///      Zero for normal tokens (full supply minted to the launchpad, identical to before).
    struct InitializeParams {
        string name;
        string symbol;
        address tokenOwner;
        address graduator;
        address launchpad;
        address feeHandler;
        uint256 vaultAllocation;
        uint16 buyFeeBps; // pre-graduation buy fee in bps (read by the launchpad each trade)
        uint16 sellFeeBps; // pre-graduation sell fee in bps (read by the launchpad each trade)
        uint16 treasuryShareBps; // share of the pre-graduation fee routed to the treasury (bps)
    }

    /// @notice Tax configuration for a token
    struct TaxConfig {
        uint16 buyTaxBps; // Buy tax in basis points (max 500 = 5%)
        uint16 sellTaxBps; // Sell tax in basis points (max 500 = 5%)
        uint40 taxDurationSeconds; // Duration after graduation during which taxes apply
        uint40 graduationTimestamp; // Timestamp when token graduated (0 if not graduated)
    }

    /// @notice Per-trade context the launchpad passes to `getLaunchpadFees` during pre-graduation trades.
    struct LaunchpadTrade {
        bool isBuy; // true for buys, false for sells
        address trader; // original caller of the launchpad trade
        uint256 ethAmount; // gross ETH the fee is assessed on
        uint256 tokenAmount; // tokens out (buy) / in (sell)
        uint256 ethReserves; // launchpad ETH reserves for this token, pre-trade
        // TODO: review if we should have instead `tokenReserves` (pre-trade) and derive circulating supply from `tokenReserves` + `releasedSupply`
        uint256 releasedSupply; // circulating supply sold by the launchpad, pre-trade
    }

    /// @notice Pre-graduation fee policy returned by the token for a given trade.
    struct LaunchpadFees {
        uint16 feeBps; // fee for THIS trade, in bps of `ethAmount`
        uint16 treasuryShareBps; // share of the fee routed to the treasury; remainder to the creator
    }

    ////////////////// STATE CHANGING FUNCTIONS ////////////////////

    function markGraduated() external;

    /// @notice Registers the token's initial fee receiver config in its fee handler.
    /// @dev Callable only by the factory that initialized the token.
    function registerFees(ILivoFactory.FeeShare[] calldata feeShares) external;

    /// @notice Routes ETH fees to the token's fee handler for the token's fee receiver
    function accrueFees() external payable;

    /// @notice Allows the current owner or whitelisted address to propose a new owner
    function proposeNewOwner(address newOwner) external;

    /// @notice Allows the proposed owner to accept the ownership
    function acceptTokenOwnership() external;

    /// @notice Allows the current owner to permanently renounce ownership
    function renounceOwnership() external;

    /// @notice Lowers the token's pre-graduation buy/sell fee rates (decrease-only).
    /// @dev Callable by the token owner or the launchpad owner. Increases revert.
    function setLaunchpadFees(uint16 newBuyFeeBps, uint16 newSellFeeBps) external;

    ////////////////// VIEW FUNCTIONS ////////////////////

    /// @notice Returns the tax configuration for this token
    /// @return config The complete tax configuration
    function getTaxConfig() external view returns (TaxConfig memory config);

    /// @notice Returns the pre-graduation fee policy for a given trade.
    /// @dev Read by the launchpad on every pre-graduation buy/sell. `virtual` implementations may
    ///      derive the rate dynamically from `trade`; the base implementation returns the statically
    ///      configured rates. A dynamic rate must depend only on pre-trade state (reserves, supply,
    ///      timestamp, trader), never on this trade's own gross size, or inverse quotes break.
    function getLaunchpadFees(LaunchpadTrade calldata trade) external view returns (LaunchpadFees memory);

    /// @notice Contract in charge of handling the graduation process
    /// @dev Must implement ILivoGraduator interface
    function graduator() external view returns (address);

    /// @notice Returns true if already graduated
    function graduated() external view returns (bool);

    /// @notice Address where liquidity is deployed after graduation
    function pair() external view returns (address);

    /// @notice The contract address where fees are claimed from
    function feeHandler() external view returns (address);

    /// @notice Owner of the token. The creator unless communityTakeOver takes place
    function owner() external view returns (address);

    /// @notice Address who can accept ownership of the token
    /// @dev It can be address(0) if no owner is proposed
    function proposedOwner() external view returns (address);

    /// @notice Returns the underlying fee receiver addresses and their share in basis points
    /// @dev Sourced from the master fee handler's per-token config: returns every current
    ///      recipient (direct + claimable) with their BPS share. Sum of shares is always 10_000.
    function getFeeReceivers() external view returns (address[] memory receivers, uint256[] memory sharesBps);

    /// @notice Returns the maximum amount of tokens `buyer` can purchase right now on the bonding curve.
    /// @dev Sniper-protected variants enforce per-tx and per-wallet caps during the protection window;
    ///      non-protected tokens always return `type(uint256).max` (no cap).
    /// @dev Integrators: feeding this value directly through `LivoLaunchpad.quoteBuyExactTokens` and
    ///      then `buyTokensWithExactEth` REVERTS with `MaxBuyPerTxExceeded`. The bonding curve isn't
    ///      symmetrically invertible (`forward(inverse(T)) > T`), so target slightly under this value
    ///      (e.g. `maxTokens - maxTokens / 100_000`) and verify with `quoteBuyTokensWithExactEth`
    ///      before broadcasting.
    function maxTokenPurchase(address buyer) external view returns (uint256);
}
