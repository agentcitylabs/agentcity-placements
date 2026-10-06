// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {AgentcityPlacementMarket} from "../src/AgentcityPlacementMarket.sol";
import {Migrate} from "../script/Migrate.s.sol";

contract MigrateTest is Test {
    uint256 constant KEY = 0xA11CE;
    address deployer;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address holder = makeAddr("holder");
    address renter = makeAddr("renter");
    AgentcityPlacements old;
    AgentcityPlacementMarket market;

    function setUp() public {
        deployer = vm.addr(KEY);
        // The old collection, as testnet has it: run by the deployer, held by
        // the treasury, a few tokens with names and ads.
        old = new AgentcityPlacements("Agentcity Placements", "ACPL", deployer, treasury, treasury, 46, 500);
        market = new AgentcityPlacementMarket(deployer, treasury, 250);
        vm.startPrank(deployer);
        market.setCollection(address(old), true);
        old.setPlacement(3, "central-south", "billboard");
        old.setPlacement(18, "banner-data-2", "banner");
        old.setModerator(deployer, true);
        old.setRentalOperator(deployer, true);
        vm.stopPrank();
        vm.startPrank(treasury);
        old.setCreative(3, AgentcityPlacements.Creative("https://cdn/promethee.mp4", "https://x.com/p", "Augment", "A"));
        old.setCreative(18, AgentcityPlacements.Creative("https://cdn/ad.png", "https://x.com/a", "Testnet", "B"));
        old.transferFrom(treasury, holder, 18);
        vm.stopPrank();
        vm.prank(deployer);
        old.flag(5, "spam");
        vm.prank(deployer);
        old.setUser(7, renter, uint64(block.timestamp + 3 days));

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(KEY)));
        vm.setEnv("PLACEMENTS_CONTRACT_ADDRESS", vm.toString(address(old)));
        vm.setEnv("PLACEMENTS_MARKET_ADDRESS", vm.toString(address(market)));
        vm.setEnv("PLACEMENTS_ADMIN", vm.toString(admin));
        vm.setEnv("PLACEMENTS_TREASURY", vm.toString(treasury));
    }

    function test_everyTokenCarriesOver() public {
        AgentcityPlacements next = new Migrate().run();
        assertEq(next.maxSupply(), 46);
        for (uint256 id = 1; id <= 46; ++id) {
            assertEq(next.ownerOf(id), old.ownerOf(id), "holder");
            assertEq(next.placementOf(id).placementId, old.placementOf(id).placementId, "placement");
            assertEq(next.creativeOf(id).mediaURI, old.creativeOf(id).mediaURI, "ad");
            assertEq(next.creativeOf(id).title, old.creativeOf(id).title, "title");
            assertEq(next.flagged(id), old.flagged(id), "flag");
            assertEq(next.userOf(id), old.userOf(id), "renter");
        }
        assertEq(next.ownerOf(18), holder);
        assertEq(next.userExpires(7), old.userExpires(7));
        (address royaltyTo, uint256 royalty) = next.royaltyInfo(1, 10_000);
        assertEq(royaltyTo, treasury);
        assertEq(royalty, 500);

        // The marketplace trades the new collection only, and may grant rentals.
        assertTrue(market.isCollectionAllowed(address(next)));
        assertFalse(market.isCollectionAllowed(address(old)));
        assertTrue(next.isRentalOperator(address(market)));
        assertFalse(next.isRentalOperator(deployer), "the deployer's temporary roles are gone");
        assertFalse(next.isModerator(deployer));
        assertTrue(next.isModerator(admin));
        assertEq(next.pendingOwner(), admin);
    }
}
