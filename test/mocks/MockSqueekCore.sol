// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";

/// @notice Test double for the SqueekCore proxy: the same ABI, with knobs to certify rounds, complete blocks,
///         simulate unavailability and regressions.
contract MockSqueekCore is ISqueekCore {
    uint64 public constant ROUND_DURATION = 600;
    uint96 public constant BLOCK_UNITS_PER_BLOCK = 1_000_000_000;

    uint64 public genesisTimestamp;
    uint64 public settledThroughRound;
    uint96 public cumulativeBlockUnits;
    bool public unavailable;
    bool public corePaused;
    uint64 public roundDurationOverride;
    uint96 public blockUnitsOverride;

    // position after each certified round (round => cumulativeBlockUnits)
    mapping(uint64 => uint96) public unitsAfterRound;

    constructor(uint64 genesis) {
        genesisTimestamp = genesis;
        roundDurationOverride = ROUND_DURATION;
        blockUnitsOverride = BLOCK_UNITS_PER_BLOCK;
    }

    // ---- knobs ----

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function setCorePaused(bool value) external {
        corePaused = value;
    }

    function setClock(uint64 roundDuration_, uint96 blockUnits_) external {
        roundDurationOverride = roundDuration_;
        blockUnitsOverride = blockUnits_;
    }

    /// @notice Certifies rounds through `round` with `newBlocks` additional completed blocks (plus `extraUnits`).
    function settle(uint64 round, uint64 newBlocks, uint96 extraUnits) external {
        require(round >= settledThroughRound, "non increasing");
        cumulativeBlockUnits += uint96(newBlocks) * BLOCK_UNITS_PER_BLOCK + extraUnits;
        for (uint64 r = settledThroughRound + 1; r <= round; ++r) {
            unitsAfterRound[r] = cumulativeBlockUnits;
        }
        settledThroughRound = round;
    }

    /// @notice Forces the block counter (used to simulate a regression).
    function forceUnits(uint96 units) external {
        cumulativeBlockUnits = units;
    }

    // ---- ISqueekCore ----

    function state() external view returns (CoreState memory result) {
        require(!unavailable, "core unavailable");
        result.settledThroughRound = settledThroughRound;
        result.cumulativeBlockUnits = cumulativeBlockUnits;
        result.blockHeight = uint64(cumulativeBlockUnits / BLOCK_UNITS_PER_BLOCK);
        result.blockProgress = cumulativeBlockUnits % BLOCK_UNITS_PER_BLOCK;
        result.paused = corePaused;
    }

    function configuration() external view returns (CoreConfiguration memory result) {
        require(!unavailable, "core unavailable");
        result.genesisTimestamp = genesisTimestamp;
        result.roundDuration = roundDurationOverride;
        result.maxWorkPerRound = 10_000;
        result.maxRoundsPerBatch = 16;
        result.targetBlocksPerActiveRound = 40;
        result.difficultySmoothingRounds = 30;
        result.blockUnitsPerBlock = blockUnitsOverride;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256)
        external
        view
        returns (RoundPage memory result)
    {
        require(!unavailable, "core unavailable");
        require(afterRound <= throughRound && throughRound <= settledThroughRound, "InvalidRoundPageBounds");
        result.certifiedThroughRound = throughRound;
        result.start.cumulativeBlockUnits = unitsAfterRound[afterRound];
        result.end.cumulativeBlockUnits = unitsAfterRound[throughRound];
    }

    function blockInfo(uint64) external pure returns (BlockInfo memory) {
        revert("BlockNotSettled");
    }

    function paused() external view returns (bool) {
        return corePaused;
    }
}
