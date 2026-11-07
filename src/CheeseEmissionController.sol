// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ISqueekCore} from "./interfaces/ISqueekCore.sol";
import {ICheeseToken} from "./interfaces/ICheeseToken.sol";
import {ICheeseFarm} from "./interfaces/ICheeseFarm.sol";
import {ICheeseEmissionController} from "./interfaces/ICheeseEmissionController.sol";
import {SqueekIssuance} from "./libraries/SqueekIssuance.sol";

/// @title CheeseEmissionController
/// @notice The single global CHEESE emission authority. It reads the verified SqueekCore block counter,
///         prices newly certified Squeek blocks with SQK's exact issuance schedule (launch bonus plus three
///         halvings), and distributes the result across farm pools by allocation points with O(1) lazy
///         accounting. Only pools' farms can pull minted CHEESE, and only for emission accrued while they
///         were enabled.
///
///         Emission model (mirrors SqueekMining):
///           - `activate()` schedules the start at the next full SqueekCore round (startRound = current + 1).
///           - The first checkpoint that sees round startRound-1 certified records the completed height at
///             that round as h0. Blocks at or below h0 never emit (no retroactive minting).
///           - Each checkpoint prices `issued(height - h0) - issued(lastHeight - h0)` in O(1), clipped to the
///             remaining allowance, so delayed checkpoints, halving crossings and large jumps all settle
///             exactly, and zero block movement emits zero.
///           - Only the share belonging to enabled pools is ever minted. The Future Pool Reserve (points not
///             assigned to an enabled pool) stays unminted; its historical emission is never redistributed.
///
///         Weight changes checkpoint first, settle the affected pools under the old weights, and apply
///         prospectively. Pools and depositors can never receive emission accrued before their eligibility.
contract CheeseEmissionController is Ownable2Step, ICheeseEmissionController {
    // ------------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------------

    /// @notice Allocation points in total: 400 CHEESE / 200 ETH / 200 sIMD / 200 Future Pool Reserve.
    uint16 public constant TOTAL_POINTS = 1000;
    /// @notice Precision of the per-point accumulator.
    uint256 public constant PRECISION = 1e18;
    /// @notice SqueekCore constants the schedule depends on; verified at activation.
    uint64 public constant ROUND_DURATION = 600;
    uint96 public constant BLOCK_UNITS_PER_BLOCK = 1_000_000_000;
    /// @dev Exact ABI sizes of SqueekCore's static return structs; any other size is treated as unavailable.
    uint256 internal constant CORE_STATE_BYTES = 8 * 32;
    uint256 internal constant CORE_CONFIGURATION_BYTES = 11 * 32;
    /// @dev Largest roundPage(r, r, 0) payload accepted. The page for a single round is 320 bytes with no
    ///      records and 480 with one; 4 KiB leaves room for a dozen records and costs a few hundred gas to
    ///      copy. Return data is never copied before its size has been checked against these bounds, so a
    ///      Core that returns megabytes cannot make the caller run out of gas (see _boundedStaticcall).
    uint256 internal constant CORE_ROUND_PAGE_MAX_BYTES = 4096;

    uint256 public constant MINING_ALLOWANCE = SqueekIssuance.ALLOWANCE;
    uint256 public constant LAUNCH_BONUS = SqueekIssuance.LAUNCH_BONUS;
    uint64 public constant BONUS_BLOCKS = SqueekIssuance.BONUS_BLOCKS;
    uint64 public constant HALVING_BLOCKS = SqueekIssuance.HALVING_BLOCKS;
    uint256 public constant FIRST_PERIOD_RATE = SqueekIssuance.FIRST_PERIOD_RATE;
    uint64 public constant SCHEDULE_BLOCKS = SqueekIssuance.SCHEDULE_BLOCKS;

    // ------------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------------

    /// @notice The verified SqueekCore proxy (Sepolia: 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4).
    ISqueekCore public immutable squeekCore;

    /// @notice CHEESE; set once by the owner after both contracts exist (the launch deploys this first).
    ICheeseToken public cheese;
    address public treasury;
    /// @notice May pause emissions (owner may too); only the owner unpauses. Role separation.
    address public guardian;
    bool public emissionsPaused;

    // Activation and Squeek cursor
    bool public activated;
    uint64 public genesisTimestamp;
    uint64 public startRound; // first earning round; 0 until activate()
    bool public startCaptured;
    uint64 public startHeight; // h0
    uint64 public lastHeight; // last Squeek block height priced
    bool public completed;

    // Emission accounting
    uint256 public cumulativeEmission; // scheduled emission priced so far (all 1000 points)
    uint256 public emissionPerPoint; // cumulativeEmission * PRECISION / TOTAL_POINTS
    uint256 public reserveUnminted; // emission attributable to unassigned/disabled points; never minted
    uint256 public forfeitedEmission; // emission accrued to pools with no stakers; never minted
    uint256 public totalMinted; // CHEESE minted by this controller
    uint16 public activeWeight; // points of enabled pools
    uint16 public totalWeight; // points of all registered pools (enabled or not)

    Pool[] internal _pools;
    mapping(address farm => uint256 poolIdPlusOne) internal _poolIndex;

    // ------------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------------

    event TokenBound(address indexed cheese);
    event TreasuryUpdated(address indexed previous, address indexed current);
    event GuardianUpdated(address indexed previous, address indexed current);
    event Activated(uint64 startRound, uint64 genesisTimestamp);
    event StartHeightCaptured(uint64 startRound, uint64 startHeight);
    event Checkpointed(
        uint64 indexed fromHeight, uint64 indexed toHeight, uint256 emission, uint256 cumulativeEmission
    );
    event EmissionCompleted(uint64 height, uint256 cumulativeEmission);
    event EmissionsPaused(address indexed by);
    event EmissionsUnpaused(address indexed by);
    event CoreUnavailable(bytes reason);
    event CoreRegression(uint64 lastHeight, uint64 reportedHeight);
    event PoolAdded(uint256 indexed poolId, address indexed farm, uint16 weight);
    event PoolWeightSet(uint256 indexed poolId, uint16 previousWeight, uint16 weight);
    event PoolEnabled(uint256 indexed poolId);
    event PoolDisabled(uint256 indexed poolId);
    event PoolSettled(uint256 indexed poolId, uint256 accrued);
    event RewardsPulled(uint256 indexed poolId, address indexed farm, uint256 amount);
    event RewardsForfeited(uint256 indexed poolId, uint256 amount);

    // ------------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------------

    error ZeroAddress();
    error TokenAlreadyBound();
    error TokenNotBound();
    error TokenAuthorityMismatch(address authority);
    error AlreadyActivated();
    error NotActivated();
    error EmissionsArePaused();
    error EmissionsNotPaused();
    error NotGuardianOrOwner(address caller);
    error SqueekCoreUnavailable();
    error SqueekCoreIdentityMismatch();
    error SyncRequired();
    error PoolAlreadyRegistered(address farm);
    error PoolNotFound(uint256 poolId);
    error PoolAlreadyEnabled(uint256 poolId);
    error PoolAlreadyDisabled(uint256 poolId);
    error WeightExceedsTotal(uint256 requested, uint256 available);
    error FarmMismatch(address farm);
    error NotPoolFarm(uint256 poolId, address caller);
    error LengthMismatch();
    error EmptyBatch();
    error DuplicatePoolId(uint256 poolId);
    /// @dev Never thrown; encoded as the CoreUnavailable reason when SqueekCore returns more than the bound.
    error OversizedReturnData(uint256 size, uint256 maxSize);

    // ------------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------------

    /// @param owner_ the launch owner; administers pools, treasury, guardian and pausing
    /// @param squeekCore_ the verified SqueekCore proxy on the launch chain; checked on first use, never here
    /// @param treasury_ receives the 1% Hamster Bite share (and the full 15% when a farm empties)
    constructor(address owner_, address squeekCore_, address treasury_) Ownable(owner_) {
        if (squeekCore_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        squeekCore = ISqueekCore(squeekCore_);
        treasury = treasury_;
        guardian = owner_;
        emit TreasuryUpdated(address(0), treasury_);
        emit GuardianUpdated(address(0), owner_);
    }

    // ------------------------------------------------------------------------------------------------
    // Owner configuration
    // ------------------------------------------------------------------------------------------------

    /// @notice Binds CHEESE once. The token must name this controller as its immutable emission authority.
    function bindToken(address cheese_) external onlyOwner {
        if (address(cheese) != address(0)) revert TokenAlreadyBound();
        if (cheese_ == address(0)) revert ZeroAddress();
        address authority = ICheeseToken(cheese_).emissionAuthority();
        if (authority != address(this)) revert TokenAuthorityMismatch(authority);
        cheese = ICheeseToken(cheese_);
        emit TokenBound(cheese_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, treasury_);
        treasury = treasury_;
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        emit GuardianUpdated(guardian, guardian_);
        guardian = guardian_;
    }

    /// @notice Schedules emission from the next full SqueekCore round, like SqueekMining.start(). Reads and
    ///         verifies SqueekCore's clock constants; reverts if they differ from the documented values.
    function activate() external onlyOwner {
        if (address(cheese) == address(0)) revert TokenNotBound();
        if (activated) revert AlreadyActivated();
        (bool ok, ISqueekCore.CoreConfiguration memory config) = _readConfiguration();
        if (!ok) revert SqueekCoreUnavailable();
        if (config.roundDuration != ROUND_DURATION || config.blockUnitsPerBlock != BLOCK_UNITS_PER_BLOCK) {
            revert SqueekCoreIdentityMismatch();
        }
        uint64 current = _currentRound(config.genesisTimestamp);
        activated = true;
        genesisTimestamp = config.genesisTimestamp;
        startRound = current + 1;
        emit Activated(startRound, config.genesisTimestamp);
    }

    /// @notice Emergency stop. While paused no emission is priced or minted, farms refuse deposits, and
    ///         allocation changes revert; withdrawals and claims keep working. Unpausing catches up the
    ///         blocks certified meanwhile, so the schedule still matches SQK one for one. Blocks certified
    ///         before the pause are priced first (best effort), so they stay with whoever was staked then.
    function pauseEmissions() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner(msg.sender);
        if (emissionsPaused) revert EmissionsArePaused();
        _sync();
        emissionsPaused = true;
        emit EmissionsPaused(msg.sender);
    }

    function unpauseEmissions() external onlyOwner {
        if (!emissionsPaused) revert EmissionsNotPaused();
        emissionsPaused = false;
        emit EmissionsUnpaused(msg.sender);
    }

    // ------------------------------------------------------------------------------------------------
    // Pool administration (all changes apply prospectively, after a successful checkpoint)
    // ------------------------------------------------------------------------------------------------

    /// @notice Registers a farm as a pool with `weight` points. The farm must point back at this controller.
    function addPool(address farm, uint16 weight) external onlyOwner returns (uint256 poolId) {
        if (farm == address(0)) revert ZeroAddress();
        if (_poolIndex[farm] != 0) revert PoolAlreadyRegistered(farm);
        if (ICheeseFarm(farm).emissionController() != address(this) || ICheeseFarm(farm).registered()) {
            revert FarmMismatch(farm);
        }
        _requireSync();
        if (uint256(totalWeight) + weight > TOTAL_POINTS) {
            revert WeightExceedsTotal(weight, TOTAL_POINTS - totalWeight);
        }
        poolId = _pools.length;
        _pools.push(
            Pool({
                farm: farm, weight: weight, enabled: true, lastEmissionPerPoint: emissionPerPoint, accrued: 0, minted: 0
            })
        );
        _poolIndex[farm] = poolId + 1;
        totalWeight += weight;
        activeWeight += weight;
        ICheeseFarm(farm).onPoolRegistered(poolId);
        emit PoolAdded(poolId, farm, weight);
    }

    function setPoolWeight(uint256 poolId, uint16 weight) external onlyOwner {
        _requireSync();
        _setWeight(poolId, weight);
    }

    function batchSetPoolWeights(uint256[] calldata poolIds, uint16[] calldata weights) external onlyOwner {
        if (poolIds.length != weights.length) revert LengthMismatch();
        if (poolIds.length == 0) revert EmptyBatch();
        // The two passes below are order-independent, so a repeated id would have no defined winner.
        for (uint256 i; i < poolIds.length; ++i) {
            for (uint256 j = i + 1; j < poolIds.length; ++j) {
                if (poolIds[i] == poolIds[j]) revert DuplicatePoolId(poolIds[i]);
            }
        }
        _requireSync();
        // Lower weights first so a reallocation whose sum stays within TOTAL_POINTS never fails midway.
        for (uint256 i; i < poolIds.length; ++i) {
            if (weights[i] <= _pool(poolIds[i]).weight) _setWeight(poolIds[i], weights[i]);
        }
        for (uint256 i; i < poolIds.length; ++i) {
            if (weights[i] > _pool(poolIds[i]).weight) _setWeight(poolIds[i], weights[i]);
        }
    }

    /// @notice Stops a pool's accrual. Its points fall back to the inactive reserve until re-enabled.
    function disablePool(uint256 poolId) external onlyOwner {
        Pool storage pool = _pool(poolId);
        if (!pool.enabled) revert PoolAlreadyDisabled(poolId);
        _requireSync();
        _settle(poolId, pool);
        pool.enabled = false;
        activeWeight -= pool.weight;
        emit PoolDisabled(poolId);
    }

    function enablePool(uint256 poolId) external onlyOwner {
        Pool storage pool = _pool(poolId);
        if (pool.enabled) revert PoolAlreadyEnabled(poolId);
        _requireSync();
        pool.lastEmissionPerPoint = emissionPerPoint; // prospective only
        pool.enabled = true;
        activeWeight += pool.weight;
        emit PoolEnabled(poolId);
    }

    // ------------------------------------------------------------------------------------------------
    // Permissionless checkpoint
    // ------------------------------------------------------------------------------------------------

    /// @notice Prices every newly certified Squeek block. Anyone may call. Returns false (and emits why)
    ///         when emissions are paused or SqueekCore cannot be read; nothing is lost, the next successful
    ///         call catches up.
    function checkpoint() external returns (bool synced, uint256 emitted) {
        return _sync();
    }

    /// @notice Farm hook: settles the pool and mints its accrued CHEESE to the farm. When the farm has no
    ///         stakers the accrual is forfeited (never minted) so a later depositor cannot inherit it.
    ///         `synced` reports whether every certified block is now priced; farms refuse deposits when it
    ///         is false and let withdrawals and claims through regardless.
    function pullRewards(uint256 poolId, bool hasStakers) external returns (uint256 amount, bool synced) {
        Pool storage pool = _pool(poolId);
        if (msg.sender != pool.farm) revert NotPoolFarm(poolId, msg.sender);
        (synced,) = _sync(); // best effort: withdrawals must never be blocked by Squeekchain availability
        if (pool.enabled) _settle(poolId, pool);
        amount = pool.accrued;
        if (amount == 0) return (0, synced);
        pool.accrued = 0;
        if (hasStakers) {
            pool.minted += amount;
            totalMinted += amount;
            emit RewardsPulled(poolId, pool.farm, amount);
            cheese.mintEmission(pool.farm, amount);
        } else {
            forfeitedEmission += amount;
            emit RewardsForfeited(poolId, amount);
            amount = 0;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    function poolCount() external view returns (uint256) {
        return _pools.length;
    }

    function poolIdOf(address farm) external view returns (uint256) {
        uint256 idx = _poolIndex[farm];
        if (idx == 0) revert PoolNotFound(type(uint256).max);
        return idx - 1;
    }

    function token() external view returns (address) {
        return address(cheese);
    }

    /// @notice A pool's allocation and accounting, including emission settled-but-unpulled and unsettled.
    function getPoolAllocation(uint256 poolId)
        external
        view
        returns (address farm, uint16 weight, bool enabled, uint256 pendingEmission, uint256 minted)
    {
        Pool storage pool = _pool(poolId);
        farm = pool.farm;
        weight = pool.weight;
        enabled = pool.enabled;
        minted = pool.minted;
        pendingEmission = pool.accrued;
        if (pool.enabled) {
            pendingEmission += (uint256(pool.weight) * (emissionPerPoint - pool.lastEmissionPerPoint)) / PRECISION;
        }
    }

    /// @notice Everything a pool could pull right now: settled accrual, unsettled accrual, and its share of the
    ///         Squeek blocks certified since the last checkpoint. Used by farms' pendingRewards views.
    function previewPoolEmission(uint256 poolId) external view returns (uint256 total) {
        Pool storage pool = _pool(poolId);
        total = pool.accrued;
        if (!pool.enabled) return total;
        // Computed exactly as a pull would: the unsynced checkpoint first raises the per-point accumulator
        // (_sync), then the pool's share floors once (_settle). Two separate floors could read 1 wei low.
        uint256 deltaPerPoint = emissionPerPoint - pool.lastEmissionPerPoint;
        (bool readable,, uint256 unsynced) = this.pendingCheckpoint();
        if (readable) deltaPerPoint += (unsynced * PRECISION) / TOTAL_POINTS;
        total += (uint256(pool.weight) * deltaPerPoint) / PRECISION;
    }

    /// @notice Points split: enabled pools / disabled pools / the Future Pool Reserve (never minted).
    function getAllocation() external view returns (uint16 active, uint16 disabled, uint16 reserve) {
        active = activeWeight;
        disabled = totalWeight - activeWeight;
        reserve = TOTAL_POINTS - totalWeight;
    }

    /// @notice Blocks priced so far after h0 (SqueekMining.state().fundedBlocks analogue).
    function fundedBlocks() external view returns (uint64) {
        return startCaptured ? lastHeight - startHeight : 0;
    }

    /// @notice SQK's cumulative schedule: identical to SqueekMining.issued.
    function issued(uint64 blocksSinceStart) external pure returns (uint256) {
        return SqueekIssuance.issued(blocksSinceStart);
    }

    /// @notice What a checkpoint would emit now, and whether SqueekCore could be read.
    function pendingCheckpoint() external view returns (bool readable, uint64 toHeight, uint256 emission) {
        if (!activated || completed || emissionsPaused) return (true, lastHeight, 0);
        (bool ok, ISqueekCore.CoreState memory s,) = _readState();
        if (!ok) return (false, lastHeight, 0);
        uint64 h0 = startHeight;
        uint64 from = lastHeight;
        if (!startCaptured) {
            if (s.settledThroughRound < startRound - 1) return (true, 0, 0);
            (bool pageOk, uint64 height,) = _readHeightAtRound(startRound - 1);
            if (!pageOk) return (false, 0, 0);
            h0 = height;
            from = h0;
        }
        if (s.blockHeight <= from) return (true, from, 0);
        emission = _clip(SqueekIssuance.issuedBetween(from - h0, s.blockHeight - h0));
        return (true, s.blockHeight, emission);
    }

    function currentRound() external view returns (uint64) {
        if (!activated) revert NotActivated();
        return _currentRound(genesisTimestamp);
    }

    // ------------------------------------------------------------------------------------------------
    // ABI decoding helpers (called only through `this`, so a malformed payload reverts here, not in the
    // user's transaction; see _readState)
    // ------------------------------------------------------------------------------------------------

    function decodeCoreState(bytes calldata data) external pure returns (ISqueekCore.CoreState memory) {
        return abi.decode(data, (ISqueekCore.CoreState));
    }

    function decodeCoreConfiguration(bytes calldata data) external pure returns (ISqueekCore.CoreConfiguration memory) {
        return abi.decode(data, (ISqueekCore.CoreConfiguration));
    }

    function decodeRoundPage(bytes calldata data) external pure returns (ISqueekCore.RoundPage memory) {
        return abi.decode(data, (ISqueekCore.RoundPage));
    }

    // ------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------

    function _pool(uint256 poolId) internal view returns (Pool storage pool) {
        if (poolId >= _pools.length) revert PoolNotFound(poolId);
        pool = _pools[poolId];
    }

    function _currentRound(uint64 genesis) internal view returns (uint64) {
        if (block.timestamp < genesis) return 0;
        return uint64((block.timestamp - genesis) / ROUND_DURATION) + 1;
    }

    /// @dev Allocation changes must see every accrued block under the old weights; otherwise revert.
    function _requireSync() internal {
        if (emissionsPaused) revert EmissionsArePaused();
        (bool ok,) = _sync();
        if (!ok) revert SyncRequired();
    }

    function _setWeight(uint256 poolId, uint16 weight) internal {
        Pool storage pool = _pool(poolId);
        uint16 previous = pool.weight;
        if (weight == previous) return;
        uint256 newTotal = uint256(totalWeight) - previous + weight;
        if (newTotal > TOTAL_POINTS) revert WeightExceedsTotal(weight, TOTAL_POINTS - totalWeight + previous);
        if (pool.enabled) {
            _settle(poolId, pool);
            activeWeight = uint16(uint256(activeWeight) - previous + weight);
        }
        totalWeight = uint16(newTotal);
        pool.weight = weight;
        emit PoolWeightSet(poolId, previous, weight);
    }

    /// @dev Moves an enabled pool's share of emission since its last settlement into `accrued`.
    function _settle(uint256 poolId, Pool storage pool) internal {
        uint256 delta = emissionPerPoint - pool.lastEmissionPerPoint;
        if (delta == 0) return;
        uint256 owed = (uint256(pool.weight) * delta) / PRECISION;
        pool.lastEmissionPerPoint = emissionPerPoint;
        if (owed == 0) return;
        pool.accrued += owed;
        emit PoolSettled(poolId, owed);
    }

    function _clip(uint256 emission) internal view returns (uint256) {
        uint256 remaining = MINING_ALLOWANCE - cumulativeEmission;
        return emission > remaining ? remaining : emission;
    }

    /// @dev Static call to SqueekCore that copies return data only after checking its size. Solidity's
    ///      `addr.staticcall(...)` copies the whole payload first, and the copy is paid by the caller out of
    ///      the 1/64 of gas it kept (EIP-150): a Core that burns the forwarded gas and then returns megabytes
    ///      would make every read, and with it every withdraw, claim and the emergency pause, run out of gas.
    ///      Here nothing is written during the call and `returndatasize()` is checked against `maxBytes`
    ///      before any copy, so an oversized payload (success or revert) costs nothing and reads as
    ///      unavailable with an `OversizedReturnData` reason.
    function _boundedStaticcall(bytes memory input, uint256 maxBytes)
        internal
        view
        returns (bool success, bytes memory data)
    {
        address target = address(squeekCore);
        uint256 size;
        assembly ("memory-safe") {
            success := staticcall(gas(), target, add(input, 0x20), mload(input), 0, 0)
            size := returndatasize()
        }
        if (size > maxBytes) {
            return (false, abi.encodeWithSelector(OversizedReturnData.selector, size, maxBytes));
        }
        data = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(data, 0x20), 0, size)
        }
    }

    /// @dev Reads SqueekCore.state() defensively. Solidity's try/catch does not cover return data that fails
    ///      to decode or a target without code (both revert in the caller), so the call is a bounded raw
    ///      staticcall whose payload must have the exact ABI size and decode through `this.decodeCoreState`.
    ///      Any failure reads as "unavailable" with the raw payload as the reason, and never blocks a user
    ///      action.
    function _readState() internal view returns (bool ok, ISqueekCore.CoreState memory s, bytes memory reason) {
        (bool success, bytes memory data) = _boundedStaticcall(abi.encodeCall(ISqueekCore.state, ()), CORE_STATE_BYTES);
        if (!success || data.length != CORE_STATE_BYTES) return (false, s, data);
        try this.decodeCoreState(data) returns (ISqueekCore.CoreState memory decoded) {
            return (true, decoded, "");
        } catch {
            return (false, s, data);
        }
    }

    /// @dev Same defensive read for SqueekCore.configuration() (used only by activate()).
    function _readConfiguration() internal view returns (bool ok, ISqueekCore.CoreConfiguration memory c) {
        (bool success, bytes memory data) =
            _boundedStaticcall(abi.encodeCall(ISqueekCore.configuration, ()), CORE_CONFIGURATION_BYTES);
        if (!success || data.length != CORE_CONFIGURATION_BYTES) return (false, c);
        try this.decodeCoreConfiguration(data) returns (ISqueekCore.CoreConfiguration memory decoded) {
            return (true, decoded);
        } catch {
            return (false, c);
        }
    }

    /// @dev Completed Squeek height at the end of `round`, from roundPage(round, round, 0).end, read the same
    ///      defensive way (the page is dynamically encoded, so its size is only bounded here and the decode
    ///      helper validates the layout).
    function _readHeightAtRound(uint64 round) internal view returns (bool ok, uint64 height, bytes memory reason) {
        (bool success, bytes memory data) =
            _boundedStaticcall(abi.encodeCall(ISqueekCore.roundPage, (round, round, 0)), CORE_ROUND_PAGE_MAX_BYTES);
        if (!success || data.length == 0) return (false, 0, data);
        try this.decodeRoundPage(data) returns (ISqueekCore.RoundPage memory page) {
            return (true, uint64(page.end.cumulativeBlockUnits / BLOCK_UNITS_PER_BLOCK), "");
        } catch {
            return (false, 0, data);
        }
    }

    /// @dev Reads SqueekCore and prices newly certified blocks. Returns (true, x) when accounting is current,
    ///      (false, 0) when it could not be brought current (paused, Core unreadable, Core regressed).
    function _sync() internal returns (bool, uint256) {
        if (!activated || completed) return (true, 0);
        if (emissionsPaused) return (false, 0);

        (bool ok, ISqueekCore.CoreState memory s, bytes memory reason) = _readState();
        if (!ok) {
            emit CoreUnavailable(reason);
            return (false, 0);
        }

        if (!startCaptured) {
            // Mirror SqueekMining: h0 is the completed height at the end of round startRound - 1.
            if (s.settledThroughRound < startRound - 1) return (true, 0);
            (bool pageOk, uint64 h0, bytes memory pageReason) = _readHeightAtRound(startRound - 1);
            if (!pageOk) {
                emit CoreUnavailable(pageReason);
                return (false, 0);
            }
            startCaptured = true;
            startHeight = h0;
            lastHeight = h0;
            emit StartHeightCaptured(startRound, h0);
        }

        uint64 from = lastHeight;
        uint64 to = s.blockHeight;
        if (to < from) {
            emit CoreRegression(from, to);
            return (false, 0);
        }
        if (to == from) return (true, 0);

        uint256 emission = _clip(SqueekIssuance.issuedBetween(from - startHeight, to - startHeight));
        lastHeight = to;
        if (emission != 0) {
            cumulativeEmission += emission;
            emissionPerPoint += (emission * PRECISION) / TOTAL_POINTS;
            reserveUnminted += (emission * (TOTAL_POINTS - activeWeight)) / TOTAL_POINTS;
        }
        emit Checkpointed(from, to, emission, cumulativeEmission);

        if (to - startHeight >= SCHEDULE_BLOCKS || cumulativeEmission == MINING_ALLOWANCE) {
            completed = true;
            emit EmissionCompleted(to, cumulativeEmission);
        }
        return (true, emission);
    }
}
