// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestnetToken} from "../src/testnet/TestnetToken.sol";

contract TestnetTokenTest is Test {
    TestnetToken usdg;
    address owner = makeAddr("owner");
    address tester = makeAddr("tester");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdg = new TestnetToken("Mock USDG", "USDG", 6, 1_000e6, owner);
    }

    function test_faucetOncePerHour() public {
        assertEq(usdg.decimals(), 6);
        vm.prank(tester);
        usdg.faucet();
        assertEq(usdg.balanceOf(tester), 1_000e6);
        vm.prank(tester);
        vm.expectRevert();
        usdg.faucet();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(tester);
        usdg.faucet();
        assertEq(usdg.balanceOf(tester), 2_000e6);
    }

    function test_onlyOwnerMints() public {
        vm.prank(tester);
        vm.expectRevert();
        usdg.mint(tester, 1);
        vm.prank(owner);
        usdg.mint(tester, 5e6);
        assertEq(usdg.balanceOf(tester), 5e6);
    }
}
