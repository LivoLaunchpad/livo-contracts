// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoCreatorVault} from "src/vaults/LivoCreatorVault.sol";
import {LivoCreatorVaultFactory} from "src/factories/LivoCreatorVaultFactory.sol";

/// @dev Minimal token exposing a toggleable `graduated()` flag, mirroring `ILivoToken.graduated()`.
contract MockGraduatableToken is ERC20 {
    bool public graduated;

    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function setGraduated(bool v) external {
        graduated = v;
    }
}

/// @notice Fork-free unit tests for `LivoCreatorVault` math/guards and `LivoCreatorVaultFactory`.
///         The vesting clock starts at vault creation (init); claims are gated on `token.graduated()`.
contract LivoCreatorVaultUnitTest is Test {
    MockGraduatableToken token;
    LivoCreatorVault impl;
    address owner = makeAddr("owner");

    uint256 constant ALLOC = 100_000_000e18;
    uint256 constant CLIFF = 30 days;
    uint256 constant VESTING = 100 days;

    function setUp() public {
        // start at a non-zero timestamp so cliff math is meaningful
        vm.warp(1_000_000);
        token = new MockGraduatableToken();
        impl = new LivoCreatorVault();
    }

    function _newVault(uint256 cliff, uint256 vesting) internal returns (LivoCreatorVault vault) {
        vault = LivoCreatorVault(Clones.clone(address(impl)));
        vault.initialize(address(token), owner, ALLOC, cliff, vesting);
        token.transfer(address(vault), ALLOC);
    }

    function test_implementation_cannotBeInitialized() public {
        vm.expectRevert();
        impl.initialize(address(token), owner, ALLOC, CLIFF, VESTING);
    }

    function test_initialize_rejectsZeroToken() public {
        LivoCreatorVault vault = LivoCreatorVault(Clones.clone(address(impl)));
        vm.expectRevert(LivoCreatorVault.InvalidToken.selector);
        vault.initialize(address(0), owner, ALLOC, CLIFF, VESTING);
    }

    function test_initialize_rejectsZeroOwner() public {
        LivoCreatorVault vault = LivoCreatorVault(Clones.clone(address(impl)));
        vm.expectRevert(LivoCreatorVault.InvalidOwner.selector);
        vault.initialize(address(token), address(0), ALLOC, CLIFF, VESTING);
    }

    function test_initialize_anchorsClockAtCreation() public {
        LivoCreatorVault vault = _newVault(CLIFF, VESTING);
        assertEq(vault.startTimestamp(), block.timestamp, "vesting clock starts at creation");
    }

    function test_claimable_zeroBeforeGraduation_evenAfterCliff() public {
        LivoCreatorVault vault = _newVault(CLIFF, VESTING);
        // jump past the whole schedule, but the token never graduated
        vm.warp(block.timestamp + CLIFF + VESTING + 1);
        assertEq(vault.vestedAmount(), ALLOC, "schedule fully vested by time");
        assertEq(vault.claimable(), 0, "nothing claimable while not graduated");
    }

    function test_claim_revertsBeforeGraduation() public {
        LivoCreatorVault vault = _newVault(0, VESTING);
        vm.warp(block.timestamp + VESTING / 2);
        vm.prank(owner);
        vm.expectRevert(LivoCreatorVault.NotGraduated.selector);
        vault.claim();
    }

    function test_claim_revertsForNonOwner() public {
        LivoCreatorVault vault = _newVault(0, VESTING);
        token.setGraduated(true);
        vm.warp(block.timestamp + VESTING / 2);
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(LivoCreatorVault.NotOwner.selector);
        vault.claim();
    }

    function test_cliffThenLinear_precise() public {
        LivoCreatorVault vault = _newVault(CLIFF, VESTING);
        token.setGraduated(true);
        uint256 start = block.timestamp;

        // exactly at cliff end: 0 vested (linear starts here)
        vm.warp(start + CLIFF);
        assertEq(vault.vestedAmount(), 0, "0 at cliff end");

        // 25% through vesting
        vm.warp(start + CLIFF + VESTING / 4);
        assertEq(vault.vestedAmount(), ALLOC / 4, "25% vested");

        // exactly at end
        vm.warp(start + CLIFF + VESTING);
        assertEq(vault.vestedAmount(), ALLOC, "100% vested at end");

        // past end stays capped
        vm.warp(start + CLIFF + VESTING + 999 days);
        assertEq(vault.vestedAmount(), ALLOC, "capped past end");
    }

    function test_claim_incremental_sumsToAllocation() public {
        LivoCreatorVault vault = _newVault(0, VESTING); // no cliff
        token.setGraduated(true);
        uint256 start = block.timestamp;

        vm.warp(start + VESTING / 2);
        vm.prank(owner);
        vault.claim();
        assertEq(token.balanceOf(owner), ALLOC / 2);

        // second claim at 75%: only the new 25% is transferred
        vm.warp(start + (VESTING * 3) / 4);
        vm.prank(owner);
        vault.claim();
        assertEq(token.balanceOf(owner), (ALLOC * 3) / 4);

        vm.warp(start + VESTING);
        vm.prank(owner);
        vault.claim();
        assertEq(token.balanceOf(owner), ALLOC, "fully claimed");
        assertEq(vault.claimed(), ALLOC);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_claim_nothingToClaim_duringCliff_reverts() public {
        LivoCreatorVault vault = _newVault(CLIFF, VESTING);
        token.setGraduated(true);
        // graduated but still inside the cliff
        vm.prank(owner);
        vm.expectRevert(LivoCreatorVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_factory_createVault_emitsAndInitializes() public {
        address factoryImpl = address(new LivoCreatorVaultFactory(address(impl)));
        LivoCreatorVaultFactory factory = LivoCreatorVaultFactory(
            address(new ERC1967Proxy(factoryImpl, abi.encodeCall(LivoCreatorVaultFactory.initialize, ())))
        );

        address vault = factory.createVault(address(token), owner, ALLOC, CLIFF, VESTING);
        LivoCreatorVault v = LivoCreatorVault(vault);
        assertEq(v.token(), address(token));
        assertEq(v.owner(), owner);
        assertEq(v.totalAllocation(), ALLOC);
        assertEq(v.cliffSeconds(), CLIFF);
        assertEq(v.vestingSeconds(), VESTING);
        assertEq(v.startTimestamp(), block.timestamp);
        assertEq(factory.VAULT_IMPLEMENTATION(), address(impl));
    }

    function testFuzz_vestedMonotonicAndBounded(uint256 cliff, uint256 vesting, uint256 t) public {
        cliff = bound(cliff, 0, 3650 days);
        vesting = bound(vesting, 0, 3650 days);
        LivoCreatorVault vault = _newVault(cliff, vesting);
        uint256 start = block.timestamp;
        t = bound(t, 0, 10_000 days);
        vm.warp(start + t);
        uint256 vested = vault.vestedAmount();
        assertLe(vested, ALLOC, "never exceeds allocation");
        if (t < cliff) assertEq(vested, 0, "zero before cliff");
        if (t >= cliff + vesting) assertEq(vested, ALLOC, "full after end");
    }
}
