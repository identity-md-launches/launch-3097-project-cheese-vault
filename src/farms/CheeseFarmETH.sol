// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseFarm} from "../CheeseFarm.sol";

/// @title CheeseFarmETH
/// @notice Farm for native ETH (the ETH Pool, 200 points). Deposits are payable; plain transfers are refused
///         so principal can only enter through deposit().
contract CheeseFarmETH is CheeseFarm {
    error DirectTransferRejected();
    error ValueMismatch(uint256 declared, uint256 sent);

    constructor(address owner_, address controller_) CheeseFarm(owner_, controller_) {}

    /// @notice Deposits msg.value of ETH and mints shares. 0% fee.
    function deposit() external payable nonReentrant returns (uint256 shares) {
        return _deposit(msg.value, msg.value);
    }

    receive() external payable {
        revert DirectTransferRejected();
    }

    function _pull(uint256 amount, uint256 msgValue) internal pure override returns (uint256) {
        if (amount != msgValue) revert ValueMismatch(amount, msgValue);
        return amount;
    }

    function _push(address to, uint256 amount) internal override {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    function _assetBalance() internal view override returns (uint256) {
        return address(this).balance;
    }

    function _assetIsCheese() internal pure override returns (bool) {
        return false;
    }
}
