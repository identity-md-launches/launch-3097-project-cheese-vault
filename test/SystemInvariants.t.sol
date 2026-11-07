// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseFarm} from "../src/CheeseFarm.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseToken} from "../src/CheeseToken.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @notice Drives the whole system at once: both value-holding farms (CHEESE, where principal and rewards
///         share one token, and native ETH), allocation changes, guardian pauses, SqueekCore outages, CHEESE
///         donations and skims, and certified Squeek blocks up to and past the end of the schedule.
contract SystemHandler is Test {
    CheeseEmissionController public controller;
    CheeseToken public cheese;
    CheeseFarmERC20 public cheeseFarm;
    CheeseFarmETH public ethFarm;
    MockSqueekCore public core;
    address public owner;
    address public treasury;

    address[] public actors;

    // ghost accounting, per principal asset
    uint256 public cheeseIn;
    uint256 public cheeseOutUsers;
    uint256 public cheeseOutTreasury;
    uint256 public ethIn;
    uint256 public ethOutUsers;
    uint256 public ethOutTreasury;
    uint256 public rewardsClaimed;

    uint256 public lastCumulative;
    bool public sawCompleted;
    bool public emissionRegressed;
    bool public completionReopened;
    bool public claimReverted;
    bool public claimMismatch;
    bool public withdrawReverted;

    constructor(
        CheeseEmissionController controller_,
        CheeseToken cheese_,
        CheeseFarmERC20 cheeseFarm_,
        CheeseFarmETH ethFarm_,
        MockSqueekCore core_,
        address owner_,
        address treasury_,
        address[] memory actors_
    ) {
        controller = controller_;
        cheese = cheese_;
        cheeseFarm = cheeseFarm_;
        ethFarm = ethFarm_;
        core = core_;
        owner = owner_;
        treasury = treasury_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _track() internal {
        uint256 cum = controller.cumulativeEmission();
        if (cum < lastCumulative) emissionRegressed = true;
        lastCumulative = cum;
        if (sawCompleted && !controller.completed()) completionReopened = true;
        if (controller.completed()) sawCompleted = true;
    }

    // ---- users ----

    function depositEth(uint256 seed, uint96 amount) external {
        address who = _actor(seed);
        uint256 amt = bound(amount, 1, 50 ether);
        vm.prank(who);
        try ethFarm.deposit{value: amt}() {
            ethIn += amt;
        } catch {}
        _track();
    }

    function depositCheese(uint256 seed, uint96 amount) external {
        address who = _actor(seed);
        uint256 bal = cheese.balanceOf(who);
        if (bal == 0) return;
        uint256 amt = bound(amount, 1, bal);
        vm.startPrank(who);
        cheese.approve(address(cheeseFarm), amt);
        try cheeseFarm.deposit(amt) {
            cheeseIn += amt;
        } catch {}
        vm.stopPrank();
        _track();
    }

    function withdrawEth(uint256 seed, uint16 fractionBps) external {
        address who = _actor(seed);
        uint256 shares = (ethFarm.sharesOf(who) * bound(fractionBps, 1, 10_000)) / 10_000;
        if (shares == 0) return;
        uint256 tBefore = treasury.balance;
        vm.prank(who);
        try ethFarm.withdraw(shares) returns (uint256 paid) {
            ethOutUsers += paid;
            ethOutTreasury += treasury.balance - tBefore;
        } catch {
            withdrawReverted = true;
        }
        _track();
    }

    function withdrawCheese(uint256 seed, uint16 fractionBps) external {
        address who = _actor(seed);
        uint256 shares = (cheeseFarm.sharesOf(who) * bound(fractionBps, 1, 10_000)) / 10_000;
        if (shares == 0) return;
        uint256 tBefore = cheese.balanceOf(treasury);
        vm.prank(who);
        try cheeseFarm.withdraw(shares) returns (uint256 paid) {
            cheeseOutUsers += paid;
            cheeseOutTreasury += cheese.balanceOf(treasury) - tBefore;
        } catch {
            withdrawReverted = true;
        }
        _track();
    }

    /// @dev A claim must never revert (the earlier rounding underflow is fixed) and must pay what pendingRewards
    ///      promised just before (to within view rounding), with nothing left pending.
    function claim(uint256 seed, bool fromCheeseFarm) external {
        address who = _actor(seed);
        CheeseFarm farm = fromCheeseFarm ? CheeseFarm(address(cheeseFarm)) : CheeseFarm(address(ethFarm));
        uint256 promised = farm.pendingRewards(who);
        uint256 balBefore = cheese.balanceOf(who);
        vm.prank(who);
        try farm.claim(who) returns (uint256 amount) {
            rewardsClaimed += amount;
            // The view prices unsynced blocks in a separate floor, so it may differ from the claim by rounding.
            if (amount > promised + 2 || promised > amount + 2) claimMismatch = true;
            if (cheese.balanceOf(who) - balBefore != amount) claimMismatch = true;
            if (farm.pendingRewards(who) != 0) claimMismatch = true;
        } catch {
            claimReverted = true;
        }
        _track();
    }

    function donateCheese(uint256 seed, uint96 amount) external {
        address who = _actor(seed);
        uint256 bal = cheese.balanceOf(who);
        if (bal == 0) return;
        uint256 amt = bound(amount, 1, bal);
        vm.prank(who);
        cheese.transfer(address(cheeseFarm), amt);
    }

    function skim() external {
        vm.prank(owner);
        try cheeseFarm.skimSurplus() {} catch {}
    }

    // ---- Squeekchain ----

    function advance(uint32 blocks, uint32 extraUnits) external {
        core.settle(core.settledThroughRound() + 1, uint64(bound(blocks, 0, 60_000)), uint96(bound(extraUnits, 0, 1e9)));
    }

    function checkpoint() external {
        controller.checkpoint();
        _track();
    }

    function toggleOutage(bool down) external {
        core.setUnavailable(down);
    }

    // ---- administration ----

    function setWeight(uint8 pool, uint16 weight) external {
        vm.prank(owner);
        try controller.setPoolWeight(bound(pool, 0, 2), uint16(bound(weight, 0, 600))) {} catch {}
        _track();
    }

    function togglePool(uint8 pool, bool enable) external {
        uint256 id = bound(pool, 0, 2);
        vm.prank(owner);
        if (enable) {
            try controller.enablePool(id) {} catch {}
        } else {
            try controller.disablePool(id) {} catch {}
        }
        _track();
    }

    function togglePause(bool pause) external {
        vm.prank(owner);
        if (pause) {
            try controller.pauseEmissions() {} catch {}
        } else {
            try controller.unpauseEmissions() {} catch {}
        }
        _track();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract SystemInvariantTest is CheeseBase {
    SystemHandler internal handler;
    address[] internal players;

    function setUp() public override {
        super.setUp();
        activateWithHistory(0);
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xBEEF00 + i));
            players.push(a);
            vm.deal(a, 10_000 ether);
            giveCheese(a, 1_000_000e18);
        }
        handler = new SystemHandler(controller, cheese, cheeseFarm, ethFarm, core, owner, treasury, players);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_reservesBacked() public view {
        // Principal and rewards share the CHEESE balance; donations only ever add surplus.
        assertGe(cheese.balanceOf(address(cheeseFarm)), cheeseFarm.totalAssets() + cheeseFarm.rewardReserve());
        assertEq(address(ethFarm).balance, ethFarm.totalAssets());
        assertEq(cheese.balanceOf(address(ethFarm)), ethFarm.rewardReserve());
        // The Treasury is an EOA, so nothing is ever deferred.
        assertEq(ethFarm.treasuryOwed(), 0);
        assertEq(cheeseFarm.treasuryOwed(), 0);
        // An empty farm holds no principal: the last withdrawer's exit sweeps the residual to the Treasury.
        if (ethFarm.totalShares() == 0) assertEq(ethFarm.totalAssets(), 0, "empty ETH farm, zero principal");
        if (cheeseFarm.totalShares() == 0) assertEq(cheeseFarm.totalAssets(), 0, "empty CHEESE farm, zero principal");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_exitsNeverRevert() public view {
        assertFalse(handler.claimReverted(), "claim reverted");
        assertFalse(handler.claimMismatch(), "claim paid other than pendingRewards promised");
        assertFalse(handler.withdrawReverted(), "withdraw of held shares reverted");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_principalConservation() public view {
        assertEq(
            handler.ethIn(), ethFarm.totalAssets() + handler.ethOutUsers() + handler.ethOutTreasury(), "ETH conserved"
        );
        assertEq(
            handler.cheeseIn(),
            cheeseFarm.totalAssets() + handler.cheeseOutUsers() + handler.cheeseOutTreasury(),
            "CHEESE principal conserved"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_sharesFullySubscribed() public view {
        uint256 ethSum;
        uint256 cheeseSum;
        for (uint256 i; i < players.length; ++i) {
            ethSum += ethFarm.sharesOf(players[i]);
            cheeseSum += cheeseFarm.sharesOf(players[i]);
        }
        assertEq(ethSum, ethFarm.totalShares());
        assertEq(cheeseSum, cheeseFarm.totalShares());
        assertLe(ethFarm.convertToAssets(ethFarm.totalShares()), ethFarm.totalAssets());
        assertLe(cheeseFarm.convertToAssets(cheeseFarm.totalShares()), cheeseFarm.totalAssets());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_supplyAndMintAccounting() public view {
        assertLe(cheese.totalMinted(), cheese.MAX_SUPPLY());
        assertEq(cheese.totalMinted(), cheese.PREMINT() + controller.totalMinted());
        uint256 mintedSum;
        uint256 pendingSum;
        for (uint256 p; p < controller.poolCount(); ++p) {
            (,,, uint256 pe, uint256 minted) = controller.getPoolAllocation(p);
            mintedSum += minted;
            pendingSum += pe;
        }
        assertEq(mintedSum, controller.totalMinted(), "pool mints sum to controller mints");
        assertEq(controller.cumulativeEmission(), issued(controller.fundedBlocks()), "exact SQK schedule");
        assertLe(controller.cumulativeEmission(), controller.MINING_ALLOWANCE());
        assertLe(
            controller.totalMinted() + controller.forfeitedEmission() + controller.reserveUnminted() + pendingSum,
            controller.cumulativeEmission(),
            "never more than scheduled"
        );
        // Everything minted is either claimed or held by a farm's reward reserve.
        assertEq(
            handler.rewardsClaimed() + cheeseFarm.rewardReserve() + ethFarm.rewardReserve(), controller.totalMinted()
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_monotoneAndFinal() public view {
        assertFalse(handler.emissionRegressed(), "cumulative emission never decreases");
        assertFalse(handler.completionReopened(), "completed never reopens");
        (uint16 active, uint16 disabled, uint16 reserve) = controller.getAllocation();
        assertEq(uint256(active) + disabled + reserve, 1000);
        assertLe(controller.fundedBlocks(), uint64(3) * H + 60_000);
    }

    /// @dev Debts round up and the accumulator rounds down, so what every account is owed never exceeds what
    ///      the farm holds for rewards plus what its pool could pull now. Exact, no tolerance.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_rewardsOwedBoundedByReserve() public view {
        uint256 ethOwed;
        uint256 cheeseOwed;
        for (uint256 i; i < players.length; ++i) {
            ethOwed += ethFarm.pendingRewards(players[i]);
            cheeseOwed += cheeseFarm.pendingRewards(players[i]);
        }
        // pendingRewards includes unpulled pool emission; add it to the reserve side.
        uint256 ethPool = controller.previewPoolEmission(1);
        uint256 cheesePool = controller.previewPoolEmission(0);
        assertLe(ethOwed, ethFarm.rewardReserve() + ethPool, "ETH farm rewards owed");
        assertLe(cheeseOwed, cheeseFarm.rewardReserve() + cheesePool, "CHEESE farm rewards owed");
    }
}
