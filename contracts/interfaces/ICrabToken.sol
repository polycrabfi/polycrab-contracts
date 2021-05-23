// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface ICrabToken is IERC20Upgradeable {
    function mint(address _to, uint256 _amount) external;
}