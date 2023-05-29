// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IBaklavaGlpVaultRouter {
    function depositGlp(uint256 _assets, address _sender, bool _compound, bool _rebalance) external returns (uint256);
    function depositStable(uint256 _assets, address _user, bool _compound) external returns (uint256);
    function redeemGlpAdapter(uint256 _shares, bool _compound, address _token, address _user, bool _native)
        external
        returns (uint256);
    function redeemGlp(uint256 _shares, bool _compound)
        external
        returns (uint256);
}