// SPDX-License-Identifier: UNLICENSED

// Copyright (c) 2023 Baklava Space - All rights reserved
// Baklava Space: https://www.baklava.space/

pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Governable} from "../../common/Governable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBaklavaGlpRewardDistributor} from "../../interfaces/IBaklavaGlpRewardDistributor.sol";
import {IBaklavaGlpRewardsSplitter} from "../../interfaces/IBaklavaGlpRewardsSplitter.sol";
import {IIncentiveReceiver} from "../../interfaces/IIncentiveReceiver.sol";
import {IBaklavaGlpRewardTracker} from "../../interfaces/IBaklavaGlpRewardTracker.sol";
import {IUniV2Router} from "../../interfaces/IUniV2Router.sol";

contract BaklavaGlpRewardDistributor is Initializable, IBaklavaGlpRewardDistributor, Governable, ReentrancyGuardUpgradeable, UUPSUpgradeable  {
    using Math for uint256;

    uint256 public constant BASIS_POINTS = 1e12;
    uint256 public constant PRECISION = 1e30;

    address public constant wavax = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address public constant stable = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    
    IIncentiveReceiver public incentiveReceiver;
    IUniV2Router public dexRouter;
    address public strategy;
    
    uint256 public bavaPercentage;

    mapping(address => uint256) public rewardPools;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _dexRouter
    ) initializer public {
        __Governable_init(msg.sender, msg.sender);
        if (_dexRouter == address(0)) {
            revert AddressCannotBeZeroAddress();
        }

        dexRouter = IUniV2Router(_dexRouter);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
    }

    // ============================= Operator functions ================================ //

    /**
     * @inheritdoc IBaklavaGlpRewardDistributor
     */
    function splitRewards(uint256 _amount, uint256 _leverage, uint256 _utilization)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
        returns (uint256,uint256)
    {
        if (_amount == 0) {
            return(0,0);
        }
        IERC20(wavax).transferFrom(msg.sender, address(this), _amount);
        (uint256 glpRewards, uint256 stableRewards, uint256 bavaRewards) =
            _splitRewards(_amount, _leverage, _utilization);

        IERC20(wavax).transfer(address(incentiveReceiver), bavaRewards);
        IERC20(wavax).transfer(address(strategy), glpRewards);

        address[] memory path;
        path = new address[](2);
        path[0] = address(wavax);
        path[1] = address(stable);

        uint256 stableAmount = _convertExactTokentoToken(path, stableRewards);
        IERC20(stable).transfer(address(strategy), stableAmount);

        // Information needed to calculate rewards per Vault
        emit SplitRewards(glpRewards, stableAmount, bavaRewards);
        return (stableAmount, glpRewards);
    }

    // ============================= Private functions ================================ //

    function _splitRewards(uint256 _amount, uint256 _leverage, uint256 _utilization)
        internal
        view
        
        returns (uint256, uint256, uint256)
    {
        if (_leverage <= BASIS_POINTS) {
            return (_amount, 0, 0);
        }
        uint256 glpRewards = _amount.mulDiv(BASIS_POINTS, _leverage, Math.Rounding.Down);
        uint256 rewardRemainder = _amount - glpRewards;
        uint256 stableRewards =
            rewardRemainder.mulDiv(_stableRewardsPercentage(_utilization), BASIS_POINTS, Math.Rounding.Down);
        uint256 bavaRewards = rewardRemainder.mulDiv(bavaPercentage, BASIS_POINTS, Math.Rounding.Down);
        rewardRemainder = rewardRemainder - stableRewards - bavaRewards;
        glpRewards = glpRewards + rewardRemainder;

        return (glpRewards, stableRewards, bavaRewards);
    }

    function _stableRewardsPercentage(uint256 _utilization) private pure returns (uint256) {
        if (_utilization > (9935 * BASIS_POINTS) / 10000) {
            return BASIS_POINTS.mulDiv(50, 100);
        }
        if (_utilization <= (95 * BASIS_POINTS) / 100) {
            return BASIS_POINTS.mulDiv(30, 100);
        }
        return (_utilization * 2) - BASIS_POINTS.mulDiv(16, 10);
    }

    function _convertExactTokentoToken(address[] memory path, uint256 amount)
        private
        returns (uint256)
    {
        uint256[] memory amountsOutToken = dexRouter.getAmountsOut(amount, path);
        uint256 amountOutToken = amountsOutToken[amountsOutToken.length - 1];
        IERC20(path[0]).approve(address(dexRouter), amount);
        uint256[] memory amountOut = dexRouter.swapExactTokensForTokens(
            amount,
            amountOutToken,
            path,
            address(this),
            block.timestamp + 1200
        );
        uint256 swapAmount = amountOut[amountOut.length - 1];

        return swapAmount;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(OWNER_ROLE)
        override
    {}

    // ============================= Governor functions ================================ //

    /**
     * @notice Set the beneficiaries address of the GMX rewards
     * @param _incentiveReceiver incentive receiver address
     */
    function setBeneficiaries(IIncentiveReceiver _incentiveReceiver)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (address(_incentiveReceiver) == address(0)) {
            revert AddressCannotBeZeroAddress();
        }

        incentiveReceiver = _incentiveReceiver;
    }

    /**
     * @notice Set the strategy address of the GMX rewards
     * @param _strategy strategy address
     */
    function setStrategy(address _strategy)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (_strategy == address(0)) {
            revert AddressCannotBeZeroAddress();
        }

        strategy = _strategy;
    }


    /**
     * @notice Set reward percetage for bava platform
     * @param _bavaPercentage Bava reward percentage
     */
    function setBavaRewardsPercentage(uint256 _bavaPercentage) external onlyRole(GOVERNOR_ROLE) {
        if (_bavaPercentage > BASIS_POINTS) {
            revert TotalPercentageExceedsMax();
        }
        bavaPercentage = _bavaPercentage;
    }
}