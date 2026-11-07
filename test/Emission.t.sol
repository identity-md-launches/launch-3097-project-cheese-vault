// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {SqueekIssuance} from "../src/libraries/SqueekIssuance.sol";

/// @notice Exact SQK emission matching, halving boundaries, supply cap, no double minting, delayed and zero
///         checkpoints, completion, pause and Squeekchain unavailability.
contract EmissionTest is CheeseBase {
    // ---- schedule constants and live vectors (read from Sepolia at Ethereum block 12081684) ----

    function test_scheduleConstantsMatchSqueekMining() public pure {
        assertEq(SqueekIssuance.SUPPLY_CAP, 2_100_000_000e18);
        assertEq(SqueekIssuance.PREMINT, 210_000_000e18);
        assertEq(SqueekIssuance.ALLOWANCE, 1_890_000_000e18);
        assertEq(SqueekIssuance.LAUNCH_BONUS, 105_000_000e18);
        assertEq(SqueekIssuance.BONUS_BLOCKS, 97_020);
        assertEq(SqueekIssuance.HALVING_BLOCKS, 393_470);
        // SqueekMining.issuanceSchedule().firstPeriodRate on Sepolia
        assertEq(SqueekIssuance.FIRST_PERIOD_RATE, 2_592_319_617_759_930_871_476);
        assertEq(SqueekIssuance.FIRST_PERIOD_RATE % 4, 0, "R0 multiple of 4");
    }

    function test_issuedMatchesLiveSqueekMiningVectors() public pure {
        assertEq(SqueekIssuance.issued(0), 0);
        assertEq(SqueekIssuance.issued(1), 3_674_570_700_011_013_122_558);
        assertEq(SqueekIssuance.issued(2), 7_349_141_400_022_026_245_116);
        assertEq(SqueekIssuance.issued(97_020), 356_506_849_315_068_493_150_601_520);
        assertEq(SqueekIssuance.issued(97_021), 356_509_441_634_686_253_081_472_996);
        assertEq(SqueekIssuance.issued(393_470), 1_124_999_999_999_999_999_999_661_720);
        assertEq(SqueekIssuance.issued(393_471), 1_125_001_296_159_808_879_965_097_458);
        assertEq(SqueekIssuance.issued(786_940), 1_634_999_999_999_999_999_999_492_580);
        assertEq(SqueekIssuance.issued(786_941), 1_635_000_648_079_904_439_982_210_449);
        assertEq(SqueekIssuance.issued(1_180_410), 1_889_999_999_999_999_999_999_408_010);
        assertEq(SqueekIssuance.issued(2_000_000), 1_889_999_999_999_999_999_999_408_010);
        // SqueekMining.state(): fundedBlocks 1633, minted 6000573953117984429137624
        assertEq(SqueekIssuance.issued(1_633), 6_000_573_953_117_984_429_137_624);
        assertLe(SqueekIssuance.issued(type(uint64).max), SqueekIssuance.ALLOWANCE);
    }

    function testFuzz_issuedMatchesReferenceAndIsMonotone(uint64 a, uint64 b) public pure {
        a = uint64(bound(a, 0, 4 * uint64(H)));
        b = uint64(bound(b, 0, 4 * uint64(H)));
        assertEq(SqueekIssuance.issued(a), referenceIssued(a));
        if (a <= b) assertLe(SqueekIssuance.issued(a), SqueekIssuance.issued(b));
        assertLe(SqueekIssuance.issued(b), A);
    }

    function test_perBlockRatesAcrossHalvings() public pure {
        uint256 bonusPerBlock = G / N; // flooring differs by at most 1 wei between blocks
        uint256 d1 = issued(10) - issued(9);
        assertApproxEqAbs(d1, R0 + bonusPerBlock, 1);
        uint256 dAfterBonus = issued(N + 2) - issued(N + 1);
        assertEq(dAfterBonus, R0);
        assertEq(issued(H + 1) - issued(H), R0 / 2);
        assertEq(issued(2 * H + 1) - issued(2 * H), R0 / 4);
        assertEq(issued(3 * H + 1) - issued(3 * H), 0);
    }

    // ---- activation and h0 ----

    function test_activateSchedulesNextRound() public {
        vm.prank(owner);
        controller.activate();
        // warped into round 101 in setUp
        assertEq(controller.startRound(), 102);
        assertEq(controller.genesisTimestamp(), GENESIS);
        assertTrue(controller.activated());
    }

    function test_activateRevertsTwiceAndForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        controller.activate();
        vm.prank(owner);
        controller.activate();
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.AlreadyActivated.selector);
        controller.activate();
    }

    function test_activateRevertsOnClockMismatch() public {
        core.setClock(601, 1_000_000_000);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.SqueekCoreIdentityMismatch.selector);
        controller.activate();
    }

    function test_activateRevertsWhenCoreUnavailable() public {
        core.setUnavailable(true);
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.SqueekCoreUnavailable.selector);
        controller.activate();
    }

    function test_noEmissionBeforeStartRoundCertified() public {
        vm.prank(owner);
        controller.activate();
        core.settle(controller.startRound() - 2, 500, 0); // lots of blocks, round before the anchor
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted, 0);
        assertFalse(controller.startCaptured());
        assertEq(controller.cumulativeEmission(), 0);
    }

    function test_blocksBeforeActivationNeverEmit() public {
        activateWithHistory(1_633); // Squeekchain already completed 1633 blocks (the live state)
        assertEq(controller.cumulativeEmission(), 0, "no retroactive emission");
        advanceBlocks(7);
        (, uint256 emitted) = controller.checkpoint();
        assertEq(emitted, issued(7), "only the 7 new blocks are priced, from b = 0");
        assertEq(controller.fundedBlocks(), 7);
    }

    // ---- checkpoints ----

    function test_checkpointBeforeActivationIsNoop() public {
        advanceBlocks(10);
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted, 0);
    }

    function test_zeroBlockMovementEmitsNothing() public {
        activateWithHistory(0);
        advanceBlocks(3);
        controller.checkpoint();
        uint256 before = controller.cumulativeEmission();
        core.settle(core.settledThroughRound() + 1, 0, 123_456); // progress but no completed block
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted, 0);
        assertEq(controller.cumulativeEmission(), before);
    }

    function test_noDoubleMintingOnRepeatedCheckpoints() public {
        activateWithHistory(0);
        advanceBlocks(40);
        controller.checkpoint();
        uint256 once = controller.cumulativeEmission();
        for (uint256 i; i < 5; ++i) {
            (, uint256 emitted) = controller.checkpoint();
            assertEq(emitted, 0);
        }
        assertEq(controller.cumulativeEmission(), once);
        assertEq(once, issued(40));
    }

    function test_delayedCheckpointEqualsFrequentCheckpoints() public {
        activateWithHistory(0);
        // frequent: 10 rounds x 40 blocks, checkpoint each
        for (uint256 i; i < 10; ++i) {
            advanceBlocks(40);
            controller.checkpoint();
        }
        uint256 frequent = controller.cumulativeEmission();
        // delayed: 10 more rounds, one checkpoint
        for (uint256 i; i < 10; ++i) {
            advanceBlocks(40);
        }
        controller.checkpoint();
        assertEq(frequent, issued(400));
        assertEq(controller.cumulativeEmission(), issued(800));
        assertEq(controller.cumulativeEmission() - frequent, issued(800) - issued(400));
    }

    function test_halvingCrossingInsideOneCheckpoint() public {
        activateWithHistory(0);
        advanceBlocks(H - 5);
        controller.checkpoint();
        assertEq(controller.cumulativeEmission(), issued(H - 5));
        advanceBlocks(10); // crosses the first halving
        (, uint256 emitted) = controller.checkpoint();
        assertEq(emitted, 5 * R0 + 5 * (R0 / 2));
        assertEq(controller.cumulativeEmission(), issued(H + 5));
    }

    function test_fullScheduleCompletesAndStaysCapped() public {
        activateWithHistory(0);
        advanceBlocks(3 * H + 1_000);
        (, uint256 emitted) = controller.checkpoint();
        assertEq(emitted, issued(3 * H));
        assertTrue(controller.completed());
        assertLe(controller.cumulativeEmission(), A);
        assertEq(controller.cumulativeEmission(), 1_889_999_999_999_999_999_999_408_010);
        // nothing more, ever
        advanceBlocks(10_000);
        (bool ok, uint256 more) = controller.checkpoint();
        assertTrue(ok);
        assertEq(more, 0);
    }

    function test_completionEmitsEventAndMintsAtMostAllowance() public {
        activateWithHistory(0);
        depositCheese(alice, 1e18); // only the CHEESE pool has stakers (400 points)
        advanceBlocks(3 * H);
        vm.expectEmit(false, false, false, false, address(controller));
        emit CheeseEmissionController.EmissionCompleted(0, 0);
        controller.checkpoint();
        vm.prank(alice);
        cheeseFarm.claim(alice);
        // 40% of the schedule minted to the CHEESE farm; the 20% reserve is never minted; the ETH and sIMD
        // pools' 40% sits accrued (unminted) and is forfeited when those empty farms first pull.
        assertApproxEqAbs(controller.totalMinted(), (issued(3 * H) * 400) / 1000, 1e6);
        assertLe(cheese.totalMinted(), cheese.MAX_SUPPLY());
        assertEq(controller.reserveUnminted(), (issued(3 * H) * 200) / 1000);
        depositEth(bob, 1 ether); // first pull on the empty ETH farm forfeits its accrual
        assertEq(controller.forfeitedEmission(), (issued(3 * H) * 200) / 1000);
        assertEq(ethFarm.pendingRewards(bob), 0);
    }

    function test_coreRegressionIsIgnored() public {
        activateWithHistory(0);
        advanceBlocks(50);
        controller.checkpoint();
        core.forceUnits(10 * 1e9); // height 10 < 50
        vm.expectEmit(address(controller));
        emit CheeseEmissionController.CoreRegression(50, 10);
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertFalse(ok);
        assertEq(emitted, 0);
        assertEq(controller.lastHeight(), 50);
    }

    function test_coreUnavailableIsTolerated() public {
        activateWithHistory(0);
        advanceBlocks(20);
        core.setUnavailable(true);
        (bool ok, uint256 emitted) = controller.checkpoint();
        assertFalse(ok);
        assertEq(emitted, 0);
        (bool readable,,) = controller.pendingCheckpoint();
        assertFalse(readable);
        core.setUnavailable(false);
        (ok, emitted) = controller.checkpoint();
        assertTrue(ok);
        assertEq(emitted, issued(20), "catches up once Core is back");
    }

    function test_pendingCheckpointPreview() public {
        activateWithHistory(5);
        advanceBlocks(33);
        (bool readable, uint64 toHeight, uint256 emission) = controller.pendingCheckpoint();
        assertTrue(readable);
        assertEq(toHeight, 38);
        assertEq(emission, issued(33));
        (, uint256 emitted) = controller.checkpoint();
        assertEq(emitted, emission);
    }

    // ---- pause ----

    function test_pauseStopsEmissionAndUnpauseCatchesUp() public {
        activateWithHistory(0);
        advanceBlocks(10);
        controller.checkpoint();
        vm.prank(owner);
        controller.pauseEmissions();
        advanceBlocks(10);
        (bool ok,) = controller.checkpoint();
        assertFalse(ok);
        assertEq(controller.cumulativeEmission(), issued(10));
        vm.prank(alice);
        vm.expectRevert();
        controller.unpauseEmissions();
        vm.prank(owner);
        controller.unpauseEmissions();
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.EmissionsNotPaused.selector);
        controller.unpauseEmissions();
        controller.checkpoint();
        assertEq(controller.cumulativeEmission(), issued(20), "schedule still matches SQK after unpause");
    }

    function test_guardianCanPauseOnlyOwnerUnpauses() public {
        vm.prank(owner);
        controller.setGuardian(carol);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.NotGuardianOrOwner.selector, alice));
        controller.pauseEmissions();
        vm.prank(carol);
        controller.pauseEmissions();
        assertTrue(controller.emissionsPaused());
        vm.prank(carol);
        vm.expectRevert();
        controller.unpauseEmissions();
        vm.prank(owner);
        controller.unpauseEmissions();
    }

    // ---- token binding ----

    function test_bindTokenOnceAndOnlyMatchingAuthority() public {
        vm.startPrank(owner);
        vm.expectRevert(CheeseEmissionController.TokenAlreadyBound.selector);
        controller.bindToken(address(cheese));
        vm.stopPrank();
        CheeseEmissionController fresh = new CheeseEmissionController(owner, address(core), treasury);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CheeseEmissionController.TokenAuthorityMismatch.selector, address(controller))
        );
        fresh.bindToken(address(cheese));
        vm.prank(owner);
        vm.expectRevert(CheeseEmissionController.TokenNotBound.selector);
        fresh.activate();
    }
}
