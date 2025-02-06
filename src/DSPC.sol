// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface JugLike {
    function file(bytes32 ilk, bytes32 what, uint256 data) external;
    function ilks(bytes32) external view returns (uint256 duty, uint256 rho);
}

interface PotLike {
    function file(bytes32 what, uint256 data) external;
    function dsr() external view returns (uint256);
}

interface SUSDSLike {
    function file(bytes32 what, uint256 data) external;
    function ssr() external view returns (uint256);
}

interface ConvLike {
    function turn(uint256 bps) external pure returns (uint256 ray);
    function back(uint256 ray) external pure returns (uint256 bps);
}

/// @title Direct Stability Parameters Change Module
/// @notice A module that allows direct changes to stability parameters with constraints
contract DSPC {
    // --- Structs ---
    struct Cfg {
        uint16 min; // Minimum rate in basis points
        uint16 max; // Maximum rate in basis points
        uint16 step; // Maximum rate change in basis points
    }

    struct ParamChange {
        bytes32 id; // Identifier (ilk | "DSR" | "SSR")
        uint256 bps; // New rate in basis points
    }

    // --- Immutables ---
    JugLike public immutable jug; // Stability fee rates
    PotLike public immutable pot; // DSR rate
    SUSDSLike public immutable susds; // SSR rate
    ConvLike public immutable conv; // Rate conversion utility

    // --- Storage Variables ---
    /// @notice Mapping of admin addresses
    mapping(address => uint256) public wards;
    /// @notice Mapping of addresses that can operate this module
    mapping(address => uint256) public buds;
    /// @notice Mapping of rate constraints
    mapping(bytes32 => Cfg) private _cfgs;
    /// @notice Pending rate updates
    ParamChange[] private _batch;
    /// @notice Circuit breaker flag
    uint8 public bad;
    /// @notice Timelock duration
    uint32 public lag;
    /// @notice Timestamp when current batch can be executed
    uint64 public eta;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed id, bytes32 indexed what, uint256 data);
    event Put(ParamChange[] updates, uint256 eta);
    event Pop(ParamChange[] updates);
    event Zap(ParamChange[] updates);

    // --- Modifiers ---
    modifier auth() {
        require(wards[msg.sender] == 1, "DSPC/not-authorized");
        _;
    }

    modifier toll() {
        require(buds[msg.sender] == 1, "DSPC/not-facilitator");
        _;
    }

    modifier good() {
        require(bad == 0, "DSPC/module-halted");
        _;
    }

    /// @notice Constructor sets the core contracts
    constructor(address _jug, address _pot, address _susds, address _conv) {
        jug = JugLike(_jug);
        pot = PotLike(_pot);
        susds = SUSDSLike(_susds);
        conv = ConvLike(_conv);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    /// @notice Grant authorization to an address
    /// @param usr The address to be authorized
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /// @notice Revoke authorization from an address
    /// @param usr The address to be deauthorized
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    /// @notice Add a facilitator
    /// @param usr The address to add as a facilitator
    /// @dev Facilitators can propose rate updates but cannot modify system parameters
    function kiss(address usr) external auth {
        buds[usr] = 1;
        emit Kiss(usr);
    }

    /// @notice Remove a facilitator
    /// @param usr The address to remove as a facilitator
    function diss(address usr) external auth {
        buds[usr] = 0;
        emit Diss(usr);
    }

    /// @notice Configure module parameters
    function file(bytes32 what, uint256 data) external auth {
        if (what == "lag") {
            require(data <= type(uint32).max, "DSPC/lag-overflow");
            lag = uint32(data);
        } else if (what == "bad") {
            require(data <= 1, "DSPC/invalid-bad-value");
            bad = uint8(data);
        } else {
            revert("DSPC/file-unrecognized-param");
        }

        // Clear any pending batch when configs change
        _pop();

        emit File(what, data);
    }

    /// @notice Configure constraints for a rate
    function file(bytes32 id, bytes32 what, uint256 data) external auth {
        require(data <= type(uint16).max, "DSPC/overflow");
        if (what == "min") {
            require(data > 0, "DSPC/invalid-min");
            _cfgs[id].min = uint16(data);
        } else if (what == "max") {
            require(data > 0, "DSPC/invalid-max");
            _cfgs[id].max = uint16(data);
        } else if (what == "step") {
            require(data > 0, "DSPC/invalid-step");
            _cfgs[id].step = uint16(data);
        } else {
            revert("DSPC/file-unrecognized-param");
        }

        // Clear any pending batch when configs change
        _pop();

        emit File(id, what, data);
    }

    /// @notice Cancel a pending batch
    function pop() external toll good {
        _pop();
    }

    /// @notice Internal function to cancel a pending batch
    /// @dev Clears the pending batch and resets the activation time
    function _pop() internal {
        if (_batch.length > 0) {
            emit Pop(_batch);
            delete _batch;
            eta = 0;
        }
    }

    /// @notice Schedule a batch of rate updates
    function put(ParamChange[] calldata updates) external toll good {
        require(updates.length > 0, "DSPC/empty-batch");

        // Validate all updates in the batch
        for (uint256 i = 0; i < updates.length; i++) {
            bytes32 id = updates[i].id;
            uint256 bps = updates[i].bps;
            Cfg memory cfg = _cfgs[id];

            require(bps >= cfg.min, "DSPC/below-min");
            require(bps <= cfg.max, "DSPC/above-max");

            // Check rate change is within allowed gap
            uint256 oldBps;
            if (id == "DSR") {
                oldBps = conv.back(PotLike(pot).dsr());
            } else if (id == "SSR") {
                oldBps = conv.back(SUSDSLike(susds).ssr());
            } else {
                (uint256 duty,) = JugLike(jug).ilks(id);
                oldBps = conv.back(duty);
            }

            uint256 delta = bps > oldBps ? bps - oldBps : oldBps - bps;
            require(delta <= cfg.step, "DSPC/delta-above-step");
        }

        // Store the batch
        delete _batch;
        for (uint256 i = 0; i < updates.length; i++) {
            _batch.push(updates[i]);
        }
        eta = uint64(block.timestamp + lag);

        emit Put(updates, eta);
    }

    /// @notice Execute a pending batch
    function zap() external good {
        require(_batch.length > 0, "DSPC/no-pending-batch");
        require(block.timestamp >= eta, "DSPC/batch-not-ready");

        ParamChange[] memory updates = _batch;

        // Execute all updates
        for (uint256 i = 0; i < updates.length; i++) {
            bytes32 id = updates[i].id;
            uint256 ray = conv.turn(updates[i].bps);

            if (id == "DSR") {
                pot.file("dsr", ray);
            } else if (id == "SSR") {
                susds.file("ssr", ray);
            } else {
                jug.file(id, "duty", ray);
            }
        }

        delete _batch;
        eta = 0;
        emit Zap(updates);
    }

    // --- Getters ---
    /// @notice Get configuration for a rate
    /// @param id The rate identifier
    /// @return The configuration struct
    function cfgs(bytes32 id) external view returns (Cfg memory) {
        return _cfgs[id];
    }

    /// @notice Get current pending batch
    /// @return batch The array of pending rate updates
    /// @return eta The timestamp when the batch becomes executable
    function batch() external view returns (ParamChange[] memory, uint256) {
        return (_batch, eta);
    }
}
