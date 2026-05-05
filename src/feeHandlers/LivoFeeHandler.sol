// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @title LivoFeeHandler
/// @notice Fee handler with pending-claims tracking, reentrancy protection, and excess ETH sweep.
///         Tokens may opt one or more receivers into direct ETH forwarding via
///         `registerDirectReceivers` (callable by whitelisted factories). Forward failures
///         (malicious receivers) silently fall back to the existing pending-claim path so swap
///         and graduation hot paths cannot be DoS'd.
contract LivoFeeHandler is ILivoFeeHandler, Ownable, ReentrancyGuardTransient {
    /// @notice Launchpad whose factory whitelist gates `registerDirectReceivers`.
    ILivoLaunchpad public immutable LAUNCHPAD;

    /// @notice claimable eth per account associated to a token
    /// @dev claims are per token to not force an account to claim all-or-none
    mapping(address token => mapping(address account => uint256 amount)) internal _pendingClaims;

    /// @notice Sum of all pending creator claims (used to identify excess/stuck ETH)
    uint256 internal totalPendingCreatorClaims;

    /// @notice Per-(token, account) direct-fees flag. Flips to `true` when a whitelisted factory
    ///         registers `account` for `token`. The flag only gates how `depositFees` routes ETH;
    ///         a stale `true` for an account that never receives fees is harmless.
    mapping(address token => mapping(address account => bool)) public isDirectReceiver;

    constructor(address launchpad) Ownable(msg.sender) {
        LAUNCHPAD = ILivoLaunchpad(launchpad);
    }

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice Deposits ETH fees for a token's fee receiver. If `(token, feeReceiver)` is flagged
    ///         as direct, attempts to forward immediately and emit `CreatorClaimed`. On forward
    ///         failure, falls back to crediting pending claims.
    /// @dev `CreatorFeesDeposited` is always emitted before the optional forward, preserving the
    ///      existing event-order contract for indexers. Reentrancy: the bare `.call` lands in an
    ///      arbitrary receiver. State mutated post-forward (`_pendingClaims`, `totalPendingCreatorClaims`)
    ///      is unrelated to the in-flight deposit, so a re-entry into `claim()` only sees
    ///      already-credited balances. Safe by construction.
    function depositFees(address token, address feeReceiver) external payable {
        emit CreatorFeesDeposited(token, feeReceiver, msg.value);

        if (msg.value > 0 && isDirectReceiver[token][feeReceiver] && feeReceiver != address(0)) {
            (bool ok,) = feeReceiver.call{value: msg.value}("");
            if (ok) {
                emit CreatorClaimed(token, feeReceiver, msg.value);
                return;
            }
        }

        _pendingClaims[token][feeReceiver] += msg.value;
        totalPendingCreatorClaims += msg.value;
    }

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    function claim(address[] calldata tokens) external nonReentrant {
        uint256 claimable;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];

            uint256 tokenClaimable = _pendingClaims[token][msg.sender];
            if (tokenClaimable == 0) continue;

            claimable += tokenClaimable;
            delete _pendingClaims[token][msg.sender];

            emit CreatorClaimed(token, msg.sender, tokenClaimable);
        }

        if (claimable == 0) return;

        totalPendingCreatorClaims -= claimable;
        _transferEth(msg.sender, claimable);
    }

    /// @notice Sweeps excess ETH (donations, dust) to a recipient. Only callable by owner.
    function sweepExcessEth(address recipient) external onlyOwner {
        uint256 excess = address(this).balance - totalPendingCreatorClaims;
        if (excess > 0) {
            _transferEth(recipient, excess);
        }
    }

    /// @notice Flags each `receivers[i]` for direct ETH forwarding for `token`. Callable only by
    ///         addresses whitelisted as factories on the launchpad. Intended to be invoked by the
    ///         factory immediately after `_cloneAndCreateToken` and before `LAUNCHPAD.launchToken`,
    ///         so the registration is in place by the time any fee accrual can occur. Re-registration
    ///         is idempotent: calling again with new addresses simply adds them to the set.
    /// @dev No migration path is exposed by design — if the token owner calls
    ///      `LivoToken.setFeeReceiver(newAddr)`, the registration silently goes stale (mapping
    ///      still flags the old address; new deposits fall through to standard pending-claim
    ///      accounting). Emits `DirectReceiverRegistered` per receiver so indexers can track the
    ///      direct-receiver set without changing existing event signatures.
    function registerDirectReceivers(address token, address[] calldata receivers) external {
        require(LAUNCHPAD.whitelistedFactories(msg.sender), OnlyWhitelistedFactory());

        uint256 len = receivers.length;
        for (uint256 i = 0; i < len; i++) {
            isDirectReceiver[token][receivers[i]] = true;
            emit DirectReceiverRegistered(token, receivers[i]);
        }
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns the pending claimable ETH fees for an account across the given tokens
    /// @param tokens Array of token addresses
    /// @param receiver Address for which pending claimable amounts are computed
    /// @return creatorClaimable Array of claimable ETH amounts per token for `receiver`
    function getClaimable(address[] calldata tokens, address receiver)
        external
        view
        returns (uint256[] memory creatorClaimable)
    {
        uint256 nTokens = tokens.length;
        creatorClaimable = new uint256[](nTokens);

        for (uint256 i = 0; i < nTokens; i++) {
            creatorClaimable[i] = _pendingClaims[tokens[i]][receiver];
        }
    }

    ///////////////////////// INTERNAL //////////////////////////

    /// @notice Transfers ETH to a recipient, reverting on failure
    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }
}
