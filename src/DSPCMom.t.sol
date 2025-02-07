// SPDX-FileCopyrightText: 2025 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.24;

import "dss-test/DssTest.sol";
import {DSPC} from "./DSPC.sol";
import {DSPCMom} from "./DSPCMom.sol";
import {ConvMock} from "./mocks/ConvMock.sol";
import {DSPCDeploy, DSPCDeployParams} from "./deployment/DSPCDeploy.sol";
import {DSPCInstance} from "./deployment/DSPCInstance.sol";

interface ChiefLike {
    function hat() external view returns (address);
}

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
    ChiefLike chief;
    DSPC dspc;
    DSPCMom mom;
    ConvLike conv;
    SUSDSLike susds;
    address pause;
    address pauseProxy;

    bytes32 constant ILK = "ETH-A";
    bytes32 constant DSR = "DSR";
    bytes32 constant SSR = "SSR";

    function setUp() public {
        vm.createSelectFork("mainnet");
        dss = MCD.loadFromChainlog(CHAINLOG);
        chief = ChiefLike(dss.chainlog.getAddress("MCD_ADM"));
        pause = dss.chainlog.getAddress("MCD_PAUSE");
        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");
        susds = SUSDSLike(dss.chainlog.getAddress("SUSDS"));

        MCD.giveAdminAccess(dss);

        conv = ConvLike(address(new ConvMock()));

        DSPCInstance memory inst = DSPCDeploy.deploy(
            DSPCDeployParams({
                deployer: address(this),
                owner: address(this),
                authority: address(chief),
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
        dspc.file(ILK, "max", 2000);
        dspc.file(ILK, "step", 50);
        dspc.file(DSR, "min", 1);
        dspc.file(DSR, "max", 2000);
        dspc.file(DSR, "step", 50);
        dspc.file(SSR, "min", 1);
        dspc.file(SSR, "max", 2000);
        dspc.file(SSR, "step", 50);
    }

    function test_constructor() public view {
        assertEq(mom.owner(), address(this));
    }

    function test_setOwner() public {
        mom.setOwner(address(0x1234));
        assertEq(mom.owner(), address(0x1234));
    }

    function test_setOwner_unauthorized() public {
        vm.prank(address(0x0ddaf));
        vm.expectRevert("DSPCMom/not-owner");
        mom.setOwner(address(0x123));
    }

    function test_setAuthority() public {
        mom.setAuthority(address(0x123));
        assertEq(address(mom.authority()), address(0x123));
    }

    function test_setAuthority_unauthorized() public {
        vm.prank(address(0x0ddaf));
        vm.expectRevert("DSPCMom/not-owner");
        mom.setAuthority(address(0x123));
    }

    function test_halt_unauthorized() public {
        vm.prank(address(0x0ddaf));
        vm.expectRevert("DSPCMom/not-authorized");
        mom.halt(address(dspc));
    }

    function test_halt_owner() public {
        mom.halt(address(dspc));
        assertEq(dspc.bad(), 1);
    }

    function test_halt_hat() public {
        vm.prank(chief.hat());
        mom.halt(address(dspc));
        assertEq(dspc.bad(), 1);
    }
}
