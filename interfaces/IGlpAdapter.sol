// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IGlpAdapter {
    function depositGlp(uint256 glpRewards, address _user) external;
}
