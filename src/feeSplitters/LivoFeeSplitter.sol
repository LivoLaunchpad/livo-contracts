// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @notice Splits ETH fees received via `depositFees` / `receive()` among multiple recipients.
/// @dev The token's `feeHandler` slot points directly at this splitter, so every accrual path
///      (`LivoSwapHook._accrue`, V2/V4 graduation creator fee) lands here via
///      `LivoToken.accrueFees() → feeHandler.depositFees()`. The singleton `LivoFeeHandler` is
///      never in the path for splitter-backed tokens.
///      Two recipient classes coexist:
///        - **claimable** recipients accumulate ETH via the cumulative `_ethPerBps` accumulator
///          (existing pattern, scales O(1) per deposit).
///        - **direct** recipients have their slice forwarded synchronously on every accrual; the
///          slice is excluded from the accumulator math entirely.
///      The direct-receiver set is mutable via `setShares`: any address may be added, removed,
///      promoted from claimable, or demoted to claimable. Transitions preserve every recipient's
///      accrued/residue balance — see `setShares` natspec.
///      Forward failures fall back to per-account pending claims so a hostile receiver cannot DoS
///      the swap or graduation hot path.
contract LivoFeeSplitter is ILivoFeeSplitter, Initializable, ReentrancyGuardTransient {
    uint256 internal constant BPS_TOTAL = 10_000;
    uint256 internal constant PRECISION = 1e18;

    /// @notice The token whose fees are being split. This splitter only supports one token.
    address public token;

    /// @notice Current recipients (direct + claimable). Rebuilt by every `_setShares` call.
    address[] public recipients;

    /// @notice BPS shares aligned with `recipients`. Sum must == 10_000.
    uint256[] public sharesBps;

    /// @notice Sum of BPS across direct receivers — kept in storage for access in
    ///         `_accrueBalance`. Updated whenever `setShares` runs.
    uint256 public totalDirectBps;

    /// @notice Current list of direct-receiver addresses. Rebuilt by every `_setShares` call to
    ///         mirror the new payload.
    address[] internal _directReceivers;

    /// @notice BPS share assigned to each *claimable* recipient. 0 for direct recipients (their
    ///         BPS lives in `_directBpsOf`). The accumulator math
    ///         `_ethPerBps * _sharesBpsOf[acc] / PRECISION` therefore naturally yields 0 for
    ///         direct recipients.
    mapping(address => uint256) internal _sharesBpsOf;

    /// @notice BPS share assigned to each *direct* recipient. 0 for claimable recipients. Used
    ///         both for the synchronous forward in `_accrueBalance` and as a current-direct probe
    ///         (`_directBpsOf[acc] > 0` iff `acc` is currently direct, since the wipe loop in
    ///         `_setShares` zeroes ex-direct entries).
    mapping(address => uint256) internal _directBpsOf;

    /// @dev Tracks ETH already accounted for so new deposits are detectable via
    ///      `address(this).balance - _totalAccountedInBalance`. Decreases on claims.
    uint256 internal _totalAccountedInBalance;

    /// @dev Cumulative ETH earned per BPS of *claimable* share, scaled by `PRECISION`. Up-only.
    uint256 internal _ethPerBps;

    /// @dev Snapshot of `_ethPerBps` at the time of the recipient's last claim or share update.
    mapping(address => uint256) internal _claimedPerBps;

    /// @dev Residual claimable ETH carried over after a share update (claimable recipients) or
    ///      from a failed direct forward (direct recipients).
    mapping(address => uint256) internal _pendingClaims;

    constructor() {
        _disableInitializers();
    }

    /// @notice Accepts ETH deposits (e.g. from the fee handler).
    receive() external payable {}

    /// @notice Initializes the splitter with its token and initial fee shares.
    function initialize(address token_, ILivoFactory.FeeShare[] calldata feeShares) external initializer {
        token = token_;
        _setShares(feeShares);
    }

    ///////////// ONLY TOKEN OWNER //////////////////

    /// @notice Replaces the recipient list and per-recipient shares. The direct-receiver set is
    ///         mutable: any address may be added, removed, promoted from claimable, or demoted
    ///         to claimable. Snapshots claimable recipients' accrued share into `_pendingClaims`
    ///         before overwriting so promotions and removals don't lose accumulator-credited ETH.
    function setShares(ILivoFactory.FeeShare[] calldata feeShares) external {
        require(msg.sender == ILivoToken(token).owner(), Unauthorized());

        // Fold any unaccounted ETH into the accumulator so claimable recipients' snapshot is
        // up-to-date before we overwrite their share state.
        _accrueBalance();

        // Snapshot claimable accrual into pending for every existing recipient. For old direct
        // recipients `_sharesBpsOf[r] == 0` makes `_getClaimableFromAccrued(r)` collapse to
        // `_pendingClaims[r]`, so the assignment is a no-op (no need for a special case).
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            address r = recipients[i];
            _pendingClaims[r] = _getClaimableFromAccrued(r);
            _claimedPerBps[r] = _ethPerBps;
        }

        _setShares(feeShares);
    }

    ////////////////// FEE HANDLER INTERFACE /////////////////

    /// @notice Accepts ETH fees and accrues them for shareholders.
    function depositFees(address, address) external payable {
        _accrueBalance();
    }

    /// @notice Claims all accrued ETH fees for `msg.sender` and transfers them.
    /// @dev The tokens parameter is ignored; the splitter knows its single token.
    function claim(address[] calldata) external nonReentrant {
        // Fold any unaccounted ETH into the accumulator before computing the caller's claimable.
        _accrueBalance();

        // claimable is now updated with the latest accrued balance
        uint256 claimable = _getClaimableFromAccrued(msg.sender);
        if (claimable == 0) return;

        _claimedPerBps[msg.sender] = _ethPerBps;
        _pendingClaims[msg.sender] = 0;
        _totalAccountedInBalance -= claimable;

        (bool success,) = msg.sender.call{value: claimable}("");
        require(success);

        emit CreatorClaimed(token, msg.sender, claimable);
    }

    //////////////////////// VIEW FUNCTIONS ////////////////////////

    /// @notice Returns the claimable ETH for `account` across the given tokens.
    /// @dev Only returns non-zero for entries matching this splitter's token.
    /// @param tokens The token addresses to query.
    /// @param account The address to query.
    /// @return amounts Array of claimable amounts per token.
    function getClaimable(address[] calldata tokens, address account) external view returns (uint256[] memory amounts) {
        uint256 len = tokens.length;
        amounts = new uint256[](len);

        // this will only be non-zero for the token this splitter manages, but we still need to loop to put it in the right index
        uint256 claimableForToken = _getFullClaimable(account);

        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == token) {
                amounts[i] = claimableForToken;
            }
        }
    }

    /// @notice Returns all current recipients and their BPS shares.
    function getRecipients() external view returns (address[] memory, uint256[] memory) {
        return (recipients, sharesBps);
    }

    /// @notice Returns the current list of direct-receiver addresses.
    function getDirectReceivers() external view returns (address[] memory) {
        return _directReceivers;
    }

    ///////////////////// INTERNALS //////////////////////////////

    /// @dev Returns the total claimable ETH for `account`, including any unaccrued ETH already
    ///      sitting in the contract.
    ///      For *current* direct recipients, only `_pendingClaims[account]` is reported
    ///      (failed-forward residue) — the unaccrued slice will be forwarded synchronously on the
    ///      next accrual and never reaches their claimable balance.
    ///      For claimable recipients (and ex-direct addresses no longer in the direct set), the
    ///      slice that would be forwarded to direct receivers is stripped off the top before the
    ///      per-account math; addresses with `_sharesBpsOf[account] == 0` correctly receive only
    ///      their parked `_pendingClaims` since the multiplier zeroes out the unaccounted term.
    function _getFullClaimable(address account) internal view returns (uint256) {
        uint256 fromAccrued = _getClaimableFromAccrued(account);
        if (_directBpsOf[account] > 0) return fromAccrued;

        uint256 unaccounted = address(this).balance - _totalAccountedInBalance;
        uint256 claimableBpsTotal = BPS_TOTAL - totalDirectBps;
        if (claimableBpsTotal == 0) return fromAccrued;

        uint256 forClaimables = (unaccounted * claimableBpsTotal) / BPS_TOTAL;
        return fromAccrued + (forClaimables * _sharesBpsOf[account]) / claimableBpsTotal;
    }

    /// @dev Returns the claimable ETH for `account` based on already-accrued balances only.
    function _getClaimableFromAccrued(address account) internal view returns (uint256) {
        return ((_ethPerBps - _claimedPerBps[account]) * _sharesBpsOf[account]) / PRECISION + _pendingClaims[account];
    }

    /// @dev Overwrites recipients and shares, validates inputs, and emits diff-style direct-set
    ///      events:
    ///        - `DirectReceiverRemoved` for each address that was direct before the call and is
    ///          not direct after (demoted or removed).
    ///        - `DirectReceiverRegistered` for each address that is direct after the call and was
    ///          not direct before (added or promoted from claimable).
    ///      No event fires when the direct set is unchanged (BPS-only rebalance).
    ///      `SharesUpdated` is emitted last to preserve the documented event-tail order.
    function _setShares(ILivoFactory.FeeShare[] calldata feeShares) internal {
        // Snapshot old direct set into memory BEFORE wiping storage so the diff loop below can
        // detect removals.
        address[] memory oldDirects = _directReceivers;

        // Wipe per-account share state for previous recipients. Direct receivers had their
        // entries in `_directBpsOf` instead of `_sharesBpsOf`; reset both to be safe.
        uint256 oldLen = recipients.length;
        for (uint256 i = 0; i < oldLen; i++) {
            address r = recipients[i];
            delete _sharesBpsOf[r];
            delete _directBpsOf[r];
        }
        delete _directReceivers;

        uint256 len = feeShares.length;
        require(len > 0, InvalidRecipients());

        // duplicate address would break accounting and eth would be unrecoverable from this splitter contract
        // this check costs only 500-700 gas, which is quite an affordable one-time payment against losing funds
        _requireNoDuplicates(feeShares);

        address[] memory newRecipients = new address[](len);
        uint256[] memory newShares = new uint256[](len);

        uint256 total;
        uint256 directSum;
        for (uint256 i = 0; i < len; i++) {
            address acc = feeShares[i].account;
            uint256 sh = feeShares[i].shares;
            require(acc != address(0), InvalidRecipients());
            require(sh > 0, InvalidShares());

            newRecipients[i] = acc;
            newShares[i] = sh;
            total += sh;

            if (feeShares[i].directFeesEnabled) {
                _directBpsOf[acc] = sh;
                _directReceivers.push(acc);
                directSum += sh;
            } else {
                _sharesBpsOf[acc] = sh;
                // Initialize the accumulator pointer so future accruals don't credit historical eth.
                _claimedPerBps[acc] = _ethPerBps;
            }
        }
        require(total == BPS_TOTAL, InvalidShares());

        recipients = newRecipients;
        sharesBps = newShares;
        totalDirectBps = directSum;

        // Diff-style direct-set events. Cache token to avoid repeated SLOADs.
        address tk = token;
        uint256 oldDirectsLen = oldDirects.length;

        // Removals: an old direct whose new `_directBpsOf` entry is 0 was demoted or removed.
        for (uint256 i = 0; i < oldDirectsLen; i++) {
            if (_directBpsOf[oldDirects[i]] == 0) {
                emit DirectReceiverRemoved(tk, oldDirects[i]);
            }
        }

        // Additions: a new direct that does not appear in the old snapshot was added or promoted.
        for (uint256 i = 0; i < len; i++) {
            if (!feeShares[i].directFeesEnabled) continue;
            address acc = feeShares[i].account;
            bool wasDirectBefore;
            for (uint256 j = 0; j < oldDirectsLen; j++) {
                if (oldDirects[j] == acc) {
                    wasDirectBefore = true;
                    break;
                }
            }
            if (!wasDirectBefore) {
                emit DirectReceiverRegistered(tk, acc);
            }
        }

        emit SharesUpdated(newRecipients, newShares);
    }

    /// @dev Reverts if any two `feeShares` entries share the same `account`. O(n²) but n is the
    ///      number of fee receivers (typically ≤ 5) — cheap belt-and-braces against silent
    ///      account collisions that would corrupt per-account accounting.
    function _requireNoDuplicates(ILivoFactory.FeeShare[] calldata feeShares) internal pure {
        uint256 len = feeShares.length;
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                require(feeShares[i].account != feeShares[j].account, InvalidRecipients());
            }
        }
    }

    /// @dev Accounts for any new ETH that has arrived since the last accrual.
    ///      Direct receivers' slices are forwarded synchronously and excluded from the
    ///      accumulator. Forward failures fall back to per-account pending so the swap and
    ///      graduation hot paths cannot be DoS'd. `FeesAccrued` reports the full incoming amount —
    ///      indexers see the same event with the same payload regardless of which path each slice
    ///      took.
    function _accrueBalance() internal {
        uint256 newEth = address(this).balance - _totalAccountedInBalance;
        if (newEth == 0) return;

        // FeesAccrued fires first to match the existing event-ordering contract: every non-direct
        // path emits the "accrue" event before any "claim" event in the same trace.
        emit FeesAccrued(newEth);

        (uint256 directAmountTotal, uint256 forwardedAmount) = _forwardToDirectReceivers(newEth);

        // Only the ETH still in the contract counts as "accounted". Forwarded funds left.
        _totalAccountedInBalance += newEth - forwardedAmount;

        // Accumulate the claimable shareholders' slice. We always strip `directAmountTotal` off
        // the top regardless of forward success — failed amounts are parked under
        // `_pendingClaims[directReceiver]`, never accumulator-credited.
        uint256 claimableBpsTotal = BPS_TOTAL - totalDirectBps;
        if (claimableBpsTotal > 0) {
            uint256 toAccumulate = newEth - directAmountTotal;
            _ethPerBps += (toAccumulate * PRECISION) / claimableBpsTotal;
        }
    }

    /// @dev Iterates `_directReceivers`, computes each receiver's slice from `newEth`, and
    ///      forwards it synchronously. Failed forwards are parked under `_pendingClaims[receiver]`
    ///      so a hostile receiver cannot DoS the hot path.
    /// @param newEth The total fresh ETH being accrued in this call.
    /// @return directAmountTotal Sum of every direct slice computed, regardless of forward
    ///         success. Used by the caller to strip the direct portion from the claimable
    ///         accumulator math.
    /// @return forwardedAmount Sum of slices that left the contract via successful forwards.
    ///         Used by the caller to update `_totalAccountedInBalance`.
    function _forwardToDirectReceivers(uint256 newEth)
        internal
        returns (uint256 directAmountTotal, uint256 forwardedAmount)
    {
        uint256 directLen = _directReceivers.length;
        for (uint256 i = 0; i < directLen; i++) {
            address directReceiver = _directReceivers[i];
            uint256 directBps = _directBpsOf[directReceiver];
            if (directBps == 0) continue;

            uint256 directAmount = (newEth * directBps) / BPS_TOTAL;
            directAmountTotal += directAmount;
            if (directAmount == 0) continue;

            (bool ok,) = directReceiver.call{value: directAmount}("");
            if (ok) {
                forwardedAmount += directAmount;
                emit CreatorClaimed(token, directReceiver, directAmount);
            } else {
                // Fallback: park the failed forward as pending. Direct recipient can recover via claim().
                _pendingClaims[directReceiver] += directAmount;
            }
        }
    }
}
