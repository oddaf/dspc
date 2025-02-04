// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../DSPC.sol";
import "./Rates.sol";

contract MockJug {
    function file(bytes32, bytes32, uint256) external {}

    function ilks(bytes32) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

contract MockPot {
    function file(bytes32, uint256) external {}

    function dsr() external pure returns (uint256) {
        return 0;
    }
}

contract MockSusds {
    function file(bytes32, uint256) external {}

    function ssr() external pure returns (uint256) {
        return 0;
    }
}

contract MockConv {
    function turn(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract DSPCHarness is DSPC {
    constructor(address _jug, address _pot, address _susds, address _conv) DSPC(_jug, _pot, _susds, _conv) {}

    function exposed_back(uint256 ray) public pure returns (uint256) {
        return _back(ray);
    }
}

contract RayToBpsTest is Test, Rates {
    DSPCHarness dspc;
    MockJug jug;
    MockPot pot;
    MockSusds susds;
    MockConv conv;

    function setUp() public {
        jug = new MockJug();
        pot = new MockPot();
        susds = new MockSusds();
        conv = new MockConv();

        dspc = new DSPCHarness(address(jug), address(pot), address(susds), address(conv));
    }

    function test_back() public {
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
