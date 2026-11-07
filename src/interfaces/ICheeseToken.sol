// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICheeseToken is IERC20 {
    function MAX_SUPPLY() external view returns (uint256);
    function emissionAuthority() external view returns (address);
    function totalMinted() external view returns (uint256);
    function totalPreminted() external view returns (uint256);
    function totalBurned() external view returns (uint256);
    function mintEmission(address to, uint256 amount) external;
}
