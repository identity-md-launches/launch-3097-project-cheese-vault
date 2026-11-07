// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";

/// @notice Fuzzed accounting properties of a farm: conservation of assets, fee split, reward pro-rata.
contract FarmFuzzTest is CheeseBase {
    function testFuzz_depositWithdrawConservesAssets(uint96 a, uint96 b, uint96 fractionBps) public {
        uint256 da = bound(a, 1, 500 ether);
        uint256 db = bound(b, 1, 500 ether);
        uint256 frac = bound(fractionBps, 1, 10_000);
        depositEth(alice, da);
        depositEth(bob, db);
        uint256 shares = (ethFarm.sharesOf(alice) * frac) / 10_000;
        if (shares == 0) return;
        (uint256 gross, uint256 paid, uint256 retained, uint256 toTreasury) = ethFarm.previewWithdraw(shares);
        uint256 treasuryBefore = treasury.balance;
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        ethFarm.withdraw(shares);
        assertEq(alice.balance - aliceBefore, paid);
        assertEq(treasury.balance - treasuryBefore, toTreasury);
        assertEq(paid + retained + toTreasury, gross, "fee pieces sum to gross");
        assertEq(paid, gross - (gross * 1500) / 10_000, "85%");
        assertEq(address(ethFarm).balance, ethFarm.totalAssets(), "balance tracks principal");
        assertEq(ethFarm.totalAssets(), da + db - paid - toTreasury);
        assertLe(ethFarm.convertToAssets(ethFarm.totalShares()), ethFarm.totalAssets(), "never over-backed");
    }

    function testFuzz_rewardsSplitProRata(uint96 a, uint96 b, uint32 blocks) public {
        uint256 da = bound(a, 1e9, 500 ether);
        uint256 db = bound(b, 1e9, 500 ether);
        uint64 n = uint64(bound(blocks, 1, 100_000));
        activateWithHistory(0);
        depositEth(alice, da);
        depositEth(bob, db);
        advanceBlocks(n);
        uint256 poolShare = (issued(n) * 200) / 1000;
        vm.prank(alice);
        uint256 ra = ethFarm.claim(alice);
        vm.prank(bob);
        uint256 rb = ethFarm.claim(bob);
        assertLe(ra + rb, poolShare);
        assertApproxEqAbs(ra + rb, poolShare, 2, "dust only");
        // ratio within rounding of the share ratio
        uint256 expectedA = (poolShare * ethFarm.sharesOf(alice)) / ethFarm.totalShares();
        assertApproxEqAbs(ra, expectedA, 2);
        assertEq(cheese.balanceOf(alice), ra);
        assertEq(cheese.balanceOf(bob), rb);
    }

    function testFuzz_lateDepositorNeverInheritsRewards(uint96 early, uint96 late, uint32 blocks) public {
        uint256 de = bound(early, 1e9, 100 ether);
        uint256 dl = bound(late, 1e9, 900 ether);
        uint64 n = uint64(bound(blocks, 1, 50_000));
        activateWithHistory(0);
        depositEth(alice, de);
        advanceBlocks(n);
        depositEth(bob, dl);
        assertEq(ethFarm.pendingRewards(bob), 0);
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), 0);
        vm.prank(alice);
        assertApproxEqAbs(ethFarm.claim(alice), (issued(n) * 200) / 1000, 2);
    }

    function testFuzz_checkpointGroupingIsIrrelevant(uint16 a, uint16 b, uint16 c) public {
        uint64 x = uint64(bound(a, 0, 2_000));
        uint64 y = uint64(bound(b, 0, 2_000));
        uint64 z = uint64(bound(c, 0, 2_000));
        activateWithHistory(3);
        advanceBlocks(x);
        controller.checkpoint();
        advanceBlocks(y);
        advanceBlocks(z);
        controller.checkpoint();
        assertEq(controller.cumulativeEmission(), issued(x + y + z));
        assertEq(controller.fundedBlocks(), x + y + z);
    }
}
