// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IYakStrategyV2 is IERC20Upgradeable {

    function getDepositTokensForShares(uint amount) external view returns (uint);
    
    function getSharesForDepositTokens(uint amount) external view returns (uint);

    function deposit(uint256 amount) external;

    function depositFor(address account, uint256 amount) external;

    function withdraw(uint256 amount) external;

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    function totalDeposits() external view returns (uint256);

    function totalSupply() external view returns (uint256);

}