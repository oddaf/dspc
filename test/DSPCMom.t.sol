// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DSPCMom} from "../src/DSPCMom.sol";
import {AuthorityMock} from "./mocks/AuthorityMock.sol";
import {DSPC} from "../src/DSPC.sol";

contract DSPCMomTest is Test {
    // --- Events ---
    event SetOwner(address indexed owner);
    event SetAuthority(address indexed authority);
    event Halt(address indexed dspc);

    DSPC dspc;
    DSPCMom mom;
    AuthorityMock authority;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // Deploy DSPC with required dependencies
        dspc = new DSPC(makeAddr("jug"), makeAddr("pot"), makeAddr("susds"), makeAddr("conv"));

        // Deploy Mom and Authority
        mom = new DSPCMom();
        authority = new AuthorityMock();

        // Setup initial state
        dspc.rely(address(mom)); // Mom needs authority over DSPC
        dspc.rely(address(this)); // Keep test contract authority for test setup

        // Transfer ownership to admin
        vm.startPrank(address(this));
        mom.setOwner(admin);
        authority.rely(admin); // Give admin authority over AuthorityMock
        authority.deny(address(this)); // Remove deployer authority from AuthorityMock
        vm.stopPrank();
    }

    function test_constructor() public view {
        assertEq(mom.owner(), admin);
    }

    function test_setOwner() public {
        vm.prank(admin);
        mom.setOwner(alice);
        assertEq(mom.owner(), alice);
    }

    function test_setAuthority() public {
        vm.prank(admin);
        mom.setAuthority(address(authority));
        assertEq(address(mom.authority()), address(authority));
    }

    function test_halt_with_authority() public {
        // Set up authority
        vm.prank(admin);
        mom.setAuthority(address(authority));

        // Grant permission to bob through authority
        vm.prank(authority.wards(address(this)) == 1 ? address(this) : admin);
        authority.setCanCall(bob, address(mom), DSPCMom.halt.selector, true);

        // Bob can now halt through authority
        assertEq(dspc.bad(), 0);
        vm.prank(bob);
        mom.halt(address(dspc));
        assertEq(dspc.bad(), 1);
    }

    function test_halt_as_owner() public {
        assertEq(dspc.bad(), 0);

        vm.prank(admin);
        mom.halt(address(dspc));

        assertEq(dspc.bad(), 1);
    }

    function test_RevertWhen_NotAuthorized() public {
        vm.prank(bob);
        vm.expectRevert("DSPCMom/not-authorized");
        mom.halt(address(dspc));
    }

    function test_RevertWhen_AuthorityNotEnabled() public {
        // Set up authority but don't grant permission
        vm.prank(admin);
        mom.setAuthority(address(authority));

        // Should fail since bob doesn't have permission
        vm.prank(bob);
        vm.expectRevert("DSPCMom/not-authorized");
        mom.halt(address(dspc));
    }

    function test_RevertWhen_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        mom.halt(address(0));
    }

    function test_RevertWhen_NotOwner() public {
        vm.prank(bob);
        vm.expectRevert("DSPCMom/not-owner");
        mom.setOwner(alice);

        vm.prank(bob);
        vm.expectRevert("DSPCMom/not-owner");
        mom.setAuthority(address(authority));
    }

    function test_events() public {
        // Test SetOwner event
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit SetOwner(alice);
        mom.setOwner(alice);

        // Test SetAuthority event
        vm.prank(alice); // Now alice is the owner
        vm.expectEmit(true, true, true, true);
        emit SetAuthority(address(authority));
        mom.setAuthority(address(authority));

        // Test Halt event
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Halt(address(dspc));
        mom.halt(address(dspc));
    }

    function test_isAuthorized_this() public {
        // Test that the contract itself is authorized
        vm.prank(address(mom));
        mom.halt(address(dspc));
        assertEq(dspc.bad(), 1);
    }

    function test_authority_disabled() public {
        // Test that authorization fails when authority is address(0)
        vm.prank(admin);
        mom.setAuthority(address(0));

        vm.prank(bob);
        vm.expectRevert("DSPCMom/not-authorized");
        mom.halt(address(dspc));
    }

    function test_authority_revoked() public {
        // Set up authority and grant permission
        vm.prank(admin);
        mom.setAuthority(address(authority));

        // Grant permission to bob through authority
        vm.prank(admin);
        authority.setCanCall(bob, address(mom), DSPCMom.halt.selector, true);

        // Bob can halt
        vm.prank(bob);
        mom.halt(address(dspc));
        assertEq(dspc.bad(), 1);

        // Reset bad flag
        dspc.rely(address(this));  // Give test contract authority
        dspc.file("bad", 0);
        dspc.deny(address(this));  // Remove test contract authority

        // Revoke permission
        vm.prank(admin);
        authority.setCanCall(bob, address(mom), DSPCMom.halt.selector, false);

        // Bob can no longer halt
        vm.prank(bob);
        vm.expectRevert("DSPCMom/not-authorized");
        mom.halt(address(dspc));
    }
}
