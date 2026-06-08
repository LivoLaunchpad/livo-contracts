// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

interface ILivoToken is IERC20 {
    //////////////////////// Events //////////////////////

    event Graduated();
    event NewOwnerProposed(address owner, address proposedOwner, address caller);
    event OwnershipTransferred(address newOwner);

    /// @notice Shared initialization parameters for Livo token clones
    /// @dev `vaultAllocation` is the amount of supply that is minted to the factory (`msg.sender` of
    ///      `initialize`) instead of the launchpad, so the factory can lock it in creator vaults.
    ///      Zero for normal tokens (full supply minted to the launchpad, identical to before).
    /// @dev `lpFeeBps` is the per-swap LP fee `LivoSwapHook` charges, surfaced via `getCurrentFees`.
    ///      Set by the factory per venue: 0 for Uniswap V2 (no hook LP fee), 50 or 100 for V4.
    struct InitializeParams {
        string name;
        string symbol;
        address tokenOwner;
        address graduator;
        address launchpad;
        address feeHandler;
        uint256 vaultAllocation;
        uint16 lpFeeBps;
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

    ////////////////// VIEW FUNCTIONS ////////////////////

    /// @notice Returns the fees `LivoSwapHook` charges on a swap right now: the always-on LP fee
    ///         plus the buy/sell tax, which is non-zero only inside the post-graduation tax window.
    /// @dev Non-taxable tokens return only the LP fee (zero buy/sell tax); taxable variants override
    ///      to add the windowed tax. Replaces the former `getTaxConfig`: the hook needs only the
    ///      currently-effective rates, not the raw stored config, so the tax-window logic lives in
    ///      the token now.
    /// @return buyTaxBps Currently-effective buy tax in basis points (0 outside the tax window).
    /// @return sellTaxBps Currently-effective sell tax in basis points (0 outside the tax window).
    /// @return lpFeeBps LP fee in basis points (always effective).
    function getCurrentFees() external view returns (uint16 buyTaxBps, uint16 sellTaxBps, uint16 lpFeeBps);

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
