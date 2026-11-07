// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ISqueekCore
/// @notice The subset of the published SqueekCore ABI (docs.squeekchain.com/assets/abi/SqueekCore.json,
///         release core-sepolia-20261103) that CHEESE reads. Field names, types and order match the
///         deployed proxy at 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4 (Sepolia, chain id 11155111).
interface ISqueekCore {
    struct CoreState {
        uint64 settledThroughRound; // certified frontier: every round <= this is settled
        uint64 cumulativeWork; // physical work units, all time
        uint96 cumulativeBlockUnits; // earned progress; 10^9 units = one Squeek block
        uint64 blockHeight; // cumulativeBlockUnits / 10^9
        uint96 blockProgress; // cumulativeBlockUnits % 10^9
        uint32 workPerThousandBlocks; // difficulty for the next active round
        uint256 authorizationNonce;
        bool paused;
    }

    struct CoreConfiguration {
        bytes32 streamId;
        uint64 genesisTimestamp; // seconds; round 1 starts here
        uint64 roundDuration; // 600 seconds
        uint64 maxWorkPerRound;
        uint16 maxRoundsPerBatch; // 16
        address guardian;
        address reporter;
        uint32 initialWorkPerThousandBlocks;
        uint64 targetBlocksPerActiveRound; // 40
        uint64 difficultySmoothingRounds; // 30
        uint96 blockUnitsPerBlock; // 1_000_000_000
    }

    struct LedgerPosition {
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint32 workPerThousandBlocks;
    }

    struct RoundCheckpoint {
        uint64 roundId;
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint32 workPerThousandBlocks;
        bytes32 dataHash;
    }

    struct RoundPage {
        uint64 certifiedThroughRound;
        LedgerPosition start;
        LedgerPosition end;
        RoundCheckpoint[] rounds;
    }

    struct BlockInfo {
        uint64 roundId;
        uint64 workThreshold;
    }

    function state() external view returns (CoreState memory result);
    function configuration() external view returns (CoreConfiguration memory result);
    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory result);
    function blockInfo(uint64 squeekBlock) external view returns (BlockInfo memory result);
    function paused() external view returns (bool);
}
