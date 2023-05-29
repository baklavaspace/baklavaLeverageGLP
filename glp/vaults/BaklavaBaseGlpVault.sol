// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.10;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable, IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IAggregatorV3} from "../../interfaces/IAggregatorV3.sol";
import {IBaklavaGlpLeverageStrategy} from "../../interfaces/IBaklavaGlpLeverageStrategy.sol";
import {BaklavaOperableVault} from "../../vaults/BaklavaOperableVault.sol";

abstract contract BaklavaBaseGlpVault is BaklavaOperableVault, PausableUpgradeable {
    IBaklavaGlpLeverageStrategy public strategy;
    IAggregatorV3 public priceOracle;


    function __BavaBaseGlpVaultInit(IERC20MetadataUpgradeable _asset, string memory _name, string memory _symbol, IAggregatorV3 _priceOracle, address _owner, address _governor) internal{
        __ERC4626_init(_asset);
        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __AccessControl_init();

        priceOracle = _priceOracle;
        __LS1Roles_init(_owner, _governor);
    }

    // ============================= Operable functions ================================ //

    /**
     * @dev See {openzeppelin-IERC4626-deposit}.
     */
    function deposit(uint256 _assets, address _receiver)
        public
        virtual
        override
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(_assets, _receiver);
    }

    /**
     * @dev See {openzeppelin-IERC4626-mint}.
     */
    function mint(uint256 _shares, address _receiver)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        return super.mint(_shares, _receiver);
    }

    /**
     * @dev See {openzeppelin-IERC4626-withdraw}.
     */
    function withdraw(uint256 _assets, address _receiver, address _owner)
        public
        virtual
        override
        returns (uint256)
    {
        return super.withdraw(_assets, _receiver, _owner);
    }

    /**
     * @dev See {openzeppelin-IERC4626-redeem}.
     */
    function redeem(uint256 _shares, address _receiver, address _owner)
        public
        virtual
        override
        returns (uint256)
    {
        return super.redeem(_shares, _receiver, _owner);
    }


    // ============================= USD_Vault functions ================================ //

    function tvl() external view returns (uint256) {
        return _toUsdValue(totalAssets());
    }

    function _toUsdValue(uint256 _value) internal view returns (uint256) {
        IAggregatorV3 oracle = priceOracle;

        (, int256 currentPrice,,,) = oracle.latestRoundData();

        uint8 totalDecimals = IERC20MetadataUpgradeable(asset()).decimals() + oracle.decimals();
        uint8 targetDecimals = 18;

        return totalDecimals > targetDecimals
            ? (_value * uint256(currentPrice)) / 10 ** (totalDecimals - targetDecimals)
            : (_value * uint256(currentPrice)) * 10 ** (targetDecimals - totalDecimals);
    }




    // ============================= Borrower functions ================================ //

    function borrow(
        uint256 _amount
    ) external virtual onlyRole(BORROWER_ROLE) whenNotPaused returns (uint256) {
        IERC20Upgradeable(asset()).transfer(msg.sender, _amount);

        emit AssetsBorrowed(msg.sender, _amount);

        return _amount;
    }

    function repay(
        uint256 _amount
    ) external virtual onlyRole(BORROWER_ROLE) returns (uint256) {
        IERC20Upgradeable(asset()).transferFrom(
            msg.sender,
            address(this),
            _amount
        );

        emit AssetsRepayed(msg.sender, _amount);

        return _amount;
    }

    // ============================= Governable functions ================================ //

    /**
     * @notice Set new strategy address
     * @param _strategy Strategy Contract
     */
    function setStrategyAddress(IBaklavaGlpLeverageStrategy _strategy) external onlyRole(GOVERNOR_ROLE) {
        strategy = _strategy;
    }

    function setPriceAggregator(IAggregatorV3 _newPriceOracle) external onlyRole(GOVERNOR_ROLE) {
        emit PriceOracleUpdated(address(priceOracle), address(_newPriceOracle));

        priceOracle = _newPriceOracle;
    }

    function pause() public onlyRole(OWNER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(OWNER_ROLE) {
        _unpause();
    }

    event PriceOracleUpdated(address _oldPriceOracle, address _newPriceOracle);
    event AssetsBorrowed(address _borrower, uint256 _amount);
    event AssetsRepayed(address _borrower, uint256 _amount);

    error CallerIsNotBorrower();
}