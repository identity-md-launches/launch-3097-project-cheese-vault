// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICheeseEmissionController} from "./interfaces/ICheeseEmissionController.sol";
import {ICheeseFarm} from "./interfaces/ICheeseFarm.sol";

/// @title CheeseFarm
/// @notice Base farm: nontransferable 18-decimal internal shares over a principal reserve, MasterChef-style
///         CHEESE reward accounting fed by CheeseEmissionController, and the Hamster Bite withdrawal fee.
///
///         Principal:   deposits mint shares at the current assets-per-share (0% fee). Withdrawals burn
///                      shares immediately (no cooldown). 15% of the gross assets backing the burned shares
///                      is the Hamster Bite: 85% goes to the withdrawer, 14% stays in the farm (raising
///                      assets per share for everyone remaining), 1% goes to the Treasury. If no shares
///                      remain, the whole 15% goes to the Treasury.
///         Rewards:     claimed separately from principal. The farm pulls the pool's accrued CHEESE from the
///                      controller before any share change, so new depositors never see earlier emission;
///                      if the farm is empty, the controller forfeits the accrual instead of minting it.
///         Reserves:    `totalAssets` (principal), `rewardReserve` (minted CHEESE) and `treasuryOwed` (fees
///                      the Treasury could not receive) are tracked internally and never read from balances,
///                      so donations cannot move the share price or be mistaken for rewards. The CHEESE farm
///                      holds all three in one token; the invariant
///                      balance >= totalAssets + rewardReserve + treasuryOwed always holds and surplus is
///                      skimmable only to the Treasury.
///         Treasury:    its share is pushed with a bounded gas stipend. If the push fails (a receiver that
///                      reverts, has no receive function or burns the stipend) the amount is credited to
///                      `treasuryOwed` and paid later through `payTreasury()`, so a withdrawer's 85% never
///                      depends on the Treasury accepting funds.
///
///         Owner powers: pause deposits (emergency) and skim donated surplus to the Treasury. The owner
///         cannot move principal, change fees or touch accrued rewards.
abstract contract CheeseFarm is Ownable2Step, ReentrancyGuard, ICheeseFarm {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant WITHDRAW_FEE_BPS = 1500; // Hamster Bite
    uint256 public constant RETAINED_FEE_BPS = 1400; // stays in the farm
    uint256 public constant TREASURY_FEE_BPS = 100; // to Treasury
    /// @dev Virtual offset against share-price manipulation when the farm is nearly empty.
    uint256 public constant VIRTUAL_SHARES = 1e3;
    uint256 public constant VIRTUAL_ASSETS = 1;
    uint256 public constant ACC_PRECISION = 1e36;
    /// @dev Gas forwarded with the Treasury's ETH share. Enough for any EOA, Safe or event-emitting receiver;
    ///      a receiver that needs more (or reverts) is paid through `payTreasury()` instead.
    uint256 public constant TREASURY_PUSH_GAS = 100_000;

    ICheeseEmissionController public immutable controller;

    uint256 public poolId;
    bool public registered;
    bool public depositsPaused;

    uint256 public totalShares;
    uint256 public totalAssets; // principal reserve
    uint256 public rewardReserve; // CHEESE pulled from the controller, not yet claimed
    uint256 public treasuryOwed; // Hamster Bite share the Treasury could not receive; paid by payTreasury()
    uint256 public accRewardPerShare;

    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) internal _rewardDebt;
    mapping(address => uint256) public claimedOf;
    mapping(address => uint256) internal _pendingOf; // harvested but unclaimed rewards

    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(
        address indexed account, uint256 shares, uint256 grossAssets, uint256 paid, uint256 retained, uint256 toTreasury
    );
    event RewardsClaimed(address indexed account, address indexed to, uint256 amount);
    event RewardsAccrued(uint256 amount, uint256 accRewardPerShare);
    event PoolRegistered(uint256 poolId);
    event DepositsPaused(bool paused);
    event SurplusSkimmed(address indexed treasury, uint256 amount);
    event TreasuryPaymentDeferred(address indexed treasury, uint256 amount);
    event TreasuryPaid(address indexed treasury, uint256 amount);

    error ZeroAmount();
    error ZeroShares();
    error ZeroAddress();
    error InsufficientShares(uint256 requested, uint256 available);
    error NotRegistered();
    error AlreadyRegistered();
    error NotController(address caller);
    error DepositsArePaused();
    error EmissionsPausedDepositsClosed();
    error AssetNotConfigured();
    error NativeTransferFailed(address to, uint256 amount);
    error NothingToSkim();
    error NothingOwedToTreasury();
    error SyncRequired();

    /// @dev Touches no other contract: the launch rehearses constructors on an empty chain.
    constructor(address owner_, address controller_) Ownable(owner_) {
        if (controller_ == address(0)) revert ZeroAddress();
        controller = ICheeseEmissionController(controller_);
    }

    /// @notice The CHEESE token, read from the controller (bound by the owner after launch).
    function cheese() public view returns (IERC20) {
        return IERC20(controller.token());
    }

    // ------------------------------------------------------------------------------------------------
    // Asset adapter (implemented per farm)
    // ------------------------------------------------------------------------------------------------

    /// @dev Pulls `amount` of the principal asset from msg.sender; returns the amount actually received.
    function _pull(uint256 amount, uint256 msgValue) internal virtual returns (uint256 received);
    /// @dev Pays `amount` of the principal asset to `to`; reverts on failure.
    function _push(address to, uint256 amount) internal virtual;
    /// @dev Pays `amount` of the principal asset to `to` without reverting; returns whether it succeeded.
    function _tryPush(address to, uint256 amount) internal virtual returns (bool);
    /// @dev The farm's current balance of the principal asset.
    function _assetBalance() internal view virtual returns (uint256);
    /// @dev Whether the principal asset is the CHEESE token (shared balance with rewards).
    function _assetIsCheese() internal view virtual returns (bool);

    /// @dev Whether the principal asset is configured (false only for the deferred sIMD farm before setAsset).
    function _assetConfigured() internal view virtual returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------------------------------------

    function emissionController() external view returns (address) {
        return address(controller);
    }

    /// @notice Called once by the controller's addPool.
    function onPoolRegistered(uint256 poolId_) external {
        if (msg.sender != address(controller)) revert NotController(msg.sender);
        if (registered) revert AlreadyRegistered();
        registered = true;
        poolId = poolId_;
        emit PoolRegistered(poolId_);
    }

    // ------------------------------------------------------------------------------------------------
    // Owner (emergency only)
    // ------------------------------------------------------------------------------------------------

    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPaused(paused);
    }

    /// @notice Sends tokens that were donated or sent by mistake to the Treasury. Principal and reward
    ///         reserves are never touched.
    function skimSurplus() external onlyOwner nonReentrant {
        uint256 extra = _surplus();
        if (extra == 0) revert NothingToSkim();
        address treasury = controller.treasury();
        emit SurplusSkimmed(treasury, extra);
        _push(treasury, extra);
    }

    // ------------------------------------------------------------------------------------------------
    // User actions
    // ------------------------------------------------------------------------------------------------

    /// @dev Shared deposit path. `msgValue` is msg.value for the ETH farm, 0 otherwise.
    function _deposit(uint256 amount, uint256 msgValue) internal returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        if (depositsPaused) revert DepositsArePaused();
        if (!_assetConfigured()) revert AssetNotConfigured();
        // A paused emission cannot be checkpointed; refusing deposits keeps catch-up emission away from
        // depositors who were not there when the blocks were certified.
        if (controller.emissionsPaused()) revert EmissionsPausedDepositsClosed();

        // Every Squeek block certified before this deposit must be priced and pulled (or forfeited) before
        // the new shares exist; otherwise the next successful checkpoint would spread it over them. A
        // deposit therefore waits while SqueekCore is unreadable or regressed; withdrawals never do.
        if (!_accrue()) revert SyncRequired();
        _harvestDebt(msg.sender);

        uint256 received = _pull(amount, msgValue);
        shares = _convertToShares(received);
        if (shares == 0) revert ZeroShares();

        totalAssets += received;
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        _rewardDebt[msg.sender] = _debtFor(sharesOf[msg.sender]);
        emit Deposited(msg.sender, received, shares);
    }

    /// @notice Burns `shares` and pays out 85% of the assets they back; applies the Hamster Bite.
    ///         Pending rewards are not claimed here (use claim).
    function withdraw(uint256 shares) external nonReentrant returns (uint256 paid) {
        if (shares == 0) revert ZeroShares();
        uint256 held = sharesOf[msg.sender];
        if (shares > held) revert InsufficientShares(shares, held);

        _accrue();
        _harvestDebt(msg.sender);

        uint256 gross = _convertToAssets(shares);
        uint256 fee = (gross * WITHDRAW_FEE_BPS) / BPS;
        paid = gross - fee;
        uint256 retained = (gross * RETAINED_FEE_BPS) / BPS;
        uint256 toTreasury = fee - retained;

        totalShares -= shares;
        sharesOf[msg.sender] = held - shares;
        _rewardDebt[msg.sender] = _debtFor(held - shares);
        if (totalShares == 0) {
            // Last depositor out: nobody remains to receive the retained share, so the whole fee goes to
            // the Treasury, together with whatever the virtual offset left in the reserve (retained fees
            // of earlier withdrawals that no share can reach). The farm restarts at an empty reserve.
            toTreasury = totalAssets - paid;
            retained = 0;
        }
        totalAssets -= (paid + toTreasury); // `retained` stays in the principal reserve
        emit Withdrawn(msg.sender, shares, gross, paid, retained, toTreasury);

        if (toTreasury != 0) _payTreasury(toTreasury);
        if (paid != 0) _push(msg.sender, paid);
    }

    /// @notice Claims the caller's accrued CHEESE rewards to `to`. Independent of principal.
    function claim(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        _accrue();
        uint256 pending = _harvestDebt(msg.sender);
        // Debts round up and the accumulator rounds down, so entitlements never sum above the reserve.
        // The clamp is defence in depth: a claim must never revert over rounding, and anything short stays
        // pending rather than being lost.
        amount = pending > rewardReserve ? rewardReserve : pending;
        if (amount == 0) return 0;
        _pendingOf[msg.sender] = pending - amount;
        rewardReserve -= amount;
        claimedOf[msg.sender] += amount;
        emit RewardsClaimed(msg.sender, to, amount);
        cheese().safeTransfer(to, amount);
    }

    /// @notice Pays the Treasury the Hamster Bite share that withdrawals could not push to it. Anyone may
    ///         call; it pays the Treasury configured on the controller now, so the owner can repoint a
    ///         broken Treasury and collect.
    function payTreasury() external nonReentrant returns (uint256 amount) {
        amount = treasuryOwed;
        if (amount == 0) revert NothingOwedToTreasury();
        treasuryOwed = 0;
        address treasury = controller.treasury();
        emit TreasuryPaid(treasury, amount);
        _push(treasury, amount);
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice Rewards claimable by `account` if claim() were called now (includes unpulled pool emission).
    function pendingRewards(address account) external view returns (uint256) {
        uint256 shares = sharesOf[account];
        if (shares == 0) return _pendingOf[account];
        uint256 acc = accRewardPerShare;
        if (totalShares != 0 && registered) {
            acc += (controller.previewPoolEmission(poolId) * ACC_PRECISION) / totalShares;
        }
        uint256 owed = Math.mulDiv(shares, acc, ACC_PRECISION);
        uint256 debt = _rewardDebt[account];
        return _pendingOf[account] + (owed > debt ? owed - debt : 0);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    /// @notice Assets backing `account`'s shares, before the Hamster Bite.
    function assetsOf(address account) external view returns (uint256) {
        return _convertToAssets(sharesOf[account]);
    }

    /// @notice Gross, paid, retained and treasury amounts for withdrawing `shares` now.
    function previewWithdraw(uint256 shares)
        external
        view
        returns (uint256 gross, uint256 paid, uint256 retained, uint256 toTreasury)
    {
        gross = _convertToAssets(shares);
        uint256 fee = (gross * WITHDRAW_FEE_BPS) / BPS;
        paid = gross - fee;
        retained = (gross * RETAINED_FEE_BPS) / BPS;
        toTreasury = fee - retained;
        if (shares >= totalShares) {
            toTreasury = totalAssets - paid; // the fee plus the residual no share can reach
            retained = 0;
        }
    }

    /// @notice Balance above the tracked principal, reward and Treasury reserves (donations, mistakes).
    function surplus() external view returns (uint256) {
        return _surplus();
    }

    // ------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------

    /// @dev Pulls the pool's accrued emission and spreads it over current shares. With no shares the
    ///      controller forfeits it, so nobody can inherit emission from before their deposit. Returns
    ///      whether the controller's accounting is current (every certified block priced).
    function _accrue() internal returns (bool synced) {
        if (!registered) return true;
        uint256 amount;
        (amount, synced) = controller.pullRewards(poolId, totalShares != 0);
        if (amount == 0) return synced;
        rewardReserve += amount;
        accRewardPerShare += (amount * ACC_PRECISION) / totalShares;
        emit RewardsAccrued(amount, accRewardPerShare);
    }

    /// @dev Moves `account`'s newly accrued rewards into its pending bucket; returns the full pending total.
    ///      Earned rewards floor and the debt ceils (see _debtFor), so an account's harvest never exceeds
    ///      its exact share and the sum over all accounts never exceeds what the farm pulled.
    function _harvestDebt(address account) internal returns (uint256 pending) {
        uint256 shares = sharesOf[account];
        uint256 owed = Math.mulDiv(shares, accRewardPerShare, ACC_PRECISION);
        uint256 debt = _rewardDebt[account];
        uint256 earned = owed > debt ? owed - debt : 0;
        _rewardDebt[account] = _debtFor(shares);
        pending = _pendingOf[account] + earned;
        _pendingOf[account] = pending;
    }

    /// @dev Reward debt for `shares` at the current accumulator, rounded up. The 512-bit product keeps the
    ///      farm usable however large the accumulator grows (a 1-wei first deposit makes it grow fast).
    function _debtFor(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, accRewardPerShare, ACC_PRECISION, Math.Rounding.Ceil);
    }

    /// @dev Pushes the Treasury's share with a bounded stipend; on failure it is owed instead of reverting,
    ///      so no Treasury configuration can block a withdrawer's own payout.
    function _payTreasury(uint256 amount) internal {
        address treasury = controller.treasury();
        if (_tryPush(treasury, amount)) return;
        treasuryOwed += amount;
        emit TreasuryPaymentDeferred(treasury, amount);
    }

    /// @dev Non-reverting ERC-20 transfer for the farms whose asset is a token: a false return, a revert or
    ///      malformed return data all read as failure.
    function _tryTransferERC20(IERC20 token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (data.length == 0) return address(token).code.length != 0;
        return data.length >= 32 && abi.decode(data, (bool));
    }

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    function _surplus() internal view returns (uint256) {
        uint256 reserved = totalAssets + treasuryOwed;
        if (_assetIsCheese()) reserved += rewardReserve;
        uint256 balance = _assetBalance();
        return balance > reserved ? balance - reserved : 0;
    }
}
