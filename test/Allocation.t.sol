// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Dynamic pool allocation: initial weights, prospective changes, inactive reserve, new pools, no
///         retroactive rewards, batch updates, enable/disable, access control, gas scalability.
contract AllocationTest is CheeseBase {
    uint256 internal constant CHEESE_POOL = 0;
    uint256 internal constant ETH_POOL = 1;
    uint256 internal constant SIMD_POOL = 2;

    function test_initialAllocationIs400_200_200_200() public view {
        (address farm, uint16 weight, bool enabled,,) = controller.getPoolAllocation(CHEESE_POOL);
        assertEq(farm, address(cheeseFarm));
        assertEq(weight, 400);
        assertTrue(enabled);
        (, weight,,,) = controller.getPoolAllocation(ETH_POOL);
        assertEq(weight, 200);
        (, weight,,,) = controller.getPoolAllocation(SIMD_POOL);
        assertEq(weight, 200);
        (uint16 active, uint16 disabled, uint16 reserve) = controller.getAllocation();
        assertEq(active, 800);
        assertEq(disabled, 0);
        assertEq(reserve, 200);
        assertEq(controller.poolCount(), 3);
        assertEq(controller.poolIdOf(address(ethFarm)), ETH_POOL);
    }

    function test_emissionSplitsByWeightAndReserveStaysUnminted() public {
        activateWithHistory(0);
        depositCheese(alice, 100e18);
        depositEth(bob, 1 ether);
        depositSimd(carol, 50e18);
        advanceBlocks(100);
        controller.checkpoint();
        uint256 total = issued(100);
        (,,, uint256 pCheese,) = controller.getPoolAllocation(CHEESE_POOL);
        (,,, uint256 pEth,) = controller.getPoolAllocation(ETH_POOL);
        (,,, uint256 pSimd,) = controller.getPoolAllocation(SIMD_POOL);
        assertEq(pCheese, (total * 400) / 1000);
        assertEq(pEth, (total * 200) / 1000);
        assertEq(pSimd, (total * 200) / 1000);
        assertEq(controller.reserveUnminted(), (total * 200) / 1000);
        // pull everything and check minted supply
        vm.prank(alice);
        cheeseFarm.claim(alice);
        vm.prank(bob);
        ethFarm.claim(bob);
        vm.prank(carol);
        simdFarm.claim(carol);
        assertEq(controller.totalMinted(), pCheese + pEth + pSimd);
        assertEq(cheese.totalMinted(), cheese.PREMINT() + pCheese + pEth + pSimd);
        assertEq(cheese.balanceOf(alice), pCheese);
        assertEq(cheese.balanceOf(bob), pEth);
        assertEq(cheese.balanceOf(carol), pSimd);
    }

    function test_setPoolWeightAppliesProspectivelyAfterCheckpoint() public {
        activateWithHistory(0);
        depositEth(bob, 1 ether);
        advanceBlocks(100); // accrued under 200 points, not yet checkpointed
        vm.prank(owner);
        controller.setPoolWeight(ETH_POOL, 400); // must checkpoint first, then change
        (,,, uint256 pending,) = controller.getPoolAllocation(ETH_POOL);
        assertEq(pending, (issued(100) * 200) / 1000, "old weight for old blocks");
        advanceBlocks(100);
        controller.checkpoint();
        (,,, pending,) = controller.getPoolAllocation(ETH_POOL);
        assertEq(pending, (issued(100) * 200) / 1000 + ((issued(200) - issued(100)) * 400) / 1000);
        (uint16 active,, uint16 reserve) = controller.getAllocation();
        assertEq(active, 1000);
        assertEq(reserve, 0);
    }

    function test_reserveAssignedLaterIsNeverRetroactive() public {
        activateWithHistory(0);
        advanceBlocks(100);
        controller.checkpoint();
        uint256 reserveBefore = controller.reserveUnminted();
        assertEq(reserveBefore, (issued(100) * 200) / 1000);
        // assign the reserve to a brand new farm
        CheeseFarmETH newFarm = new CheeseFarmETH(owner, address(controller));
        vm.prank(owner);
        uint256 id = controller.addPool(address(newFarm), 200);
        (,,, uint256 pending,) = controller.getPoolAllocation(id);
        assertEq(pending, 0, "new pool starts at zero");
        assertEq(controller.reserveUnminted(), reserveBefore, "historical reserve stays unminted");
        advanceBlocks(10);
        controller.checkpoint();
        (,,, pending,) = controller.getPoolAllocation(id);
        assertEq(pending, ((issued(110) - issued(100)) * 200) / 1000);
        assertEq(controller.reserveUnminted(), reserveBefore, "reserve no longer grows");
    }

    function test_weightsCannotExceedTotalPoints() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.WeightExceedsTotal.selector, 801, 600));
        controller.setPoolWeight(CHEESE_POOL, 801);
        CheeseFarmETH extra = new CheeseFarmETH(owner, address(controller));
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.WeightExceedsTotal.selector, 201, 200));
        controller.addPool(address(extra), 201);
        controller.addPool(address(extra), 200);
        (,, uint16 reserve) = controller.getAllocation();
        assertEq(reserve, 0);
        vm.stopPrank();
    }

    function test_addPoolRejectsForeignOrDuplicateFarms() public {
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CheeseEmissionController.PoolAlreadyRegistered.selector, address(ethFarm))
        );
        controller.addPool(address(ethFarm), 10);
        vm.stopPrank();
    }

    function test_addPoolRejectsFarmOfAnotherController() public {
        CheeseEmissionController other = new CheeseEmissionController(owner, address(core), treasury);
        CheeseFarmETH foreign = new CheeseFarmETH(owner, address(other));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.FarmMismatch.selector, address(foreign)));
        controller.addPool(address(foreign), 10);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        controller.addPool(address(0), 10);
    }

    function test_batchSetPoolWeightsReallocatesAtomically() public {
        activateWithHistory(0);
        depositCheese(alice, 1e18);
        advanceBlocks(10);
        uint256[] memory ids = new uint256[](3);
        uint16[] memory weights = new uint16[](3);
        ids[0] = CHEESE_POOL;
        ids[1] = ETH_POOL;
        ids[2] = SIMD_POOL;
        weights[0] = 100; // down
        weights[1] = 500; // up: works only because lowering happens first
        weights[2] = 400;
        vm.prank(owner);
        controller.batchSetPoolWeights(ids, weights);
        (uint16 active,, uint16 reserve) = controller.getAllocation();
        assertEq(active, 1000);
        assertEq(reserve, 0);
        (,,, uint256 pending,) = controller.getPoolAllocation(CHEESE_POOL);
        assertEq(pending, (issued(10) * 400) / 1000, "settled under the old 400 points");
        // mismatched / empty batches
        uint16[] memory shortWeights = new uint16[](1);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.LengthMismatch.selector);
        controller.batchSetPoolWeights(ids, shortWeights);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.EmptyBatch.selector);
        controller.batchSetPoolWeights(new uint256[](0), new uint16[](0));
        // over-allocated batch reverts as a whole
        weights[0] = 200;
        vm.prank(owner);
        vm.expectRevert();
        controller.batchSetPoolWeights(ids, weights);
    }

    function test_disableAndEnablePool() public {
        activateWithHistory(0);
        depositEth(bob, 1 ether);
        advanceBlocks(10);
        vm.prank(owner);
        controller.disablePool(ETH_POOL);
        (,, bool enabled, uint256 pending,) = controller.getPoolAllocation(ETH_POOL);
        assertFalse(enabled);
        assertEq(pending, (issued(10) * 200) / 1000, "settled before disabling");
        (uint16 active, uint16 disabled, uint16 reserve) = controller.getAllocation();
        assertEq(active, 600);
        assertEq(disabled, 200);
        assertEq(reserve, 200);
        advanceBlocks(10);
        controller.checkpoint();
        (,,, uint256 pendingAfter,) = controller.getPoolAllocation(ETH_POOL);
        assertEq(pendingAfter, pending, "disabled pool accrues nothing");
        assertEq(controller.reserveUnminted(), (issued(10) * 200) / 1000 + ((issued(20) - issued(10)) * 400) / 1000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolAlreadyDisabled.selector, ETH_POOL));
        controller.disablePool(ETH_POOL);
        // bob can still withdraw and claim what accrued before the disable
        vm.prank(bob);
        uint256 claimed = ethFarm.claim(bob);
        assertEq(claimed, pending);
        vm.prank(owner);
        controller.enablePool(ETH_POOL);
        (,,, pendingAfter,) = controller.getPoolAllocation(ETH_POOL);
        assertEq(pendingAfter, 0, "re-enable is prospective");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolAlreadyEnabled.selector, ETH_POOL));
        controller.enablePool(ETH_POOL);
    }

    function test_allocationChangesRevertWhilePausedOrCoreUnavailable() public {
        activateWithHistory(0);
        advanceBlocks(5);
        core.setUnavailable(true);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.SyncRequired.selector);
        controller.setPoolWeight(ETH_POOL, 100);
        core.setUnavailable(false);
        vm.prank(owner);
        controller.pauseEmissions();
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.EmissionsArePaused.selector);
        controller.setPoolWeight(ETH_POOL, 100);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.EmissionsArePaused.selector);
        controller.disablePool(ETH_POOL);
    }

    function test_onlyOwnerAdministers() public {
        vm.startPrank(alice);
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(denied);
        controller.setPoolWeight(ETH_POOL, 1);
        vm.expectRevert(denied);
        controller.disablePool(ETH_POOL);
        vm.expectRevert(denied);
        controller.enablePool(ETH_POOL);
        vm.expectRevert(denied);
        controller.addPool(address(ethFarm), 1);
        vm.expectRevert(denied);
        controller.setTreasury(alice);
        vm.expectRevert(denied);
        controller.setGuardian(alice);
        vm.expectRevert(denied);
        controller.bindToken(address(cheese));
        vm.stopPrank();
    }

    function test_onlyPoolFarmPullsRewards() public {
        activateWithHistory(0);
        advanceBlocks(5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.NotPoolFarm.selector, ETH_POOL, alice));
        controller.pullRewards(ETH_POOL, true);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, 99));
        controller.pullRewards(99, true);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, 99));
        controller.getPoolAllocation(99);
    }

    function test_treasuryAndGuardianSetters() public {
        vm.startPrank(owner);
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        controller.setTreasury(address(0));
        controller.setTreasury(carol);
        assertEq(controller.treasury(), carol);
        vm.expectRevert(CheeseEmissionController.ZeroAddress.selector);
        controller.setGuardian(address(0));
        vm.stopPrank();
    }

    /// @notice Checkpoint and user operations cost the same with 3 pools and with 60: lazy per-point accounting.
    function test_gasScalabilityDoesNotGrowWithPoolCount() public {
        activateWithHistory(0);
        depositEth(bob, 1 ether);
        advanceBlocks(10);
        controller.checkpoint(); // warm-up: first writes to the accumulators
        advanceBlocks(10);
        uint256 gasBefore = gasleft();
        controller.checkpoint();
        uint256 checkpointGas3 = gasBefore - gasleft();

        // shrink the existing weights, then add many small pools
        uint256[] memory ids = new uint256[](3);
        uint16[] memory weights = new uint16[](3);
        ids[1] = 1;
        ids[2] = 2;
        weights[0] = 10;
        weights[1] = 10;
        weights[2] = 10;
        vm.prank(owner);
        controller.batchSetPoolWeights(ids, weights);
        for (uint256 i; i < 57; ++i) {
            CheeseFarmETH f = new CheeseFarmETH(owner, address(controller));
            vm.prank(owner);
            controller.addPool(address(f), 1);
        }
        assertEq(controller.poolCount(), 60);

        advanceBlocks(10);
        controller.checkpoint(); // warm-up under the new allocation
        advanceBlocks(10);
        gasBefore = gasleft();
        controller.checkpoint();
        uint256 checkpointGas60 = gasBefore - gasleft();
        assertApproxEqAbs(checkpointGas60, checkpointGas3, 5_000, "checkpoint gas independent of pools");

        advanceBlocks(10);
        vm.prank(bob);
        gasBefore = gasleft();
        ethFarm.claim(bob);
        uint256 claimGas = gasBefore - gasleft();
        assertLt(claimGas, 400_000, "claim stays bounded");
    }
}
