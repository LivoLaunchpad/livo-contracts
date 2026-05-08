// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployersWhitelist} from "src/factories/DeployersWhitelist.sol";

contract DeployersWhitelistTests is Test {
    DeployersWhitelist internal whitelist;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal deployer = makeAddr("deployer");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(owner);
        whitelist = new DeployersWhitelist();
    }

    function test_ownerCanSetAdmin() public {
        vm.prank(owner);
        whitelist.setAdmin(admin, true);
        assertTrue(whitelist.admins(admin));

        vm.prank(owner);
        whitelist.setAdmin(admin, false);
        assertFalse(whitelist.admins(admin));
    }

    function test_nonOwnerCannotSetAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        whitelist.setAdmin(admin, true);
    }

    function test_adminCanSetWhitelisted() public {
        vm.prank(owner);
        whitelist.setAdmin(admin, true);

        vm.prank(admin);
        whitelist.setWhitelisted(deployer, true);
        assertTrue(whitelist.isWhitelisted(deployer));

        vm.prank(admin);
        whitelist.setWhitelisted(deployer, false);
        assertFalse(whitelist.isWhitelisted(deployer));
    }

    function test_nonAdminCannotSetWhitelisted() public {
        vm.prank(stranger);
        vm.expectRevert(DeployersWhitelist.OnlyAdmin.selector);
        whitelist.setWhitelisted(deployer, true);
    }

    function test_removedAdminCannotSetWhitelisted() public {
        vm.prank(owner);
        whitelist.setAdmin(admin, true);
        vm.prank(owner);
        whitelist.setAdmin(admin, false);

        vm.prank(admin);
        vm.expectRevert(DeployersWhitelist.OnlyAdmin.selector);
        whitelist.setWhitelisted(deployer, true);
    }
}
