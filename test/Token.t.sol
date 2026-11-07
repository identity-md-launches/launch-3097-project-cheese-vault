// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {CheeseToken} from "../src/CheeseToken.sol";

/// @notice CHEESE token: metadata, premint mirror, immutable minter, cap on minted total, burns.
contract TokenTest is CheeseBase {
    function test_metadataAndPremint() public view {
        assertEq(cheese.name(), "CHEESE");
        assertEq(cheese.symbol(), "CHEESE");
        assertEq(cheese.decimals(), 18);
        assertEq(cheese.MAX_SUPPLY(), 2_100_000_000e18);
        assertEq(cheese.totalSupply(), 210_000_000e18);
        assertEq(cheese.totalMinted(), 210_000_000e18);
        assertEq(cheese.totalPreminted(), 210_000_000e18);
        assertEq(cheese.balanceOf(team), 63_000_000e18);
        assertEq(cheese.balanceOf(treasury), 63_000_000e18);
        assertEq(cheese.balanceOf(liquidity), 84_000_000e18);
        assertEq(cheese.MINING_ALLOWANCE(), 1_890_000_000e18);
        assertEq(cheese.emissionAuthority(), address(controller));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(CheeseToken.ZeroAddress.selector);
        new CheeseToken(address(0), treasury, liquidity, address(controller));
        vm.expectRevert(CheeseToken.ZeroAddress.selector);
        new CheeseToken(team, treasury, liquidity, address(0));
    }

    function test_onlyEmissionAuthorityMints() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseToken.UnauthorizedMinter.selector, owner));
        cheese.mintEmission(owner, 1);
        vm.prank(address(controller));
        cheese.mintEmission(alice, 5e18);
        assertEq(cheese.balanceOf(alice), 5e18);
        assertEq(cheese.totalMinted(), 210_000_000e18 + 5e18);
        vm.prank(address(controller));
        vm.expectRevert(CheeseToken.ZeroAddress.selector);
        cheese.mintEmission(address(0), 1);
    }

    function test_capBoundsMintedTotalNotSupply() public {
        uint256 remaining = cheese.MAX_SUPPLY() - cheese.totalMinted();
        vm.prank(address(controller));
        vm.expectRevert(abi.encodeWithSelector(CheeseToken.ExceedsMaxSupply.selector, remaining + 1, remaining));
        cheese.mintEmission(alice, remaining + 1);
        vm.prank(address(controller));
        cheese.mintEmission(alice, remaining);
        assertEq(cheese.totalMinted(), cheese.MAX_SUPPLY());
        vm.prank(alice);
        cheese.burn(1_000e18);
        assertEq(cheese.totalBurned(), 1_000e18);
        assertEq(cheese.totalSupply(), cheese.MAX_SUPPLY() - 1_000e18);
        vm.prank(address(controller));
        vm.expectRevert(abi.encodeWithSelector(CheeseToken.ExceedsMaxSupply.selector, 1, 0));
        cheese.mintEmission(alice, 1);
    }

    function testFuzz_mintNeverExceedsCap(uint256 a, uint256 b) public {
        a = bound(a, 0, cheese.MINING_ALLOWANCE());
        b = bound(b, 0, cheese.MINING_ALLOWANCE());
        vm.startPrank(address(controller));
        cheese.mintEmission(alice, a);
        if (a + b > cheese.MINING_ALLOWANCE()) {
            vm.expectRevert();
            cheese.mintEmission(alice, b);
        } else {
            cheese.mintEmission(alice, b);
        }
        vm.stopPrank();
        assertLe(cheese.totalMinted(), cheese.MAX_SUPPLY());
    }
}
