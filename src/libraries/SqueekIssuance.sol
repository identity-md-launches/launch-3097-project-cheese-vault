// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SqueekIssuance
/// @notice The SQK issuance schedule, transcribed from docs.squeekchain.com/developers/mining ("Issuance
///         schedule") and verified against SqueekMining.issuanceSchedule() and issued() on Sepolia
///         (release core-sepolia-20261103, Ethereum block 12081684):
///
///           allowance        A  = 1_890_000_000e18   (SUPPLY_CAP 2_100_000_000e18 - premint 210_000_000e18)
///           launchBonus      G  =   105_000_000e18
///           bonusBlocks      N  =        97_020
///           halvingBlocks    H  =       393_470
///           firstPeriodRate  R0 = 4 * floor((A - G) / (7 * H)) = 2_592_319_617_759_930_871_476 base units
///
///           issued(b) = R0     * min(b, H)
///                     + R0 / 2 * min(max(b - H, 0), H)
///                     + R0 / 4 * min(max(b - 2H, 0), H)
///                     + floor(G * min(b, N) / N)
///
///         CHEESE mirrors every value one for one. All functions are internal so the compiler inlines them.
library SqueekIssuance {
    /// @notice Lifetime cap, premint included (SqueekMining.SUPPLY_CAP, SqueekToken.cap).
    uint256 internal constant SUPPLY_CAP = 2_100_000_000e18;
    /// @notice Premint fixed by the SqueekToken constructor (SqueekToken.totalPreminted).
    uint256 internal constant PREMINT = 210_000_000e18;
    /// @notice Premint split published in sepolia.json launchConfiguration.tokenPremint.
    uint256 internal constant PREMINT_TEAM = 63_000_000e18;
    uint256 internal constant PREMINT_TREASURY = 63_000_000e18;
    uint256 internal constant PREMINT_LIQUIDITY = 84_000_000e18;
    /// @notice Mining allowance A = SUPPLY_CAP - PREMINT (issuanceSchedule().allowance).
    uint256 internal constant ALLOWANCE = SUPPLY_CAP - PREMINT;
    /// @notice Launch bonus G (issuanceSchedule().launchBonus).
    uint256 internal constant LAUNCH_BONUS = 105_000_000e18;
    /// @notice Blocks over which the launch bonus is spread, N (issuanceSchedule().bonusBlocks).
    uint64 internal constant BONUS_BLOCKS = 97_020;
    /// @notice Blocks per halving period, H (issuanceSchedule().halvingBlocks).
    uint64 internal constant HALVING_BLOCKS = 393_470;
    /// @notice Number of halving periods in the schedule (R0, R0/2, R0/4; nothing afterwards).
    uint64 internal constant HALVING_PERIODS = 3;
    /// @notice R0 (issuanceSchedule().firstPeriodRate), a multiple of 4 so the halved rates are exact.
    uint256 internal constant FIRST_PERIOD_RATE = 4 * ((ALLOWANCE - LAUNCH_BONUS) / (7 * uint256(HALVING_BLOCKS)));
    /// @notice Blocks after which issued() is flat: the schedule is complete.
    uint64 internal constant SCHEDULE_BLOCKS = HALVING_PERIODS * HALVING_BLOCKS;

    /// @notice Cumulative scheduled issuance after `blocksSinceStart` completed Squeek blocks past h0.
    /// @dev Identical to SqueekMining.issued. Never decreases and never exceeds ALLOWANCE.
    function issued(uint64 blocksSinceStart) internal pure returns (uint256 total) {
        uint256 b = blocksSinceStart;
        uint256 h = HALVING_BLOCKS;
        unchecked {
            // Each min(...) term is at most H and R0 * H fits comfortably in 256 bits.
            total = FIRST_PERIOD_RATE * _min(b, h);
            total += (FIRST_PERIOD_RATE / 2) * _min(b > h ? b - h : 0, h);
            total += (FIRST_PERIOD_RATE / 4) * _min(b > 2 * h ? b - 2 * h : 0, h);
            total += (LAUNCH_BONUS * _min(b, BONUS_BLOCKS)) / BONUS_BLOCKS;
        }
    }

    /// @notice Issuance for the blocks strictly after `fromBlocks` up to and including `toBlocks` (both counted
    ///         from h0). Pricing cumulative issuance at both ends makes the result independent of how blocks
    ///         are grouped into checkpoints, exactly as SqueekMining does per round.
    function issuedBetween(uint64 fromBlocks, uint64 toBlocks) internal pure returns (uint256) {
        if (toBlocks <= fromBlocks) return 0;
        return issued(toBlocks) - issued(fromBlocks);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
