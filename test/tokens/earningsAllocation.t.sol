// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EarningsAllocation} from "src/tokens/EarningsAllocation.sol";

/// @dev Harness exposing `EarningsAllocation`'s internal split, with the bucket handlers overridden to
///      record amounts instead of routing real ETH. Lets us unit-test the split arithmetic + dispatch
///      in isolation, without the fork/factory machinery a real token needs.
contract EarningsAllocationHarness is EarningsAllocation {
    bool public grad;
    uint256 public fundReceived;
    uint256 public burnReceived;
    uint256 public dividendsReceived;
    uint256 public liquidityReceived;

    function setGraduated(bool g) external {
        grad = g;
    }

    function initAllocation(uint16 b, uint16 d, uint16 l) external {
        _initializeEarningsAllocation(b, d, l);
    }

    function allocate(uint256 amount) external {
        _allocateEarnings(amount);
    }

    function _earningsGraduated() internal view override returns (bool) {
        return grad;
    }

    function _depositToFund(uint256 amount) internal override {
        fundReceived += amount;
    }

    function _handleBurn(uint256 amount) internal override returns (uint256) {
        burnReceived += amount;
        return 0; // fully consumed (accrued), nothing folds back to fund
    }

    function _handleDividends(uint256 amount) internal override returns (uint256) {
        dividendsReceived += amount;
        return 0;
    }

    function _handleLiquidity(uint256 amount) internal override returns (uint256) {
        liquidityReceived += amount;
        return 0;
    }
}

/// @dev Harness that leaves the base fund-fallback `_handle*` in place (does NOT override them), to
///      prove that until a module ships every non-fund bucket routes to the fund wallets.
contract EarningsAllocationFallbackHarness is EarningsAllocation {
    bool public grad;
    uint256 public fundReceived;

    function setGraduated(bool g) external {
        grad = g;
    }

    function initAllocation(uint16 b, uint16 d, uint16 l) external {
        _initializeEarningsAllocation(b, d, l);
    }

    function allocate(uint256 amount) external {
        _allocateEarnings(amount);
    }

    function _earningsGraduated() internal view override returns (bool) {
        return grad;
    }

    function _depositToFund(uint256 amount) internal override {
        fundReceived += amount;
    }
}

contract EarningsAllocationTest is Test {
    EarningsAllocationHarness internal h;

    function setUp() public {
        h = new EarningsAllocationHarness();
    }

    function test_preGraduation_everythingToFund() public {
        h.initAllocation(3000, 2000, 1000);
        h.setGraduated(false);
        h.allocate(1 ether);

        assertEq(h.fundReceived(), 1 ether);
        assertEq(h.burnReceived(), 0);
        assertEq(h.dividendsReceived(), 0);
        assertEq(h.liquidityReceived(), 0);
    }

    function test_graduated_zeroAllocation_everythingToFund() public {
        h.setGraduated(true);
        h.allocate(1 ether);

        assertEq(h.fundReceived(), 1 ether);
        assertEq(h.burnReceived(), 0);
    }

    function test_graduated_splitsByBps() public {
        h.initAllocation(3000, 2000, 1000); // fund = 40%
        h.setGraduated(true);
        h.allocate(1 ether);

        assertEq(h.burnReceived(), 0.3 ether);
        assertEq(h.dividendsReceived(), 0.2 ether);
        assertEq(h.liquidityReceived(), 0.1 ether);
        assertEq(h.fundReceived(), 0.4 ether);
        // Slices sum back to the input — no wei stranded or double-counted.
        assertEq(h.burnReceived() + h.dividendsReceived() + h.liquidityReceived() + h.fundReceived(), 1 ether);
    }

    function test_graduated_fullAllocation_noFundRemainder() public {
        h.initAllocation(5000, 3000, 2000); // fund = 0%
        h.setGraduated(true);
        h.allocate(1 ether);

        assertEq(h.burnReceived(), 0.5 ether);
        assertEq(h.dividendsReceived(), 0.3 ether);
        assertEq(h.liquidityReceived(), 0.2 ether);
        assertEq(h.fundReceived(), 0);
    }

    function test_roundingRemainderGoesToFund() public {
        h.initAllocation(3333, 3333, 3333); // fund = 1 bp, but rounding leaves more
        h.setGraduated(true);
        h.allocate(10); // each bucket: 10*3333/10000 = 3; fund absorbs the rest

        assertEq(h.burnReceived(), 3);
        assertEq(h.dividendsReceived(), 3);
        assertEq(h.liquidityReceived(), 3);
        assertEq(h.fundReceived(), 1);
        assertEq(h.burnReceived() + h.dividendsReceived() + h.liquidityReceived() + h.fundReceived(), 10);
    }

    function test_zeroAmount_noop() public {
        h.initAllocation(3000, 2000, 1000);
        h.setGraduated(true);
        h.allocate(0);

        assertEq(h.fundReceived(), 0);
        assertEq(h.burnReceived(), 0);
    }

    function test_initReverts_whenBucketsExceedTotal() public {
        vm.expectRevert(EarningsAllocation.InvalidEarningsAllocation.selector);
        h.initAllocation(5000, 5000, 1); // 10001 bps
    }

    function testFuzz_slicesAlwaysSumToInput(uint16 b, uint16 d, uint16 l, uint256 amount) public {
        b = uint16(bound(b, 0, 10_000));
        d = uint16(bound(d, 0, 10_000 - b));
        l = uint16(bound(l, 0, 10_000 - b - d));
        amount = bound(amount, 0, 1e30);

        h.initAllocation(b, d, l);
        h.setGraduated(true);
        h.allocate(amount);

        assertEq(h.burnReceived() + h.dividendsReceived() + h.liquidityReceived() + h.fundReceived(), amount);
    }
}

contract EarningsAllocationFallbackTest is Test {
    EarningsAllocationFallbackHarness internal h;

    function setUp() public {
        h = new EarningsAllocationFallbackHarness();
    }

    /// @dev Step-1 real-token behavior: with the modules not yet shipped, a non-zero burn/dividends/
    ///      liquidity allocation routes to the fund wallets instead of bricking or stranding ETH.
    function test_unimplementedBuckets_fallBackToFund() public {
        h.initAllocation(3000, 2000, 1000);
        h.setGraduated(true);
        h.allocate(1 ether);

        assertEq(h.fundReceived(), 1 ether);
    }
}

/// @dev Harness whose burn leg consumes only half its slice and returns the rest as unconsumed, to
///      verify `_allocateEarnings` folds the residual back into the fund deposit.
contract EarningsAllocationPartialHarness is EarningsAllocation {
    uint256 public burnConsumed;
    uint256 public fundReceived;

    function initAllocation(uint16 b, uint16 d, uint16 l) external {
        _initializeEarningsAllocation(b, d, l);
    }

    function allocate(uint256 amount) external {
        _allocateEarnings(amount);
    }

    function _earningsGraduated() internal pure override returns (bool) {
        return true;
    }

    function _depositToFund(uint256 amount) internal override {
        fundReceived += amount;
    }

    function _handleBurn(uint256 amount) internal override returns (uint256) {
        uint256 consume = amount / 2;
        burnConsumed += consume;
        return amount - consume; // residual folds back to fund
    }
}

contract EarningsAllocationPartialTest is Test {
    EarningsAllocationPartialHarness internal h;

    function setUp() public {
        h = new EarningsAllocationPartialHarness();
    }

    function test_unconsumedResidualFoldsToFund() public {
        h.initAllocation(4000, 0, 0); // 40% burn, 60% fund
        h.allocate(1 ether);

        assertEq(h.burnConsumed(), 0.2 ether); // half of the 0.4e18 burn slice
        assertEq(h.fundReceived(), 0.8 ether); // 0.6e18 remainder + 0.2e18 residual
        assertEq(h.burnConsumed() + h.fundReceived(), 1 ether);
    }
}
