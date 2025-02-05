// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DSPC} from "./DSPC.sol";
import {RatesMock} from "./mocks/RatesMock.sol";

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
    RatesMock public rates;

    constructor() {
        rates = new RatesMock();
    }

    function turn(uint256 bps) external view returns (uint256) {
        // Get the pre-computed rate from Rates contract
        return rates.rates(bps);
    }
}

contract DSPCHarness is DSPC {
    constructor(address _jug, address _pot, address _susds, address _conv) DSPC(_jug, _pot, _susds, _conv) {}

    function exposed_back(uint256 ray) public pure returns (uint256) {
        return _back(ray);
    }
}

contract DSPCTest is Test, RatesMock {
    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed id, bytes32 indexed what, uint256 data);
    event Put(DSPC.ParamChange[] updates, uint256 eta);
    event Pop(DSPC.ParamChange[] updates);
    event Zap(DSPC.ParamChange[] updates);

    DSPCHarness dspc;
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
        dspc = new DSPCHarness(address(jug), address(pot), address(susds), address(conv));

        // Initialize mock rates
        jug.file(ILK, "duty", conv.turn(100)); // 1%
        pot.file("dsr", conv.turn(50)); // 0.5%
        susds.file("ssr", conv.turn(75)); // 0.75%

        // Configure the module
        dspc.file("lag", 1 days);
        dspc.file(ILK, "min", 1); // 0.01%
        dspc.file(ILK, "max", 1000); // 10%
        dspc.file(ILK, "step", 100); // 1%
        dspc.file("DSR", "min", 1); // 0.01%
        dspc.file("DSR", "max", 800); // 8%
        dspc.file("DSR", "step", 50); // 0.5%
        dspc.file("SSR", "min", 1); // 0.01%
        dspc.file("SSR", "max", 800); // 8%
        dspc.file("SSR", "step", 50); // 0.5%

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

        dspc.file(ILK, "min", 100);
        DSPC.Cfg memory cfg = dspc.cfgs(ILK);
        assertEq(cfg.min, 100);

        vm.expectRevert("DSPC/not-authorized");
        vm.prank(alice);
        dspc.file("lag", 1 days);
    }

    function test_file_clears_pending_batch() public {
        // Setup a pending batch
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 150);
        vm.prank(alice);
        dspc.put(updates);

        // Verify batch exists
        (DSPC.ParamChange[] memory storedUpdates,) = dspc.batch();
        assertEq(storedUpdates.length, 1);

        // File operation should clear the batch
        dspc.file("lag", 2 days);

        // Verify batch was cleared
        (storedUpdates,) = dspc.batch();
        assertEq(storedUpdates.length, 0);
    }

    function test_file_with_params_clears_pending_batch() public {
        // Setup a pending batch
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 150);
        vm.prank(alice);
        dspc.put(updates);

        // Verify batch exists
        (DSPC.ParamChange[] memory storedUpdates,) = dspc.batch();
        assertEq(storedUpdates.length, 1);

        // File operation with params should clear the batch
        dspc.file(ILK, "max", 900);

        // Verify batch was cleared
        (storedUpdates,) = dspc.batch();
        assertEq(storedUpdates.length, 0);
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
        vm.expectRevert("DSPC/above-max");
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
        dspc.file("bad", 1);
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
        emit File(ILK, "step", 200);

        // Change a config parameter (as admin)
        vm.prank(address(this)); // Test contract is admin
        dspc.file(ILK, "step", 200); // Change gap from 1% to 2%

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

    function test_back() public view {
        uint256[] memory validKeys = new uint256[](450);
        uint256 idx;

        // Add all keys that exist in the mapping
        validKeys[idx++] = 0;
        validKeys[idx++] = 1;
        validKeys[idx++] = 2;
        validKeys[idx++] = 5;
        validKeys[idx++] = 6;
        validKeys[idx++] = 10;
        validKeys[idx++] = 25;
        validKeys[idx++] = 50;
        validKeys[idx++] = 75;
        validKeys[idx++] = 100;
        validKeys[idx++] = 125;
        validKeys[idx++] = 133;
        validKeys[idx++] = 150;
        validKeys[idx++] = 175;
        validKeys[idx++] = 200;
        validKeys[idx++] = 225;
        validKeys[idx++] = 250;
        validKeys[idx++] = 275;
        validKeys[idx++] = 300;
        validKeys[idx++] = 319;
        validKeys[idx++] = 325;
        validKeys[idx++] = 333;
        validKeys[idx++] = 344;
        validKeys[idx++] = 345;
        validKeys[idx++] = 349;
        validKeys[idx++] = 350;
        validKeys[idx++] = 358;
        validKeys[idx++] = 370;
        validKeys[idx++] = 374;
        validKeys[idx++] = 375;
        validKeys[idx++] = 394;
        validKeys[idx++] = 400;
        validKeys[idx++] = 408;
        validKeys[idx++] = 420;
        validKeys[idx++] = 424;
        validKeys[idx++] = 425;
        validKeys[idx++] = 450;
        validKeys[idx++] = 475;
        validKeys[idx++] = 490;
        validKeys[idx++] = 500;
        validKeys[idx++] = 520;
        validKeys[idx++] = 525;
        validKeys[idx++] = 537;
        validKeys[idx++] = 544;
        validKeys[idx++] = 550;
        validKeys[idx++] = 554;
        validKeys[idx++] = 555;
        validKeys[idx++] = 561;
        validKeys[idx++] = 569;
        validKeys[idx++] = 575;
        validKeys[idx++] = 579;
        validKeys[idx++] = 580;
        validKeys[idx++] = 586;
        validKeys[idx++] = 600;
        validKeys[idx++] = 616;
        validKeys[idx++] = 619;
        validKeys[idx++] = 625;
        validKeys[idx++] = 629;
        validKeys[idx++] = 630;
        validKeys[idx++] = 636;
        validKeys[idx++] = 640;
        validKeys[idx++] = 641;
        validKeys[idx++] = 643;
        validKeys[idx++] = 645;
        validKeys[idx++] = 649;
        validKeys[idx++] = 650;
        validKeys[idx++] = 665;
        validKeys[idx++] = 668;
        validKeys[idx++] = 670;
        validKeys[idx++] = 674;
        validKeys[idx++] = 675;
        validKeys[idx++] = 691;
        validKeys[idx++] = 700;
        validKeys[idx++] = 716;
        validKeys[idx++] = 718;
        validKeys[idx++] = 720;
        validKeys[idx++] = 724;
        validKeys[idx++] = 725;
        validKeys[idx++] = 750;
        validKeys[idx++] = 775;
        validKeys[idx++] = 800;
        validKeys[idx++] = 825;
        validKeys[idx++] = 850;
        validKeys[idx++] = 875;
        validKeys[idx++] = 900;
        validKeys[idx++] = 925;
        validKeys[idx++] = 931;
        validKeys[idx++] = 950;
        validKeys[idx++] = 975;
        validKeys[idx++] = 1000;

        // Add all remaining multiples of 25 from 1025 to 10000
        for (uint256 i = 1025; i <= 10000; i += 25) {
            validKeys[idx++] = i;
        }

        // Test all valid keys
        for (uint256 i = 0; i < validKeys.length; i++) {
            uint256 key = validKeys[i];
            uint256 rate = rates[key];
            require(rate > 0, string(abi.encodePacked("Rate not found for key: ", vm.toString(key))));

            uint256 bps = dspc.exposed_back(rate);
            assertEq(bps, key, string(abi.encodePacked("Incorrect BPS conversion for rate index: ", vm.toString(key))));
        }
    }
}
