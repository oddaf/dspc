// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DSPC} from "./DSPC.sol";
import {Rates} from "./test/Rates.sol";

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
    uint256 constant RAY = 1e27;
    Rates public rates;

    constructor() {
        rates = new Rates();
    }

    function turn(uint256 bps) external view returns (uint256) {
        // Get the pre-computed rate from Rates contract
        return rates.rates(bps);
    }
}

contract DSPCTest is Test {
    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed id, bytes32 indexed what, uint256 data);
    event Put(DSPC.ParamChange[] updates, uint256 eta);
    event Pop(DSPC.ParamChange[] updates);
    event Zap();
    event Halt();

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
        pot.file("dsr", conv.turn(50)); // 0.5%
        susds.file("ssr", conv.turn(75)); // 0.75%

        // Configure the module
        dspc.file("lag", 1 days);
        dspc.file(ILK, "loCapBps", 1); // 0.01%
        dspc.file(ILK, "hiCapBps", 1000); // 10%
        dspc.file(ILK, "gapBps", 100); // 1%
        dspc.file("DSR", "loCapBps", 1); // 0.01%
        dspc.file("DSR", "hiCapBps", 800); // 8%
        dspc.file("DSR", "gapBps", 50); // 0.5%
        dspc.file("SSR", "loCapBps", 1); // 0.01%
        dspc.file("SSR", "hiCapBps", 800); // 8%
        dspc.file("SSR", "gapBps", 50); // 0.5%

        // Add alice as a facilitator
        dspc.kiss(alice);
    }

    function test_constructor() public view {
        assertEq(address(dspc.jug()), address(jug));
        assertEq(address(dspc.pot()), address(pot));
        assertEq(address(dspc.susds()), address(susds));
        assertEq(address(dspc.conv()), address(conv));
        assertEq(dspc.wards(admin), 1);
    }

    function test_auth() public {
        // Admin functions
        dspc.rely(bob);
        assertEq(dspc.wards(bob), 1);
        dspc.deny(bob);
        assertEq(dspc.wards(bob), 0);
        dspc.kiss(bob);
        assertEq(dspc.buds(bob), 1);
        dspc.diss(bob);
        assertEq(dspc.buds(bob), 0);

        vm.expectRevert("DSPC/not-authorized");
        vm.prank(alice);
        dspc.rely(bob);
    }

    function test_file() public {
        dspc.file("lag", 2 days);
        assertEq(dspc.lag(), 2 days);

        dspc.file(ILK, "loCapBps", 100);
        DSPC.Cfg memory cfg = dspc.cfgs(ILK);
        assertEq(cfg.loCapBps, 100);

        vm.expectRevert("DSPC/not-authorized");
        vm.prank(alice);
        dspc.file("lag", 1 days);
    }

    function test_put() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](3);
        updates[0] = DSPC.ParamChange(ILK, 150); // From 1% to 1.5% (within 1% gap)
        updates[1] = DSPC.ParamChange("DSR", 75); // From 0.5% to 0.75% (within 0.5% gap)
        updates[2] = DSPC.ParamChange("SSR", 100); // From 0.75% to 1% (within 0.5% gap)

        vm.prank(alice);
        dspc.put(updates);

        (DSPC.ParamChange[] memory storedUpdates, uint256 eta) = dspc.batch();
        assertEq(storedUpdates.length, 3);
        assertEq(eta, block.timestamp + 1 days);
    }

    function test_RevertWhen_NotFacilitator() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 500);

        vm.prank(bob);
        vm.expectRevert("DSPC/not-facilitator");
        dspc.put(updates);
    }

    function test_RevertWhen_AboveCap() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 1100); // 11%

        vm.prank(alice);
        vm.expectRevert("DSPC/above-hiCapBps");
        dspc.put(updates);
    }

    function test_pop() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 150); // From 1% to 1.5% (within 1% gap)

        vm.prank(alice);
        dspc.put(updates);

        vm.prank(alice);
        dspc.pop();

        (DSPC.ParamChange[] memory storedUpdates,) = dspc.batch();
        assertEq(storedUpdates.length, 0);
    }

    function test_zap() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](3);
        updates[0] = DSPC.ParamChange(ILK, 150); // From 1% to 1.5% (within 1% gap)
        updates[1] = DSPC.ParamChange("DSR", 75); // From 0.5% to 0.75% (within 0.5% gap)
        updates[2] = DSPC.ParamChange("SSR", 100); // From 0.75% to 1% (within 0.5% gap)

        vm.prank(alice);
        dspc.put(updates);

        // Wait for the timelock
        vm.warp(block.timestamp + 1 days);

        dspc.zap();

        // Check rates were updated
        assertEq(jug.duty(ILK), conv.turn(150));
        assertEq(pot.dsr(), conv.turn(75));
        assertEq(susds.ssr(), conv.turn(100));
    }

    function test_RevertWhen_ZapTooEarly() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 150); // From 1% to 1.5% (within 1% gap)

        vm.prank(alice);
        dspc.put(updates);

        // Try to zap before timelock expires
        vm.expectRevert("DSPC/batch-not-ready");
        dspc.zap();
    }

    function test_halt() public {
        dspc.halt();
        assertEq(dspc.bad(), 1);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 150);

        vm.expectRevert("DSPC/module-halted");
        vm.prank(alice);
        dspc.put(updates);
    }

    function test_file_clears_pending_updates() public {
        // First put some updates
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](3);
        updates[0] = DSPC.ParamChange(ILK, 150); // From 1% to 1.5% (within 1% gap)
        updates[1] = DSPC.ParamChange("DSR", 75); // From 0.5% to 0.75% (within 0.5% gap)
        updates[2] = DSPC.ParamChange("SSR", 100); // From 0.75% to 1% (within 0.5% gap)

        vm.prank(alice);
        dspc.put(updates);

        // Verify updates are stored
        (DSPC.ParamChange[] memory storedUpdates, uint256 eta) = dspc.batch();
        assertEq(storedUpdates.length, 3);
        assertEq(eta, block.timestamp + 1 days);

        // Expect Pop and File events when config changes
        vm.expectEmit(true, true, true, true);
        emit Pop(storedUpdates);
        vm.expectEmit(true, true, true, true);
        emit File(ILK, "gapBps", 200);

        // Change a config parameter (as admin)
        vm.prank(address(this)); // Test contract is admin
        dspc.file(ILK, "gapBps", 200); // Change gap from 1% to 2%

        // Verify updates were cleared
        (storedUpdates, eta) = dspc.batch();
        assertEq(storedUpdates.length, 0);
        assertEq(eta, 0);

        // Verify we can put new updates after config change
        updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 200); // Now allowed with new 2% gap

        vm.prank(alice);
        dspc.put(updates);

        (storedUpdates, eta) = dspc.batch();
        assertEq(storedUpdates.length, 1);
        assertEq(eta, block.timestamp + 1 days);
    }
}
