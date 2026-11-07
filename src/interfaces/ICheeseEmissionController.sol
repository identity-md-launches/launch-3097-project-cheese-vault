// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICheeseEmissionController {
    struct Pool {
        address farm; // the only address allowed to pull this pool's emission
        uint16 weight; // allocation points out of TOTAL_POINTS
        bool enabled; // disabled pools accrue nothing; their points fall back to the inactive reserve
        uint256 lastEmissionPerPoint; // global accumulator value at the pool's last settlement
        uint256 accrued; // settled, not yet minted CHEESE owed to the pool
        uint256 minted; // CHEESE ever minted to the pool's farm
    }

    function treasury() external view returns (address);
    function token() external view returns (address);
    function poolIdOf(address farm) external view returns (uint256);
    function pullRewards(uint256 poolId, bool hasStakers) external returns (uint256 amount, bool synced);
    function checkpoint() external returns (bool synced, uint256 emitted);
    function emissionsPaused() external view returns (bool);
    function previewPoolEmission(uint256 poolId) external view returns (uint256);
    function getPoolAllocation(uint256 poolId)
        external
        view
        returns (address farm, uint16 weight, bool enabled, uint256 pendingEmission, uint256 minted);
}
