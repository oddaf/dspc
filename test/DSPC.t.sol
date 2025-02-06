// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DSPC} from "../src/DSPC.sol";

contract MockJug {
    mapping(bytes32 => uint256) public duty;

    function file(bytes32 ilk, bytes32 what, uint256 data) external {
        require(what == "duty", "MockJug/invalid-what");
        duty[ilk] = data;
    }

    function ilks(bytes32 ilk) external view returns (uint256, uint256) {
        return (duty[ilk], 0);
    }
}

contract MockPot {
    uint256 public dsr;

    function file(bytes32 what, uint256 data) external {
        require(what == "dsr", "MockPot/invalid-what");
        dsr = data;
    }
}

contract MockSUSDS {
    uint256 public ssr;

    function file(bytes32 what, uint256 data) external {
        require(what == "ssr", "MockSUSDS/invalid-what");
        ssr = data;
    }
}

contract MockConv {
    uint256 internal constant RAY = 10 ** 27;
    uint256 internal constant BASIS_POINTS = 100_00;

    function turn(uint256 bps) external pure returns (uint256) {
        // Convert basis points to ray
        // 100 bps = 1% = 1.01 * RAY
        return RAY + (RAY * bps) / BASIS_POINTS;
    }

    function back(uint256 ray) external pure returns (uint256) {
        // Convert ray to basis points
        // 1.01 * RAY = 1% = 100 bps
        return ((ray - RAY) * BASIS_POINTS) / RAY;
    }
}

contract DSPCTest is Test {
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed id, bytes32 indexed what, uint256 data);
    event Put(DSPC.ParamChange[] updates);

    DSPC dspc;
    MockJug jug;
    MockPot pot;
    MockSUSDS susds;
    MockConv conv;

    address admin = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 constant ILK = "ETH-A";
    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;

    function setUp() public {
        jug = new MockJug();
        pot = new MockPot();
        susds = new MockSUSDS();
        conv = new MockConv();
        dspc = new DSPC(address(jug), address(pot), address(susds), address(conv));

        // Initialize mock rates
        jug.file(ILK, "duty", conv.turn(100)); // 1%
        pot.file("dsr", conv.turn(100)); // 1%
        susds.file("ssr", conv.turn(100)); // 1%

        // Configure DSPC
        dspc.file(ILK, "min", 1);
        dspc.file(ILK, "max", 1000);
        dspc.file(ILK, "step", 200);  // Allow 2% step
        dspc.file("DSR", "min", 1);
        dspc.file("DSR", "max", 1000);
        dspc.file("DSR", "step", 200);  // Allow 2% step
        dspc.file("SSR", "min", 1);
        dspc.file("SSR", "max", 1000);
        dspc.file("SSR", "step", 200);  // Allow 2% step

        // Add test address as facilitator
        dspc.kiss(address(this));
    }

    function test_constructor() public {
        assertEq(address(dspc.jug()), address(jug));
        assertEq(address(dspc.pot()), address(pot));
        assertEq(address(dspc.susds()), address(susds));
        assertEq(address(dspc.conv()), address(conv));
    }

    function test_auth() public {
        assertTrue(dspc.wards(address(this)) == 1);
        dspc.deny(address(this));
        assertTrue(dspc.wards(address(this)) == 0);
        vm.expectRevert("DSPC/not-authorized");
        dspc.rely(address(this));
    }

    function test_file_bad() public {
        dspc.file("bad", 1);
        assertEq(dspc.bad(), 1);
        vm.expectRevert("DSPC/invalid-bad-value");
        dspc.file("bad", 2);
    }

    function test_file_unrecognized() public {
        vm.expectRevert("DSPC/file-unrecognized-param");
        dspc.file("what", 0);
    }

    function test_file_ilk() public {
        dspc.file(ILK, "min", 1);
        dspc.file(ILK, "max", 1000);
        dspc.file(ILK, "step", 100);

        DSPC.Cfg memory cfg = dspc.cfgs(ILK);
        assertEq(cfg.min, 1);
        assertEq(cfg.max, 1000);
        assertEq(cfg.step, 100);
    }

    function test_file_ilk_invalid() public {
        vm.expectRevert("DSPC/invalid-min");
        dspc.file(ILK, "min", 0);

        vm.expectRevert("DSPC/invalid-max");
        dspc.file(ILK, "max", 0);

        vm.expectRevert("DSPC/invalid-step");
        dspc.file(ILK, "step", 0);

        vm.expectRevert("DSPC/file-unrecognized-param");
        dspc.file(ILK, "what", 0);
    }

    function test_put_empty() public {
        vm.expectRevert("DSPC/empty-batch");
        dspc.put(new DSPC.ParamChange[](0));
    }

    function test_put_ilk() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 200);

        dspc.put(updates);

        (uint256 duty,) = jug.ilks(ILK);
        assertEq(conv.back(duty), 200);
    }

    function test_put_dsr() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange("DSR", 200);

        dspc.put(updates);

        assertEq(conv.back(pot.dsr()), 200);
    }

    function test_put_ssr() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange("SSR", 200);

        dspc.put(updates);

        assertEq(conv.back(susds.ssr()), 200);
    }

    function test_put_multiple() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](3);
        updates[0] = DSPC.ParamChange(ILK, 200);
        updates[1] = DSPC.ParamChange("DSR", 200);
        updates[2] = DSPC.ParamChange("SSR", 200);

        dspc.put(updates);

        (uint256 duty,) = jug.ilks(ILK);
        assertEq(conv.back(duty), 200);
        assertEq(conv.back(pot.dsr()), 200);
        assertEq(conv.back(susds.ssr()), 200);
    }

    function test_put_below_min() public {
        dspc.file(ILK, "min", 100);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 50);

        vm.expectRevert("DSPC/below-min");
        dspc.put(updates);
    }

    function test_put_above_max() public {
        dspc.file(ILK, "max", 100);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 150);

        vm.expectRevert("DSPC/above-max");
        dspc.put(updates);
    }

    function test_put_above_step() public {
        dspc.file(ILK, "step", 50);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 151);  // More than 50 bps change from 100

        vm.expectRevert("DSPC/delta-above-step");
        dspc.put(updates);
    }

    function test_put_bad() public {
        dspc.file("bad", 1);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 200);

        vm.expectRevert("DSPC/module-halted");
        dspc.put(updates);
    }

    function test_put_unauthorized() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 200);

        vm.prank(address(0));
        vm.expectRevert("DSPC/not-facilitator");
        dspc.put(updates);
    }

    function test_facilitator_management() public {
        // Test kiss
        dspc.kiss(alice);
        assertEq(dspc.buds(alice), 1);

        // Test diss
        dspc.diss(alice);
        assertEq(dspc.buds(alice), 0);

        // Test unauthorized kiss
        vm.prank(bob);
        vm.expectRevert("DSPC/not-authorized");
        dspc.kiss(alice);

        // Test unauthorized diss
        vm.prank(bob);
        vm.expectRevert("DSPC/not-authorized");
        dspc.diss(alice);
    }
}
