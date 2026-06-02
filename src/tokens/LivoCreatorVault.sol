// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @title LivoCreatorVault
/// @notice Minimal-proxy-clonable vesting vault for creator-locked token supply. Each vault holds a
///         fixed token allocation for a single `owner`, who can claim it on a linear vesting
///         schedule with an initial cliff. Nothing can be claimed before the token graduates.
///
/// @dev    Vesting clock: the cliff + linear vesting both start at `vestingStart`, which is set by
///         the permissionless one-shot `activate()` — callable only once `token.graduated()` is
///         true. This anchors vesting at (≈) graduation without coupling the token/graduator to the
///         vault. `activate()` is permissionless so a keeper or the owner can anchor it the instant
///         the token graduates; delaying it only defers the owner's OWN unlock (and is strictly more
///         protective for buyers), so there is no adversarial incentive to game the anchor.
///
///         Schedule (cliff is a pure lock-up; linear vesting begins AFTER the cliff):
///           t <  cliffEnd                       -> 0
///           cliffEnd <= t < cliffEnd+vesting    -> total * (t - cliffEnd) / vesting
///           t >= cliffEnd + vesting             -> total
///         where cliffEnd = vestingStart + cliffSeconds.
///
///         The OZ `VestingWallet` was not reused: it is not clone-initializable and has no
///         graduation gate. This contract mirrors its linear-vesting math in a small, auditable form.
contract LivoCreatorVault is Initializable {
    using SafeERC20 for IERC20;

    /// @notice The token this vault vests. Its `graduated()` flag gates `activate()`.
    address public token;

    /// @notice The sole beneficiary, allowed to claim vested tokens.
    address public owner;

    /// @notice Total token allocation locked in this vault (set once at init).
    uint256 public totalAllocation;

    /// @notice Cliff duration in seconds after `vestingStart`, before anything is claimable.
    uint256 public cliffSeconds;

    /// @notice Linear vesting duration in seconds, starting after the cliff.
    uint256 public vestingSeconds;

    /// @notice Timestamp at which the vesting clock starts. Zero until `activate()` runs.
    uint256 public vestingStart;

    /// @notice Cumulative amount already claimed by the owner.
    uint256 public claimed;

    //////////////////////// Events //////////////////////

    /// @notice Emitted once when vesting is anchored (at/after graduation).
    event VaultActivated(uint256 vestingStart);

    /// @notice Emitted on every successful claim.
    event Claimed(address indexed owner, uint256 amount);

    //////////////////////// Errors //////////////////////

    error InvalidOwner();
    error InvalidToken();
    error NotOwner();
    error NotGraduated();
    error AlreadyActivated();
    error NotActivated();
    error NothingToClaim();

    /// @dev Locks the implementation so only clones can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a vault clone. Called by `LivoCreatorVaultFactory` right after cloning.
    /// @dev The vault is funded with `amount` tokens by the caller AFTER this call returns.
    function initialize(address token_, address owner_, uint256 amount, uint256 cliffSeconds_, uint256 vestingSeconds_)
        external
        initializer
    {
        require(token_ != address(0), InvalidToken());
        require(owner_ != address(0), InvalidOwner());
        token = token_;
        owner = owner_;
        totalAllocation = amount;
        cliffSeconds = cliffSeconds_;
        vestingSeconds = vestingSeconds_;
    }

    /// @notice Anchors the vesting clock. Permissionless, but only callable once the token has
    ///         graduated, and only once. Anyone (typically the owner or a keeper) should call this
    ///         the moment the token graduates so vesting starts at graduation.
    function activate() external {
        require(vestingStart == 0, AlreadyActivated());
        require(ILivoToken(token).graduated(), NotGraduated());
        vestingStart = block.timestamp;
        emit VaultActivated(block.timestamp);
    }

    /// @notice Claims all newly-vested tokens to the owner. Requires the vault to be activated.
    function claim() external {
        require(msg.sender == owner, NotOwner());
        require(vestingStart != 0, NotActivated());

        uint256 vested = _vestedAmount(block.timestamp);
        uint256 amount = vested - claimed;
        require(amount > 0, NothingToClaim());

        claimed = vested;
        IERC20(token).safeTransfer(owner, amount);
        emit Claimed(owner, amount);
    }

    //////////////////////// view functions //////////////////////

    /// @notice Amount currently claimable by the owner (0 before activation / during the cliff).
    function claimable() external view returns (uint256) {
        if (vestingStart == 0) return 0;
        return _vestedAmount(block.timestamp) - claimed;
    }

    /// @notice Total amount vested so far (claimed + claimable). 0 before activation.
    function vestedAmount() external view returns (uint256) {
        if (vestingStart == 0) return 0;
        return _vestedAmount(block.timestamp);
    }

    //////////////////////// internal functions //////////////////////

    /// @dev Linear vesting with a pure-lock-up cliff. Assumes `vestingStart != 0`.
    function _vestedAmount(uint256 timestamp) internal view returns (uint256) {
        uint256 cliffEnd = vestingStart + cliffSeconds;
        if (timestamp < cliffEnd) return 0;

        uint256 elapsed = timestamp - cliffEnd;
        // vestingSeconds == 0 => full unlock at the cliff (elapsed >= 0 always true here)
        if (elapsed >= vestingSeconds) return totalAllocation;
        return totalAllocation * elapsed / vestingSeconds;
    }
}
