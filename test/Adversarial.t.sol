// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseFarm} from "../src/CheeseFarm.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "../src/farms/CheeseFarmSIMD.sol";
import {CheeseToken} from "../src/CheeseToken.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Failure paths and edges the happy-path suites do not reach: bad arguments, wrong callers, repeated
///         calls, exact boundary emission, partial Squeek blocks, Core regression recovery, exact Hamster Bite
///         arithmetic, disabled pools, and the emergency path when SqueekCore returns malformed data.
/// @dev Defects found while writing these are reported in .imd-findings.json, not asserted here.
contract AdversarialTest is CheeseBase {
    // ------------------------------------------------------------------------------------------------
    // Token
    // ------------------------------------------------------------------------------------------------

    function test_mintEmissionToZeroAddressReverts() public {
        vm.prank(address(controller));
        vm.expectRevert(CheeseToken.ZeroAddress.selector);
        cheese.mintEmission(address(0), 1);
    }

    function test_ownerAndTreasuryCannotMint() public {
        address[3] memory callers = [owner, treasury, address(cheeseFarm)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(CheeseToken.UnauthorizedMinter.selector, callers[i]));
            cheese.mintEmission(callers[i], 1);
        }
        assertEq(cheese.totalMinted(), cheese.PREMINT());
    }

    function test_burnMoreThanBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        cheese.burn(1);
        assertEq(cheese.totalBurned(), 0);
    }

    function test_mintExactlyRemainingThenOneMoreReverts() public {
        uint256 remaining = cheese.MAX_SUPPLY() - cheese.totalMinted();
        vm.startPrank(address(controller));
        cheese.mintEmission(alice, remaining);
        vm.expectRevert(abi.encodeWithSelector(CheeseToken.ExceedsMaxSupply.selector, 1, 0));
        cheese.mintEmission(alice, 1);
        vm.stopPrank();
        assertEq(cheese.totalSupply(), cheese.MAX_SUPPLY());
    }

    // ------------------------------------------------------------------------------------------------
    // Controller administration failure paths
    // ------------------------------------------------------------------------------------------------

    function test_constructorRejectsZeroCoreOrTreasury() public {
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        new CheeseEmissionController(owner, address(0), treasury);
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        new CheeseEmissionController(owner, address(core), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CheeseEmissionController(address(0), address(core), treasury);
    }

    function test_activateRequiresBoundToken() public {
        CheeseEmissionController fresh = new CheeseEmissionController(owner, address(core), treasury);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.TokenNotBound.selector);
        fresh.activate();
        vm.expectRevert(CheeseEmissionController.NotActivated.selector);
        fresh.currentRound();
        // An unactivated controller checkpoints as a no-op.
        (bool ok, uint256 emitted) = fresh.checkpoint();
        assertTrue(ok);
        assertEq(emitted, 0);
    }

    function test_bindTokenZeroAndNonOwner() public {
        CheeseEmissionController fresh = new CheeseEmissionController(owner, address(core), treasury);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        fresh.bindToken(address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.bindToken(address(cheese));
    }

    function test_addPoolZeroAddressAndOverweight() public {
        vm.startPrank(owner);
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        controller.addPool(address(0), 1);
        CheeseFarmETH extra = new CheeseFarmETH(owner, address(controller));
        // 800 of 1000 points are assigned: 201 does not fit, 200 does.
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.WeightExceedsTotal.selector, 201, 200));
        controller.addPool(address(extra), 201);
        uint256 id = controller.addPool(address(extra), 200);
        vm.stopPrank();
        assertEq(id, 3);
        assertEq(controller.poolIdOf(address(extra)), 3);
        (,, uint16 reserve) = controller.getAllocation();
        assertEq(reserve, 0);
    }

    function test_unknownPoolIdsRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, 3));
        controller.setPoolWeight(3, 1);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, 7));
        controller.disablePool(7);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, 7));
        controller.enablePool(7);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, 9));
        controller.getPoolAllocation(9);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, type(uint256).max));
        controller.poolIdOf(alice);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, 5));
        controller.pullRewards(5, true);
    }

    function test_batchRejectsLengthMismatchEmptyAndOverweight() public {
        uint256[] memory ids = new uint256[](2);
        uint16[] memory w = new uint16[](1);
        vm.startPrank(owner);
        vm.expectRevert(CheeseEmissionController.LengthMismatch.selector);
        controller.batchSetPoolWeights(ids, w);
        vm.expectRevert(CheeseEmissionController.EmptyBatch.selector);
        controller.batchSetPoolWeights(new uint256[](0), new uint16[](0));
        // raising pool 1 and 2 by 101 each needs 202 > 200 free points: whole batch reverts
        ids[0] = 1;
        ids[1] = 2;
        uint16[] memory w2 = new uint16[](2);
        w2[0] = 301;
        w2[1] = 301;
        vm.expectRevert();
        controller.batchSetPoolWeights(ids, w2);
        vm.stopPrank();
        (, uint16 a,,,) = controller.getPoolAllocation(1);
        (, uint16 b,,,) = controller.getPoolAllocation(2);
        assertEq(a, 200, "atomic: nothing applied");
        assertEq(b, 200, "atomic: nothing applied");
    }

    function test_disableTwiceAndEnableEnabledRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolAlreadyEnabled.selector, 0));
        controller.enablePool(0);
        controller.disablePool(0);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolAlreadyDisabled.selector, 0));
        controller.disablePool(0);
        vm.stopPrank();
        (uint16 active, uint16 disabled, uint16 reserve) = controller.getAllocation();
        assertEq(active, 400);
        assertEq(disabled, 400);
        assertEq(reserve, 200);
    }

    function test_pauseStateMachine() public {
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.EmissionsNotPaused.selector);
        controller.unpauseEmissions();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.NotGuardianOrOwner.selector, alice));
        controller.pauseEmissions();
        vm.prank(owner);
        controller.pauseEmissions();
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.EmissionsArePaused.selector);
        controller.pauseEmissions();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        controller.unpauseEmissions();
    }

    function test_settersRejectZeroAndStrangers() public {
        vm.startPrank(owner);
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        controller.setTreasury(address(0));
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        controller.setGuardian(address(0));
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        controller.setTreasury(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        controller.setGuardian(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        controller.enablePool(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        controller.disablePool(0);
        vm.stopPrank();
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        controller.transferOwnership(alice);
        assertEq(controller.owner(), owner, "not until accepted");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        controller.acceptOwnership();
        vm.prank(alice);
        controller.acceptOwnership();
        assertEq(controller.owner(), alice);
    }

    // ------------------------------------------------------------------------------------------------
    // Emission edges
    // ------------------------------------------------------------------------------------------------

    /// @dev One-block checkpoints straddling each schedule boundary price exactly the reference schedule.
    function test_singleBlockEmissionAtEveryBoundary() public {
        activateWithHistory(0);
        uint64[4] memory marks = [N, H, 2 * H, 3 * H];
        uint64 at;
        for (uint256 i; i < marks.length; ++i) {
            uint64 jump = marks[i] - 1 - at;
            advanceBlocks(jump);
            controller.checkpoint();
            at += jump;
            // the block that reaches the boundary, then the block after it
            for (uint256 k; k < 2; ++k) {
                if (controller.completed()) break;
                uint256 before = controller.cumulativeEmission();
                advanceBlocks(1);
                (, uint256 emitted) = controller.checkpoint();
                at += 1;
                assertEq(emitted, referenceIssued(at) - referenceIssued(at - 1), "per-block price");
                assertEq(controller.cumulativeEmission(), before + emitted);
            }
        }
        assertTrue(controller.completed());
        assertEq(controller.cumulativeEmission(), referenceIssued(3 * H));
        // After completion, the next block emits nothing and the state stays completed.
        advanceBlocks(1);
        (bool ok, uint256 emitted2) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted2, 0);
        assertTrue(controller.completed());
    }

    function test_partialBlockProgressNeverEmits() public {
        activateWithHistory(0);
        core.settle(core.settledThroughRound() + 1, 0, 999_999_999); // 0.999999999 of a block
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted, 0);
        core.settle(core.settledThroughRound() + 1, 0, 1); // completes block 1
        (, emitted) = controller.checkpoint();
        assertEq(emitted, issued(1));
    }

    function test_startHeightIgnoresPartialProgressAtH0() public {
        vm.prank(owner);
        controller.activate();
        core.settle(controller.startRound() - 1, 10, 500_000_000);
        controller.checkpoint();
        assertEq(controller.startHeight(), 10, "h0 counts completed blocks only");
        core.settle(core.settledThroughRound() + 1, 0, 500_000_000); // block 11 completes
        (, uint256 emitted) = controller.checkpoint();
        assertEq(emitted, issued(1));
    }

    function test_regressionThenRecoveryNeverDoubleCounts() public {
        activateWithHistory(0);
        advanceBlocks(100);
        controller.checkpoint();
        uint96 units = core.cumulativeBlockUnits();
        core.forceUnits(units - 50 * 1e9);
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertFalse(ok);
        assertEq(emitted, 0);
        assertEq(controller.lastHeight(), 100);
        core.forceUnits(units); // back to 100: no movement, nothing emitted twice
        (ok, emitted) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted, 0);
        core.forceUnits(units + 5 * 1e9);
        (, emitted) = controller.checkpoint();
        assertEq(emitted, issued(105) - issued(100));
        assertEq(controller.cumulativeEmission(), issued(105));
    }

    function test_allocationChangeRevertsDuringRegression() public {
        activateWithHistory(0);
        advanceBlocks(10);
        controller.checkpoint();
        core.forceUnits(core.cumulativeBlockUnits() - 1e9);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.SyncRequired.selector);
        controller.setPoolWeight(0, 300);
    }

    function test_allocationChangesAllowedAfterCompletion() public {
        activateWithHistory(0);
        advanceBlocks(3 * H);
        controller.checkpoint();
        assertTrue(controller.completed());
        uint256 cum = controller.cumulativeEmission();
        vm.startPrank(owner);
        controller.setPoolWeight(0, 600);
        controller.disablePool(1);
        controller.enablePool(1);
        vm.stopPrank();
        advanceBlocks(1000);
        controller.checkpoint();
        assertEq(controller.cumulativeEmission(), cum, "completion never reopens");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_anyCheckpointSplitMatchesSchedule(uint32[6] memory steps) public {
        activateWithHistory(0);
        uint64 total;
        for (uint256 i; i < steps.length; ++i) {
            uint64 s = uint64(bound(steps[i], 0, 300_000));
            advanceBlocks(s);
            controller.checkpoint();
            total += s;
        }
        uint64 capped = total > 3 * H ? 3 * H : total;
        assertEq(controller.cumulativeEmission(), referenceIssued(capped));
        assertLe(controller.cumulativeEmission(), A);
        assertEq(controller.completed(), total >= 3 * H);
    }

    // ------------------------------------------------------------------------------------------------
    // Allocation semantics
    // ------------------------------------------------------------------------------------------------

    function test_disabledPoolKeepsAccruedButEarnsNothingMore() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(100);
        vm.prank(owner);
        controller.disablePool(1);
        uint256 owed = (issued(100) * 200) / 1000;
        advanceBlocks(100);
        controller.checkpoint();
        (,, bool enabled, uint256 pendingEmission,) = controller.getPoolAllocation(1);
        assertFalse(enabled);
        assertEq(pendingEmission, owed, "accrued before disable is kept, nothing after");
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), owed);
        // Disabled points count toward the reserve: the second 100 blocks' 200 points were never minted.
        assertEq(controller.reserveUnminted(), (issued(100) * 200) / 1000 + ((issued(200) - issued(100)) * 400) / 1000);
    }

    function test_reenabledPoolGetsNothingForDisabledPeriod() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        vm.prank(owner);
        controller.disablePool(1);
        advanceBlocks(500);
        vm.prank(owner);
        controller.enablePool(1);
        assertEq(ethFarm.pendingRewards(alice), 0);
        advanceBlocks(10);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), ((issued(510) - issued(500)) * 200) / 1000);
    }

    function test_weightZeroPoolEarnsNothing() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        vm.prank(owner);
        controller.setPoolWeight(1, 0);
        advanceBlocks(100);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), 0);
    }

    function test_weightChangeOnDisabledPoolAppliesOnEnable() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        vm.startPrank(owner);
        controller.disablePool(1);
        controller.setPoolWeight(1, 400);
        vm.stopPrank();
        (uint16 active, uint16 disabled, uint16 reserve) = controller.getAllocation();
        assertEq(active, 600);
        assertEq(disabled, 400);
        assertEq(reserve, 0);
        vm.prank(owner);
        controller.enablePool(1);
        advanceBlocks(10);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), (issued(10) * 400) / 1000);
    }

    // ------------------------------------------------------------------------------------------------
    // Farm failure paths
    // ------------------------------------------------------------------------------------------------

    function test_cannotWithdrawSomeoneElsesShares() public {
        depositEth(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CheeseFarm.InsufficientShares.selector, 1, 0));
        ethFarm.withdraw(1);
    }

    function test_claimToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(CheeseFarm.ZeroAddress.selector);
        ethFarm.claim(address(0));
    }

    function test_claimWithNothingReturnsZeroAndMovesNothing() public {
        activateWithHistory(0);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), 0);
        assertEq(cheese.balanceOf(alice), 0);
    }

    function test_onlyOwnerPausesDepositsAndSkims() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ethFarm.setDepositsPaused(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cheeseFarm.skimSurplus();
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(CheeseFarm.NothingToSkim.selector);
        cheeseFarm.skimSurplus();
    }

    function test_depositsPausedStillAllowsWithdrawAndClaim() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        vm.prank(owner);
        ethFarm.setDepositsPaused(true);
        vm.prank(alice);
        assertGt(ethFarm.claim(alice), 0);
        assertGt(withdrawAll(ethFarm, alice), 0);
        vm.prank(owner);
        ethFarm.setDepositsPaused(false);
        depositEth(bob, 1 ether);
    }

    function test_simdSetAssetGuards() public {
        CheeseFarmSIMD fresh = new CheeseFarmSIMD(owner, address(controller));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setAsset(address(simd));
        vm.startPrank(owner);
        vm.expectRevert(CheeseFarm.ZeroAddress.selector);
        fresh.setAsset(address(0));
        vm.expectRevert(CheeseFarmSIMD.AssetIsNotAContract.selector);
        fresh.setAsset(alice);
        fresh.setAsset(address(simd));
        vm.expectRevert(CheeseFarmSIMD.AssetAlreadySet.selector);
        fresh.setAsset(address(cheese));
        vm.stopPrank();
        assertEq(address(fresh.asset()), address(simd));
    }

    function test_unconfiguredSimdFarmForfeitsItsEmission() public {
        CheeseFarmSIMD fresh = new CheeseFarmSIMD(owner, address(controller));
        vm.prank(owner);
        uint256 id = controller.addPool(address(fresh), 200);
        activateWithHistory(0);
        advanceBlocks(100);
        controller.checkpoint();
        vm.prank(alice);
        vm.expectRevert(CheeseFarm.AssetNotConfigured.selector);
        fresh.deposit(1);
        vm.prank(alice);
        assertEq(fresh.claim(alice), 0); // pulls with no stakers: forfeited, never minted
        (,,, uint256 pendingEmission, uint256 minted) = controller.getPoolAllocation(id);
        assertEq(pendingEmission, 0);
        assertEq(minted, 0);
        assertEq(controller.forfeitedEmission(), (issued(100) * 200) / 1000);
    }

    function test_withdrawingDustSharesBurnsThemForNothing() public {
        depositEth(alice, 1 ether);
        // 1 share is worth 1e-3 wei at the initial 1e3 virtual offset: it backs zero assets.
        (uint256 gross,,,) = ethFarm.previewWithdraw(1);
        assertEq(gross, 0);
        vm.prank(alice);
        assertEq(ethFarm.withdraw(1), 0);
        assertEq(ethFarm.totalAssets(), 1 ether, "no principal leaves");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_hamsterBiteExactSplit(uint96 a, uint96 b, uint16 fractionBps) public {
        uint256 amtA = bound(a, 1e6, 1_000 ether);
        depositEth(alice, amtA);
        depositEth(bob, bound(b, 1e6, 1_000 ether));
        uint256 shares = (ethFarm.sharesOf(alice) * bound(fractionBps, 1, 10_000)) / 10_000;
        if (shares == 0) shares = 1;
        _checkBite(shares, amtA);
    }

    function _checkBite(uint256 shares, uint256 amtA) internal {
        uint256 aliceShares = ethFarm.sharesOf(alice);
        (uint256 gross, uint256 pPaid, uint256 pRetained, uint256 pTreasury) = ethFarm.previewWithdraw(shares);
        uint256 fee = (gross * 1500) / 10_000;
        assertEq(pRetained, (gross * 1400) / 10_000, "14% retained");
        assertEq(pTreasury, fee - pRetained, "1% to treasury");
        uint256 aliceBefore = alice.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 assetsBefore = ethFarm.totalAssets();
        uint256 bobAssetsBefore = ethFarm.assetsOf(bob);
        vm.prank(alice);
        uint256 paid = ethFarm.withdraw(shares);
        assertEq(paid, gross - fee, "85% paid");
        assertEq(paid, pPaid, "preview paid");
        assertEq(alice.balance - aliceBefore, paid);
        assertEq(treasury.balance - treasuryBefore, pTreasury, "treasury received");
        assertEq(assetsBefore - ethFarm.totalAssets(), paid + pTreasury, "14% stays");
        assertGe(ethFarm.assetsOf(bob), bobAssetsBefore, "remaining depositor never loses");
        assertLe(gross, (amtA * shares) / aliceShares + 1, "no more than deposited");
    }

    /// @dev The last withdrawer still receives exactly 85% of gross; the Treasury receives the full 15% plus the
    ///      residual the virtual offset left unreachable, and the farm restarts at an empty reserve.
    function test_lastWithdrawerPaysFullFifteenPercentToTreasuryAfterFees() public {
        depositEth(alice, 10 ether);
        depositEth(bob, 10 ether);
        withdrawAll(ethFarm, alice); // 14% of alice's stays with bob
        uint256 gross = ethFarm.assetsOf(bob);
        assertGt(gross, 10 ether, "bob gained alice's retained share");
        uint256 reserveBefore = ethFarm.totalAssets();
        uint256 treasuryBefore = treasury.balance;
        uint256 paid = withdrawAll(ethFarm, bob);
        uint256 fee = (gross * 1500) / 10_000;
        assertEq(paid, gross - fee, "85% of gross to the withdrawer");
        uint256 toTreasury = treasury.balance - treasuryBefore;
        assertGe(toTreasury, fee, "at least the full 15% to treasury");
        assertEq(toTreasury, reserveBefore - paid, "treasury takes the whole remainder");
        assertLe(toTreasury - fee, 1e3, "residual above the fee is only virtual-offset dust");
        assertEq(ethFarm.totalShares(), 0);
        assertEq(ethFarm.totalAssets(), 0, "farm restarts empty");
        assertEq(address(ethFarm).balance, 0);
    }

    /// @dev After the reset a fresh depositor gets the exact virtual-offset price, inheriting nothing.
    function test_depositAfterFullExitStartsAtFreshPrice() public {
        depositEth(alice, 3 ether);
        depositEth(bob, 7 ether);
        withdrawAll(ethFarm, alice);
        withdrawAll(ethFarm, bob);
        uint256 shares = depositEth(carol, 1 ether);
        assertEq(shares, 1 ether * 1e3, "same price as the very first deposit");
        assertLe(ethFarm.assetsOf(carol), 1 ether, "no inherited value");
        assertApproxEqAbs(ethFarm.assetsOf(carol), 1 ether, 1, "full deposit backed");
    }

    // ------------------------------------------------------------------------------------------------
    // External dependency: malformed SqueekCore data
    // ------------------------------------------------------------------------------------------------

    /// @dev Malformed Core return data reads as unavailable: withdrawals and claims go through unpaused,
    ///      deposits wait, and the guardian can still pause.
    function test_malformedCoreDataDoesNotBlockExitsButBlocksDeposits() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        depositEth(bob, 1 ether);
        advanceBlocks(10);
        controller.checkpoint();
        vm.mockCall(address(core), abi.encodeWithSelector(ISqueekCore.state.selector), abi.encode(uint256(1)));
        (bool ok,) = controller.checkpoint();
        assertFalse(ok, "malformed data is unavailable, not a revert");
        vm.prank(carol);
        vm.expectRevert(CheeseFarm.SyncRequired.selector);
        ethFarm.deposit{value: 1 ether}();
        vm.prank(alice);
        uint256 claimed = ethFarm.claim(alice);
        assertEq(claimed, (issued(10) * 200) / 1000 / 2);
        uint256 balBefore = alice.balance;
        uint256 paid = withdrawAll(ethFarm, alice);
        assertEq(alice.balance - balBefore, paid);
        assertEq(paid, 1 ether - (1 ether * 1500) / 10_000, "85% back");
        vm.prank(owner);
        controller.pauseEmissions();
        assertTrue(controller.emissionsPaused());
        assertGt(withdrawAll(ethFarm, bob), 0);
    }

    /// @dev Blocks certified before a pause are priced by the pause itself, so they go to whoever was staked
    ///      then; blocks certified while paused are caught up after unpausing.
    function test_pausePricesBlocksCertifiedBeforeIt() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        vm.prank(owner);
        controller.pauseEmissions();
        assertEq(controller.cumulativeEmission(), issued(10), "pre-pause blocks priced at pause");
        advanceBlocks(5);
        assertEq(controller.cumulativeEmission(), issued(10), "nothing priced while paused");
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), (issued(10) * 200) / 1000, "alice owns the pre-pause blocks");
        vm.prank(owner);
        controller.unpauseEmissions();
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted, issued(15) - issued(10), "paused blocks caught up exactly");
    }

    /// @dev A pause while Core is unreadable still succeeds (the sync is best effort).
    function test_pauseSucceedsWhileCoreUnavailable() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        core.setUnavailable(true);
        vm.prank(owner);
        controller.pauseEmissions();
        assertTrue(controller.emissionsPaused());
        assertEq(controller.cumulativeEmission(), 0);
    }

    /// @dev A Core that burns all forwarded gas (INVALID) still leaves the caller its 1/64: exits and the
    ///      emergency pause go through within a 30M-gas transaction. (A Core that instead returns a huge
    ///      payload does block them; that is reported in .imd-findings.json, not asserted here.)
    function test_gasBurningCoreDoesNotBlockExitsOrPause() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        depositEth(bob, 1 ether);
        advanceBlocks(10);
        controller.checkpoint();
        vm.etch(address(core), hex"fe");
        uint256 shares = ethFarm.sharesOf(alice);
        vm.prank(alice);
        uint256 paid = ethFarm.withdraw{gas: 30_000_000}(shares);
        assertEq(paid, 0.85 ether);
        vm.prank(bob);
        assertEq(ethFarm.claim{gas: 30_000_000}(bob), (issued(10) * 200) / 1000 / 2);
        vm.prank(owner);
        controller.pauseEmissions{gas: 30_000_000}();
        assertTrue(controller.emissionsPaused());
    }

    function test_depositWaitsForCoreRecoveryThenSucceeds() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        core.setUnavailable(true);
        vm.prank(bob);
        vm.expectRevert(CheeseFarm.SyncRequired.selector);
        ethFarm.deposit{value: 1 ether}();
        core.setUnavailable(false);
        depositEth(bob, 1 ether);
        // the 10 blocks certified during the outage went to alice alone
        assertEq(ethFarm.pendingRewards(alice), (issued(10) * 200) / 1000);
        assertEq(ethFarm.pendingRewards(bob), 0);
    }

    function test_unavailableCoreDoesNotBlockWithdrawOrClaim() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        controller.checkpoint();
        core.setUnavailable(true);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), (issued(10) * 200) / 1000);
        assertGt(withdrawAll(ethFarm, alice), 0);
    }
}
