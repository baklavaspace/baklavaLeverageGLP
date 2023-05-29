// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IGlpBavaRewards {

    function deposit(address _user, uint256 _amount) external;

    function claimReward(address _user) external view returns (uint256);

    function withdraw(address _user, uint256 _amount) external;
}