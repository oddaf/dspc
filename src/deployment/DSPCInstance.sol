// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {DSPC} from "../DSPC.sol";
import {DSPCMom} from "../DSPCMom.sol";

struct DSPCInstance {
    DSPC dspc;
    DSPCMom mom;
}
