// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";
import {ISqueekMining} from "../src/interfaces/ISqueekMining.sol";
import {SqueekIssuance} from "../src/libraries/SqueekIssuance.sol";

/// @title VerifySqueekchain
/// @notice Read-only Sepolia integration check. Run with
///           forge script script/VerifySqueekchain.s.sol --rpc-url $SEPOLIA_RPC
///         It never broadcasts. It proves, against the live proxies, that CHEESE's compiled-in schedule is
///         SQK's: the cap, allowance, bonus, halving length, first-period rate, issued() at the halving
///         boundaries, and that SqueekMining's minted total equals issued(fundedBlocks). It also checks the
///         proxy implementation slots and runtime hashes published in sepolia.json.
contract VerifySqueekchain is Script {
    address public constant CORE = 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4;
    address public constant MINING = 0x2dCcB11fcC2dEfdd188555e45aCb52231e82e218;
    address public constant CORE_IMPL = 0x6869D6102696243Fd17013ab955d99CD0c522ad3;
    address public constant MINING_IMPL = 0x32639fc0bBd16BA0b140F78950751591609cFaa4;
    bytes32 public constant CORE_IMPL_HASH = 0x65b5780a4fccafedeca1260806364d2bb512b4501c097253f792ae2839565a9c;
    bytes32 public constant MINING_IMPL_HASH = 0xbcc7179f61610f44cf19a8fe4ffe27c06cba083a9430eb2787c5807b30e1e959;
    bytes32 public constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        require(block.chainid == 11155111, "run against Sepolia");

        // Proxy identities
        address coreImpl = address(uint160(uint256(vm.load(CORE, EIP1967_IMPL_SLOT))));
        address miningImpl = address(uint160(uint256(vm.load(MINING, EIP1967_IMPL_SLOT))));
        require(coreImpl == CORE_IMPL, "SqueekCore implementation changed");
        require(miningImpl == MINING_IMPL, "SqueekMining implementation changed");
        require(keccak256(CORE_IMPL.code) == CORE_IMPL_HASH, "SqueekCore runtime hash changed");
        require(keccak256(MINING_IMPL.code) == MINING_IMPL_HASH, "SqueekMining runtime hash changed");

        // Clock constants the controller verifies at activation
        ISqueekCore.CoreConfiguration memory config = ISqueekCore(CORE).configuration();
        require(config.roundDuration == 600, "round duration");
        require(config.blockUnitsPerBlock == 1_000_000_000, "block units");

        // Schedule
        ISqueekMining mining = ISqueekMining(MINING);
        require(mining.core() == CORE, "mining.core");
        require(mining.SUPPLY_CAP() == SqueekIssuance.SUPPLY_CAP, "cap");
        ISqueekMining.MiningIssuanceSchedule memory s = mining.issuanceSchedule();
        require(s.allowance == SqueekIssuance.ALLOWANCE, "allowance");
        require(s.launchBonus == SqueekIssuance.LAUNCH_BONUS, "launch bonus");
        require(s.bonusBlocks == SqueekIssuance.BONUS_BLOCKS, "bonus blocks");
        require(s.halvingBlocks == SqueekIssuance.HALVING_BLOCKS, "halving blocks");
        require(s.firstPeriodRate == SqueekIssuance.FIRST_PERIOD_RATE, "first period rate");

        uint64[8] memory probes = [uint64(1), 97_020, 97_021, 393_470, 393_471, 786_940, 786_941, 1_180_410];
        for (uint256 i; i < probes.length; ++i) {
            require(mining.issued(probes[i]) == SqueekIssuance.issued(probes[i]), "issued() mismatch");
        }

        // Live minting behaviour: minted equals the schedule at the funded block count.
        ISqueekMining.MiningState memory st = mining.state();
        uint256 scheduled = SqueekIssuance.issued(st.fundedBlocks);
        require(st.minted == (scheduled < s.allowance ? scheduled : s.allowance), "minted != issued(fundedBlocks)");

        ISqueekCore.CoreState memory cs = ISqueekCore(CORE).state();
        console2.log("SqueekCore settledThroughRound", cs.settledThroughRound);
        console2.log("SqueekCore blockHeight", cs.blockHeight);
        console2.log("SqueekMining startRound", st.startRound);
        console2.log("SqueekMining fundedBlocks", st.fundedBlocks);
        console2.log("SqueekMining minted", st.minted);
        console2.log("CHEESE schedule matches SQK: OK");
    }
}
