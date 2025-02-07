// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {ScriptTools} from "dss-test/ScriptTools.sol";
import {DSPC} from "../DSPC.sol";
import {DSPCMom} from "../DSPCMom.sol";
import {DSPCInstance} from "./DSPCInstance.sol";

struct DSPCDeployParams {
    address deployer;
    address owner;
    address authority;
    address jug;
    address pot;
    address susds;
    address conv;
}

library DSPCDeploy {
    function deploy(DSPCDeployParams memory params) internal returns (DSPCInstance memory inst) {
        inst.dspc = new DSPC(
            params.jug,
            params.pot,
            params.susds,
            params.conv
        );

        inst.mom = new DSPCMom();

        inst.dspc.rely(address(inst.mom));
        inst.mom.setAuthority(params.authority);
        ScriptTools.switchOwner(address(inst.dspc), params.deployer, params.owner);
        inst.mom.setOwner(params.owner);
    }
}
