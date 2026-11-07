// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployCheese} from "../script/Deploy.s.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @notice The deploy script's functions, called directly: launch-order deployment, wiring, hand-over, and
///         constructors that touch no other contract (the launch rehearses them on an empty chain).
contract DeployTest is Test {
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");

    function _cfg(address core) internal view returns (DeployCheese.Config memory cfg) {
        cfg = DeployCheese.Config({
            owner: owner,
            treasury: treasury,
            squeekCore: core,
            teamRecipient: owner,
            treasuryRecipient: owner,
            liquidityRecipient: owner,
            simdAsset: address(0),
            activate: false
        });
    }

    function test_constructorsNeedNoLiveContracts() public {
        // SqueekCore is a bare address with no code here; constructors must still succeed.
        DeployCheese d = new DeployCheese();
        DeployCheese.Deployment memory dep = d.deployContracts(_cfg(address(0xC0DE)), owner);
        assertEq(dep.token.emissionAuthority(), address(dep.controller));
        assertEq(address(dep.controller.squeekCore()), address(0xC0DE));
        assertEq(dep.controller.owner(), owner);
        assertEq(dep.cheeseFarm.owner(), owner);
        assertEq(dep.ethFarm.owner(), owner);
        assertEq(dep.simdFarm.owner(), owner);
        assertEq(address(dep.cheeseFarm.asset()), address(dep.token));
        assertFalse(dep.cheeseFarm.registered());
        assertEq(dep.controller.treasury(), treasury);
    }

    function test_wireAndHandOver() public {
        MockSqueekCore core = new MockSqueekCore(1_793_735_400);
        vm.warp(1_793_735_400 + 6_000);
        DeployCheese d = new DeployCheese();
        DeployCheese.Config memory cfg = _cfg(address(core));
        cfg.activate = true;
        DeployCheese.Deployment memory dep = d.deploy(cfg, address(d));
        assertEq(dep.controller.poolCount(), 3);
        assertEq(address(dep.controller.cheese()), address(dep.token));
        assertTrue(dep.controller.activated());
        assertEq(dep.cheeseFarm.poolId(), 0);
        assertEq(dep.ethFarm.poolId(), 1);
        assertEq(dep.simdFarm.poolId(), 2);
        (uint16 active,, uint16 reserve) = dep.controller.getAllocation();
        assertEq(active, 800);
        assertEq(reserve, 200);
        // two-step hand-over: pending until the owner accepts
        assertEq(dep.controller.owner(), address(d));
        assertEq(dep.controller.pendingOwner(), owner);
        vm.startPrank(owner);
        dep.controller.acceptOwnership();
        dep.cheeseFarm.acceptOwnership();
        dep.ethFarm.acceptOwnership();
        dep.simdFarm.acceptOwnership();
        vm.stopPrank();
        assertEq(dep.controller.owner(), owner);
        assertEq(dep.simdFarm.owner(), owner);
        // the deployer keeps no role: the guardian moved with ownership
        assertEq(dep.controller.guardian(), owner);
        vm.prank(address(d));
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.NotGuardianOrOwner.selector, address(d)));
        dep.controller.pauseEmissions();
    }
}
