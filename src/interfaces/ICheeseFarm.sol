// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICheeseFarm {
    function emissionController() external view returns (address);
    function poolId() external view returns (uint256);
    function registered() external view returns (bool);
    function onPoolRegistered(uint256 poolId) external;
}
