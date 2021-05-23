// SPDX-License-Identifier: MIT
// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IFeeDistributor {
    function distribute(address _token) external;
}