// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ISqueekMining
/// @notice The subset of the published SqueekMining ABI used by the Sepolia verification script to prove
///         that CHEESE's compiled-in schedule equals the live SQK schedule. Proxy on Sepolia:
///         0x2dCcB11fcC2dEfdd188555e45aCb52231e82e218.
interface ISqueekMining {
    struct MiningState {
        uint256 minted;
        uint64 processedThroughRound;
        uint64 startRound;
        uint64 startHeight;
        uint64 fundedBlocks;
        address guardian;
        bool bootstrapped;
        bool startCaptured;
        bool paused;
        bool active;
    }

    struct MiningIssuanceSchedule {
        uint256 allowance;
        uint256 launchBonus;
        uint64 bonusBlocks;
        uint64 halvingBlocks;
        uint256 firstPeriodRate;
        uint64 startHeight;
    }

    function SUPPLY_CAP() external view returns (uint256);
    function state() external view returns (MiningState memory);
    function issuanceSchedule() external view returns (MiningIssuanceSchedule memory schedule);
    function issued(uint64 blocksSinceStart) external view returns (uint256);
    function core() external view returns (address);
}
