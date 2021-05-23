// SPDX-License-Identifier: No license

pragma solidity 0.6.12;

interface IStrategy {
    function invest() external;
    function withdraw(uint256 _amount) external;
    function withdrawAll() external;
    function emergencyExit() external;
    function harvest() external;
    function investedUnderlyingBalance() external view returns (uint256);
    function collectToken(address _token, uint256 _amount) external;
    function underlying() external view returns (address);
    function unsalvageableTokens(address _token) external view returns (bool);
}