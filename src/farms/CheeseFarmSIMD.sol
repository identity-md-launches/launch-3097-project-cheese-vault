// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CheeseFarm} from "../CheeseFarm.sol";

/// @title CheeseFarmSIMD
/// @notice Farm for sIMD (the sIMD Pool, 200 points). The brief names the asset but gives no Sepolia address
///         for it, so the owner sets it once after launch with setAsset(); until then deposits revert with
///         AssetNotConfigured and the pool's emission is forfeited (never minted) when first pulled.
contract CheeseFarmSIMD is CheeseFarm {
    using SafeERC20 for IERC20;

    IERC20 public asset;

    event AssetSet(address indexed asset);

    error AssetAlreadySet();
    error AssetIsNotAContract();

    constructor(address owner_, address controller_) CheeseFarm(owner_, controller_) {}

    /// @notice Sets the sIMD token once. The address comes from the IMD sIMD deployment on Sepolia.
    function setAsset(address asset_) external onlyOwner {
        if (address(asset) != address(0)) revert AssetAlreadySet();
        if (asset_ == address(0)) revert ZeroAddress();
        if (asset_.code.length == 0) revert AssetIsNotAContract();
        asset = IERC20(asset_);
        emit AssetSet(asset_);
    }

    /// @notice Deposits `amount` of sIMD (approve first) and mints shares. 0% fee.
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        return _deposit(amount, 0);
    }

    function _assetConfigured() internal view override returns (bool) {
        return address(asset) != address(0);
    }

    function _pull(uint256 amount, uint256) internal override returns (uint256 received) {
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        received = asset.balanceOf(address(this)) - before;
    }

    function _push(address to, uint256 amount) internal override {
        if (!_assetConfigured()) revert AssetNotConfigured();
        asset.safeTransfer(to, amount);
    }

    function _tryPush(address to, uint256 amount) internal override returns (bool) {
        if (!_assetConfigured()) return false;
        return _tryTransferERC20(asset, to, amount);
    }

    function _assetBalance() internal view override returns (uint256) {
        if (!_assetConfigured()) return 0;
        return asset.balanceOf(address(this));
    }

    function _assetIsCheese() internal view override returns (bool) {
        return address(asset) == controller.token();
    }
}
