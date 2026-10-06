// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {AgentcityPlacementMarket} from "../src/AgentcityPlacementMarket.sol";
import {Deployer} from "./Deploy.s.sol";

/// @notice Finishes a Migrate run that stopped part way (a transaction can
/// fail on an Arbitrum chain when its L1 gas was underestimated). Every step
/// checks the chain first, so this is safe to run again until it reports
/// nothing left to do. Run with a generous --gas-estimate-multiplier.
///
///   PLACEMENTS_CONTRACT_ADDRESS  the old collection
///   PLACEMENTS_NEW_ADDRESS       the new collection Migrate deployed
///   PLACEMENTS_MARKET_ADDRESS, PLACEMENTS_ADMIN
contract MigrateFinish is Deployer {
    function run() external {
        AgentcityPlacements old = AgentcityPlacements(vm.envAddress("PLACEMENTS_CONTRACT_ADDRESS"));
        AgentcityPlacements next = AgentcityPlacements(vm.envAddress("PLACEMENTS_NEW_ADDRESS"));
        AgentcityPlacementMarket market = AgentcityPlacementMarket(vm.envAddress("PLACEMENTS_MARKET_ADDRESS"));
        address admin = vm.envAddress("PLACEMENTS_ADMIN");
        uint256 supply = next.maxSupply();

        address deployer = _start();
        uint256 steps;
        // The deployer's temporary roles.
        if (next.isModerator(deployer)) {
            next.setModerator(deployer, false);
            ++steps;
        }
        if (next.isRentalOperator(deployer)) {
            next.setRentalOperator(deployer, false);
            ++steps;
        }
        // Every token back to its holder in the old collection.
        for (uint256 id = 1; id <= supply; ++id) {
            address holder = old.ownerOf(id);
            if (next.ownerOf(id) == deployer && holder != deployer) {
                next.transferFrom(deployer, holder, id);
                ++steps;
            }
        }
        // The marketplace's roles and whitelist.
        if (!next.isRentalOperator(address(market))) {
            next.setRentalOperator(address(market), true);
            ++steps;
        }
        if (!next.isModerator(admin)) {
            next.setModerator(admin, true);
            ++steps;
        }
        if (market.owner() == deployer) {
            if (!market.isCollectionAllowed(address(next))) {
                market.setCollection(address(next), true);
                ++steps;
            }
            if (market.isCollectionAllowed(address(old))) {
                market.setCollection(address(old), false);
                ++steps;
            }
        }
        // Ownership to the admin.
        if (next.owner() == deployer && next.pendingOwner() != admin) {
            next.transferOwnership(admin);
            ++steps;
        }
        vm.stopBroadcast();
        console.log("Steps sent", steps);
    }
}
