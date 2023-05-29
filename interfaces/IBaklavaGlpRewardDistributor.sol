// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IBaklavaGlpRewardDistributor {
    event Distribute(uint256 amount);
    event SplitRewards(uint256 _glpRewards, uint256 _stableRewards, uint256 _baklavaRewards);

    /**
     * @notice Split the rewards comming from GMX
     * @param _amount of rewards to be splited
     * @param _leverage current strategy leverage
     * @param _utilization current stable pool utilization
     */
    function splitRewards(uint256 _amount, uint256 _leverage, uint256 _utilization) external returns (uint256, uint256);

    error AddressCannotBeZeroAddress();
    error TotalPercentageExceedsMax();
}