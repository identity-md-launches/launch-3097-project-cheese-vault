// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CheeseToken} from "../src/CheeseToken.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "../src/farms/CheeseFarmSIMD.sol";

/// @title DeployCheese
/// @notice Deploys the full CHEESE system and runs the post-deploy wiring in one transaction batch. Used by
///         the tests (deploy() is called directly) and as a reviewable Sepolia rehearsal script. The IMD
///         launch deploys the five contracts through the project factory instead; the owner then performs the
///         "After launch" steps listed in the README, which are exactly the calls `wire()` makes here.
///
///         This script never holds keys: run() takes its configuration from the environment and broadcasts
///         only when the operator passes --broadcast with their own signer.
contract DeployCheese is Script {
    /// @notice The verified SqueekCore proxy on Sepolia (chain id 11155111), release core-sepolia-20261103.
    address public constant SEPOLIA_SQUEEK_CORE = 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4;
    /// @notice The verified SqueekMining proxy on Sepolia, used only to cross-check the schedule.
    address public constant SEPOLIA_SQUEEK_MINING = 0x2dCcB11fcC2dEfdd188555e45aCb52231e82e218;

    uint16 public constant CHEESE_POOL_POINTS = 400;
    uint16 public constant ETH_POOL_POINTS = 200;
    uint16 public constant SIMD_POOL_POINTS = 200;
    // Future Pool Reserve = 1000 - 800 = 200 points, unassigned and unminted.

    struct Config {
        address owner;
        address treasury;
        address squeekCore;
        address teamRecipient;
        address treasuryRecipient;
        address liquidityRecipient;
        address simdAsset; // zero = leave unconfigured for the owner to set later
        bool activate; // schedule emission at the next Squeek round
    }

    struct Deployment {
        CheeseEmissionController controller;
        CheeseToken token;
        CheeseFarmERC20 cheeseFarm;
        CheeseFarmETH ethFarm;
        CheeseFarmSIMD simdFarm;
    }

    /// @notice Deploys the five launch contracts in launch order. No wiring; mirrors what the factory does.
    function deployContracts(Config memory cfg, address wiringOwner) public returns (Deployment memory d) {
        // The wiring owner is the account that will call the owner-only setup functions; in the factory
        // launch that is the launch owner itself.
        d.controller = new CheeseEmissionController(wiringOwner, cfg.squeekCore, cfg.treasury);
        d.token =
            new CheeseToken(cfg.teamRecipient, cfg.treasuryRecipient, cfg.liquidityRecipient, address(d.controller));
        d.cheeseFarm = new CheeseFarmERC20(wiringOwner, address(d.controller), address(d.token));
        d.ethFarm = new CheeseFarmETH(wiringOwner, address(d.controller));
        d.simdFarm = new CheeseFarmSIMD(wiringOwner, address(d.controller));
    }

    /// @notice The owner-only post-deploy steps (the README's "After launch" list).
    function wire(Deployment memory d, Config memory cfg) public {
        d.controller.bindToken(address(d.token));
        d.controller.addPool(address(d.cheeseFarm), CHEESE_POOL_POINTS);
        d.controller.addPool(address(d.ethFarm), ETH_POOL_POINTS);
        d.controller.addPool(address(d.simdFarm), SIMD_POOL_POINTS);
        if (cfg.simdAsset != address(0)) d.simdFarm.setAsset(cfg.simdAsset);
        if (cfg.activate) d.controller.activate();
    }

    /// @notice Hands ownership of every contract to the final owner (two-step; the owner must accept).
    function handOver(Deployment memory d, address owner) public {
        d.controller.transferOwnership(owner);
        d.cheeseFarm.transferOwnership(owner);
        d.ethFarm.transferOwnership(owner);
        d.simdFarm.transferOwnership(owner);
    }

    /// @notice Full local deployment from `deployer`: deploy, wire, then offer ownership to cfg.owner.
    function deploy(Config memory cfg, address deployer) public returns (Deployment memory d) {
        d = deployContracts(cfg, deployer);
        wire(d, cfg);
        if (cfg.owner != deployer) handOver(d, cfg.owner);
    }

    /// @notice Sepolia rehearsal entry point. Reads CHEESE_OWNER, CHEESE_TREASURY, CHEESE_TEAM,
    ///         CHEESE_TREASURY_PREMINT, CHEESE_LIQUIDITY, optional CHEESE_SIMD and CHEESE_ACTIVATE.
    function run() external {
        Config memory cfg = Config({
            owner: vm.envAddress("CHEESE_OWNER"),
            treasury: vm.envAddress("CHEESE_TREASURY"),
            squeekCore: vm.envOr("CHEESE_SQUEEK_CORE", SEPOLIA_SQUEEK_CORE),
            teamRecipient: vm.envAddress("CHEESE_TEAM"),
            treasuryRecipient: vm.envAddress("CHEESE_TREASURY_PREMINT"),
            liquidityRecipient: vm.envAddress("CHEESE_LIQUIDITY"),
            simdAsset: vm.envOr("CHEESE_SIMD", address(0)),
            activate: vm.envOr("CHEESE_ACTIVATE", false)
        });
        require(block.chainid == 11155111, "Sepolia only");
        address deployer = vm.envAddress("CHEESE_DEPLOYER");
        vm.startBroadcast(deployer);
        Deployment memory d = deploy(cfg, deployer);
        vm.stopBroadcast();
        console2.log("CheeseEmissionController", address(d.controller));
        console2.log("CheeseToken", address(d.token));
        console2.log("CheeseFarmERC20 (CHEESE pool)", address(d.cheeseFarm));
        console2.log("CheeseFarmETH", address(d.ethFarm));
        console2.log("CheeseFarmSIMD", address(d.simdFarm));
    }
}
