// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {AgentcityPlacementMarket} from "../src/AgentcityPlacementMarket.sol";
import {TestnetToken} from "../src/testnet/TestnetToken.sol";

/// @notice Signs with DEPLOYER_PRIVATE_KEY from .env when it is set,
/// otherwise with whatever forge was given (--account for a keystore).
abstract contract Deployer is Script {
    /// @return deployer the address that will actually send the transactions.
    function _start() internal returns (address deployer) {
        // Hex, with or without the 0x a wallet export may leave off.
        string memory raw = vm.envOr("DEPLOYER_PRIVATE_KEY", string(""));
        if (bytes(raw).length != 0) {
            bytes memory b = bytes(raw);
            bool prefixed = b.length > 1 && b[0] == "0" && (b[1] == "x" || b[1] == "X");
            vm.startBroadcast(vm.parseUint(prefixed ? raw : string.concat("0x", raw)));
        } else {
            vm.startBroadcast();
        }
        (, deployer,) = vm.readCallers();
    }

    /// Deploys the collection and the market, wires them, names the city's
    /// placements and starts the handover to PLACEMENTS_ADMIN. The caller has
    /// already started broadcasting as `deployer`.
    function _deployCity(address deployer, address[] memory currencies)
        internal
        returns (AgentcityPlacements nft, AgentcityPlacementMarket market)
    {
        address admin = vm.envAddress("PLACEMENTS_ADMIN");
        address treasury = vm.envAddress("PLACEMENTS_TREASURY");
        uint256 supply = vm.envOr("PLACEMENTS_SUPPLY", uint256(46));
        uint96 royaltyBps = uint96(vm.envOr("PLACEMENTS_ROYALTY_BPS", uint256(500)));
        uint16 feeBps = uint16(vm.envOr("MARKET_FEE_BPS", uint256(250)));

        nft = new AgentcityPlacements("Agentcity Placements", "ACPL", deployer, treasury, supply, royaltyBps);
        market = new AgentcityPlacementMarket(deployer, treasury, feeBps);

        market.setCollection(address(nft), true);
        for (uint256 i; i < currencies.length; ++i) {
            market.setCurrency(currencies[i], true);
        }
        nft.setRentalOperator(address(market), true);
        nft.setModerator(admin, true);

        // The twenty surfaces the city already draws. Tokens past these are
        // named later with setPlacement() as new boards go up.
        (string[] memory ids, string[] memory kinds) = cityPlacements();
        uint256 named = ids.length < supply ? ids.length : supply;
        for (uint256 i; i < named; ++i) {
            nft.setPlacement(i + 1, ids[i], kinds[i]);
        }

        nft.transferOwnership(admin);
        market.transferOwnership(admin);

        console.log("AgentcityPlacements", address(nft));
        console.log("AgentcityPlacementMarket", address(market));
        console.log("Supply", supply, "named", named);
        console.log("Next: the admin calls acceptOwnership() on both contracts.");
    }

    /// Mirrors PLACEMENTS in src/map/city/layout.js: token id = index + 1.
    function cityPlacements() internal pure returns (string[] memory ids, string[] memory kinds) {
        ids = new string[](20);
        kinds = new string[](20);
        ids[0] = "central-north";
        kinds[0] = "billboard";
        ids[1] = "central-east";
        kinds[1] = "billboard";
        ids[2] = "central-south";
        kinds[2] = "billboard";
        ids[3] = "central-west";
        kinds[3] = "billboard";
        ids[4] = "banner-programming-1";
        kinds[4] = "banner";
        ids[5] = "banner-programming-2";
        kinds[5] = "banner";
        ids[6] = "banner-design-1";
        kinds[6] = "banner";
        ids[7] = "banner-design-2";
        kinds[7] = "banner";
        ids[8] = "banner-video-1";
        kinds[8] = "banner";
        ids[9] = "banner-video-2";
        kinds[9] = "banner";
        ids[10] = "banner-writing-1";
        kinds[10] = "banner";
        ids[11] = "banner-writing-2";
        kinds[11] = "banner";
        ids[12] = "banner-marketing-1";
        kinds[12] = "banner";
        ids[13] = "banner-marketing-2";
        kinds[13] = "banner";
        ids[14] = "banner-business-1";
        kinds[14] = "banner";
        ids[15] = "banner-business-2";
        kinds[15] = "banner";
        ids[16] = "banner-data-1";
        kinds[16] = "banner";
        ids[17] = "banner-data-2";
        kinds[17] = "banner";
        ids[18] = "banner-sales-1";
        kinds[18] = "banner";
        ids[19] = "banner-sales-2";
        kinds[19] = "banner";
    }
}

/// @notice Deploys downtown Agentcity's placements collection and the
/// marketplace, wires them together, then hands both to the admin.
///
///   PLACEMENTS_ADMIN        multisig that will own both contracts (required)
///   PLACEMENTS_TREASURY     receives all tokens, fees and royalties (required)
///   PLACEMENTS_SUPPLY       fixed supply, minted to the treasury (default 46)
///   PLACEMENTS_ROYALTY_BPS  secondary-sale royalty, max 1000 (default 500)
///   MARKET_FEE_BPS          protocol fee, max 500 (default 250)
///   USDG_ADDRESS            enable USDG payments (optional)
///   TOKEN_CURRENCIES        ERC-20s to accept besides USDG, comma-separated:
///                           the town token, a partner's token… (optional).
///                           More can be added later with setCurrency().
///
/// Ownership uses two steps: the admin must call acceptOwnership() on both
/// contracts afterwards. Until then the deployer still owns them.
///
/// Settings come from .env (see .env.example).
///
///   forge script script/Deploy.s.sol --tc Deploy --rpc-url deploy --broadcast
///   (add --account deployer when DEPLOYER_PRIVATE_KEY is empty)
contract Deploy is Deployer {
    function run() external returns (AgentcityPlacements nft, AgentcityPlacementMarket market) {
        address usdg = vm.envOr("USDG_ADDRESS", address(0));
        address[] memory tokenCurrencies = vm.envOr("TOKEN_CURRENCIES", ",", new address[](0));
        address[] memory currencies = new address[](tokenCurrencies.length + (usdg == address(0) ? 0 : 1));
        uint256 n;
        if (usdg != address(0)) currencies[n++] = usdg;
        for (uint256 i; i < tokenCurrencies.length; ++i) {
            currencies[n++] = tokenCurrencies[i];
        }

        address deployer = _start();
        (nft, market) = _deployCity(deployer, currencies);
        vm.stopBroadcast();
    }
}

/// @notice Another city's collection, with its own supply. The marketplace
/// admin then whitelists it: market.setCollection(<printed address>, true),
/// and the new collection's admin calls setRentalOperator(market, true).
///
///   PLACEMENTS_ADMIN, PLACEMENTS_TREASURY, PLACEMENTS_SUPPLY (required),
///   PLACEMENTS_NAME, PLACEMENTS_SYMBOL, PLACEMENTS_ROYALTY_BPS
contract DeployCityCollection is Deployer {
    function run() external returns (AgentcityPlacements nft) {
        address admin = vm.envAddress("PLACEMENTS_ADMIN");
        address treasury = vm.envAddress("PLACEMENTS_TREASURY");
        uint256 supply = vm.envUint("PLACEMENTS_SUPPLY");
        string memory name = vm.envOr("PLACEMENTS_NAME", string("Agentcity Placements"));
        string memory symbol = vm.envOr("PLACEMENTS_SYMBOL", string("ACPL"));
        uint96 royaltyBps = uint96(vm.envOr("PLACEMENTS_ROYALTY_BPS", uint256(500)));

        _start();
        nft = new AgentcityPlacements(name, symbol, admin, treasury, supply, royaltyBps);
        vm.stopBroadcast();
        console.log("AgentcityPlacements", address(nft));
        console.log("Next: whitelist it on the marketplace and approve the market as rental operator.");
    }
}

/// @notice TESTNET ONLY: deploys mock USDG and mock AGCT, then the city's
/// collection and market accepting ETH and both mocks. Refuses to run on any
/// chain but Robinhood Chain testnet (46630) or a local node (31337).
///
///   forge script script/Deploy.s.sol --tc DeployTestnet --rpc-url deploy --broadcast
contract DeployTestnet is Deployer {
    function run()
        external
        returns (TestnetToken usdg, TestnetToken agct, AgentcityPlacements nft, AgentcityPlacementMarket market)
    {
        require(block.chainid == 46630 || block.chainid == 31337, "DeployTestnet: testnet only");
        address admin = vm.envAddress("PLACEMENTS_ADMIN");
        address treasury = vm.envAddress("PLACEMENTS_TREASURY");

        address deployer = _start();
        // Faucets hand out 1,000 USDG / 10,000 AGCT an hour to anyone.
        usdg = new TestnetToken("Mock USDG", "USDG", 6, 1_000e6, deployer);
        agct = new TestnetToken("Mock Agentcity Token", "AGCT", 18, 10_000e18, deployer);
        // A float for the team to test with.
        usdg.mint(admin, 1_000_000e6);
        usdg.mint(treasury, 1_000_000e6);
        agct.mint(admin, 10_000_000e18);
        agct.mint(treasury, 10_000_000e18);
        usdg.transferOwnership(admin);
        agct.transferOwnership(admin);
        console.log("Mock USDG", address(usdg));
        console.log("Mock AGCT", address(agct));

        address[] memory currencies = new address[](2);
        currencies[0] = address(usdg);
        currencies[1] = address(agct);
        (nft, market) = _deployCity(deployer, currencies);
        vm.stopBroadcast();
    }
}
