// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {CheeseToken} from "../src/CheeseToken.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Random sequences of deposits, withdrawals, claims, checkpoints and allocation changes.
contract CheeseHandler is Test {
    CheeseEmissionController public controller;
    CheeseFarmETH public farm;
    CheeseToken public cheese;
    MockSqueekCore public core;
    address public owner;
    address public treasury;

    address[] public actors;
    uint256 public ethIn;
    uint256 public ethOutUsers;
    uint256 public ethOutTreasury;
    uint256 public cheeseClaimed;

    constructor(
        CheeseEmissionController controller_,
        CheeseFarmETH farm_,
        CheeseToken cheese_,
        MockSqueekCore core_,
        address owner_,
        address treasury_
    ) {
        controller = controller_;
        farm = farm_;
        cheese = cheese_;
        core = core_;
        owner = owner_;
        treasury = treasury_;
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xA11CE + i));
            actors.push(a);
            vm.deal(a, 10_000 ether);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint96 amount) external {
        address who = _actor(seed);
        uint256 amt = bound(amount, 1, 100 ether);
        if (who.balance < amt) return;
        vm.prank(who);
        try farm.deposit{value: amt}() {
            ethIn += amt;
        } catch {}
    }

    function withdraw(uint256 seed, uint96 fraction) external {
        address who = _actor(seed);
        uint256 shares = (farm.sharesOf(who) * bound(fraction, 1, 10_000)) / 10_000;
        if (shares == 0) return;
        uint256 tBefore = treasury.balance;
        vm.prank(who);
        uint256 paid = farm.withdraw(shares);
        ethOutUsers += paid;
        ethOutTreasury += treasury.balance - tBefore;
    }

    function claim(uint256 seed) external {
        address who = _actor(seed);
        vm.prank(who);
        cheeseClaimed += farm.claim(who);
    }

    function advance(uint16 blocks) external {
        core.settle(core.settledThroughRound() + 1, uint64(bound(blocks, 0, 5_000)), 0);
    }

    function checkpoint() external {
        controller.checkpoint();
    }

    function setWeight(uint16 weight) external {
        vm.prank(owner);
        try controller.setPoolWeight(1, uint16(bound(weight, 0, 400))) {} catch {}
    }

    function toggle(bool enable) external {
        vm.prank(owner);
        if (enable) {
            try controller.enablePool(1) {} catch {}
        } else {
            try controller.disablePool(1) {} catch {}
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract InvariantTest is CheeseBase {
    CheeseHandler internal handler;

    function setUp() public override {
        super.setUp();
        activateWithHistory(0);
        handler = new CheeseHandler(controller, ethFarm, cheese, core, owner, treasury);
        targetContract(address(handler));
    }

    function invariant_farmBalanceCoversPrincipal() public view {
        assertEq(address(ethFarm).balance, ethFarm.totalAssets());
        assertEq(cheese.balanceOf(address(ethFarm)), ethFarm.rewardReserve());
    }

    function invariant_ethConservation() public view {
        assertEq(handler.ethIn(), ethFarm.totalAssets() + handler.ethOutUsers() + handler.ethOutTreasury());
    }

    function invariant_sharesSumAndBacking() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += ethFarm.sharesOf(handler.actors(i));
        }
        assertEq(sum, ethFarm.totalShares());
        assertLe(ethFarm.convertToAssets(ethFarm.totalShares()), ethFarm.totalAssets());
    }

    function invariant_supplyAccounting() public view {
        assertLe(cheese.totalMinted(), cheese.MAX_SUPPLY());
        assertEq(cheese.totalMinted(), cheese.PREMINT() + controller.totalMinted());
        assertLe(controller.cumulativeEmission(), controller.MINING_ALLOWANCE());
        assertEq(controller.cumulativeEmission(), issued(controller.fundedBlocks()));
        // minted + forfeited + reserve + still-pending <= scheduled emission
        uint256 pending;
        for (uint256 p; p < controller.poolCount(); ++p) {
            (,,, uint256 pe,) = controller.getPoolAllocation(p);
            pending += pe;
        }
        assertLe(
            controller.totalMinted() + controller.forfeitedEmission() + controller.reserveUnminted() + pending,
            controller.cumulativeEmission()
        );
    }

    function invariant_weightsWithinTotal() public view {
        (uint16 active, uint16 disabled, uint16 reserve) = controller.getAllocation();
        assertEq(uint256(active) + disabled + reserve, 1000);
    }
}
