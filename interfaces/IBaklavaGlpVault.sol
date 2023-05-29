// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";

interface IBaklavaGlpVault is IERC4626Upgradeable {
    function burn(address _user, uint256 _amount) external;

    function totalUnderlyingAssets() view external returns (uint256);

    function borrow(uint256 _amount) external returns (uint256);

    function repay(uint256 _amount) external returns (uint256);

}