// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseFarm} from "../src/CheeseFarm.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmSIMD} from "../src/farms/CheeseFarmSIMD.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {FeeOnTransferERC20, BlockingERC20} from "./mocks/MockERC20.sol";
import {ReentrantWithdrawer, RejectsETH, BurnsGas, NoReceive} from "./mocks/Attackers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

/// @notice Deposit and withdrawal accounting, the 15% Hamster Bite, last-depositor exit, reward claim
///         independence, no retroactive rewards, rewards after emission ends, reentrancy, access control,
///         Treasury payment deferral, rounding safety and Squeekchain outages.
contract FarmTest is CheeseBase {
    using stdStorage for StdStorage;

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
        assertEq(paid, gross - (gross * 1500) / 10_000);
        assertEq(ethFarm.totalShares(), 0);
        // the virtual offset's dust goes to the Treasury with the fee; nothing is stranded
        assertEq(ethFarm.totalAssets(), 0);
        assertEq(address(ethFarm).balance, 0);
    }

    function test_emptyFarmSweepsResidualRetainedFeeToTreasury() public {
        // alice's retained 14% accrues partly to the virtual shares while bob holds only 1000 real shares
        depositEth(alice, 1 ether);
        depositEth(bob, 1);
        withdrawAll(ethFarm, alice);
        uint256 bobAssets = ethFarm.assetsOf(bob);
        assertLt(bobAssets, 0.14 ether, "most of the retained fee sits on the virtual shares");
        uint256 treasuryBefore = treasury.balance;
        (uint256 gross, uint256 paid,, uint256 toTreasury) = ethFarm.previewWithdraw(ethFarm.sharesOf(bob));
        assertEq(gross, bobAssets);
        assertEq(toTreasury, ethFarm.totalAssets() - paid, "fee plus the stranded residual");
        assertEq(withdrawAll(ethFarm, bob), paid);
        assertEq(treasury.balance - treasuryBefore, toTreasury);
        assertEq(ethFarm.totalShares(), 0);
        assertEq(ethFarm.totalAssets(), 0, "nothing stranded");
        assertEq(address(ethFarm).balance, 0);
        // the farm restarts at the initial price, so small deposits work again
        assertEq(depositEth(carol, 0.1 ether), 0.1 ether * 1e3);
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

    // ---- Treasury that cannot receive ----

    function test_revertingTreasuryNeverBlocksWithdrawalEvenWithoutAnOwner() public {
        depositEth(alice, 10 ether);
        depositEth(bob, 10 ether);
        RejectsETH bad = new RejectsETH();
        vm.startPrank(owner);
        controller.setTreasury(address(bad));
        controller.renounceOwnership();
        vm.stopPrank();

        uint256 shares = ethFarm.sharesOf(alice);
        (, uint256 paid,, uint256 toTreasury) = ethFarm.previewWithdraw(shares);
        uint256 aliceBefore = alice.balance;
        vm.expectEmit(address(ethFarm));
        emit CheeseFarm.TreasuryPaymentDeferred(address(bad), toTreasury);
        vm.prank(alice);
        assertEq(ethFarm.withdraw(shares), paid);
        assertEq(alice.balance - aliceBefore, paid, "85% paid regardless of the Treasury");
        assertEq(ethFarm.treasuryOwed(), toTreasury);
        assertEq(address(bad).balance, 0);
        assertEq(address(ethFarm).balance, ethFarm.totalAssets() + ethFarm.treasuryOwed());
        assertEq(ethFarm.surplus(), 0, "the deferred share is reserved, not skimmable");
        // the deferred share waits for a Treasury that can receive it
        vm.expectRevert(abi.encodeWithSelector(CheeseFarm.NativeTransferFailed.selector, address(bad), toTreasury));
        ethFarm.payTreasury();
        // bob can leave too; the last withdrawer's full fee is deferred the same way
        uint256 owedBefore = ethFarm.treasuryOwed();
        (, uint256 bobPaid,, uint256 bobTreasury) = ethFarm.previewWithdraw(ethFarm.sharesOf(bob));
        assertEq(withdrawAll(ethFarm, bob), bobPaid);
        assertEq(ethFarm.treasuryOwed(), owedBefore + bobTreasury);
        assertEq(ethFarm.totalAssets(), 0);
    }

    function test_deferredTreasuryShareIsPaidOnceTheTreasuryCanReceive() public {
        depositEth(alice, 4 ether);
        depositEth(bob, 4 ether);
        RejectsETH bad = new RejectsETH();
        vm.prank(owner);
        controller.setTreasury(address(bad));
        (,,, uint256 toTreasury) = ethFarm.previewWithdraw(ethFarm.sharesOf(alice));
        withdrawAll(ethFarm, alice);
        assertEq(ethFarm.treasuryOwed(), toTreasury);
        vm.expectRevert(CheeseFarm.NothingOwedToTreasury.selector);
        cheeseFarm.payTreasury();
        // the owner repoints the Treasury; anyone can then push the owed amount
        vm.prank(owner);
        controller.setTreasury(treasury);
        uint256 before = treasury.balance;
        vm.expectEmit(address(ethFarm));
        emit CheeseFarm.TreasuryPaid(treasury, toTreasury);
        vm.prank(carol);
        assertEq(ethFarm.payTreasury(), toTreasury);
        assertEq(treasury.balance - before, toTreasury);
        assertEq(ethFarm.treasuryOwed(), 0);
        vm.expectRevert(CheeseFarm.NothingOwedToTreasury.selector);
        ethFarm.payTreasury();
        // a working Treasury is paid directly again
        before = treasury.balance;
        (,,, uint256 bobTreasury) = ethFarm.previewWithdraw(ethFarm.sharesOf(bob));
        withdrawAll(ethFarm, bob);
        assertEq(treasury.balance - before, bobTreasury);
        assertEq(ethFarm.treasuryOwed(), 0);
    }

    function test_gasBurningOrReceiverlessTreasuryIsDeferredToo() public {
        depositEth(alice, 2 ether);
        depositEth(bob, 2 ether);
        BurnsGas burner = new BurnsGas();
        NoReceive silent = new NoReceive();
        vm.prank(owner);
        controller.setTreasury(address(burner));
        (, uint256 paid,, uint256 toTreasury) = ethFarm.previewWithdraw(ethFarm.sharesOf(alice));
        uint256 gasBefore = gasleft();
        assertEq(withdrawAll(ethFarm, alice), paid);
        assertLt(gasBefore - gasleft(), 1_000_000, "the stipend bounds what a hostile Treasury can burn");
        assertEq(ethFarm.treasuryOwed(), toTreasury);
        vm.prank(owner);
        controller.setTreasury(address(silent));
        (, uint256 bobPaid,, uint256 bobTreasury) = ethFarm.previewWithdraw(ethFarm.sharesOf(bob));
        assertEq(withdrawAll(ethFarm, bob), bobPaid);
        assertEq(ethFarm.treasuryOwed(), toTreasury + bobTreasury);
    }

    function test_erc20FarmDefersTreasuryShareTheTokenRefusesToDeliver() public {
        BlockingERC20 token = new BlockingERC20();
        CheeseFarmSIMD farm = new CheeseFarmSIMD(owner, address(controller));
        vm.prank(owner);
        farm.setAsset(address(token));
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(farm), 100e18);
        farm.deposit(100e18);
        vm.stopPrank();
        token.setBlocked(treasury, true);
        (, uint256 paid,, uint256 toTreasury) = farm.previewWithdraw(farm.sharesOf(alice));
        assertEq(withdrawAll(farm, alice), paid);
        assertEq(token.balanceOf(alice), paid);
        assertEq(farm.treasuryOwed(), toTreasury);
        assertEq(token.balanceOf(address(farm)), toTreasury);
        vm.expectRevert("recipient blocked");
        farm.payTreasury();
        token.setBlocked(treasury, false);
        assertEq(farm.payTreasury(), toTreasury);
        assertEq(token.balanceOf(treasury), toTreasury);
        assertEq(token.balanceOf(address(farm)), 0);
    }

    function test_cheeseFarmDeferredTreasuryShareIsReservedAgainstSkim() public {
        activateWithHistory(0);
        depositCheese(alice, 100e18);
        depositCheese(bob, 100e18);
        advanceBlocks(10);
        // CHEESE is a plain OpenZeppelin ERC-20, so the Treasury push cannot fail; the reserve bookkeeping is
        // still exercised through the owed path by a mocked failed transfer.
        (,,, uint256 toTreasury) = cheeseFarm.previewWithdraw(cheeseFarm.sharesOf(alice));
        vm.mockCall(address(cheese), abi.encodeCall(cheese.transfer, (treasury, toTreasury)), abi.encode(false));
        withdrawAll(cheeseFarm, alice);
        vm.clearMockedCalls();
        assertEq(cheeseFarm.treasuryOwed(), toTreasury);
        assertEq(cheeseFarm.surplus(), 0);
        assertGe(
            cheese.balanceOf(address(cheeseFarm)),
            cheeseFarm.totalAssets() + cheeseFarm.rewardReserve() + cheeseFarm.treasuryOwed()
        );
        vm.prank(owner);
        vm.expectRevert(CheeseFarm.NothingToSkim.selector);
        cheeseFarm.skimSurplus();
        uint256 before = cheese.balanceOf(treasury);
        cheeseFarm.payTreasury();
        assertEq(cheese.balanceOf(treasury) - before, toTreasury);
        // rewards are untouched by any of it
        vm.prank(bob);
        assertGt(cheeseFarm.claim(bob), 0);
    }

    // ---- rounding and accumulator growth ----

    function test_oneWeiFirstDepositorCannotBrickLaterDeposits() public {
        activateWithHistory(0);
        depositEth(alice, 1); // 1000 shares alone in the farm
        assertEq(ethFarm.totalShares(), 1000);
        for (uint256 i; i < 24; ++i) {
            advanceBlocks(40);
            controller.checkpoint();
        }
        // bob's deposit pulls 960 blocks of emission over 1000 shares: the accumulator becomes astronomically
        // large and shares * acc no longer fits in 256 bits; 512-bit products keep every deposit size usable
        uint256 shares = depositEth(bob, 100 ether);
        assertEq(shares, (100 ether * (1000 + 1000)) / (1 + 1));
        assertGt(ethFarm.accRewardPerShare(), type(uint256).max / shares, "plain product would overflow");
        assertEq(ethFarm.pendingRewards(bob), 0, "nothing from before bob's deposit");
        advanceBlocks(40);
        uint256 next = ((issued(1000) - issued(960)) * 200) / 1000;
        assertApproxEqAbs(ethFarm.pendingRewards(bob), (next * shares) / ethFarm.totalShares(), 4);
        vm.prank(alice);
        uint256 aliceClaim = ethFarm.claim(alice);
        assertApproxEqAbs(aliceClaim, (issued(960) * 200) / 1000 + (next * 1000) / ethFarm.totalShares(), 4);
        withdrawAll(ethFarm, bob);
        vm.prank(bob);
        ethFarm.claim(bob);
        assertLe(cheese.balanceOf(alice) + cheese.balanceOf(bob), controller.totalMinted());
    }

    function test_everyAccountCanClaimAfterEmissionEnds() public {
        // Twelve deposits by five accounts, 1 to 80 blocks apart, no withdrawals: floored reward debts used to
        // let the entitlements sum one wei above the reserve, so the last claim reverted for good.
        activateWithHistory(0);
        address[5] memory users = [alice, bob, carol, makeAddr("dave"), makeAddr("erin")];
        for (uint256 i = 3; i < 5; ++i) {
            vm.deal(users[i], 1_000 ether);
        }
        for (uint256 k; k < 12; ++k) {
            uint256 r = uint256(keccak256(abi.encode(13, k)));
            depositEth(users[r % 5], 0.01 ether + (r >> 16) % 5 ether);
            advanceBlocks(uint64(1 + (r >> 200) % 80));
        }
        advanceBlocks(3 * H);
        controller.checkpoint();
        assertTrue(controller.completed());
        uint256 paidTotal;
        for (uint256 i; i < 5; ++i) {
            uint256 pending = ethFarm.pendingRewards(users[i]);
            vm.prank(users[i]);
            uint256 paid = ethFarm.claim(users[i]);
            assertEq(paid, pending, "claim pays exactly what pendingRewards reports");
            paidTotal += paid;
        }
        uint256 minted = cheese.balanceOf(address(ethFarm)) + paidTotal;
        assertLe(paidTotal, minted);
        assertLe(minted - paidTotal, 16, "at most a wei per share change stays as dust");
        assertEq(ethFarm.rewardReserve(), minted - paidTotal);
    }

    function test_claimNeverRevertsOnReserveShortfall() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        depositEth(bob, 1 ether); // pulls alice's 10 blocks of emission into the farm's reserve
        uint256 pending = ethFarm.pendingRewards(alice);
        uint256 reserve = ethFarm.rewardReserve();
        assertEq(pending, reserve);
        // A shortfall cannot arise from the accounting (debts round up); force one to show that the clamp pays
        // what exists, keeps the rest pending, and never reverts.
        uint256 slot = stdstore.target(address(ethFarm)).sig("rewardReserve()").find();
        vm.store(address(ethFarm), bytes32(slot), bytes32(reserve - 1));
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), reserve - 1, "pays what the reserve holds");
        assertEq(ethFarm.pendingRewards(alice), 1, "the wei short stays pending");
        vm.store(address(ethFarm), bytes32(slot), bytes32(uint256(1)));
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), 1);
        assertEq(ethFarm.pendingRewards(alice), 0);
    }

    // ---- Squeekchain outages ----

    function test_depositWaitsForSyncWhileWithdrawAndClaimDoNot() public {
        activateWithHistory(0);
        depositEth(alice, 10 ether);
        advanceBlocks(1000); // certified, not yet priced
        core.setUnavailable(true);
        vm.prank(bob);
        vm.expectRevert(CheeseFarm.SyncRequired.selector);
        ethFarm.deposit{value: 10 ether}();
        // alice can still leave and claim what was priced so far
        uint256 half = ethFarm.sharesOf(alice) / 2;
        vm.prank(alice);
        ethFarm.withdraw(half);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), 0);
        core.setUnavailable(false);
        depositEth(bob, 10 ether);
        uint256 poolShare = (issued(1000) * 200) / 1000;
        vm.prank(alice);
        assertApproxEqAbs(ethFarm.claim(alice), poolShare, 2, "alice gets every block certified before bob");
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), 0, "bob gets nothing from before his deposit");
    }

    function test_firstDepositDuringOutageCannotInheritForfeitableEmission() public {
        activateWithHistory(0);
        advanceBlocks(100); // the ETH farm is empty: this emission must be forfeited, never paid
        core.setUnavailable(true);
        vm.prank(alice);
        vm.expectRevert(CheeseFarm.SyncRequired.selector);
        ethFarm.deposit{value: 1 ether}();
        core.setUnavailable(false);
        depositEth(alice, 1 ether);
        assertEq(controller.forfeitedEmission(), (issued(100) * 200) / 1000);
        assertEq(ethFarm.pendingRewards(alice), 0);
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
