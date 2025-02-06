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

    // --- Constants ---
    uint256 internal constant RAY = 10 ** 27;
    uint256 internal constant WAD = 10 ** 18;
    uint256 internal constant BASIS_POINTS = 100_00;

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
    /// @notice Circuit breaker flag
    uint256 public bad;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed id, bytes32 indexed what, uint256 data);
    event Set(ParamChange[] updates);

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
        if (what == "bad") {
            require(data <= 1, "DSPC/invalid-bad-value");
            bad = data;
        } else {
            revert("DSPC/file-unrecognized-param");
        }

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

        emit File(id, what, data);
    }

    /// @notice Set and apply rate updates immediately
    function set(ParamChange[] calldata updates) external toll good {
        require(updates.length > 0, "DSPC/empty-batch");

        // Validate and execute all updates
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

            // Calculate absolute difference between new and old rate, and ensure it doesn't exceed maximum allowed change
            uint256 delta = bps > oldBps ? bps - oldBps : oldBps - bps;
            require(delta <= cfg.step, "DSPC/delta-above-step");

            // Apply the update immediately
            uint256 ray = conv.turn(bps);
            if (id == "DSR") {
                pot.file("dsr", ray);
            } else if (id == "SSR") {
                susds.file("ssr", ray);
            } else {
                jug.file(id, "duty", ray);
            }
        }

        emit Set(updates);
    }

    // --- Getters ---
    /// @notice Get configuration for a rate
    /// @param id The rate identifier
    /// @return The configuration struct
    function cfgs(bytes32 id) external view returns (Cfg memory) {
        return _cfgs[id];
    }
}
