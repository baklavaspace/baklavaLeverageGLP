// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from  "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {Governable} from "../../common/Governable.sol";
import {IBaklavaGlpVault} from "../../interfaces/IBaklavaGlpVault.sol";
import {IBaklavaGlpStableVault} from "../../interfaces/IBaklavaGlpStableVault.sol";
import {IBaklavaGlpRewardDistributor} from "../../interfaces/IBaklavaGlpRewardDistributor.sol";
import {IGmxRewardRouter} from "../../interfaces/IGmxRewardRouter.sol";
import {IGmxRewardTracker} from "../../interfaces/IGmxRewardTracker.sol";
import {IGlpManager} from "../../interfaces/IGlpManager.sol";
import {IGMXVault} from "../../interfaces/IGMXVault.sol";
import {IIncentiveReceiver} from "../../interfaces/IIncentiveReceiver.sol";
import {IYakStrategyV2} from "../../interfaces/IYakStrategyV2.sol";
import {Errors} from "../../interfaces/Errors.sol";

contract BaklavaGlpLeverageStrategy is Initializable, ReentrancyGuardUpgradeable, UUPSUpgradeable, Governable {
    using MathUpgradeable for uint256;

    struct LeverageConfig {
        uint256 target;
        uint256 min;
        uint256 max;
    }

    IGmxRewardRouter constant routerV1 = IGmxRewardRouter(0x82147C5A7E850eA4E28155DF107F2590fD4ba327);
    IGmxRewardRouter constant routerV2 = IGmxRewardRouter(0xB70B91CE0771d3f4c81D87660f71Da31d48eB3B3);
    IGlpManager constant glpManager = IGlpManager(0xD152c7F25db7F4B95b7658323c5F33d176818EE4);
    address constant weth = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    uint256 public constant PRECISION = 1e30;
    uint256 public constant BASIS_POINTS = 1e12;
    uint256 public constant GMX_BASIS = 1e4;
    uint256 public constant USDC_DECIMALS = 1e6;
    uint256 public constant GLP_DECIMALS = 1e18;

    IERC20Upgradeable public glp;
    IERC20Upgradeable public stable;

    IBaklavaGlpVault glpVault;
    IBaklavaGlpStableVault glpStableVault;

    IBaklavaGlpRewardDistributor distributor;
    uint256 public stableDebt;
    LeverageConfig public leverageConfig;

    // For Compounder
    uint256 public glpRetentionPercentage;
    uint256 public stableRetentionPercentage;
    IIncentiveReceiver public incentiveReceiver;
    IYakStrategyV2 public yrt;

    uint256 private constant MIN_REBALANCE_INDEX = 1e18;
    IERC20Upgradeable public sglp;
    uint256 public MIN_TOKENS_TO_REINVEST;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _governor,
        IBaklavaGlpVault _glpVault,
        IBaklavaGlpStableVault _glpStableVault,
        IBaklavaGlpRewardDistributor _distributor,
        uint256 _stableRetentionPercentage,
        uint256 _glpRetentionPercentage,
        IIncentiveReceiver _incentiveReceiver,
        LeverageConfig memory _leverageConfig
    ) initializer public {
        glpVault = _glpVault;
        glpStableVault = _glpStableVault;
        distributor = _distributor;
        stableRetentionPercentage = _stableRetentionPercentage;
        glpRetentionPercentage = _glpRetentionPercentage;
        incentiveReceiver = _incentiveReceiver;

        _setLeverageConfig(_leverageConfig);
        __Governable_init(_owner, _governor);

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
    }


    // ============================= Operator functions ================================ //

    function onGlpDeposit(uint256 _amount) external nonReentrant onlyRole(OPERATOR_ROLE) {
        glpVault.borrow(_amount);
        
        (uint256 underlying, uint256 yrtGlp, ) = getUnderlyingGlp();
        
        _rebalanceYrt(underlying, yrtGlp);

        _rebalance(underlying);
    }

    function onStableDeposit() external nonReentrant onlyRole(OPERATOR_ROLE) {
        (uint256 underlying, uint256 yrtGlp, ) = getUnderlyingGlp();

        _rebalanceYrt(underlying, yrtGlp);

        _rebalance(underlying);
    }

    function onGlpRedeem(uint256 _glpAmount) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256) {
        uint256 glpRedeemRetentionAmount = glpRedeemRetention(_glpAmount);
        uint256 assetsToRedeem = _glpAmount - glpRedeemRetentionAmount;

        uint256 yrtToRedeem = yrt.getSharesForDepositTokens(assetsToRedeem + 1);
        uint256 yrtBalance = yrt.balanceOf(address(this));

        if (yrtBalance > 0) {
            if (yrtBalance >= yrtToRedeem) {
                _withdrawDepositTokens(yrtToRedeem);
            } else {
                _withdrawDepositTokens(yrtToRedeem-yrtBalance);
            }
        }

        uint256 glpBalance = glp.balanceOf(address(this));
        uint256 transferGlpAmount;

        if (glpBalance >= _glpAmount) {
            transferGlpAmount = _glpAmount;
            glp.transfer(msg.sender, transferGlpAmount);
        } else {
            transferGlpAmount = glpBalance-(_glpAmount);
            glp.transfer(msg.sender, transferGlpAmount);
        }
        
        (uint256 underlying, , ) = getUnderlyingGlp();
        if (underlying > 0) {
            _rebalance(underlying);
        }

        return transferGlpAmount;
    }

    function onStableRedeem(uint256 _amount, uint256 _amountAfterRetention) external onlyRole(OPERATOR_ROLE) returns (uint256) {
        uint256 stableAmount;

        if (_amountAfterRetention > 0) {
            (uint256 glpAmount,) = _getRequiredGlpAmount(_amountAfterRetention + 2);
            stableAmount =
                routerV2.unstakeAndRedeemGlp(address(stable), glpAmount, _amountAfterRetention, address(this));
            if (stableAmount < _amountAfterRetention) {
                revert Errors.NotEnoughStables();
            }
        }

        stable.transfer(address(msg.sender), _amountAfterRetention);
        uint256 remainingStable = stable.balanceOf(address(this));

        if(remainingStable > 0) {
            stable.transfer(address(glpStableVault), remainingStable);
        }

        stableDebt = stableDebt - _amount;

        return _amountAfterRetention;
    }

    function claimGlpRewards() internal nonReentrant returns(uint256, uint256) {
        routerV1.handleRewards(false, false, true, true, true, true, false);

        uint256 rewards = IERC20Upgradeable(weth).balanceOf(address(this));
        uint256 stableRewards = 0;
        uint256 glpRewards = 0;
        
        if (rewards > 0) {
            uint256 currentLeverage = leverage();

            IERC20Upgradeable(weth).approve(address(distributor), rewards);
            (stableRewards, glpRewards) = distributor.splitRewards(rewards, currentLeverage, utilization());
        }

        return (stableRewards, glpRewards);
    }



    // ============================= Public & External View functions ================================ //

    function utilization() public view returns (uint256) {
        uint256 borrowed = stableDebt;
        uint256 available = stable.balanceOf(address(glpStableVault));
        uint256 total = borrowed + available;

        if (total == 0) {
            return 0;
        }

        return (borrowed * BASIS_POINTS) / total;
    }

    function leverage() public view returns (uint256) {
        (uint256 glpTvl, , uint256 totalGlp) = getUnderlyingGlp(); // 18 Decimals

        if (glpTvl == 0) {
            return 0;
        }

        if (stableDebt == 0) {
            return 1 * BASIS_POINTS;
        }

        return ((totalGlp * BASIS_POINTS) / glpTvl); // 12 Decimals;
    }

    /**
     * @return Amount of depositor underlying GLP
     * @return Amount of Glp in Yrt form
     * @return Amount of total Glp including borrowed Glp
     */
    function getUnderlyingGlp() public view returns (uint256, uint256, uint256) {
        uint256 glpBalance = glp.balanceOf(address(this));
        uint256 yrtBalance = yrt.balanceOf(address(this));
        uint256 yrtGlpBalance = yrt.getDepositTokensForShares(yrtBalance);
        uint256 totalGlpBalance = glpBalance + yrtGlpBalance;

        if (totalGlpBalance == 0) {
            return (0,0,0);
        }

        if (stableDebt > 0) {
            (uint256 glpAmount,) = _getRequiredGlpAmount(stableDebt + 2);
            return (totalGlpBalance > glpAmount ? totalGlpBalance - glpAmount : 0, yrtGlpBalance, totalGlpBalance);
        } else {
            return (totalGlpBalance, yrtGlpBalance, totalGlpBalance);
        }
    }

    function getStableGlpValue(uint256 _glpAmount) public view returns (uint256) {
        (uint256 _value,) = _sellGlpStableSimulation(_glpAmount);
        return _value;
    }

    function buyGlpStableSimulation(uint256 _stableAmount) public view returns (uint256) {
        return _buyGlpStableSimulation(_stableAmount);
    }

    function getRequiredStableAmount(uint256 _glpAmount) external view returns (uint256) {
        (uint256 stableAmount,) = _getRequiredStableAmount(_glpAmount);
        return stableAmount;
    }

    function getRequiredGlpAmount(uint256 _stableAmount) external view returns (uint256) {
        (uint256 glpAmount,) = _getRequiredGlpAmount(_stableAmount);
        return glpAmount;
    }

    function getRedeemStableGMXIncentive(uint256 _stableAmount) external view returns (uint256) {
        (, uint256 gmxRetention) = _getRequiredGlpAmount(_stableAmount);
        return gmxRetention;
    }

    function glpMintIncentive(uint256 _glpAmount) public view returns (uint256) {
        return _glpMintIncentive(_glpAmount);
    }

    function glpRedeemRetention(uint256 _glpAmount) public view returns (uint256) {
        return _glpRedeemRetention(_glpAmount);
    }

    function getGMXCapDifference() public view returns (uint256) {
        return _getGMXCapDifference();
    }

    function getTargetLeverage() public view returns (uint256) {
        return leverageConfig.target;
    }

    function pendingRewards() public view returns (uint256) {
        return
            IGmxRewardTracker(IGmxRewardRouter(routerV1).feeGlpTracker()).claimable(address(this));
    }


    // ============================= Governor functions ================================ //

    /**
     * @notice Set Leverage Configuration
     * @dev Precision is based on 1e12 as 1x leverage
     * @param _target Target leverage
     * @param _min Min Leverage
     * @param _max Max Leverage
     * @param rebalance_ If is true trigger a rebalance
     */
    function setLeverageConfig(uint256 _target, uint256 _min, uint256 _max, bool rebalance_) public onlyRole(GOVERNOR_ROLE) {
        _setLeverageConfig(LeverageConfig(_target, _min, _max));
        emit SetLeverageConfig(_target, _min, _max);
        if (rebalance_) {
            (uint256 underlying, , ) = getUnderlyingGlp();
            _rebalance(underlying);
        }
    }

    /**
     * @notice Emergency withdraw GLP in this contract
     * @param _to address to send the funds
     */
    function emergencyWithdraw(address _to) external onlyRole(GOVERNOR_ROLE) {
        uint256 currentBalance = glp.balanceOf(address(this));

        if (currentBalance == 0) {
            return;
        }

        glp.transfer(_to, currentBalance);

        emit EmergencyWithdraw(_to, currentBalance);
    }

    /**
     * @notice GMX function to signal transfer position
     * @param _to address to send the funds
     * @param _gmxRouter address of gmx router with the function
     */
    function transferAccount(address _to, address _gmxRouter) external onlyRole(GOVERNOR_ROLE) {
        if (_to == address(0)) {
            revert Errors.AddressCannotBeZeroAddress();
        }

        IGmxRewardRouter(_gmxRouter).signalTransfer(_to);
    }

    /**
     * @notice GMX function to accept transfer position
     * @param _sender address to receive the funds
     * @param _gmxRouter address of gmx router with the function
     */
    function acceptAccountTransfer(address _sender, address _gmxRouter) external onlyRole(GOVERNOR_ROLE) {
        IGmxRewardRouter gmxRouter = IGmxRewardRouter(_gmxRouter);

        gmxRouter.acceptTransfer(_sender);
    }

    /**
     * @notice Set new retentions
     * @param _stableRetentionPercentage New stable retention
     * @param _glpRetentionPercentage New glp retention
     */
    function setNewRetentions(uint256 _stableRetentionPercentage, uint256 _glpRetentionPercentage)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (_stableRetentionPercentage > BASIS_POINTS) {
            revert RetentionPercentageOutOfRange();
        }
        if (_glpRetentionPercentage > BASIS_POINTS) {
            revert RetentionPercentageOutOfRange();
        }

        stableRetentionPercentage = _stableRetentionPercentage;
        glpRetentionPercentage = _glpRetentionPercentage;
    }

    /**
     * @notice Set new MIN_TOKENS_TO_REINVEST
     * @param _newMinTokenToInvest New Mininum Token To Invest
     */
    function setNewMinTokenToInvest(uint256 _newMinTokenToInvest)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(_newMinTokenToInvest > 0, "!0");
        MIN_TOKENS_TO_REINVEST = _newMinTokenToInvest;
    }


    // ============================= Owner functions ================================ //

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(OWNER_ROLE) {}

    /**
     * @notice Deleverage & pay stable debt
     */
    function unwind() external onlyRole(OWNER_ROLE) {
        _setLeverageConfig(LeverageConfig(BASIS_POINTS + 1, BASIS_POINTS, BASIS_POINTS + 2));
        _liquidate();
    }

    function setAsset(address _glp, address _sglp, address _stable, address _yrt) external onlyRole(OWNER_ROLE) {
        glp = IERC20Upgradeable(_glp);
        sglp = IERC20Upgradeable(_sglp);
        stable = IERC20Upgradeable(_stable);
        yrt = IYakStrategyV2(_yrt);
    }


    // ============================= Keeper functions ================================ //

    /**
     * @notice Using by the bot to rebalance if is it needed
     */
    function rebalance() external onlyRole(KEEPER_ROLE) {
        (uint256 underlying, , ) = getUnderlyingGlp();
        _rebalance(underlying);
    }

    /**
     * @notice Using by the bot to leverage Up if is needed
     */
    function leverageUp(uint256 _stableAmount) external onlyRole(KEEPER_ROLE) {
        uint256 availableForBorrowing = stable.balanceOf(address(glpStableVault));

        if (availableForBorrowing == 0) {
            return;
        }

        uint256 oldLeverage = leverage();

        _stableAmount = _adjustToGMXCap(_stableAmount);

        if (_stableAmount < 1e4) {
            return;
        }

        if (availableForBorrowing < _stableAmount) {
            _stableAmount = availableForBorrowing;
        }

        uint256 stableToBorrow = _stableAmount - stable.balanceOf(address(this));

        glpStableVault.borrow(stableToBorrow);
        emit BorrowStable(stableToBorrow);

        stableDebt = stableDebt + stableToBorrow;

        address stableAsset = address(stable);
        IERC20Upgradeable(stableAsset).approve(routerV2.glpManager(), _stableAmount);
        routerV2.mintAndStakeGlp(stableAsset, _stableAmount, 0, 0);

        uint256 newLeverage = leverage();

        if (newLeverage > leverageConfig.max) {
            revert Errors.OverLeveraged();
        }

        emit LeverageUp(stableDebt, oldLeverage, newLeverage);
    }

    /**
     * @notice Using by the bot to leverage Down if is needed
     */
    function leverageDown(uint256 _glpAmount) external onlyRole(KEEPER_ROLE) {
        uint256 oldLeverage = leverage();

        uint256 stablesReceived = routerV2.unstakeAndRedeemGlp(address(stable), _glpAmount, 0, address(this));

        uint256 currentStableDebt = stableDebt;

        if (stablesReceived <= currentStableDebt) {
            _repayStable(stablesReceived);
        } else {
            _repayStable(currentStableDebt);
        }

        uint256 newLeverage = leverage();

        if (newLeverage < leverageConfig.min) {
            revert Errors.UnderLeveraged();
        }

        emit LeverageDown(stableDebt, oldLeverage, newLeverage);
    }

    function compound() external onlyRole(KEEPER_ROLE) {
        uint256 rewards = pendingRewards();
        if (rewards >= MIN_TOKENS_TO_REINVEST) {
            _compound();
        }
    }


    // ============================= Private functions ================================ //

    function _rebalance(uint256 _glpDebt) private {
        uint256 currentLeverage = leverage();

        LeverageConfig memory currentLeverageConfig = leverageConfig;

        if (currentLeverage < currentLeverageConfig.min) {
            uint256 missingGlp = (_glpDebt * (currentLeverageConfig.target - currentLeverage)) / BASIS_POINTS; // 18 Decimals

            (uint256 stableToDeposit,) = _getRequiredStableAmount(missingGlp); // 6 Decimals

            stableToDeposit = _adjustToGMXCap(stableToDeposit);

            if (stableToDeposit < 1e4) {
                return;
            }

            uint256 availableForBorrowing = stable.balanceOf(address(glpStableVault));

            if (availableForBorrowing == 0) {
                return;
            }

            if (availableForBorrowing < stableToDeposit) {
                stableToDeposit = availableForBorrowing;
            }

            uint256 stableToBorrow = stableToDeposit - stable.balanceOf(address(this));

            glpStableVault.borrow(stableToBorrow);
            emit BorrowStable(stableToBorrow);

            stableDebt = stableDebt + stableToBorrow;

            address stableAsset = address(stable);
            IERC20Upgradeable(stableAsset).approve(routerV2.glpManager(), stableToDeposit);
            routerV2.mintAndStakeGlp(stableAsset, stableToDeposit, 0, 0);

            emit Rebalance(_glpDebt, currentLeverage, leverage(), tx.origin);

            return;
        }

        if (currentLeverage > currentLeverageConfig.max) {
            uint256 excessGlp = (_glpDebt * (currentLeverage - currentLeverageConfig.target)) / BASIS_POINTS;

            uint256 stablesReceived = routerV2.unstakeAndRedeemGlp(address(stable), excessGlp, 0, address(this));

            uint256 currentStableDebt = stableDebt;

            if (stablesReceived <= currentStableDebt) {
                _repayStable(stablesReceived);
            } else {
                _repayStable(currentStableDebt);
            }

            emit Rebalance(_glpDebt, currentLeverage, leverage(), tx.origin);

            return;
        }

        return;
    }

    function _rebalanceYrt(uint256 _glpDebt, uint256 _yrtGlp) private {
        if (_yrtGlp > _glpDebt) {
            if(_yrtGlp - _glpDebt > MIN_REBALANCE_INDEX) {
                uint256 excessGlp = _yrtGlp - _glpDebt;

                uint256 excessYrt = yrt.getSharesForDepositTokens(excessGlp);

                yrt.withdraw(excessYrt);
            }
        } else if (_yrtGlp < _glpDebt) {
            if(_glpDebt - _yrtGlp > MIN_REBALANCE_INDEX) {
                uint256 requiredGlp = _glpDebt - _yrtGlp;
            
                IERC20Upgradeable(sglp).approve(address(yrt), requiredGlp);

                yrt.deposit(requiredGlp);
            }
        }
    }

    function _liquidate() private {
        if (stableDebt == 0) {
            return;
        }

        uint256 glpBalance = glp.balanceOf(address(this));

        (uint256 glpAmount,) = _getRequiredGlpAmount(stableDebt + 2);

        if (glpAmount > glpBalance) {
            glpAmount = glpBalance;
        }

        uint256 stablesReceived = routerV2.unstakeAndRedeemGlp(address(stable), glpAmount, 0, address(this));

        uint256 currentStableDebt = stableDebt;

        if (stablesReceived <= currentStableDebt) {
            _repayStable(stablesReceived);
        } else {
            _repayStable(currentStableDebt);
        }

        emit Liquidate(stablesReceived);
    }

    function _repayStable(uint256 _amount) private returns (uint256) {
        stable.approve(address(glpStableVault), _amount);

        uint256 updatedAmount = stableDebt - glpStableVault.repay(_amount);

        stableDebt = updatedAmount;

        return updatedAmount;
    }

    function _setLeverageConfig(LeverageConfig memory _config) private {
        if (
            _config.min >= _config.max || _config.min >= _config.target || _config.max <= _config.target
                || _config.min < BASIS_POINTS
        ) {
            revert Errors.InvalidLeverageConfig();
        }

        leverageConfig = _config;
    }

    function _withdrawDepositTokens(uint256 _amount) private {
        // uint256 beforeGlpBalance = glp.balanceOf(address(this));
        yrt.withdraw(_amount);
        // uint256 afterGlpBalance = glp.balanceOf(address(this));
        // return (afterGlpBalance - beforeGlpBalance);
    }

    function _compound() private {
        // stableRewards in stable coin, glpRewards in weth
        (uint256 stableRewards, uint256 glpRewards) = claimGlpRewards();
        if (glpRewards > 0) {
            uint256 retention = _retention(glpRewards, glpRetentionPercentage);
            if (retention > 0) {
                IERC20Upgradeable(weth).transfer(address(incentiveReceiver), retention);
                glpRewards = glpRewards - retention;
            }

            IERC20Upgradeable(weth).approve(routerV2.glpManager(), glpRewards);
            uint256 glpAmount = routerV2.mintAndStakeGlp(weth, glpRewards, 0, 0);
            glpRewards = glpAmount;

            IERC20Upgradeable(sglp).approve(address(yrt), glpRewards);
            yrt.deposit(glpRewards);

            // Information needed to calculate compounding rewards per Vault
            emit Compound(glpRewards, retention);
        }
        if (stableRewards > 0) {
            uint256 retention = _retention(stableRewards, stableRetentionPercentage);
            if (retention > 0) {
                IERC20Upgradeable(stable).transfer(address(incentiveReceiver), retention);
                stableRewards = stableRewards - retention;
            }

            IERC20Upgradeable(stable).transfer(address(glpStableVault), stableRewards);

            // Information needed to calculate compounding rewards per Vault
            emit Compound(stableRewards, retention);
        }
    }

    // ============================= Private View functions ================================ //

    function _getRequiredGlpAmount(uint256 _stableAmount) private view returns (uint256, uint256) {
        // Working as expected, will get the amount of glp nedeed to get a few less stables than expected
        // If you have to get an amount greater or equal of _stableAmount, use _stableAmount + 2
        IGlpManager manager = glpManager;
        IGMXVault vault = IGMXVault(manager.vault());

        address usdc = address(stable);

        uint256 usdcPrice = vault.getMaxPrice(usdc); // 30 decimals

        uint256 glpSupply = glp.totalSupply();

        uint256 glpPrice = manager.getAum(false).mulDiv(GLP_DECIMALS, glpSupply, MathUpgradeable.Rounding.Down); // 30 decimals

        uint256 usdgAmount = _stableAmount.mulDiv(usdcPrice, PRECISION, MathUpgradeable.Rounding.Down) * BASIS_POINTS; // 18 decimals

        uint256 glpAmount = _stableAmount.mulDiv(usdcPrice, glpPrice, MathUpgradeable.Rounding.Down) * BASIS_POINTS; // 18 decimals

        uint256 retentionBasisPoints =
            _getGMXBasisRetention(usdc, usdgAmount, vault.mintBurnFeeBasisPoints(), vault.taxBasisPoints(), false);

        uint256 glpRequired = (glpAmount * GMX_BASIS) / (GMX_BASIS - retentionBasisPoints);

        return (glpRequired, retentionBasisPoints);
    }

    function _getRequiredStableAmount(uint256 _glpAmount) private view returns (uint256, uint256) {
        // Working as expected, will get the amount of stables nedeed to get a few less glp than expected
        // If you have to get an amount greater or equal of _glpAmount, use _glpAmount + 2
        IGlpManager manager = glpManager;
        IGMXVault vault = IGMXVault(manager.vault());

        address usdc = address(stable);

        uint256 usdcPrice = vault.getMinPrice(usdc); // 30 decimals

        uint256 glpPrice = manager.getAum(true).mulDiv(GLP_DECIMALS, glp.totalSupply(), MathUpgradeable.Rounding.Down); // 30 decimals

        uint256 stableAmount = _glpAmount.mulDiv(glpPrice, usdcPrice, MathUpgradeable.Rounding.Down); // 18 decimals

        uint256 usdgAmount = _glpAmount.mulDiv(glpPrice, PRECISION, MathUpgradeable.Rounding.Down); // 18 decimals

        uint256 retentionBasisPoints =
            vault.getFeeBasisPoints(usdc, usdgAmount, vault.mintBurnFeeBasisPoints(), vault.taxBasisPoints(), true);

        return ((stableAmount * GMX_BASIS / (GMX_BASIS - retentionBasisPoints)) / BASIS_POINTS, retentionBasisPoints); // 18 decimals
    }



    function _adjustToGMXCap(uint256 _stableAmount) private view returns (uint256) {
        IGlpManager manager = glpManager;
        IGMXVault vault = IGMXVault(manager.vault());

        address usdc = address(stable);

        uint256 mintAmount = _buyGlpStableSimulation(_stableAmount);

        uint256 currentUsdgAmount = vault.usdgAmounts(usdc);

        uint256 nextAmount = currentUsdgAmount + mintAmount;
        uint256 maxUsdgAmount = vault.maxUsdgAmounts(usdc);

        if (nextAmount > maxUsdgAmount) {
            (uint256 requiredStables,) = _getRequiredStableAmount(maxUsdgAmount - currentUsdgAmount);
            return requiredStables;
        } else {
            return _stableAmount;
        }
    }

    function _getGMXCapDifference() private view returns (uint256) {
        IGlpManager manager = glpManager;
        IGMXVault vault = IGMXVault(manager.vault());

        address usdc = address(stable);

        uint256 currentUsdgAmount = vault.usdgAmounts(usdc);

        uint256 maxUsdgAmount = vault.maxUsdgAmounts(usdc);

        return maxUsdgAmount - currentUsdgAmount;
    }

    function _buyGlpStableSimulation(uint256 _stableAmount) private view returns (uint256) {
        IGlpManager manager = glpManager;
        IGMXVault vault = IGMXVault(manager.vault());

        address usdc = address(stable);

        uint256 aumInUsdg = manager.getAumInUsdg(true);

        uint256 usdcPrice = vault.getMinPrice(usdc); // 30 decimals

        uint256 usdgAmount = _stableAmount.mulDiv(usdcPrice, PRECISION); // 6 decimals

        usdgAmount = usdgAmount.mulDiv(GLP_DECIMALS, USDC_DECIMALS); // 18 decimals

        uint256 retentionBasisPoints =
            vault.getFeeBasisPoints(usdc, usdgAmount, vault.mintBurnFeeBasisPoints(), vault.taxBasisPoints(), true);

        uint256 amountAfterRetention = _stableAmount.mulDiv(GMX_BASIS - retentionBasisPoints, GMX_BASIS); // 6 decimals

        uint256 mintAmount = amountAfterRetention.mulDiv(usdcPrice, PRECISION); // 6 decimals

        mintAmount = mintAmount.mulDiv(GLP_DECIMALS, USDC_DECIMALS); // 18 decimals

        return aumInUsdg == 0 ? mintAmount : mintAmount.mulDiv(glp.totalSupply(), aumInUsdg); // 18 decimals
    }

    function _buyGlpStableSimulationWhitoutRetention(uint256 _stableAmount) private view returns (uint256) {
        IGlpManager manager = glpManager;
        IGMXVault vault = IGMXVault(manager.vault());

        address usdc = address(stable);

        uint256 aumInUsdg = manager.getAumInUsdg(true);

        uint256 usdcPrice = vault.getMinPrice(usdc); // 30 decimals

        uint256 usdgAmount = _stableAmount.mulDiv(usdcPrice, PRECISION); // 6 decimals

        usdgAmount = usdgAmount.mulDiv(GLP_DECIMALS, USDC_DECIMALS); // 18 decimals

        uint256 mintAmount = _stableAmount.mulDiv(usdcPrice, PRECISION); // 6 decimals

        mintAmount = mintAmount.mulDiv(GLP_DECIMALS, USDC_DECIMALS); // 18 decimals

        return aumInUsdg == 0 ? mintAmount : mintAmount.mulDiv(glp.totalSupply(), aumInUsdg); // 18 decimals
    }

    function _sellGlpStableSimulation(uint256 _glpAmount) private view returns (uint256, uint256) {
        IGlpManager manager = glpManager;
        IGMXVault vault = IGMXVault(manager.vault());

        address usdc = address(stable);

        uint256 usdgAmount = _glpAmount.mulDiv(manager.getAumInUsdg(false), glp.totalSupply());

        uint256 redemptionAmount = usdgAmount.mulDiv(PRECISION, vault.getMaxPrice(usdc));

        redemptionAmount = redemptionAmount.mulDiv(USDC_DECIMALS, GLP_DECIMALS); // 6 decimals

        uint256 retentionBasisPoints =
            _getGMXBasisRetention(usdc, usdgAmount, vault.mintBurnFeeBasisPoints(), vault.taxBasisPoints(), false);

        return (redemptionAmount.mulDiv(GMX_BASIS - retentionBasisPoints, GMX_BASIS), retentionBasisPoints);
    }

    function _glpMintIncentive(uint256 _glpAmount) private view returns (uint256) {
        uint256 amountToMint = _glpAmount.mulDiv(leverageConfig.target - BASIS_POINTS, BASIS_POINTS); // 18 Decimals
        (uint256 stablesNeeded, uint256 gmxIncentive) = _getRequiredStableAmount(amountToMint + 2);
        uint256 incentiveInStables = stablesNeeded.mulDiv(gmxIncentive, GMX_BASIS);
        return _buyGlpStableSimulationWhitoutRetention(incentiveInStables); // retention in glp
    }

    function _glpRedeemRetention(uint256 _glpAmount) private view returns (uint256) {
        uint256 amountToRedeem = _glpAmount.mulDiv(leverageConfig.target - BASIS_POINTS, BASIS_POINTS); //18
        (, uint256 gmxRetention) = _sellGlpStableSimulation(amountToRedeem + 2);
        uint256 retentionInGlp = amountToRedeem.mulDiv(gmxRetention, GMX_BASIS);
        return retentionInGlp;
    }

    function _getGMXBasisRetention(
        address _token,
        uint256 _usdgDelta,
        uint256 _retentionBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) private view returns (uint256) {
        IGMXVault vault = IGMXVault(glpManager.vault());

        if (!vault.hasDynamicFees()) return _retentionBasisPoints;

        uint256 initialAmount = _increment ? vault.usdgAmounts(_token) : vault.usdgAmounts(_token) - _usdgDelta;

        uint256 nextAmount = initialAmount + _usdgDelta;
        if (!_increment) {
            nextAmount = _usdgDelta > initialAmount ? 0 : initialAmount - _usdgDelta;
        }

        uint256 targetAmount = vault.getTargetUsdgAmount(_token);
        if (targetAmount == 0) return _retentionBasisPoints;

        uint256 initialDiff = initialAmount > targetAmount ? initialAmount - targetAmount : targetAmount - initialAmount;
        uint256 nextDiff = nextAmount > targetAmount ? nextAmount - targetAmount : targetAmount - nextAmount;

        // action improves relative asset balance
        if (nextDiff < initialDiff) {
            uint256 rebateBps = _taxBasisPoints.mulDiv(initialDiff, targetAmount);
            return rebateBps > _retentionBasisPoints ? 0 : _retentionBasisPoints - rebateBps;
        }

        uint256 averageDiff = (initialDiff + nextDiff) / 2;
        if (averageDiff > targetAmount) {
            averageDiff = targetAmount;
        }
        uint256 taxBps = _taxBasisPoints.mulDiv(averageDiff, targetAmount);
        return _retentionBasisPoints + taxBps;
    }

    function _retention(uint256 _rewards, uint256 _retentionPercentage) private pure returns (uint256) {
        return (_rewards * _retentionPercentage) / BASIS_POINTS;
    }



    // ============================= Event functions ================================ //

    event Compound(uint256 _rewards, uint256 _retentions);
    event Rebalance(
        uint256 _glpDebt, uint256 indexed _currentLeverage, uint256 indexed _newLeverage, address indexed _sender
    );
    event SetLeverageConfig(uint256 _target, uint256 _min, uint256 _max);
    event Liquidate(uint256 indexed _stablesReceived);
    event BorrowStable(uint256 indexed _amount);
    event RepayStable(uint256 indexed _amount);
    event RepayGlp(uint256 indexed _amount);
    event EmergencyWithdraw(address indexed _to, uint256 indexed _amount);
    event Leverage(uint256 _glpDeposited, uint256 _glpMinted);
    event LeverageUp(uint256 _stableDebt, uint256 _oldLeverage, uint256 _currentLeverage);
    event LeverageDown(uint256 _stableDebt, uint256 _oldLeverage, uint256 _currentLeverage);
    event Deleverage(uint256 _glpAmount, uint256 _glpRedeemed);

    error NotEnoughUnderlyingGlp();
    error RetentionPercentageOutOfRange();
}