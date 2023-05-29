// SPDX-License-Identifier: UNLICENSED

// Copyright (c) 2023 Baklava Space - All rights reserved
// Baklava Space: https://www.baklava.space/

pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";

import {Governable} from "../common/Governable.sol";
import {IGmxRewardRouter} from "../interfaces/IGmxRewardRouter.sol";
import {IBaklavaGlpVault} from "../interfaces/IBaklavaGlpVault.sol";
import {IBaklavaGlpStableVault} from "../interfaces/IBaklavaGlpStableVault.sol";
import {IBaklavaGlpLeverageStrategy} from "../interfaces/IBaklavaGlpLeverageStrategy.sol";
import {IGlpBavaRewards} from "../interfaces/IGlpBavaRewards.sol";
import {IWhitelistController} from "../interfaces/IWhitelistController.sol";
import {IIncentiveReceiver} from "../interfaces/IIncentiveReceiver.sol";
import {IYakStrategyV2} from "../interfaces/IYakStrategyV2.sol";
import {Errors} from "../interfaces/Errors.sol";

contract BaklavaGlpVaultRouter is Initializable, PausableUpgradeable, ReentrancyGuardUpgradeable, Governable, UUPSUpgradeable {

    struct WithdrawalSignal {
        uint256 targetEpoch;
        uint256 commitedShares;
        bool redeemed;
    }

    IGmxRewardRouter private constant router = IGmxRewardRouter(0xB70B91CE0771d3f4c81D87660f71Da31d48eB3B3);
    address private constant wavax = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    IBaklavaGlpVault private glpVault;
    IBaklavaGlpStableVault private glpStableVault;
    IBaklavaGlpLeverageStrategy public strategy;
    IWhitelistController private whitelistController;
    IIncentiveReceiver private incentiveReceiver;
    address private adapter;

    IERC20Upgradeable private glp;
    IERC20Upgradeable private stable;
    IYakStrategyV2 private yrt;

    uint256 private constant BASIS_POINTS = 1e12;
    uint256 private constant EPOCH_DURATION = 1 days;
    uint256 public EXIT_COOLDOWN;
    IGlpBavaRewards private glpBavaRewards;
    IGlpBavaRewards private stableBavaRewards;

    mapping(address => mapping(uint256 => WithdrawalSignal)) private userSignal;
    mapping(address => uint256[]) public userSignalEpoch;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _governor,
        IBaklavaGlpVault _glpVault,
        IBaklavaGlpStableVault _glpStableVault,
        IBaklavaGlpLeverageStrategy _strategy,
        IWhitelistController _whitelistController,
        IIncentiveReceiver _incentiveReceiver,
        address _adapter
    ) initializer public {
        glpVault = _glpVault;
        glpStableVault = _glpStableVault;
        strategy = _strategy;
        adapter = _adapter;
        whitelistController = _whitelistController;
        incentiveReceiver = _incentiveReceiver;

        __Governable_init(_governor, msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
    }


    // ============================= Whitelisted functions ================================ //

    /**
     * @notice The Adapter contract can deposit GLP to the system on behalf of the _sender
     * @param _assets Amount of assets deposited
     * @param _sender address of who is deposit the assets
     * @return Amount of shares jGLP minted
     */
    function depositGlp(uint256 _assets, address _sender, bool _compound, bool _rebalance) external whenNotPaused returns (uint256) {
        _onlyInternalContract(); //can only be adapter or compounder

        bytes32 role = whitelistController.getUserRole(_sender);
        IWhitelistController.RoleInfo memory info = whitelistController.getRoleInfo(role);

        IBaklavaGlpLeverageStrategy _strategy = strategy;

        if(_compound) {
            _strategy.compound();
        }

        (uint256 underlyingGlp, , ) = _strategy.getUnderlyingGlp();
        uint256 newUnderlyingUsdValue = _strategy.getStableGlpValue(underlyingGlp + _assets);
        uint256 maxTvlGlp = getMaxCapGlp();

        if ((newUnderlyingUsdValue) * BASIS_POINTS > maxTvlGlp && !info.jGLP_BYPASS_CAP) {
            revert Errors.MaxGlpTvlReached();
        }
        
        uint256 vaultShares = _depositGlp(_assets);

        glpVault.approve(address(glpBavaRewards), vaultShares);
        glpBavaRewards.deposit(_sender, vaultShares);

        if(_rebalance) {
            _strategy.onGlpDeposit(_assets);        // borrow stable from vault to strategy
        }

        emit DepositGlp(_sender, _assets, vaultShares);

        return vaultShares;
    }

    /**
     * @notice Users & Whitelist contract can redeem GLP from the system
     * @param _shares Amount of jGLP deposited to redeem GLP
     * @return Amount of GLP remdeemed
     */
    function redeemGlp(uint256 _shares, bool _compound) external whenNotPaused nonReentrant returns (uint256) {
        _onlyEOA();

        if(_compound) {
            strategy.compound();
        }
        glpBavaRewards.withdraw(msg.sender, _shares);

        IBaklavaGlpVault _glpVault = glpVault;
        uint256 glpAmount = _glpVault.previewRedeem(_shares);

        _glpVault.burn(address(this), _shares);

        //We can't send glpAmount - retention here because it'd mess our rebalance
        glpAmount = strategy.onGlpRedeem(glpAmount);

        if (glpAmount > 0) {
            glpAmount = _distributeGlp(glpAmount, msg.sender);
        }

        return glpAmount;
    }

    /**
     * @notice User & Whitelist contract can redeem GLP using any asset of GLP basket from the system
     * @param _shares Amount of jGLP deposited to redeem GLP
     * @param _token address of asset token
     * @param _user address of the user that will receive the assets
     * @param _native flag if the user will receive raw ETH
     * @return Amount of assets redeemed
     */
    function redeemGlpAdapter(uint256 _shares, bool _compound, address _token, address _user, bool _native)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (msg.sender != address(adapter)) {
            revert Errors.OnlyAdapter();
        }

        if (_compound) {
            strategy.compound();
        }

        glpBavaRewards.withdraw(_user, _shares);

        IBaklavaGlpVault _glpVault = glpVault;
        uint256 glpAmount = _glpVault.previewRedeem(_shares);

        _glpVault.burn(address(this), _shares);

        //We can't send glpAmount - retention here because it'd mess our rebalance
        glpAmount = strategy.onGlpRedeem(glpAmount);

        if (glpAmount > 0) {
            if (address(_token) == address(yrt)) {
                glpAmount = _distributeGlp(glpAmount, msg.sender);
            } else {
                glpAmount = _distributeGlpAdapter(glpAmount, _user, _token, _native);
            }
        }

        return glpAmount;
    }

    /**
     * @notice adapter & compounder can deposit Stable assets to the system
     * @param _assets Amount of Stables deposited
     * @return Amount of shares jUSDC minted
     */
    function depositStable(uint256 _assets, address _user, bool _compound) external whenNotPaused returns (uint256) {
        _onlyInternalContract(); //can only be adapter or compounder
        IBaklavaGlpLeverageStrategy _strategy = strategy;

        if(_compound) {
            _strategy.compound();
        }        

        (uint256 shares) = _depositStable(_assets);

        glpStableVault.approve(address(stableBavaRewards), shares);
        stableBavaRewards.deposit(_user, shares);

        strategy.onStableDeposit();

        emit DepositStables(_user, _assets, shares);

        return shares;
    }

    /**
     * @notice Users can signal a stable redeem or redeem directly if user has the role to do it.
     * @dev The Bava rewards stop here
     * @param _shares Amount of shares jUSDC to redeem
     * @return Epoch when will be possible the redeem or the amount of stables received in case user has special role
     */
    function stableWithdrawalSignal(uint256 _shares, bool _compound)
        external
        whenNotPaused
        returns (uint256)
    {
        _onlyEOA();

        bytes32 userRole = whitelistController.getUserRole(msg.sender);
        IWhitelistController.RoleInfo memory info = whitelistController.getRoleInfo(userRole);

        uint256 targetEpoch = currentEpoch() + EXIT_COOLDOWN;
        WithdrawalSignal memory userWithdrawalSignal = userSignal[msg.sender][targetEpoch];

        if (userWithdrawalSignal.commitedShares > 0) {
            revert Errors.WithdrawalSignalAlreadyDone();
        }

        if (_compound) {
            strategy.compound();
        }

        stableBavaRewards.withdraw(msg.sender, _shares);

        if (info.jUSDC_BYPASS_TIME) {
            return _redeemDirectly(_shares, info.jUSDC_RETENTION);
        }

        userSignal[msg.sender][targetEpoch] = WithdrawalSignal(targetEpoch, _shares, false);
        userSignalEpoch[msg.sender].push(targetEpoch);

        emit StableWithdrawalSignal(msg.sender, _shares, targetEpoch);

        return targetEpoch;
    }

    /**
     * @notice Users can signal a stable redeem or redeem directly if user has the role to do it.
     * @dev The Bava rewards stop here
     * @param _shares Amount of shares jUSDC to redeem
     * @return Epoch when will be possible the redeem or the amount of stables received in case user has special role
     */
    function stableWithdrawalDirectly(uint256 _shares, bool _compound)
        external
        whenNotPaused
        returns (uint256)
    {
        _onlyEOA();

        bytes32 userRole = whitelistController.getUserRole(msg.sender);
        IWhitelistController.RoleInfo memory info = whitelistController.getRoleInfo(userRole);

        if(_compound) {
            strategy.compound();
        }
        
        stableBavaRewards.withdraw(msg.sender, _shares);

        return _redeemDirectly(_shares, info.jUSDC_RETENTION);
    }

    /**
     * @notice Users can cancel the signal to stable redeem
     * @param _epoch Target epoch
     * @param _compound true if the rewards should be compound
     */
    function cancelStableWithdrawalSignal(uint256 _epoch, bool _compound) external {
        WithdrawalSignal memory userWithdrawalSignal = userSignal[msg.sender][_epoch];

        if (userWithdrawalSignal.redeemed) {
            revert Errors.WithdrawalAlreadyCompleted();
        }

        uint256 snapshotCommitedShares = userWithdrawalSignal.commitedShares;

        if (snapshotCommitedShares == 0) {
            return;
        }

        userWithdrawalSignal.commitedShares = 0;
        userWithdrawalSignal.targetEpoch = 0;
        
        // Update struct storage
        userSignal[msg.sender][_epoch] = userWithdrawalSignal;

        glpStableVault.approve(address(stableBavaRewards), snapshotCommitedShares);
        stableBavaRewards.deposit(msg.sender, snapshotCommitedShares);

        emit CancelStableWithdrawalSignal(msg.sender, snapshotCommitedShares, _compound);
    }

    /**
     * @notice Users can redeem stable assets from the system
     * @param _epoch Target epoch
     * @return Amount of stables reeemed
     */
    function redeemStable(uint256 _epoch) external whenNotPaused returns (uint256) {
        bytes32 userRole = whitelistController.getUserRole(msg.sender);
        IWhitelistController.RoleInfo memory info = whitelistController.getRoleInfo(userRole);

        WithdrawalSignal memory userWithdrawalSignal = userSignal[msg.sender][_epoch];

        if (currentEpoch() < userWithdrawalSignal.targetEpoch || userWithdrawalSignal.targetEpoch == 0) {
            revert Errors.NotRightEpoch();
        }

        if (userWithdrawalSignal.redeemed) {
            revert Errors.WithdrawalAlreadyCompleted();
        }

        if (userWithdrawalSignal.commitedShares == 0) {
            revert Errors.WithdrawalWithNoShares();
        }

        uint256 stableAmount = glpStableVault.previewRedeem(userWithdrawalSignal.commitedShares);
        uint256 stablesFromVault = _borrowStables(stableAmount);
        uint256 gmxIncentive;

        IBaklavaGlpLeverageStrategy _strategy = strategy;

        // Only redeem from strategy if there is not enough on the vault
        if (stablesFromVault < stableAmount) {
            uint256 difference = stableAmount - stablesFromVault;
            gmxIncentive = (difference * _strategy.getRedeemStableGMXIncentive(difference) * 1e8) / BASIS_POINTS;
            _strategy.onStableRedeem(difference, difference - gmxIncentive);
        }

        uint256 remainderStables = stableAmount - gmxIncentive;

        IERC20Upgradeable stableToken = stable;

        if (stableToken.balanceOf(address(this)) < remainderStables) {
            revert Errors.NotEnoughStables();
        }
        
        glpStableVault.burn(address(this), userWithdrawalSignal.commitedShares);

        userSignal[msg.sender][_epoch] = WithdrawalSignal(
            userWithdrawalSignal.targetEpoch, userWithdrawalSignal.commitedShares, true);

        uint256 retention = ((stableAmount * info.jUSDC_RETENTION) / BASIS_POINTS);

        uint256 realRetention = gmxIncentive < retention ? retention - gmxIncentive : 0;

        uint256 amountAfterRetention = remainderStables - realRetention;

        if (amountAfterRetention > 0) {
            stableToken.transfer(msg.sender, amountAfterRetention);
        }

        if (realRetention > 0) {
            stableToken.transfer(address(glpStableVault), realRetention);
        }

        // Information needed to calculate stable retention
        emit RedeemStable(msg.sender, amountAfterRetention, retention, realRetention);

        return amountAfterRetention;
    }


    // ============================= Governor functions ================================ //
    /**
     * @notice Set exit cooldown length in days
     * @param _days amount of days a user needs to wait to withdraw his stables
     */
    function setExitCooldown(uint256 _days) external onlyRole(GOVERNOR_ROLE) {
        EXIT_COOLDOWN = _days * EPOCH_DURATION;
    }

    /**
     * @notice Set Bava Rewards Contract
     * @param _glpBavaRewards Contract that manage Bava Rewards for Glp Vault
     * @param _stableBavaRewards Contract that manage Bava Rewards for Stable Vault
     */
    function setBavaRewards(IGlpBavaRewards _glpBavaRewards, IGlpBavaRewards _stableBavaRewards) external onlyRole(GOVERNOR_ROLE) {
        glpBavaRewards = _glpBavaRewards;
        stableBavaRewards = _stableBavaRewards;
    }

    /**
     * @notice Set Leverage Strategy Contract
     * @param _leverageStrategy Leverage Strategy address
     */
    function setLeverageStrategy(address _leverageStrategy) external onlyRole(GOVERNOR_ROLE) {
        strategy = IBaklavaGlpLeverageStrategy(_leverageStrategy);
    }

    /**
     * @notice Set a new incentive Receiver address
     * @param _newIncentiveReceiver Incentive Receiver Address
     */
    function setIncentiveReceiver(address _newIncentiveReceiver) external onlyRole(GOVERNOR_ROLE) {
        incentiveReceiver = IIncentiveReceiver(_newIncentiveReceiver);
    }

    /**
     * @notice Set GLP Adapter Contract
     * @param _adapter GLP Adapter address
     */
    function setGlpAdapter(address _adapter) external onlyRole(GOVERNOR_ROLE) {
        adapter = _adapter;
    }

    /**
     * @notice Emergency withdraw UVRT in this contract
     * @param _to address to send the funds
     */
    function emergencyWithdraw(address _to) external onlyRole(GOVERNOR_ROLE) {
        IERC20Upgradeable UVRT = IERC20Upgradeable(address(glpStableVault));
        uint256 currentBalance = UVRT.balanceOf(address(this));

        if (currentBalance == 0) {
            return;
        }

        UVRT.transfer(_to, currentBalance);

        emit EmergencyWithdraw(_to, currentBalance);
    }


    // ============================= OWNER functions ================================ //

    function pause() public onlyRole(OWNER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(OWNER_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(OWNER_ROLE)
        override
    {}

    function setAsset(address _glp, address _stable, address _yrt) external onlyRole(OWNER_ROLE) {
        glp = IERC20Upgradeable(_glp);
        stable = IERC20Upgradeable(_stable);
        yrt = IYakStrategyV2(_yrt);
    }

    // ============================= Private functions ================================ //

    function _depositGlp(uint256 _assets)
        private
        returns (uint256)
    {
        address vaultAddress = address(glpVault);
        uint256 vaultShares;
        
        glp.transferFrom(msg.sender, address(this), _assets);
       
        uint256 glpMintIncentives = strategy.glpMintIncentive(_assets);
        uint256 assetToDeposit = _assets - glpMintIncentives;

        glp.approve(vaultAddress, assetToDeposit);
        vaultShares = glpVault.deposit(assetToDeposit, address(this));

        if (glpMintIncentives > 0) {
            glp.transfer(vaultAddress, glpMintIncentives);
        }

        return (vaultShares);
    }

    function _depositStable(uint256 _assets)
        private
        returns (uint256)
    {
        stable.transferFrom(msg.sender, address(this), _assets);

        address vaultAddress = address(glpStableVault);
        uint256 vaultShares;

        stable.approve(vaultAddress, _assets);

        vaultShares = glpStableVault.deposit(_assets, address(this));
        emit VaultDeposit(vaultAddress, _assets, 0);

        return (vaultShares);
    }

    function _distributeGlp(uint256 _amount, address _dest) private returns (uint256) {
        uint256 retention = _chargeIncentive(_amount, _dest);
        uint256 wavaxAmount;

        if (retention > 0) {
            wavaxAmount = router.unstakeAndRedeemGlp(wavax, retention, 0, address(this));
            IERC20Upgradeable(wavax).transfer(address(incentiveReceiver), wavaxAmount);
        }

        uint256 glpAfterRetention = _amount - retention;

        glp.transfer(_dest, glpAfterRetention);

        // Information needed to calculate glp retention
        emit RedeemGlp(_dest, glpAfterRetention, retention, wavaxAmount, address(0), 0);

        return glpAfterRetention;
    }

    function _distributeGlpAdapter(uint256 _amount, address _dest, address _token, bool _native)
        private
        returns (uint256)
    {
        uint256 retention = _chargeIncentive(_amount, _dest);
        uint256 wavaxAmount;

        if (retention > 0) {
            wavaxAmount = router.unstakeAndRedeemGlp(wavax, retention, 0, address(this));
            IERC20Upgradeable(wavax).transfer(address(incentiveReceiver), wavaxAmount);
        }

        if (_native) {
            uint256 avaxAmount = router.unstakeAndRedeemGlpETH(_amount - retention, 0, payable(_dest));

            // Information needed to calculate glp retention
            emit RedeemGlp(_dest, _amount - retention, retention, wavaxAmount, address(0), avaxAmount);

            return avaxAmount;
        }

        uint256 assetAmount = router.unstakeAndRedeemGlp(_token, _amount - retention, 0, _dest);

        // Information needed to calculate glp retention
        emit RedeemGlp(_dest, _amount - retention, retention, wavaxAmount, _token, 0);

        return assetAmount;
    }

    function _redeemDirectly(uint256 _shares, uint256 _retention) private returns (uint256) {
        uint256 stableAmount = glpStableVault.previewRedeem(_shares);
        uint256 stablesFromVault = _borrowStables(stableAmount);
        uint256 gmxIncentive;

        IBaklavaGlpLeverageStrategy _strategy = strategy;

        // Only redeem from strategy if there is not enough on the vault
        if (stablesFromVault < stableAmount) {
            uint256 difference = stableAmount - stablesFromVault;
            gmxIncentive = (difference * _strategy.getRedeemStableGMXIncentive(difference) * 1e8) / BASIS_POINTS;
            _strategy.onStableRedeem(difference, difference - gmxIncentive);
        }

        uint256 remainderStables = stableAmount - gmxIncentive;

        IERC20Upgradeable stableToken = stable;

        if (stableToken.balanceOf(address(this)) < remainderStables) {
            revert Errors.NotEnoughStables();
        }
        
        glpStableVault.burn(address(this), _shares);

        uint256 retention = ((stableAmount * _retention) / BASIS_POINTS);
        uint256 realRetention = gmxIncentive < retention ? retention - gmxIncentive : 0;
        uint256 amountAfterRetention = remainderStables - realRetention;

        if (amountAfterRetention > 0) {
            stableToken.transfer(msg.sender, amountAfterRetention);
        }

        if (realRetention > 0) {
            stableToken.transfer(address(glpStableVault), realRetention);
        }

        // Information needed to calculate stable retentions
        emit RedeemStable(msg.sender, amountAfterRetention, retention, realRetention);

        return amountAfterRetention;
    }

    function _borrowStables(uint256 _amount) private returns (uint256) {
        uint256 balance = stable.balanceOf(address(glpStableVault));

        if (balance == 0) {
            return 0;
        }

        uint256 amountToBorrow = balance < _amount ? balance : _amount;

        emit BorrowStables(amountToBorrow);

        return glpStableVault.borrow(amountToBorrow);
    }

    // ============================= Private View functions ================================ //
    /**
     * @notice Return user charge incentive
     * @param _withdrawAmount withdrawal amount in glp
     * @param _sender address of user
     * @return charge rentention amount in glp
     */
    function _chargeIncentive(uint256 _withdrawAmount, address _sender) private view returns (uint256) {
        bytes32 userRole = whitelistController.getUserRole(_sender);
        IWhitelistController.RoleInfo memory info = whitelistController.getRoleInfo(userRole);

        return (_withdrawAmount * info.jGLP_RETENTION) / BASIS_POINTS;
    }

    function _onlyInternalContract() private view {
        if (!whitelistController.isInternalContract(msg.sender)) {
            revert Errors.CallerIsNotInternalContract();
        }
    }

    function _onlyEOA() private view {
        if (msg.sender != tx.origin && !whitelistController.isWhitelistedContract(msg.sender)) {
            revert Errors.CallerIsNotWhitelisted();
        }
    }

    // ============================= Public View functions ================================ //
    /**
     * @notice Return user withdrawal signal
     * @param user address of user
     * @param epoch address of user
     * @return Target Epoch
     * @return Commited shares
     * @return Redeem boolean
     */
    function withdrawSignal(address user, uint256 epoch) external view returns (uint256, uint256, bool) {
        WithdrawalSignal memory userWithdrawalSignal = userSignal[user][epoch];
        return (
            userWithdrawalSignal.targetEpoch,
            userWithdrawalSignal.commitedShares,
            userWithdrawalSignal.redeemed
        );
    }

    /**
     * @notice Return the max amount of GLP that can be deposit in order to be align with the target leverage
     * @return GLP Cap
     */
    function getMaxCapGlp() public view returns (uint256) {
        return (glpStableVault.tvl() * BASIS_POINTS) / (strategy.getTargetLeverage() - BASIS_POINTS); // 18 decimals
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp / EPOCH_DURATION) * EPOCH_DURATION;
    }

    // ============================= Event functions ================================ //

    event DepositGlp(address indexed _to, uint256 _amount, uint256 _sharesReceived);
    event DepositStables(address indexed _to, uint256 _amount, uint256 _sharesReceived);
    event VaultDeposit(address indexed vault, uint256 _amount, uint256 _retention);
    event RedeemGlp(
        address indexed _to,
        uint256 _amount,
        uint256 _retentions,
        uint256 _avaxRetentions,
        address _token,
        uint256 _avaxAmount
    );
    event RedeemStable(
        address indexed _to, uint256 _amount, uint256 _retentions, uint256 _realRetentions);
    event ClaimRewards(address indexed _to, uint256 _amountBava);
    event CompoundGlp(address indexed _to, uint256 _amount);
    event CompoundStables(address indexed _to, uint256 _amount);
    event BorrowStables(uint256 indexed _amountBorrowed);
    event StableWithdrawalSignal(
        address indexed sender, uint256 _shares, uint256 indexed _targetEpochTs);
    event CancelStableWithdrawalSignal(address indexed sender, uint256 _shares, bool _compound);
    event EmergencyWithdraw(address indexed _to, uint256 indexed _amount);
}