// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MasterFeeHandlerTestHelpers, MockMasterFeeToken} from "test/helpers/MasterFeeHandlerTestHelpers.sol";
import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev Direct receiver whose `receive()` bounces 1 wei back into the handler. The recursive
///      transfer hits the handler's `receive()`, which shares the `nonReentrant` guard with the
///      in-flight outer entry point. The recursion must therefore revert; the outer `.call` to
///      this receiver returns `ok = false` and the slice is recorded as pending.
contract HandlerBouncer {
    LivoMasterFeeHandler internal immutable handler;

    constructor(LivoMasterFeeHandler _handler) {
        handler = _handler;
    }

    receive() external payable {
        (bool ok,) = address(handler).call{value: 1}("");
        require(ok, "bounce blocked");
    }
}

contract LivoMasterFeeHandlerReceiveTests is MasterFeeHandlerTestHelpers {
    MockMasterFeeToken internal tokenA;

    function setUp() public override {
        super.setUp();
        tokenA = _newRegisteredToken(creator, _fs(creator));
    }

    /// @dev `receive()` attributes the deposit to `msg.sender` (the token). A plain ETH transfer
    ///      from the token should credit the token's claimable account exactly as
    ///      `depositFees(token)` would.
    function test_receive_routesToMsgSenderToken() public {
        uint256 amount = 1 ether;

        vm.expectEmit(true, false, false, true, address(handler));
        emit ILivoMasterFeeHandler.CreatorFeesDeposited(address(tokenA), amount);

        vm.deal(address(tokenA), amount);
        tokenA.accrueFees{value: amount}();

        assertEq(_claimable(address(tokenA), creator), amount, "creator should accrue full deposit");
    }

    /// @dev Zero-value transfer through `receive()` is a no-op: no event, no state change.
    function test_receive_zeroValueNoop() public {
        vm.recordLogs();
        tokenA.accrueFees{value: 0}();

        assertEq(vm.getRecordedLogs().length, 0, "no events on zero-value receive");
        assertEq(_claimable(address(tokenA), creator), 0, "claimable unchanged");
    }

    /// @dev Plain ETH from an unregistered address fails inside the handler with the same
    ///      array-OOB panic that `depositFees(address)` exhibits for unregistered tokens
    ///      (`_depositSingle` reads `claimableRecipients[0]` on an empty config). The outer
    ///      `.call` from the unregistered sender therefore returns `false`. Verified by
    ///      bypassing the mock's `require(ok, ...)` and inspecting the boolean directly.
    function test_receive_unregisteredSenderFails() public {
        MockMasterFeeToken unregistered = _newToken(creator);
        vm.deal(address(unregistered), 1 ether);

        vm.prank(address(unregistered));
        (bool ok,) = address(handler).call{value: 1 ether}("");
        assertFalse(ok, "receive must reject ETH from unregistered sender");
    }

    /// @dev The `nonReentrant` guard on `receive()` blocks a recursive ETH bounce from a direct
    ///      receiver. The outer forward to the bouncer sees `ok = false`, so its slice falls
    ///      back to a pending claim instead of forwarding synchronously. The outer deposit does
    ///      NOT revert, which preserves the swap-hot-path liveness invariant.
    function test_receive_nonReentrantBlocksBounceFromDirectReceiver() public {
        HandlerBouncer bouncer = new HandlerBouncer(handler);

        // Register a token with the bouncer as a direct receiver. Use a fresh token to keep
        // the assertion surface minimal.
        ILivoFactory.FeeShare[] memory shares = new ILivoFactory.FeeShare[](1);
        shares[0] = ILivoFactory.FeeShare({account: address(bouncer), shares: 10_000, directFeesEnabled: true});
        MockMasterFeeToken bouncerToken = _newRegisteredToken(creator, shares);

        uint256 amount = 1 ether;
        vm.deal(address(bouncerToken), amount);

        // Outer deposit succeeds. The synchronous forward to the bouncer fails (the bouncer's
        // recursive transfer reverts under the shared transient guard), so the slice is
        // recorded as pending and recoverable via `claim()`.
        bouncerToken.accrueFees{value: amount}();

        address[] memory tokens = new address[](1);
        tokens[0] = address(bouncerToken);
        uint256[] memory pending = handler.getClaimable(tokens, address(bouncer));
        assertEq(pending[0], amount, "bouncer slice fell back to pending");
    }
}
