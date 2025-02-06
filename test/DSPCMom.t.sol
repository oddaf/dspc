// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DSPCMom} from "./DSPCMom.sol";
import {AuthorityMock} from "./mocks/AuthorityMock.sol";
import {DSPC} from "./DSPC.sol";

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
        dspc.deny(address(this)); // Remove deployer authority

        // Transfer ownership to admin
        vm.prank(address(this));
        mom.setOwner(admin);
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
}
