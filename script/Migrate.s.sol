// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {AgentcityPlacementMarket} from "../src/AgentcityPlacementMarket.sol";
import {Deployer} from "./Deploy.s.sol";

/// @notice Moves a city's placements to a new collection, for a contract
/// upgrade (this one: ERC-4906 metadata refresh). Reads the old collection,
/// deploys the new one with every token minted to the deployer, copies each
/// token's placement name, ad, flag and running rental, hands every token back
/// to its holder, then whitelists the new collection on the same marketplace
/// and retires the old one. Ownership starts its handover to the admin.
///
/// Nothing held by the marketplace moves: offers and bids on the old
/// collection stay withdrawable there. Listings and rent terms are not copied
/// (holders set them again).
///
///   PLACEMENTS_CONTRACT_ADDRESS  the collection being replaced
///   PLACEMENTS_MARKET_ADDRESS    the marketplace (kept)
///   PLACEMENTS_ADMIN, PLACEMENTS_TREASURY
///
///   forge script script/Migrate.s.sol --rpc-url deploy --broadcast --slow
contract Migrate is Deployer {
    struct Token {
        address holder;
        AgentcityPlacements.Placement placement;
        AgentcityPlacements.Creative creative;
        bool flagged;
        address renter;
        uint64 renterUntil;
    }

    function run() external returns (AgentcityPlacements next) {
        AgentcityPlacements old = AgentcityPlacements(vm.envAddress("PLACEMENTS_CONTRACT_ADDRESS"));
        AgentcityPlacementMarket market = AgentcityPlacementMarket(vm.envAddress("PLACEMENTS_MARKET_ADDRESS"));
        address admin = vm.envAddress("PLACEMENTS_ADMIN");
        address treasury = vm.envAddress("PLACEMENTS_TREASURY");

        // 1. Everything worth keeping, read before anything is sent.
        uint256 supply = old.maxSupply();
        (, uint256 royalty) = old.royaltyInfo(1, 10_000);
        Token[] memory tokens = new Token[](supply + 1);
        for (uint256 id = 1; id <= supply; ++id) {
            tokens[id] = Token({
                holder: old.ownerOf(id),
                placement: old.placementOf(id),
                creative: old.creativeOf(id),
                flagged: old.flagged(id),
                renter: old.userOf(id),
                renterUntil: uint64(old.userExpires(id))
            });
        }

        address deployer = _start();
        // 2. The new collection, every token with the deployer for now.
        next = new AgentcityPlacements(old.name(), old.symbol(), deployer, treasury, deployer, supply, uint96(royalty));

        // 3. Names and ads (the deployer holds every token, so it may set them).
        uint256 named;
        uint256 ads;
        for (uint256 id = 1; id <= supply; ++id) {
            Token memory t = tokens[id];
            if (bytes(t.placement.placementId).length != 0) {
                next.setPlacement(id, t.placement.placementId, t.placement.kind);
                ++named;
            }
            if (bytes(t.creative.mediaURI).length != 0 || bytes(t.creative.title).length != 0) {
                next.setCreative(id, t.creative);
                ++ads;
            }
        }
        // Flags and running rentals, through roles the deployer drops again.
        next.setModerator(deployer, true);
        next.setRentalOperator(deployer, true);
        for (uint256 id = 1; id <= supply; ++id) {
            if (tokens[id].flagged) next.flag(id, "carried over from the previous collection");
            if (tokens[id].renter != address(0)) next.setUser(id, tokens[id].renter, tokens[id].renterUntil);
        }
        next.setModerator(deployer, false);
        next.setRentalOperator(deployer, false);

        // 4. Every token back to whoever held it.
        for (uint256 id = 1; id <= supply; ++id) {
            if (tokens[id].holder != deployer) next.transferFrom(deployer, tokens[id].holder, id);
        }

        // 5. The same marketplace trades the new collection, not the old one.
        next.setRentalOperator(address(market), true);
        next.setModerator(admin, true);
        if (market.owner() == deployer) {
            market.setCollection(address(next), true);
            market.setCollection(address(old), false);
        } else {
            console.log("The market's owner must now call setCollection(new, true) and setCollection(old, false).");
        }

        // 6. Ownership to the admin, who calls acceptOwnership().
        next.transferOwnership(admin);
        vm.stopBroadcast();

        console.log("Old collection (retired)", address(old));
        console.log("New collection", address(next));
        console.log("Supply", supply, "named", named);
        console.log("Ads copied", ads);
        console.log("Next: set PLACEMENTS_CONTRACT_ADDRESS in the app's .env to the new collection.");
    }
}
