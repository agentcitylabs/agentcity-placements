// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {AgentcityPlacementMarket} from "../src/AgentcityPlacementMarket.sol";

/// @notice Lists a range of placements for sale at one price. Must be signed
/// by the wallet that holds them (the treasury after deploy), with
/// LISTER_PRIVATE_KEY in .env or --account.
///
///   PLACEMENTS_CONTRACT_ADDRESS, PLACEMENTS_MARKET_ADDRESS (required)
///   LIST_FROM=5  LIST_TO=46       token ids, inclusive
///   LIST_PRICE_WEI=1000000000000000   0.001 ETH
///   LIST_CURRENCY=0x0…0           ETH by default
///   LIST_DAYS=365                 how long the listings stay open
///
///   forge script script/ListPlacements.s.sol --rpc-url deploy --broadcast --slow
contract ListPlacements is Script {
    function run() external {
        AgentcityPlacements nft = AgentcityPlacements(vm.envAddress("PLACEMENTS_CONTRACT_ADDRESS"));
        AgentcityPlacementMarket market = AgentcityPlacementMarket(vm.envAddress("PLACEMENTS_MARKET_ADDRESS"));
        uint256 from = vm.envOr("LIST_FROM", uint256(5));
        uint256 to = vm.envOr("LIST_TO", uint256(46));
        uint256 price = vm.envOr("LIST_PRICE_WEI", uint256(0.001 ether));
        address currency = vm.envOr("LIST_CURRENCY", address(0));
        uint64 expiry = uint64(block.timestamp + vm.envOr("LIST_DAYS", uint256(365)) * 1 days);

        string memory raw = vm.envOr("LISTER_PRIVATE_KEY", string(""));
        if (bytes(raw).length != 0) {
            bytes memory b = bytes(raw);
            bool prefixed = b.length > 1 && b[0] == "0" && (b[1] == "x" || b[1] == "X");
            vm.startBroadcast(vm.parseUint(prefixed ? raw : string.concat("0x", raw)));
        } else {
            vm.startBroadcast();
        }
        (, address lister,) = vm.readCallers();

        if (!nft.isApprovedForAll(lister, address(market))) nft.setApprovalForAll(address(market), true);
        uint256 listed;
        for (uint256 id = from; id <= to; ++id) {
            if (nft.ownerOf(id) != lister) {
                console.log("skip, not held by the lister:", id);
                continue;
            }
            market.list(address(nft), id, currency, price, expiry);
            ++listed;
        }
        vm.stopBroadcast();
        console.log("Lister", lister);
        console.log("Listed", listed, "placements at (wei)", price);
    }
}
