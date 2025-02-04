// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title Authority Mock - Mock implementation of DSAuthority for testing
contract AuthorityMock {
    // --- Auth ---
    mapping(address => uint256) public wards;  // Admins

    // --- Access Control ---
    mapping(address => mapping(address => mapping(bytes4 => uint256))) private _canCall;  // src -> dst -> sig -> enabled

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event SetCanCall(address indexed src, address indexed dst, bytes4 indexed sig, bool enabled);

    // --- Modifiers ---
    modifier auth {
        require(wards[msg.sender] == 1, "AuthorityMock/not-authorized");
        _;
    }

    constructor() {
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

    // --- Permission Management ---
    /// @notice Set whether a source address can call a specific function on a target contract
    /// @param src The source address that wants to make the call
    /// @param dst The target contract address
    /// @param sig The function signature
    /// @param enabled Whether to enable or disable the permission
    function setCanCall(
        address src,
        address dst,
        bytes4 sig,
        bool enabled
    ) external auth {
        _canCall[src][dst][sig] = enabled ? 1 : 0;
        emit SetCanCall(src, dst, sig, enabled);
    }

    /// @notice Check if a source address can call a specific function on a target contract
    /// @param src The source address that wants to make the call
    /// @param dst The target contract address
    /// @param sig The function signature
    /// @return Whether the call is permitted
    function canCall(
        address src,
        address dst,
        bytes4 sig
    ) external view returns (bool) {
        return _canCall[src][dst][sig] == 1;
    }
}
