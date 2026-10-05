// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {IERC4907} from "../src/IERC4907.sol";

contract AgentcityPlacementsTest is Test {
    AgentcityPlacements nft;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address holder = makeAddr("holder");
    address renter = makeAddr("renter");
    address operator = makeAddr("operator");
    address moderator = makeAddr("moderator");

    function setUp() public {
        nft = new AgentcityPlacements("Agentcity Placements", "ACPL", admin, treasury, 46, 500);
        vm.startPrank(admin);
        nft.setRentalOperator(operator, true);
        nft.setModerator(moderator, true);
        vm.stopPrank();
    }

    function creative(string memory media, string memory title)
        internal
        pure
        returns (AgentcityPlacements.Creative memory)
    {
        return AgentcityPlacements.Creative(media, "https://example.com", title, "An ad.");
    }

    function test_supplyIsSetAtDeployAndAllMintedToTreasury() public view {
        assertEq(nft.maxSupply(), 46);
        assertEq(nft.totalSupply(), 46);
        assertEq(nft.balanceOf(treasury), 46);
        assertEq(nft.ownerOf(1), treasury);
        assertEq(nft.ownerOf(46), treasury);
    }

    function test_noTokenBeyondSupply() public {
        vm.expectRevert();
        nft.ownerOf(47);
    }

    function test_supplyCanDifferPerCity() public {
        AgentcityPlacements other = new AgentcityPlacements("Coast", "ACC", admin, treasury, 12, 0);
        assertEq(other.balanceOf(treasury), 12);
    }

    function test_zeroSupplyIsRefused() public {
        vm.expectRevert(AgentcityPlacements.ZeroSupply.selector);
        new AgentcityPlacements("x", "x", admin, treasury, 0, 0);
    }

    function test_placementIsSetOnceByAdmin() public {
        vm.prank(admin);
        nft.setPlacement(5, "banner-programming-1", "banner");
        assertEq(nft.placementOf(5).placementId, "banner-programming-1");
        assertEq(nft.placementOf(5).kind, "banner");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AgentcityPlacements.PlacementAlreadySet.selector, 5));
        nft.setPlacement(5, "something-else", "banner");

        vm.prank(holder);
        vm.expectRevert();
        nft.setPlacement(6, "x", "banner");
    }

    function test_holderEditsCreative_othersCannot() public {
        vm.prank(treasury);
        nft.setCreative(1, creative("https://cdn/ad.png", "Launch"));
        assertEq(nft.creativeOf(1).mediaURI, "https://cdn/ad.png");
        assertEq(nft.creativeUpdatedBy(1), treasury);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(AgentcityPlacements.NotAllowedToEdit.selector, 1));
        nft.setCreative(1, creative("x", "y"));
    }

    function test_renterEditsWhileRented_holderAgainAfter() public {
        vm.prank(operator);
        nft.setUser(2, renter, uint64(block.timestamp + 3 days));
        assertEq(nft.userOf(2), renter);

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(AgentcityPlacements.NotAllowedToEdit.selector, 2));
        nft.setCreative(2, creative("owner.png", "Owner"));

        vm.prank(renter);
        nft.setCreative(2, creative("renter.png", "Renter"));

        vm.warp(block.timestamp + 3 days + 1);
        assertEq(nft.userOf(2), address(0));
        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(AgentcityPlacements.NotAllowedToEdit.selector, 2));
        nft.setCreative(2, creative("late.png", "Late"));
        vm.prank(treasury);
        nft.setCreative(2, creative("owner.png", "Owner"));
    }

    function test_onlyOperatorGrantsRentals_andNeverOverARunningOne() public {
        vm.prank(treasury);
        vm.expectRevert(AgentcityPlacements.NotRentalOperator.selector);
        nft.setUser(3, renter, uint64(block.timestamp + 1 days));

        vm.prank(operator);
        nft.setUser(3, renter, uint64(block.timestamp + 1 days));
        vm.prank(operator);
        vm.expectRevert();
        nft.setUser(3, holder, uint64(block.timestamp + 2 days));
    }

    function test_rentalSurvivesTransfer() public {
        vm.prank(operator);
        nft.setUser(4, renter, uint64(block.timestamp + 1 days));
        vm.prank(treasury);
        nft.transferFrom(treasury, holder, 4);
        assertEq(nft.ownerOf(4), holder);
        assertEq(nft.userOf(4), renter);
    }

    function test_moderatorFlags_newCreativeClearsIt() public {
        vm.prank(treasury);
        nft.setCreative(1, creative("bad.png", "Bad"));
        vm.prank(holder);
        vm.expectRevert(AgentcityPlacements.NotModerator.selector);
        nft.flag(1, "spam");

        vm.prank(moderator);
        nft.flag(1, "spam");
        assertTrue(nft.flagged(1));
        vm.prank(treasury);
        nft.setCreative(1, creative("good.png", "Good"));
        assertFalse(nft.flagged(1));
    }

    function test_tokenURIIsValidJsonEvenWithQuotes() public {
        vm.prank(admin);
        nft.setPlacement(1, "central-north", "billboard");
        vm.prank(treasury);
        nft.setCreative(1, creative("https://cdn/a.webm", 'Say "hi" \\ there'));
        string memory uri = nft.tokenURI(1);
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory u = bytes(uri);
        bytes memory b64 = new bytes(u.length - prefix.length);
        for (uint256 i; i < b64.length; ++i) {
            b64[i] = u[i + prefix.length];
        }
        string memory json = string(_decode(string(b64)));
        // vm.parseJson reverts on invalid JSON.
        assertEq(vm.parseJsonString(json, ".name"), 'Say "hi" \\ there');
        assertEq(vm.parseJsonString(json, ".image"), "https://cdn/a.webm");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "central-north");
    }

    function test_royaltyAndInterfaces() public view {
        (address to, uint256 amount) = nft.royaltyInfo(1, 10_000);
        assertEq(to, treasury);
        assertEq(amount, 500);
        assertTrue(nft.supportsInterface(type(IERC4907).interfaceId));
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC-2981
    }

    function test_royaltyIsCapped() public {
        vm.prank(admin);
        vm.expectRevert(AgentcityPlacements.RoyaltyTooHigh.selector);
        nft.setDefaultRoyalty(treasury, 1_001);
    }

    /// Minimal base64 decoder for the test.
    function _decode(string memory data) internal pure returns (bytes memory) {
        bytes memory table = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        bytes memory input = bytes(data);
        uint8[256] memory lookup;
        for (uint8 i; i < 64; ++i) {
            lookup[uint8(table[i])] = i;
        }
        uint256 pad = input[input.length - 1] == "=" ? (input[input.length - 2] == "=" ? 2 : 1) : 0;
        bytes memory out = new bytes((input.length / 4) * 3 - pad);
        uint256 j;
        for (uint256 i; i < input.length; i += 4) {
            uint256 n = (uint256(lookup[uint8(input[i])]) << 18) | (uint256(lookup[uint8(input[i + 1])]) << 12)
                | (uint256(lookup[uint8(input[i + 2])]) << 6) | uint256(lookup[uint8(input[i + 3])]);
            if (j < out.length) out[j++] = bytes1(uint8(n >> 16));
            if (j < out.length) out[j++] = bytes1(uint8(n >> 8));
            if (j < out.length) out[j++] = bytes1(uint8(n));
        }
        return out;
    }
}
