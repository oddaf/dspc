// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "dss-test/DssTest.sol";
import {DSPCMom} from "../src/DSPCMom.sol";
import {DSPC} from "../src/DSPC.sol";
import {ConvMock} from "./mocks/ConvMock.sol";
import {AuthorityMock} from "./mocks/AuthorityMock.sol";

interface ConvLike {
    function turn(uint256 bps) external pure returns (uint256 ray);
    function back(uint256 ray) external pure returns (uint256 bps);
}

interface SUSDSLike {
    function rely(address usr) external;
    function ssr() external view returns (uint256);
    function drip() external;
}

contract DSPCMomIntegrationTest is DssTest {
    address constant CHAINLOG = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    // --- Events ---
    event SetOwner(address indexed owner);
    event SetAuthority(address indexed authority);
    event Halt(address indexed dspc);

    DssInstance dss;
    DSPC dspc;
    DSPCMom mom;
    ConvLike conv;
    SUSDSLike susds;
    AuthorityMock authority;
    address pause;
    address pauseProxy;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant ILK = "ETH-A";
    bytes32 constant DSR = "DSR";
    bytes32 constant SSR = "SSR";

    function setUp() public {
        vm.createSelectFork("mainnet");
        dss = MCD.loadFromChainlog(CHAINLOG);
        pause = dss.chainlog.getAddress("MCD_PAUSE");
        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");
        susds = SUSDSLike(dss.chainlog.getAddress("SUSDS"));

        MCD.giveAdminAccess(dss);

        conv = ConvLike(address(new ConvMock()));

        dspc = new DSPC(
            address(dss.jug),
            address(dss.pot),
            address(susds),
            address(conv)
        );

        vm.startPrank(pauseProxy);
        {
            dss.jug.rely(address(dspc));
            dss.pot.rely(address(dspc));
            SUSDSLike(address(susds)).rely(address(dspc));
        }
        vm.stopPrank();

        dspc.file(ILK, "min", 1);
        dspc.file(ILK, "max", 2000);
        dspc.file(ILK, "step", 50);
        dspc.file(DSR, "min", 1);
        dspc.file(DSR, "max", 2000);
        dspc.file(DSR, "step", 50);
        dspc.file(SSR, "min", 1);
        dspc.file(SSR, "max", 2000);
        dspc.file(SSR, "step", 50);

        mom = new DSPCMom();
        authority = new AuthorityMock();

        dspc.rely(address(mom));

        mom.setOwner(admin);
        authority.rely(admin); 
    }

    function test_constructor() public view {
        assertEq(mom.owner(), admin);
    }

    function test_setOwner() public {
        vm.prank(admin);
        mom.setOwner(alice);
        assertEq(mom.owner(), alice);
    }

    function test_setOwner_unauthorized() public {
        vm.expectRevert("DSPCMom/not-owner");
        mom.setOwner(alice);
    }

    function test_setAuthority() public {
        vm.prank(admin);
        mom.setAuthority(address(authority));
        assertEq(address(mom.authority()), address(authority));
    }

    function test_setAuthority_unauthorized() public {
        vm.expectRevert("DSPCMom/not-owner");
        mom.setAuthority(address(authority));
    }

    function test_halt_unauthorized() public {
        vm.expectRevert("DSPCMom/not-authorized");
        mom.halt(address(dspc));
    }

    function test_halt() public {
        vm.prank(admin);
        mom.halt(address(dspc));
        assertEq(dspc.bad(), 1);
    }    
}
