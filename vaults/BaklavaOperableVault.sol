// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.10;

import {BaklavaGovernableVault} from "./BaklavaGovernableVault.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

abstract contract BaklavaOperableVault is
    BaklavaGovernableVault,
    ERC4626Upgradeable
{
    function deposit(
        uint256 _assets,
        address _receiver
    ) public virtual override onlyRole(OPERATOR_ROLE) returns (uint256) {
        return super.deposit(_assets, _receiver);
    }

    function mint(
        uint256 _shares,
        address _receiver
    ) public virtual override onlyRole(OPERATOR_ROLE) returns (uint256) {
        return super.mint(_shares, _receiver);
    }

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) public virtual override onlyRole(OPERATOR_ROLE) returns (uint256) {
        return super.withdraw(_assets, _receiver, _owner);
    }

    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) public virtual override onlyRole(OPERATOR_ROLE) returns (uint256) {
        return super.redeem(_shares, _receiver, _owner);
    }
}
