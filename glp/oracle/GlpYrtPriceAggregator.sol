// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IAggregatorV3} from "../../interfaces/IAggregatorV3.sol";
import {IGlpManager} from "../../interfaces/IGlpManager.sol";
import {IYakStrategyV2} from "../../interfaces/IYakStrategyV2.sol";

contract GlpYrtPriceAggregator is Initializable, UUPSUpgradeable, OwnableUpgradeable, IAggregatorV3 {
    IERC20Upgradeable public GLP;       // Avax Mainnet: 0x01234181085565ed162a948b6a5e88758CD7c7b8
    IGlpManager public GLP_MANAGER;     // Avax Mainnet: 0xe1ae4d4b06A5Fe1fc288f6B4CD72f9F8323B107F
    IYakStrategyV2 public yrt;

    uint256 initialTime;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _glp,
        address _glpManager
    ) initializer public {
        initialTime = block.timestamp;
        GLP = IERC20Upgradeable(_glp);
        GLP_MANAGER = IGlpManager(_glpManager);

        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function decimals() external pure returns (uint8) {
        return 12;
    }

    function description() external pure returns (string memory) {
        return "";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _getPrice(), initialTime, initialTime, 1);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _getPrice(), initialTime, initialTime, 1);
    }

    function _getPrice() internal view returns (int256) {
        int256 yrtPrice = int256(GLP_MANAGER.getAum(true) / GLP.totalSupply() * yrt.totalDeposits() / yrt.totalSupply());
        return yrtPrice;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}
}