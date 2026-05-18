// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

/// @dev Minimal token double for standalone LivoMasterFeeHandler tests.
///      The handler only needs `feeHandler()` during registration and `owner()` during setShares.
contract MockMasterFeeToken {
    LivoMasterFeeHandler public feeHandler;
    address public owner;

    constructor(LivoMasterFeeHandler handler_, address owner_) {
        feeHandler = handler_;
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function registerFees(ILivoFactory.FeeShare[] calldata feeShares) external {
        feeHandler.registerToken(feeShares);
    }

    function accrueFees() external payable {
        // Mirrors the production token: plain ETH transfer to the handler; `receive()` attributes
        // the deposit via `msg.sender`.
        (bool ok,) = address(feeHandler).call{value: msg.value}("");
        require(ok, "accrueFees: transfer failed");
    }
}

/// @dev Receiver that rejects ETH transfers; used to exercise fallback-to-pending and claim failures.
contract MasterFeeEthRejecter {
    receive() external payable {
        revert("rejected");
    }
}

abstract contract MasterFeeHandlerTestHelpers is Test {
    LivoMasterFeeHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    function setUp() public virtual {
        vm.prank(owner);
        handler = new LivoMasterFeeHandler();
        vm.deal(address(this), 1_000 ether);
    }

    function _newToken(address tokenOwner) internal returns (MockMasterFeeToken) {
        return new MockMasterFeeToken(handler, tokenOwner);
    }

    function _register(MockMasterFeeToken token, ILivoFactory.FeeShare[] memory shares) internal {
        token.registerFees(shares);
    }

    function _newRegisteredToken(address tokenOwner, ILivoFactory.FeeShare[] memory shares)
        internal
        returns (MockMasterFeeToken token)
    {
        token = _newToken(tokenOwner);
        _register(token, shares);
    }

    function _deposit(MockMasterFeeToken token, uint256 amount) internal {
        handler.depositFees{value: amount}(address(token));
    }

    function _claimAs(address account, address[] memory tokens) internal {
        vm.prank(account);
        handler.claim(tokens);
    }

    function _single(address token) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = token;
    }

    function _tokens(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _tokens(address a, address b, address c) internal pure returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    function _claimable(address token, address account) internal view returns (uint256) {
        return handler.getClaimable(_single(token), account)[0];
    }

    function _fs(address account) internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        arr = new ILivoFactory.FeeShare[](1);
        arr[0] = ILivoFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: false});
    }

    function _fsDirect(address account) internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        arr = new ILivoFactory.FeeShare[](1);
        arr[0] = ILivoFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: true});
    }

    function _fs2(address a, uint256 aShare, bool aDirect, address b, uint256 bShare, bool bDirect)
        internal
        pure
        returns (ILivoFactory.FeeShare[] memory arr)
    {
        arr = new ILivoFactory.FeeShare[](2);
        arr[0] = ILivoFactory.FeeShare({account: a, shares: aShare, directFeesEnabled: aDirect});
        arr[1] = ILivoFactory.FeeShare({account: b, shares: bShare, directFeesEnabled: bDirect});
    }

    function _fs3(
        address a,
        uint256 aShare,
        bool aDirect,
        address b,
        uint256 bShare,
        bool bDirect,
        address c,
        uint256 cShare,
        bool cDirect
    ) internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        arr = new ILivoFactory.FeeShare[](3);
        arr[0] = ILivoFactory.FeeShare({account: a, shares: aShare, directFeesEnabled: aDirect});
        arr[1] = ILivoFactory.FeeShare({account: b, shares: bShare, directFeesEnabled: bDirect});
        arr[2] = ILivoFactory.FeeShare({account: c, shares: cShare, directFeesEnabled: cDirect});
    }
}
