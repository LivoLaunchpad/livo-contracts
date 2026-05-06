// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";
import {ILivoMasterFeeHandler} from "src/interfaces/ILivoMasterFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Owner-controlled contract that, on every received ETH, attempts to reenter
///         `setShares` on the master fee handler. Used to verify the `nonReentrant` guard
///         shared between `depositFees` and `setShares` blocks the reentry path.
contract ReenterOnReceive {
    LivoMasterFeeHandler public immutable handler;
    address public token;
    bool public attackTriggered;

    constructor(LivoMasterFeeHandler _handler) {
        handler = _handler;
    }

    function setToken(address _token) external {
        token = _token;
    }

    function callCreateToken(address factory, bytes calldata data) external payable returns (address newToken) {
        (bool ok, bytes memory ret) = factory.call{value: msg.value}(data);
        require(ok, "factory call failed");
        newToken = abi.decode(ret, (address));
    }

    receive() external payable {
        if (token == address(0)) return;
        attackTriggered = true;
        // Build a single-entry FeeShare[] that, if applied, would wipe the current direct
        // set. The reentry must revert because `setShares` shares the transient `nonReentrant`
        // guard with the in-flight `depositFees`.
        ILivoFactory.FeeShare[] memory newShares = new ILivoFactory.FeeShare[](1);
        newShares[0] = ILivoFactory.FeeShare({account: address(0xBEEF), shares: 10_000, directFeesEnabled: false});
        handler.setShares(token, newShares);
    }
}

contract LivoMasterFeeHandlerReentrancyTest is LaunchpadBaseTestsWithUniv4Graduator {
    ReenterOnReceive internal malicious;
    address internal eoaClaimable = makeAddr("eoaClaimable");

    function setUp() public override {
        super.setUp();
        malicious = new ReenterOnReceive(feeHandler);
    }

    /// @dev Builds a 2-entry FeeShare[]: malicious as direct (50%), EOA as claimable (50%).
    function _feeShares() internal view returns (ILivoFactory.FeeShare[] memory arr) {
        arr = new ILivoFactory.FeeShare[](2);
        arr[0] = ILivoFactory.FeeShare({account: address(malicious), shares: 5_000, directFeesEnabled: true});
        arr[1] = ILivoFactory.FeeShare({account: eoaClaimable, shares: 5_000, directFeesEnabled: false});
    }

    /// @dev Malicious-owner direct receiver tries to reenter `setShares` from `receive()`.
    ///      The nonReentrant guard blocks the inner `setShares` → outer `.call` returns false →
    ///      slice is preserved as a pending claim. Outer `depositFees` does NOT revert, so the
    ///      swap/graduation hot path stays alive.
    function test_setSharesReentryFromDirectReceiver_doesNotDosDepositFees() public {
        // Deploy a token with malicious as tokenOwner + direct fee receiver, EOA as claimable.
        vm.prank(address(malicious));
        address token = factoryV4Unified.createToken(
            "AttackToken",
            "ATTK",
            _nextValidSalt(address(factoryV4Unified), address(livoToken)),
            _feeShares(),
            _noSs(),
            false, // do NOT renounce — owner = msg.sender = malicious
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
        malicious.setToken(token);

        assertEq(ILivoToken(token).owner(), address(malicious), "owner = malicious");
        assertTrue(feeHandler.isDirectReceiver(token, address(malicious)), "malicious is direct");

        uint256 deposit = 1 ether;
        vm.deal(address(this), deposit);

        // Sanity: handler holds nothing for this token before the deposit.
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory before = feeHandler.getClaimable(tokens, address(malicious));
        assertEq(before[0], 0, "no pending pre-deposit");

        // Trigger the deposit. The reentry attempt MUST not propagate as a revert.
        feeHandler.depositFees{value: deposit}(token);

        // The reentered setShares reverted, so the slice fell back to pending.
        uint256[] memory afterAtk = feeHandler.getClaimable(tokens, address(malicious));
        assertEq(afterAtk[0], deposit / 2, "malicious slice routed to pending");

        // Claimable EOA accumulated normally.
        uint256[] memory eoaPending = feeHandler.getClaimable(tokens, eoaClaimable);
        assertEq(eoaPending[0], deposit / 2, "EOA accumulator advanced");

        // Direct config was NOT mutated by the failed reentry.
        assertTrue(feeHandler.isDirectReceiver(token, address(malicious)), "still direct");
        address[] memory directs = feeHandler.getDirectReceivers(token);
        assertEq(directs.length, 1, "directReceivers untouched");
        assertEq(directs[0], address(malicious), "direct still malicious");

        // Malicious can recover the failed slice by claiming.
        // First disable the reentry trigger so the malicious receive() doesn't try to attack
        // again when receiving the claim payout (claim() is also nonReentrant and would revert).
        malicious.setToken(address(0));

        uint256 ethBefore = address(malicious).balance;
        vm.prank(address(malicious));
        feeHandler.claim(tokens);
        assertEq(address(malicious).balance - ethBefore, deposit / 2, "claim paid out");
    }
}

contract LivoMasterFeeHandlerDirectReceiverCapTest is LaunchpadBaseTestsWithUniv4Graduator {
    address internal d0 = makeAddr("d0");
    address internal d1 = makeAddr("d1");
    address internal d2 = makeAddr("d2");
    address internal d3 = makeAddr("d3");
    address internal d4 = makeAddr("d4");

    address internal token;

    function setUp() public override {
        super.setUp();
        // Plain V4 token, owner = creator, single claimable fee receiver.
        vm.prank(creator);
        token = factoryV4Unified.createToken(
            "CapToken",
            "CAP",
            _nextValidSalt(address(factoryV4Unified), address(livoToken)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
    }

    function _shares(address[] memory directs) internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        uint256 n = directs.length;
        arr = new ILivoFactory.FeeShare[](n);
        // Equal split, BPS sums to 10_000 (with last entry absorbing rounding).
        uint256 each = 10_000 / n;
        uint256 acc;
        for (uint256 i = 0; i < n - 1; i++) {
            arr[i] = ILivoFactory.FeeShare({account: directs[i], shares: each, directFeesEnabled: true});
            acc += each;
        }
        arr[n - 1] = ILivoFactory.FeeShare({account: directs[n - 1], shares: 10_000 - acc, directFeesEnabled: true});
    }

    function test_registerToken_rejectsNonTokenCaller() public {
        vm.prank(alice);
        vm.expectRevert(ILivoMasterFeeHandler.Unauthorized.selector);
        feeHandler.registerToken(_fs(alice));
    }

    function test_tokenRegisterFees_rejectsNonFactoryCaller() public {
        vm.prank(creator);
        vm.expectRevert(ILivoMasterFeeHandler.Unauthorized.selector);
        ILivoToken(token).registerFees(_fs(alice));
    }

    function test_setShares_acceptsFourDirectReceivers() public {
        address[] memory directs = new address[](4);
        directs[0] = d0;
        directs[1] = d1;
        directs[2] = d2;
        directs[3] = d3;

        vm.prank(creator);
        feeHandler.setShares(token, _shares(directs));

        address[] memory got = feeHandler.getDirectReceivers(token);
        assertEq(got.length, 4, "4 directs accepted");
    }

    function test_setShares_rejectsFiveDirectReceivers() public {
        address[] memory directs = new address[](5);
        directs[0] = d0;
        directs[1] = d1;
        directs[2] = d2;
        directs[3] = d3;
        directs[4] = d4;

        vm.prank(creator);
        vm.expectRevert(ILivoMasterFeeHandler.TooManyDirectReceivers.selector);
        feeHandler.setShares(token, _shares(directs));
    }
}
