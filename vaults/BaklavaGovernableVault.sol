// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.10;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract BaklavaGovernableVault is AccessControlUpgradeable {

    bytes32 public constant GOVERNOR_ROLE = bytes32("GOVERNOR_ROLE");
    bytes32 public constant OWNER_ROLE = bytes32("OWNER_ROLE");
    bytes32 public constant OPERATOR_ROLE = bytes32("OPERATOR_ROLE");
    bytes32 public constant BORROWER_ROLE = bytes32("BORROWER_ROLE");

    function __LS1Roles_init(address _owner, address _governor) internal {
        // Assign roles to the sender.
        _grantRole(OWNER_ROLE, _owner);
        _grantRole(GOVERNOR_ROLE, _governor);

        // Set OWNER_ROLE as the admin of all roles.
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
        _setRoleAdmin(GOVERNOR_ROLE, OWNER_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(BORROWER_ROLE, GOVERNOR_ROLE);
    }
}