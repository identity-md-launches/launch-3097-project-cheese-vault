// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployCheese} from "../script/Deploy.s.sol";
import {CheeseToken} from "../src/CheeseToken.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {CheeseFarm} from "../src/CheeseFarm.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "../src/farms/CheeseFarmSIMD.sol";
import {SqueekIssuance} from "../src/libraries/SqueekIssuance.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Shared fixture: the full system deployed through the deploy script against a SqueekCore double.
abstract contract CheeseBase is Test {
    uint64 internal constant GENESIS = 1_793_735_400; // the live Sepolia genesis
    uint256 internal constant A = SqueekIssuance.ALLOWANCE;
    uint256 internal constant G = SqueekIssuance.LAUNCH_BONUS;
    uint64 internal constant N = SqueekIssuance.BONUS_BLOCKS;
    uint64 internal constant H = SqueekIssuance.HALVING_BLOCKS;
    uint256 internal constant R0 = SqueekIssuance.FIRST_PERIOD_RATE;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal team = makeAddr("team");
    address internal liquidity = makeAddr("liquidity");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    DeployCheese internal deployer;
    MockSqueekCore internal core;
    MockERC20 internal simd;
    CheeseEmissionController internal controller;
    CheeseToken internal cheese;
    CheeseFarmERC20 internal cheeseFarm;
    CheeseFarmETH internal ethFarm;
    CheeseFarmSIMD internal simdFarm;

    function setUp() public virtual {
        vm.warp(GENESIS + 100 * 600 + 17); // somewhere in round 101
        core = new MockSqueekCore(GENESIS);
        simd = new MockERC20("Staked IMD", "sIMD");
        deployer = new DeployCheese();
        DeployCheese.Config memory cfg = DeployCheese.Config({
            owner: owner,
            treasury: treasury,
            squeekCore: address(core),
            teamRecipient: team,
            treasuryRecipient: treasury,
            liquidityRecipient: liquidity,
            simdAsset: address(simd),
            activate: false
        });
        // The script contract deploys and wires as itself, then offers ownership to `owner`.
        DeployCheese.Deployment memory d = deployer.deploy(cfg, address(deployer));
        controller = d.controller;
        cheese = d.token;
        cheeseFarm = d.cheeseFarm;
        ethFarm = d.ethFarm;
        simdFarm = d.simdFarm;
        // The script deploys from its own address, so ownership was offered to `owner`; accept it.
        vm.startPrank(owner);
        controller.acceptOwnership();
        cheeseFarm.acceptOwnership();
        ethFarm.acceptOwnership();
        simdFarm.acceptOwnership();
        vm.stopPrank();

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    // ---- helpers ----

    /// @dev Activates emission and certifies rounds through startRound - 1 with `preBlocks` already complete,
    ///      so h0 == preBlocks. Emission begins with the next certified block.
    function activateWithHistory(uint64 preBlocks) internal {
        vm.prank(owner);
        controller.activate();
        uint64 start = controller.startRound();
        core.settle(start - 1, preBlocks, 0);
        controller.checkpoint();
        assertTrue(controller.startCaptured(), "h0 captured");
        assertEq(controller.startHeight(), preBlocks, "h0");
    }

    /// @dev Certifies one more round completing `blocks` Squeek blocks.
    function advanceBlocks(uint64 blocks) internal {
        core.settle(core.settledThroughRound() + 1, blocks, 0);
    }

    function issued(uint64 b) internal pure returns (uint256) {
        return SqueekIssuance.issued(b);
    }

    /// @dev Reference emission for the schedule between two heights after h0, using plain arithmetic.
    function referenceIssued(uint256 b) internal pure returns (uint256 total) {
        uint256 first = b < H ? b : H;
        uint256 second = b > H ? (b - H < H ? b - H : H) : 0;
        uint256 third = b > 2 * H ? (b - 2 * H < H ? b - 2 * H : H) : 0;
        total = R0 * first + (R0 / 2) * second + (R0 / 4) * third;
        total += (G * (b < N ? b : N)) / N;
    }

    /// @dev Withdraws all of `who`'s shares (reads the balance before pranking).
    function withdrawAll(CheeseFarm farm, address who) internal returns (uint256 paid) {
        uint256 shares = farm.sharesOf(who);
        vm.prank(who);
        paid = farm.withdraw(shares);
    }

    function giveCheese(address to, uint256 amount) internal {
        // the team premint funds test deposits of CHEESE
        vm.prank(team);
        cheese.transfer(to, amount);
    }

    function depositCheese(address who, uint256 amount) internal returns (uint256 shares) {
        giveCheese(who, amount);
        vm.startPrank(who);
        cheese.approve(address(cheeseFarm), amount);
        shares = cheeseFarm.deposit(amount);
        vm.stopPrank();
    }

    function depositEth(address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        shares = ethFarm.deposit{value: amount}();
    }

    function depositSimd(address who, uint256 amount) internal returns (uint256 shares) {
        simd.mint(who, amount);
        vm.startPrank(who);
        simd.approve(address(simdFarm), amount);
        shares = simdFarm.deposit(amount);
        vm.stopPrank();
    }
}
