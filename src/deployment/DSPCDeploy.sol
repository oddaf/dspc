// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {DSPC} from "../DSPC.sol";
import {DSPCMom} from "../DSPCMom.sol";
import {DSPCInstance} from "./DSPCInstance.sol";

struct DSPCDeployParams {
    address deployer;
    address owner;
    address jug;
    address pot;
    address susds;
    address conv;
}

library DSPCDeploy {
    function deploy(DSPCDeployParams memory params) internal returns (DSPCInstance memory inst) {
        // Deploy DSPC
        inst.dspc = new DSPC(
            params.jug,
            params.pot,
            params.susds,
            params.conv
        );

        // Deploy Mom
        inst.mom = new DSPCMom();

        // Set up permissions
        inst.dspc.rely(address(inst.mom));
        inst.mom.setOwner(params.owner);
    }
}
