// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseFarmETH} from "../../src/farms/CheeseFarmETH.sol";

/// @notice Re-enters the ETH farm from the withdrawal payout.
contract ReentrantWithdrawer {
    CheeseFarmETH public immutable farm;
    uint256 public reentered;
    bool public attackWithdraw;
    bool public attackDeposit;
    bool public attackClaim;

    constructor(CheeseFarmETH farm_) {
        farm = farm_;
    }

    function deposit() external payable {
        farm.deposit{value: msg.value}();
    }

    function withdrawAll(bool viaWithdraw, bool viaDeposit, bool viaClaim) external {
        attackWithdraw = viaWithdraw;
        attackDeposit = viaDeposit;
        attackClaim = viaClaim;
        farm.withdraw(farm.sharesOf(address(this)));
    }

    receive() external payable {
        if (msg.sender != address(farm)) return;
        reentered++;
        if (attackWithdraw) {
            attackWithdraw = false;
            farm.withdraw(1);
        }
        if (attackDeposit) {
            attackDeposit = false;
            farm.deposit{value: 1}();
        }
        if (attackClaim) {
            attackClaim = false;
            farm.claim(address(this));
        }
    }
}

/// @notice Refuses ETH, to show a blocked Treasury cannot trap a withdrawal (treasury payout is pushed first).
contract RejectsETH {
    receive() external payable {
        revert("no");
    }
}
