// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {AgentcityPlacementMarket} from "../src/AgentcityPlacementMarket.sol";
import {Deployer} from "./Deploy.s.sol";

/// @notice Deploys a new marketplace for a collection that already exists,
/// for a market upgrade (this one: auction winners claim their token, so a
/// winner that cannot receive it no longer blocks `settle`). Whitelists the
/// collection and the currencies, then starts the handover to the admin.
///
/// The old marketplace is left alone: its listings, offers, auctions and
/// rent terms are not copied (holders set them again on the new market) and
/// everything it holds stays withdrawable there.
///
///   PLACEMENTS_CONTRACT_ADDRESS  the collection to trade (required)
///   PLACEMENTS_ADMIN             admin wallet that will own the market (required)
///   PLACEMENTS_TREASURY          receives the protocol fee (required)
///   MARKET_FEE_BPS               protocol fee, max 500 (default 250)
///   USDG_ADDRESS                 enable USDG payments (optional)
///   TOKEN_CURRENCIES             more ERC-20s to accept, comma-separated (optional)
///
///   forge script script/DeployMarket.s.sol --rpc-url deploy --broadcast --slow
///   (add --account deployer when DEPLOYER_PRIVATE_KEY is empty)
contract DeployMarket is Deployer {
    function run() external returns (AgentcityPlacementMarket market) {
        AgentcityPlacements nft = AgentcityPlacements(vm.envAddress("PLACEMENTS_CONTRACT_ADDRESS"));
        address admin = vm.envAddress("PLACEMENTS_ADMIN");
        address treasury = vm.envAddress("PLACEMENTS_TREASURY");
        uint16 feeBps = uint16(vm.envOr("MARKET_FEE_BPS", uint256(250)));
        address usdg = vm.envOr("USDG_ADDRESS", address(0));
        address[] memory tokenCurrencies = vm.envOr("TOKEN_CURRENCIES", ",", new address[](0));

        address deployer = _start();
        market = new AgentcityPlacementMarket(deployer, treasury, feeBps);
        market.setCollection(address(nft), true);
        if (usdg != address(0)) market.setCurrency(usdg, true);
        for (uint256 i; i < tokenCurrencies.length; ++i) {
            market.setCurrency(tokenCurrencies[i], true);
        }
        // Rentals need the collection's owner to approve the new market.
        bool operatorSet = nft.owner() == deployer;
        if (operatorSet) nft.setRentalOperator(address(market), true);
        market.transferOwnership(admin);
        vm.stopBroadcast();

        console.log("AgentcityPlacementMarket", address(market));
        console.log("Next: the admin calls acceptOwnership() on the new market.");
        if (!operatorSet) {
            console.log("Next: the collection owner calls setRentalOperator(<new market>, true).");
            console.log("  collection owner", nft.owner());
        }
        console.log("Then, on the old market: pause() to stop new trades (settle, cancel and");
        console.log("withdraw keep working), and setRentalOperator(<old market>, false) on the collection.");
    }
}
