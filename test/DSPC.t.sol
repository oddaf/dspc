// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "dss-test/DssTest.sol";
import {DSPC} from "../src/DSPC.sol";
import {DSPCMom} from "../src/DSPCMom.sol";
import {ConvMock} from "./mocks/ConvMock.sol";
import {DSPCDeploy, DSPCDeployParams} from "../src/deployment/DSPCDeploy.sol";
import {DSPCInstance} from "../src/deployment/DSPCInstance.sol";

interface ConvLike {
    function turn(uint256 bps) external pure returns (uint256 ray);
    function back(uint256 ray) external pure returns (uint256 bps);
}

interface SUSDSLike {
    function rely(address usr) external;
    function ssr() external view returns (uint256);
    function drip() external;
}

contract DSPCTest is DssTest {
    address constant CHAINLOG = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    DssInstance dss;
    DSPC dspc;
    DSPCMom mom;
    ConvLike conv;
    SUSDSLike susds;
    address pause;
    address pauseProxy;

    bytes32 constant ILK = "ETH-A";
    bytes32 constant DSR = "DSR";
    bytes32 constant SSR = "SSR";

    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed id, bytes32 indexed what, uint256 data);
    event Put(DSPC.ParamChange[] updates);

    function setUp() public {
        vm.createSelectFork("mainnet");
        dss = MCD.loadFromChainlog(CHAINLOG);
        pause = dss.chainlog.getAddress("MCD_PAUSE");
        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");
        susds = SUSDSLike(dss.chainlog.getAddress("SUSDS"));

        MCD.giveAdminAccess(dss);

        conv = ConvLike(address(new ConvMock()));

        DSPCInstance memory inst = DSPCDeploy.deploy(
            DSPCDeployParams({
                deployer: address(this),
                owner: address(this),
                authority: address(dss.chainlog.getAddress("MCD_ADM")),
                jug: address(dss.jug),
                pot: address(dss.pot),
                susds: address(susds),
                conv: address(conv)
            })
        );
        dspc = inst.dspc;
        mom = inst.mom;

        vm.startPrank(pauseProxy);
        {
            dss.jug.rely(address(dspc));
            dss.pot.rely(address(dspc));
            SUSDSLike(address(susds)).rely(address(dspc));
        }
        vm.stopPrank();

        dspc.file(ILK, "min", 1);
        dspc.file(ILK, "max", 30000);
        dspc.file(ILK, "step", 50);
        dspc.file(DSR, "min", 1);
        dspc.file(DSR, "max", 30000);
        dspc.file(DSR, "step", 50);
        dspc.file(SSR, "min", 1);
        dspc.file(SSR, "max", 30000);
        dspc.file(SSR, "step", 50);
    }

    function test_constructor() public view {
        assertEq(address(dspc.jug()), address(dss.jug));
        assertEq(address(dspc.pot()), address(dss.pot));
        assertEq(address(dspc.susds()), address(susds));
        assertEq(address(dspc.conv()), address(conv));
        assertEq(dspc.wards(address(this)), 1);
    }

    function test_auth() public {
        checkAuth(address(dspc), "DSPC");
    }

    function test_file_bad() public {
        assertEq(dspc.bad(), 0);
        dspc.file("bad", 1);
        assertEq(dspc.bad(), 1);

        vm.expectRevert("DSPC/invalid-bad-value");
        dspc.file("bad", 2);

        vm.expectRevert("DSPC/file-unrecognized-param");
        dspc.file("unknown", 1);
    }

    function test_file_ilk() public {
        assertEq(dspc.cfgs(ILK).min, 1);
        assertEq(dspc.cfgs(ILK).max, 30000);
        assertEq(dspc.cfgs(ILK).step, 50);

        dspc.file(ILK, "min", 100);
        dspc.file(ILK, "max", 3000);
        dspc.file(ILK, "step", 100);

        assertEq(dspc.cfgs(ILK).min, 100);
        assertEq(dspc.cfgs(ILK).max, 3000);
        assertEq(dspc.cfgs(ILK).step, 100);
    }

    function test_file_ilk_invalid() public {
        vm.expectRevert("DSPC/invalid-min");
        dspc.file(ILK, "min", 0);

        vm.expectRevert("DSPC/invalid-max");
        dspc.file(ILK, "max", 0);

        vm.expectRevert("DSPC/invalid-step");
        dspc.file(ILK, "step", 0);

        vm.expectRevert("DSPC/file-unrecognized-param");
        dspc.file(ILK, "unknown", 100);
    }

    function test_put_ilk() public {
        dspc.kiss(address(this));
        (uint256 duty,) = dss.jug.ilks(ILK);
        uint256 target = conv.back(duty) + 50;
        dss.jug.drip(ILK);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, target);

        dspc.put(updates);

        (duty,) = dss.jug.ilks(ILK);
        assertEq(duty, conv.turn(target));
    }

    function test_put_dsr() public {
        dspc.kiss(address(this));
        uint256 target = conv.back(dss.pot.dsr()) + 50;
        dss.pot.drip();

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(DSR, target);  

        dspc.put(updates);

        assertEq(dss.pot.dsr(), conv.turn(target));
    }

    function test_put_ssr() public {
        dspc.kiss(address(this));
        uint256 target = conv.back(susds.ssr()) - 50;
        susds.drip();

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(SSR, target);

        dspc.put(updates);

        assertEq(susds.ssr(), conv.turn(target));
    }

    function test_put_multiple() public {
        dspc.kiss(address(this));

        (uint256 duty,) = dss.jug.ilks(ILK);
        uint256 ilkTarget = conv.back(duty) - 50;
        uint256 dsrTarget = conv.back(dss.pot.dsr()) - 50;
        uint256 ssrTarget = conv.back(susds.ssr()) + 50;

        dss.jug.drip(ILK);
        dss.pot.drip();
        susds.drip();

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](3);
        updates[0] = DSPC.ParamChange(ILK, ilkTarget);      
        updates[1] = DSPC.ParamChange(DSR, dsrTarget);  
        updates[2] = DSPC.ParamChange(SSR, ssrTarget);  

        dspc.put(updates);

        (duty,) = dss.jug.ilks(ILK);
        assertEq(duty, conv.turn(ilkTarget));
        assertEq(dss.pot.dsr(), conv.turn(dsrTarget));
        assertEq(susds.ssr(), conv.turn(ssrTarget));
    }

    function test_put_empty() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](0);

        dspc.kiss(address(this));
        vm.expectRevert("DSPC/empty-batch");
        dspc.put(updates);
    }

    function test_put_unauthorized() public {
        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 100);

        vm.expectRevert("DSPC/not-facilitator");
        dspc.put(updates);
    }

    function test_put_below_min() public {
        dspc.file(ILK, "min", 100);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 50);

        dspc.kiss(address(this));
        vm.expectRevert("DSPC/below-min");
        dspc.put(updates);
    }

    function test_put_above_max() public {
        dspc.file(ILK, "max", 100);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 150);

        dspc.kiss(address(this));
        vm.expectRevert("DSPC/above-max");
        dspc.put(updates);
    }

    function test_put_above_step() public {
        dspc.file(ILK, "step", 50);

        DSPC.ParamChange[] memory updates = new DSPC.ParamChange[](1);
        updates[0] = DSPC.ParamChange(ILK, 100);

        dspc.kiss(address(this));
        vm.expectRevert("DSPC/delta-above-step");
        dspc.put(updates);
    }
}
