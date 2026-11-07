// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseFarm} from "../src/CheeseFarm.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmSIMD} from "../src/farms/CheeseFarmSIMD.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {FeeOnTransferERC20} from "./mocks/MockERC20.sol";
import {ReentrantWithdrawer, RejectsETH} from "./mocks/Attackers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Deposit and withdrawal accounting, the 15% Hamster Bite, last-depositor exit, reward claim
///         independence, no retroactive rewards, rewards after emission ends, reentrancy, access control.
contract FarmTest is CheeseBase {
    // ---- deposits ----

    function test_depositMintsSharesOneToOneInitially() public {
        uint256 shares = depositEth(alice, 10 ether);
        // virtual offset: shares = assets * (0 + 1e3) / (0 + 1) = assets * 1e3
        assertEq(shares, 10 ether * 1e3);
        assertEq(ethFarm.totalShares(), shares);
        assertEq(ethFarm.totalAssets(), 10 ether);
        assertEq(ethFarm.assetsOf(alice), 10 ether);
        assertEq(address(ethFarm).balance, 10 ether);
    }

    function test_depositRejectsZeroAndPausedAndUnconfigured() public {
        vm.prank(alice);
        vm.expectRevert(CheeseFarm.ZeroAmount.selector);
        ethFarm.deposit{value: 0}();
        vm.prank(owner);
        ethFarm.setDepositsPaused(true);
        vm.prank(alice);
        vm.expectRevert(CheeseFarm.DepositsArePaused.selector);
        ethFarm.deposit{value: 1 ether}();
        vm.prank(owner);
        ethFarm.setDepositsPaused(false);
        // sIMD farm without an asset
        CheeseFarmSIMD bare = new CheeseFarmSIMD(owner, address(controller));
        vm.prank(alice);
        vm.expectRevert(CheeseFarm.AssetNotConfigured.selector);
        bare.deposit(1);
        vm.prank(owner);
        vm.expectRevert(CheeseFarmSIMD.AssetIsNotAContract.selector);
        bare.setAsset(alice);
        vm.prank(owner);
        bare.setAsset(address(simd));
        vm.prank(owner);
        vm.expectRevert(CheeseFarmSIMD.AssetAlreadySet.selector);
        bare.setAsset(address(simd));
    }

    function test_depositsCloseWhileEmissionsPausedWithdrawalsStayOpen() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        vm.prank(owner);
        controller.pauseEmissions();
        vm.prank(bob);
        vm.expectRevert(CheeseFarm.EmissionsPausedDepositsClosed.selector);
        ethFarm.deposit{value: 1 ether}();
        withdrawAll(ethFarm, alice);
    }

    function test_directEthTransferRejected() public {
        (bool ok,) = address(ethFarm).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_feeOnTransferAssetCreditsReceivedAmount() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        CheeseFarmERC20 farm = new CheeseFarmERC20(owner, address(controller), address(fee));
        fee.mint(alice, 100e18);
        vm.startPrank(alice);
        fee.approve(address(farm), 100e18);
        farm.deposit(100e18);
        vm.stopPrank();
        assertEq(farm.totalAssets(), 99e18);
        assertEq(fee.balanceOf(address(farm)), 99e18);
    }

    // ---- Hamster Bite ----

    function test_hamsterBiteSplit85_14_1() public {
        depositEth(alice, 10 ether);
        depositEth(bob, 10 ether);
        uint256 aliceShares = ethFarm.sharesOf(alice);
        (uint256 gross, uint256 paid, uint256 retained, uint256 toTreasury) = ethFarm.previewWithdraw(aliceShares);
        assertApproxEqAbs(gross, 10 ether, 2);
        assertEq(paid, gross - (gross * 1500) / 10_000);
        assertEq(retained, (gross * 1400) / 10_000);
        assertEq(toTreasury, (gross * 1500) / 10_000 - retained);

        uint256 aliceBefore = alice.balance;
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        uint256 got = ethFarm.withdraw(aliceShares);
        assertEq(got, paid);
        assertEq(alice.balance - aliceBefore, paid);
        assertEq(treasury.balance - treasuryBefore, toTreasury);
        assertEq(ethFarm.sharesOf(alice), 0);
        // retained 14% stays and now backs bob's shares
        assertEq(ethFarm.totalAssets(), 20 ether - paid - toTreasury);
        assertApproxEqAbs(ethFarm.assetsOf(bob), 10 ether + retained, 1e6);
        assertEq(address(ethFarm).balance, ethFarm.totalAssets());
    }

    function test_lastDepositorWithdrawalSendsFull15ToTreasury() public {
        depositEth(alice, 4 ether);
        uint256 shares = ethFarm.sharesOf(alice);
        (uint256 gross,, uint256 retained, uint256 toTreasury) = ethFarm.previewWithdraw(shares);
        assertEq(retained, 0);
        assertEq(toTreasury, (gross * 1500) / 10_000);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        uint256 paid = ethFarm.withdraw(shares);
        assertEq(treasury.balance - treasuryBefore, toTreasury);
        assertEq(paid, gross - toTreasury);
        assertEq(ethFarm.totalShares(), 0);
        // only virtual-offset dust (< 1e3 wei) can remain
        assertLt(ethFarm.totalAssets(), 1e3);
    }

    function test_partialWithdrawerBenefitsFromOwnRetainedShare() public {
        depositCheese(alice, 100e18);
        uint256 half = cheeseFarm.sharesOf(alice) / 2;
        vm.prank(alice);
        cheeseFarm.withdraw(half);
        // alice keeps half her shares, which now back the 14% retained from the half she withdrew
        uint256 remaining = cheeseFarm.assetsOf(alice);
        assertApproxEqAbs(remaining, 50e18 + (50e18 * 1400) / 10_000, 1e6);
        assertEq(cheese.balanceOf(address(cheeseFarm)), cheeseFarm.totalAssets() + cheeseFarm.rewardReserve());
    }

    function test_withdrawRejectsZeroAndTooMany() public {
        depositEth(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(CheeseFarm.ZeroShares.selector);
        ethFarm.withdraw(0);
        uint256 held = ethFarm.sharesOf(alice);
        vm.expectRevert(abi.encodeWithSelector(CheeseFarm.InsufficientShares.selector, held + 1, held));
        ethFarm.withdraw(held + 1);
        vm.stopPrank();
    }

    function test_noCooldownWithdrawSameBlockAsDeposit() public {
        depositEth(alice, 1 ether);
        assertGt(withdrawAll(ethFarm, alice), 0);
    }

    function test_feeWorksAfterEmissionEnds() public {
        activateWithHistory(0);
        depositEth(alice, 5 ether);
        advanceBlocks(3 * H + 1);
        controller.checkpoint();
        assertTrue(controller.completed());
        depositEth(bob, 5 ether);
        uint256 treasuryBefore = treasury.balance;
        uint256 paid = withdrawAll(ethFarm, bob);
        assertGt(paid, 0);
        assertGt(treasury.balance, treasuryBefore);
        vm.prank(alice);
        ethFarm.claim(alice);
        assertGt(cheese.balanceOf(alice), 0);
    }

    // ---- rewards ----

    function test_rewardsAccrueProRataAndClaimIsIndependentOfPrincipal() public {
        activateWithHistory(0);
        depositEth(alice, 3 ether);
        depositEth(bob, 1 ether);
        advanceBlocks(100);
        uint256 poolShare = (issued(100) * 200) / 1000;
        assertApproxEqAbs(ethFarm.pendingRewards(alice), (poolShare * 3) / 4, 1e6);
        assertApproxEqAbs(ethFarm.pendingRewards(bob), poolShare / 4, 1e6);
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        uint256 claimed = ethFarm.claim(alice);
        assertApproxEqAbs(claimed, (poolShare * 3) / 4, 1e6);
        assertEq(cheese.balanceOf(alice), claimed);
        assertEq(alice.balance, aliceEthBefore, "claim moves no principal");
        assertEq(ethFarm.sharesOf(alice), 3 ether * 1e3, "shares untouched by claim");
        assertEq(ethFarm.pendingRewards(alice), 0);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), 0, "nothing twice");
        // withdrawing principal leaves bob's unclaimed rewards intact
        withdrawAll(ethFarm, bob);
        assertApproxEqAbs(ethFarm.pendingRewards(bob), poolShare / 4, 1e6);
        vm.prank(bob);
        ethFarm.claim(carol);
        assertApproxEqAbs(cheese.balanceOf(carol), poolShare / 4, 1e6);
        assertEq(ethFarm.rewardReserve(), cheese.balanceOf(address(ethFarm)));
    }

    function test_newDepositorGetsNothingFromEarlierBlocks() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(100);
        depositEth(bob, 100 ether); // bob is much larger but arrives late
        uint256 poolShare = (issued(100) * 200) / 1000;
        assertEq(ethFarm.pendingRewards(bob), 0);
        assertApproxEqAbs(ethFarm.pendingRewards(alice), poolShare, 1e6);
        advanceBlocks(100);
        uint256 next = ((issued(200) - issued(100)) * 200) / 1000;
        assertApproxEqAbs(ethFarm.pendingRewards(bob), (next * 100) / 101, 1e9);
    }

    function test_emptyFarmEmissionIsForfeitedNotInherited() public {
        activateWithHistory(0);
        advanceBlocks(100); // the ETH farm has nobody
        depositEth(alice, 1 ether);
        assertEq(ethFarm.pendingRewards(alice), 0);
        assertEq(controller.forfeitedEmission(), (issued(100) * 200) / 1000);
        assertEq(controller.totalMinted(), 0);
        advanceBlocks(1);
        vm.prank(alice);
        uint256 claimed = ethFarm.claim(alice);
        assertEq(claimed, ((issued(101) - issued(100)) * 200) / 1000);
    }

    function test_cheeseFarmKeepsPrincipalAndRewardReservesApart() public {
        activateWithHistory(0);
        depositCheese(alice, 100e18);
        advanceBlocks(50);
        vm.prank(alice);
        cheeseFarm.claim(alice); // pulls rewards into the farm first, then pays alice
        // now alice withdraws everything: the payout must come from principal only
        uint256 pending = cheeseFarm.pendingRewards(alice);
        assertEq(pending, 0);
        advanceBlocks(50);
        controller.checkpoint();
        withdrawAll(cheeseFarm, alice);
        uint256 rewards = cheeseFarm.pendingRewards(alice);
        assertGt(rewards, 0);
        assertEq(cheeseFarm.rewardReserve(), rewards);
        assertGe(cheese.balanceOf(address(cheeseFarm)), cheeseFarm.totalAssets() + cheeseFarm.rewardReserve());
        vm.prank(alice);
        assertEq(cheeseFarm.claim(alice), rewards);
    }

    function test_donationsDoNotMoveSharePriceAndAreSkimmableOnly() public {
        depositCheese(alice, 1e18);
        giveCheese(address(cheeseFarm), 1_000e18); // donation
        uint256 shares = depositCheese(bob, 1e18);
        assertEq(shares, cheeseFarm.sharesOf(alice), "price unchanged by donation");
        assertEq(cheeseFarm.surplus(), 1_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cheeseFarm.skimSurplus();
        vm.prank(owner);
        cheeseFarm.skimSurplus();
        assertEq(cheese.balanceOf(treasury), 63_000_000e18 + 1_000e18);
        vm.prank(owner);
        vm.expectRevert(CheeseFarm.NothingToSkim.selector);
        cheeseFarm.skimSurplus();
    }

    function test_inflationAttackIsUneconomic() public {
        // attacker deposits 1 wei then tries to inflate via the retained fee by cycling; victim deposits after
        depositEth(alice, 1); // attacker
        for (uint256 i; i < 5; ++i) {
            depositEth(alice, 1 ether);
            uint256 sliver = ethFarm.sharesOf(alice) - 1_000; // leave a sliver
            vm.prank(alice);
            ethFarm.withdraw(sliver);
        }
        uint256 victimShares = depositEth(bob, 1 ether);
        assertGt(victimShares, 0, "victim is never zeroed");
        assertApproxEqRel(ethFarm.assetsOf(bob), 1 ether, 0.01e18, "victim keeps ~all value");
    }

    // ---- reentrancy ----

    function test_reentrancyBlockedOnWithdrawDepositAndClaim() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(ethFarm);
        vm.deal(address(attacker), 10 ether);
        attacker.deposit{value: 5 ether}();
        depositEth(bob, 5 ether);
        // the re-entrant call reverts inside receive(), which bubbles up as NativeTransferFailed
        vm.expectRevert();
        attacker.withdrawAll(true, false, false);
        vm.expectRevert();
        attacker.withdrawAll(false, true, false);
        vm.expectRevert();
        attacker.withdrawAll(false, false, true);
        assertEq(ethFarm.sharesOf(address(attacker)), 5 ether * 1e3, "nothing changed");
        assertEq(address(ethFarm).balance, 10 ether);
    }

    function test_blockedTreasuryCannotBeSetByNonOwnerAndOwnerCanFix() public {
        depositEth(alice, 1 ether);
        RejectsETH bad = new RejectsETH();
        vm.prank(owner);
        controller.setTreasury(address(bad));
        uint256 shares = ethFarm.sharesOf(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CheeseFarm.NativeTransferFailed.selector, address(bad), (1 ether * 1500) / 10_000)
        );
        ethFarm.withdraw(shares);
        vm.prank(owner);
        controller.setTreasury(treasury);
        withdrawAll(ethFarm, alice);
    }

    // ---- registration and ownership ----

    function test_onPoolRegisteredOnlyController() public {
        CheeseFarmETH f = new CheeseFarmETH(owner, address(controller));
        vm.expectRevert(abi.encodeWithSelector(CheeseFarm.NotController.selector, address(this)));
        f.onPoolRegistered(7);
        vm.prank(address(controller));
        f.onPoolRegistered(7);
        vm.prank(address(controller));
        vm.expectRevert(CheeseFarm.AlreadyRegistered.selector);
        f.onPoolRegistered(8);
        // unregistered farms still take deposits (no rewards) and withdraw normally
        vm.prank(alice);
        CheeseFarmETH bare = new CheeseFarmETH(owner, address(controller));
        vm.prank(alice);
        bare.deposit{value: 1 ether}();
        withdrawAll(bare, alice);
    }

    function test_ownerCannotTouchPrincipalOrRewards() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        vm.prank(alice);
        ethFarm.claim(alice);
        // The farm exposes no owner function that moves ETH or CHEESE besides skimSurplus, which has
        // nothing to skim when reserves are exact.
        vm.prank(owner);
        vm.expectRevert(CheeseFarm.NothingToSkim.selector);
        ethFarm.skimSurplus();
        assertEq(address(ethFarm).balance, ethFarm.totalAssets());
    }
}
