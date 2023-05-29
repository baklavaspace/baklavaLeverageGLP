// SPDX-License-Identifier: UNLICENSED

// Copyright (c) 2023 Baklava Space - All rights reserved
// Baklava Space: https://www.baklava.space/

pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import {BaklavaBaseGlpVault} from "./BaklavaBaseGlpVault.sol";
import {IAggregatorV3} from "../../interfaces/IAggregatorV3.sol";

contract BaklavaGlpVault is Initializable, UUPSUpgradeable, BaklavaBaseGlpVault {
    using MathUpgradeable for uint256;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     * @param symbol: GYVRT
     *************************************************************/
    function initialize(
        IAggregatorV3 _priceOracle,
        IERC20MetadataUpgradeable _asset,
        address _owner,
        address _governor
    )
        public       
        initializer
    {
         __BavaBaseGlpVaultInit(
            _asset,
            "GLP Vault Receipt Token",
            "GVRT",
            _priceOracle,
            _owner,
            _governor
        );

        __UUPSUpgradeable_init();
    }

    // ============================= Public functions ================================ //

    function deposit(
        uint256 _assets,
        address _receiver
    ) public override(BaklavaBaseGlpVault) whenNotPaused returns (uint256) {
        return super.deposit(_assets, _receiver);
    }

    /**
     * @dev See {openzeppelin-IERC4626-_burn}.
     */
    function burn(address _user, uint256 _amount) public onlyRole(OPERATOR_ROLE) {
        _burn(_user, _amount);
    }

    /**
     * @notice Return total asset deposited
     * @return Amount of asset deposited
     */
    function totalAssets() public view override returns (uint256) {
        (uint256 underlying, , ) = strategy.getUnderlyingGlp();
        return super.totalAssets() + underlying;
    }

    // ============================= Internal functions ================================ //

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(OWNER_ROLE) {}
}
