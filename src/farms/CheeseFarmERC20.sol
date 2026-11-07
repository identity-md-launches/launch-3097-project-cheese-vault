// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CheeseFarm} from "../CheeseFarm.sol";

/// @title CheeseFarmERC20
/// @notice Farm for a fixed ERC-20 principal asset. The launch deploys one with CHEESE itself as the asset
///         (the CHEESE Pool, 400 points). Fee-on-transfer assets are handled by measuring the received amount.
contract CheeseFarmERC20 is CheeseFarm {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    constructor(address owner_, address controller_, address asset_) CheeseFarm(owner_, controller_) {
        if (asset_ == address(0)) revert ZeroAddress();
        asset = IERC20(asset_);
    }

    /// @notice Deposits `amount` of the asset (approve first) and mints shares. 0% fee.
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        return _deposit(amount, 0);
    }

    function _pull(uint256 amount, uint256) internal override returns (uint256 received) {
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        received = asset.balanceOf(address(this)) - before;
    }

    function _push(address to, uint256 amount) internal override {
        asset.safeTransfer(to, amount);
    }

    function _assetBalance() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _assetIsCheese() internal view override returns (bool) {
        return address(asset) == controller.token();
    }
}
