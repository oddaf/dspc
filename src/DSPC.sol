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
}

/// @title Direct Stability Parameters Change Module
/// @notice A module that allows direct changes to stability parameters with constraints
contract DSPC {
    // --- Structs ---
    struct Cfg {
        uint16 min;  // Minimum rate in basis points
        uint16 max;  // Maximum rate in basis points
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
    mapping(address => uint256) public wards; // Admins
    mapping(address => uint256) public buds; // Facilitators
    mapping(bytes32 => Cfg) private _cfgs; // Constraints per rate
    ParamChange[] private _batch; // Pending rate updates
    uint8 public bad; // Circuit breaker
    uint32 public lag; // Timelock duration
    uint64 public eta; // Timestamp when the current batch can be executed

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
    /// @notice Add an admin
    /// @param usr The address to add as an admin
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /// @notice Remove an admin
    /// @param usr The address to remove as an admin
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
        } else revert("DSPC/file-unrecognized-param");

        // Clear any pending batch when configs change
        _pop();

        emit File(id, what, data);
    }

    /// @notice Cancel a pending batch
    function pop() external toll good {
        _pop();
    }

    /// @notice Internal function to cancel a pending batch
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
                oldBps = _back(PotLike(pot).dsr());
            } else if (id == "SSR") {
                oldBps = _back(SUSDSLike(susds).ssr());
            } else {
                (uint256 duty,) = JugLike(jug).ilks(id);
                oldBps = _back(duty);
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

    function _back(uint256 ray) internal pure returns (uint256 bps) {
        // Convert per-second rate to per-year rate using rpow
        uint256 yearlyRate = _rpow(ray, 365 days);
        // Subtract RAY to get the yearly rate delta and convert to basis points
        // Add RAY/2 for rounding: ensures values are rounded up when >= 0.5 and down when < 0.5
        return ((yearlyRate - RAY) * BASIS_POINTS + RAY / 2) / RAY;
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := RAY }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := RAY }
                default { z := x }
                let half := div(RAY, 2) // for rounding.
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, RAY)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
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
