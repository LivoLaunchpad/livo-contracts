// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";

contract LivoToken is ERC20, ILivoToken, Initializable {
    /// @notice all Livo tokens have same supply
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Owner of the token. The creator unless communityTakeOver takes place
    address public owner;

    /// @notice Address who can accept ownership of the token
    /// @dev It can be address(0) if no owner is proposed
    address public proposedOwner;

    /// @notice The only graduator allowed to graduate this token
    address public graduator;

    /// @notice Uniswap pair. Token transfers to this address are blocked before graduation
    /// @dev Packed with `graduated` so the hot-path read of both fields in `_update` costs a
    ///      single SLOAD.
    address public pair;

    /// @notice Whether the token has graduated already or not
    bool public graduated;

    /// @notice Launchpad address
    LivoLaunchpad public launchpad;

    /// @notice Contract handling fees for this token. Set once at initialization and immutable
    ///         thereafter — there is no admin path to rotate it. For master-routed tokens this is
    ///         the `LivoMasterFeeHandler`; for V2 taxable single-direct-receiver tokens it is the
    ///         receiver address itself.
    address public feeHandler;

    /// @notice Factory that initialized this token. Allowed to perform one-shot fee registration.
    /// @dev Lives in transient storage: the factory calls `initialize` and `registerFees` in the
    ///      same tx, so the value only needs to survive across that single tx. Auto-clears at
    ///      end of tx, so a second `registerFees` attempt from any future tx finds it zeroed
    ///      and reverts on the `msg.sender == 0` check.
    /// @dev SECURITY ASSUMPTION (sniper-protected variants): `SniperProtection._checkSniperProtection`
    ///      reads this slot to exempt the deployer-buy hops `launchpad → factory → supplyShares`
    ///      from the per-tx / per-wallet caps (both `to == factoryAddr` and `from == factoryAddr`
    ///      branches). Outside the deploy tx the slot reads `address(0)`, so the exemption checks
    ///      effectively become `if (to == address(0)) return;` and `if (from == address(0))
    ///      return;`. This is currently safe because:
    ///        - `to == 0`: OZ ERC20 v5's `transfer`/`transferFrom` revert with
    ///          `ERC20InvalidReceiver` before reaching `_update`, so the `to == factoryAddr`
    ///          branch is unreachable with `factoryAddr == 0`.
    ///        - `from == 0`: the only mint is `_initializeLivoToken`'s initial mint to the
    ///          launchpad, which runs BEFORE `_initializeSniperProtection` sets `launchTimestamp`.
    ///          At that moment the window-active check returns early on its own, so the
    ///          `from == factoryAddr` branch is unreachable with `factoryAddr == 0`.
    /// @dev ⚠️ FUTURE FOOT-GUN: any new path that lets `_update` fire with `to == address(0)`
    ///      OR with `from == address(0)` AFTER `launchTimestamp` is set would silently bypass
    ///      the sniper caps. Concrete cases to watch out for:
    ///        - a custom transfer override (or alternate ERC20 base) that drops the
    ///          zero-recipient guard, enabling burns through `_update`;
    ///        - any new `_mint` call site that runs after init (e.g. a rebase or inflation
    ///          hook), since post-init mints have `from == address(0)`;
    ///        - any new internal call site that issues `_update(*, address(0), x)` directly
    ///          (e.g. a "burn from launchpad" admin path).
    ///      If any such path is introduced, harden the exemption: pass a non-zero sentinel
    ///      for the cleared state, or have `_checkSniperProtection` add explicit
    ///      `factoryAddr != address(0)` guards around the factoryAddr short-circuits.
    address internal transient tokenFactory;

    /// @notice Token name
    string internal _tokenName;

    /// @notice Token symbol
    string internal _tokenSymbol;

    //////////////////////// Errors //////////////////////

    error OnlyGraduatorAllowed();
    error TransferToPairBeforeGraduationNotAllowed();
    error CannotSelfTransfer();
    error Unauthorized();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoToken instance which will be used as implementation for clones
    /// @dev Token name and symbol are set during initialization, not in constructor
    constructor() ERC20("", "") {
        _disableInitializers();
    }

    /// @notice Initializes the token clone with its parameters
    /// @param params Shared token initialization parameters
    function initialize(ILivoToken.InitializeParams memory params) external virtual initializer {
        _initializeLivoToken(params);
    }

    /// @dev Internal initializer body; callable from child `initializer`-gated functions.
    /// @dev `params.graduator` is not explicitly checked for `address(0)`; the call to
    ///      `ILivoGraduator(params.graduator).initialize(address(this))` below would revert in
    ///      that case anyway (no code at the zero address).
    function _initializeLivoToken(ILivoToken.InitializeParams memory params) internal onlyInitializing {
        _tokenName = params.name;
        _tokenSymbol = params.symbol;
        graduator = params.graduator;
        owner = params.tokenOwner;
        feeHandler = params.feeHandler;
        tokenFactory = msg.sender;
        pair = ILivoGraduator(params.graduator).initialize(address(this));

        // Defensive ordering: set `launchpad` before `_mint` so any future `_update()` override that
        // reads it sees the real value. The mint itself is not gated by the sniper-protection check:
        // `_initializeSniperProtection` runs after this initializer, so `launchTimestamp == 0` here
        // and the check's window-active early-return covers the mint.
        launchpad = LivoLaunchpad(params.launchpad);

        _mint(params.launchpad, TOTAL_SUPPLY);
    }

    //////////////////////// restricted access functions ////////////////////////

    /// @notice Marks the token as graduated, which unlocks transfers to the pair
    /// @dev Can only be called by the pre-set graduator contract
    function markGraduated() external virtual {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        emit Graduated();
    }

    /// @notice Proposes a new owner for a token. Only callable by the current tokenOwner.
    ///         Pass address(0) as newOwner to cancel a pending proposal.
    /// @dev Also callable by the launchpad for communityTakeOvers. Effectively called by admins.
    function proposeNewOwner(address newOwner) external {
        address _owner = owner;
        require(msg.sender == _owner || msg.sender == address(launchpad), Unauthorized());

        proposedOwner = newOwner;

        emit NewOwnerProposed(_owner, newOwner, msg.sender);
    }

    /// @notice Accepts token ownership. Only callable by the address proposed as new owner.
    function acceptTokenOwnership() external {
        require(msg.sender == proposedOwner, Unauthorized());

        owner = msg.sender;
        delete proposedOwner;

        emit OwnershipTransferred(msg.sender);
    }

    /// @notice Permanently renounces ownership. Only callable by the current owner.
    /// @dev Clears both owner and any pending proposedOwner.
    function renounceOwnership() external {
        require(msg.sender == owner, Unauthorized());
        delete owner;
        delete proposedOwner;
        emit OwnershipTransferred(address(0));
    }

    //////////////////////// fee accrual ////////////////////////

    /// @notice Registers this token's initial fee shares in the master fee handler.
    /// @dev Callable only by the factory that initialized the token. The handler infers the token
    ///      from `msg.sender`, so this token contract is the only address registered.
    function registerFees(ILivoFactory.FeeShare[] calldata feeShares) external {
        require(msg.sender == tokenFactory, Unauthorized());
        ILivoMasterFeeHandler(feeHandler).registerToken(feeShares);
    }

    /// @notice Routes ETH fees to the fee handler for this token.
    /// @dev Thin external wrapper around `_accrueFees` so subclasses (and internal callers like
    ///      taxable-token swap-backs) can push fees without re-entering the external function.
    function accrueFees() external payable {
        _accrueFees(msg.value);
    }

    /// @dev Sends `amount` wei to the fee handler with empty calldata. The handler's `receive()`
    ///      attributes the deposit to `msg.sender` (this token), so the redundant `address(this)`
    ///      argument is no longer needed. No-op on zero.
    /// @dev The `.call` result is intentionally ignored. If the transfer fails (e.g. a malicious
    ///      contract receiver reverts on `receive()`, or the master handler reverts on an
    ///      unregistered config), the ETH stays in this contract instead of bubbling the revert.
    ///      The V2 swap-back path sources its push from `address(this).balance`, so any residual
    ///      from a failed transfer is rolled into the next swap-back automatically. External
    ///      callers of `accrueFees()` should consider the residual likewise recoverable on a
    ///      future swap-back / accrual that lands successfully.
    function _accrueFees(uint256 amount) internal {
        if (amount == 0) return;
        // Failure ignored intentionally — ETH stays in the contract and rolls into the next push.
        // forge-lint: disable-next-line(unchecked-call)
        (bool ok,) = feeHandler.call{value: amount}("");
        ok;
    }

    //////////////////////// view functions ////////////////////////

    /// @notice Default tax config returning no taxes. Overridden by taxable token implementations.
    function getTaxConfig() external view virtual returns (ILivoToken.TaxConfig memory config) {}

    /// @notice Default max-purchase: no cap. Overridden by sniper-protected variants.
    function maxTokenPurchase(address) external view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @dev ERC20 interface compliance
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @dev ERC20 interface compliance
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @dev Launchpad is pre-approved
    function allowance(address owner_, address spender) public view override(ERC20, IERC20) returns (uint256) {
        if (spender == address(launchpad)) return type(uint256).max;
        return super.allowance(owner_, spender);
    }

    //////////////////////// internal functions ////////////////////////

    function _update(address from, address to, uint256 amount) internal virtual override {
        // this ensures tokens don't arrive to the pair before graduation
        // to avoid exploits/DOS related to liquidity addition at graduation
        if ((!graduated) && (to == pair)) {
            revert TransferToPairBeforeGraduationNotAllowed();
        }

        super._update(from, to, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 value) internal override {
        // skips allowance logic if the spender is the launchpad to pre-approve launchpad forever
        if (spender == address(launchpad)) return;

        super._spendAllowance(owner_, spender, value);
    }
}
