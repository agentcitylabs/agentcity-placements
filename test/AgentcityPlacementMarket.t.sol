// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentcityPlacements} from "../src/AgentcityPlacements.sol";
import {AgentcityPlacementMarket as Market} from "../src/AgentcityPlacementMarket.sol";
import {MockUSDG, FeeOnTransferToken, RejectsEth} from "./Mocks.sol";

contract AgentcityPlacementMarketTest is Test {
    AgentcityPlacements city; // whitelisted
    AgentcityPlacements otherCity; // a second city's collection, not yet whitelisted
    Market market;
    MockUSDG usdg;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address bidder2 = makeAddr("bidder2");
    address renter = makeAddr("renter");
    address constant ETH = address(0);

    uint16 constant FEE = 250; // 2.5%
    uint96 constant ROYALTY = 500; // 5%

    function setUp() public {
        city = new AgentcityPlacements("Agentcity Placements", "ACPL", admin, treasury, treasury, 46, ROYALTY);
        otherCity = new AgentcityPlacements("Coast Placements", "ACCP", admin, treasury, treasury, 10, ROYALTY);
        market = new Market(admin, treasury, FEE);
        usdg = new MockUSDG();

        vm.startPrank(admin);
        market.setCollection(address(city), true);
        market.setCurrency(address(usdg), true);
        city.setRentalOperator(address(market), true);
        otherCity.setRentalOperator(address(market), true);
        vm.stopPrank();

        // The seller holds tokens 1-3 and lets the market move them.
        vm.startPrank(treasury);
        for (uint256 id = 1; id <= 3; ++id) {
            city.transferFrom(treasury, seller, id);
        }
        otherCity.transferFrom(treasury, seller, 1);
        vm.stopPrank();
        vm.startPrank(seller);
        city.setApprovalForAll(address(market), true);
        otherCity.setApprovalForAll(address(market), true);
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            address who = [buyer, bidder2, renter][i];
            vm.deal(who, 100 ether);
            usdg.mint(who, 1_000_000e6);
            vm.prank(who);
            usdg.approve(address(market), type(uint256).max);
        }
    }

    /// Whatever happens, the market holds exactly what it owes.
    function assertSolvent() internal view {
        assertEq(address(market).balance, market.escrowed(ETH), "ETH escrow");
        assertEq(usdg.balanceOf(address(market)), market.escrowed(address(usdg)), "USDG escrow");
    }

    /* ----------------------------- whitelist --------------------------- */

    function test_onlyWhitelistedCollectionsTrade() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Market.CollectionNotAllowed.selector, address(otherCity)));
        market.list(address(otherCity), 1, ETH, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Market.CollectionNotAllowed.selector, address(otherCity)));
        market.makeOffer{value: 1 ether}(address(otherCity), 1, ETH, 1 ether, uint64(block.timestamp + 1 days));

        // A new city is added by the admin, then trades like the first.
        vm.prank(admin);
        market.setCollection(address(otherCity), true);
        vm.prank(seller);
        market.list(address(otherCity), 1, ETH, 1 ether, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        market.buy{value: 1 ether}(address(otherCity), 1, ETH, 1 ether);
        assertEq(otherCity.ownerOf(1), buyer);
    }

    function test_onlyAdminWhitelists_andOnlyRealNfts() public {
        vm.prank(seller);
        vm.expectRevert();
        market.setCollection(address(otherCity), true);

        vm.prank(admin);
        vm.expectRevert(Market.NotAContract.selector);
        market.setCollection(address(usdg), true); // an ERC-20 is not an NFT
    }

    function test_removedCollectionStopsNewTradesButFundsComeBack() public {
        vm.prank(buyer);
        market.makeOffer{value: 2 ether}(address(city), 1, ETH, 2 ether, uint64(block.timestamp + 1 days));
        vm.prank(admin);
        market.setCollection(address(city), false);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Market.CollectionNotAllowed.selector, address(city)));
        market.acceptOffer(address(city), 1, buyer, ETH, 2 ether);

        uint256 before = buyer.balance;
        vm.startPrank(buyer);
        market.cancelOffer(address(city), 1);
        market.withdraw(ETH);
        vm.stopPrank();
        assertEq(buyer.balance, before + 2 ether);
        assertSolvent();
    }

    function test_unlistedCurrencyRefused() public {
        FeeOnTransferToken tax = new FeeOnTransferToken();
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Market.CurrencyNotAllowed.selector, address(tax)));
        market.list(address(city), 1, address(tax), 100, uint64(block.timestamp + 1 days));
    }

    function test_feeOnTransferTokenRefusedEvenIfWhitelisted() public {
        FeeOnTransferToken tax = new FeeOnTransferToken();
        tax.mint(buyer, 1_000e18);
        vm.prank(buyer);
        tax.approve(address(market), type(uint256).max);
        vm.prank(admin);
        market.setCurrency(address(tax), true);
        vm.prank(seller);
        market.list(address(city), 1, address(tax), 100e18, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        vm.expectRevert(Market.WrongPayment.selector);
        market.buy(address(city), 1, address(tax), 100e18);
    }

    /* ------------------------------ listings --------------------------- */

    function test_buyWithEthPaysFeeRoyaltyAndSeller() public {
        vm.prank(seller);
        market.list(address(city), 1, ETH, 10 ether, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        market.buy{value: 10 ether}(address(city), 1, ETH, 10 ether);

        assertEq(city.ownerOf(1), buyer);
        // 2.5% fee and 5% royalty, both to the treasury here; 92.5% to the seller.
        assertEq(market.credits(treasury, ETH), 0.25 ether + 0.5 ether);
        assertEq(market.credits(seller, ETH), 9.25 ether);
        assertSolvent();

        uint256 before = seller.balance;
        vm.prank(seller);
        market.withdraw(ETH);
        assertEq(seller.balance, before + 9.25 ether);
        assertSolvent();
    }

    function test_buyWithUsdg() public {
        vm.prank(seller);
        market.list(address(city), 2, address(usdg), 500e6, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        market.buy(address(city), 2, address(usdg), 500e6);
        assertEq(city.ownerOf(2), buyer);
        assertEq(market.credits(seller, address(usdg)), 462.5e6);
        assertSolvent();
    }

    function test_buyRejectsChangedPriceAndWrongPayment() public {
        vm.prank(seller);
        market.list(address(city), 1, ETH, 1 ether, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        vm.expectRevert(Market.ListingChanged.selector);
        market.buy{value: 0.5 ether}(address(city), 1, ETH, 0.5 ether);
        vm.prank(buyer);
        vm.expectRevert(Market.WrongPayment.selector);
        market.buy{value: 0.9 ether}(address(city), 1, ETH, 1 ether);
    }

    function test_staleListingAfterTransferCannotBeBought() public {
        vm.prank(seller);
        market.list(address(city), 1, ETH, 1 ether, uint64(block.timestamp + 1 days));
        vm.prank(seller);
        city.transferFrom(seller, bidder2, 1);
        vm.prank(buyer);
        vm.expectRevert(Market.NotTokenOwner.selector);
        market.buy{value: 1 ether}(address(city), 1, ETH, 1 ether);
        // And anyone may clear it.
        vm.prank(buyer);
        market.cancelListing(address(city), 1);
    }

    function test_sellerThatRejectsEthCannotBlockTheSale() public {
        RejectsEth contractSeller = new RejectsEth();
        vm.prank(seller);
        city.transferFrom(seller, address(contractSeller), 3);
        vm.startPrank(address(contractSeller));
        city.setApprovalForAll(address(market), true);
        market.list(address(city), 3, ETH, 1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(buyer);
        market.buy{value: 1 ether}(address(city), 3, ETH, 1 ether);
        assertEq(city.ownerOf(3), buyer);
        assertEq(market.credits(address(contractSeller), ETH), 0.925 ether);
        assertSolvent();
    }

    /* ------------------------------- offers ---------------------------- */

    function test_offerEscrowedAcceptedAndReplaced() public {
        vm.startPrank(buyer);
        market.makeOffer{value: 1 ether}(address(city), 1, ETH, 1 ether, uint64(block.timestamp + 1 days));
        // A better offer replaces it; the first comes back as a credit.
        market.makeOffer{value: 2 ether}(address(city), 1, ETH, 2 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(market.credits(buyer, ETH), 1 ether);
        assertSolvent();

        vm.prank(seller);
        vm.expectRevert(Market.OfferTooLow.selector);
        market.acceptOffer(address(city), 1, buyer, ETH, 3 ether);

        vm.prank(seller);
        market.acceptOffer(address(city), 1, buyer, ETH, 2 ether);
        assertEq(city.ownerOf(1), buyer);
        assertEq(market.credits(seller, ETH), 1.85 ether);
        assertSolvent();
    }

    function test_expiredOfferCannotBeAcceptedButCanBeReclaimed() public {
        vm.prank(buyer);
        market.makeOffer(address(city), 1, address(usdg), 100e6, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(seller);
        vm.expectRevert(Market.Expired.selector);
        market.acceptOffer(address(city), 1, buyer, address(usdg), 100e6);
        vm.startPrank(buyer);
        market.cancelOffer(address(city), 1);
        market.withdraw(address(usdg));
        vm.stopPrank();
        assertEq(usdg.balanceOf(buyer), 1_000_000e6);
        assertSolvent();
    }

    /* ------------------------------ auctions --------------------------- */

    function test_auctionWithOutbidAntiSnipeAndSettle() public {
        uint64 end = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        market.startAuction(address(city), 1, ETH, 1 ether, 0, end);
        assertEq(city.ownerOf(1), address(market));

        vm.prank(buyer);
        vm.expectRevert(Market.BidTooLow.selector);
        market.bid{value: 0.5 ether}(address(city), 1, 0.5 ether);

        vm.prank(buyer);
        market.bid{value: 1 ether}(address(city), 1, 1 ether);
        // Less than 5% more is not enough.
        vm.prank(bidder2);
        vm.expectRevert(Market.BidTooLow.selector);
        market.bid{value: 1.04 ether}(address(city), 1, 1.04 ether);

        // A bid in the last minutes pushes the end back.
        vm.warp(end - 2 minutes);
        vm.prank(bidder2);
        market.bid{value: 1.05 ether}(address(city), 1, 1.05 ether);
        (,,,, uint64 newEnd,,) = market.auctions(address(city), 1);
        assertEq(newEnd, uint64(block.timestamp) + 10 minutes);
        assertEq(market.credits(buyer, ETH), 1 ether, "outbid refunded as credit");
        assertSolvent();

        vm.warp(end);
        vm.expectRevert(Market.AuctionNotOver.selector);
        market.settle(address(city), 1);

        vm.warp(newEnd);
        market.settle(address(city), 1);
        assertEq(city.ownerOf(1), bidder2);
        assertSolvent();
    }

    function test_auctionWithNoBidReturnsTheToken() public {
        vm.prank(seller);
        market.startAuction(address(city), 2, address(usdg), 100e6, 0, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours);
        market.settle(address(city), 2);
        assertEq(city.ownerOf(2), seller);
    }

    function test_cancelAuctionOnlyWithoutBids() public {
        vm.prank(seller);
        market.startAuction(address(city), 1, ETH, 1 ether, 0, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        market.bid{value: 1 ether}(address(city), 1, 1 ether);
        vm.prank(seller);
        vm.expectRevert(Market.HasBids.selector);
        market.cancelAuction(address(city), 1);
    }

    function test_pauseStopsTradesButNeverSettlementOrWithdrawals() public {
        vm.prank(seller);
        market.startAuction(address(city), 1, ETH, 1 ether, 0, uint64(block.timestamp + 1 hours));
        vm.prank(buyer);
        market.bid{value: 1 ether}(address(city), 1, 1 ether);
        vm.prank(admin);
        market.pause();

        vm.prank(bidder2);
        vm.expectRevert();
        market.bid{value: 2 ether}(address(city), 1, 2 ether);

        vm.warp(block.timestamp + 1 hours);
        market.settle(address(city), 1);
        vm.prank(seller);
        market.withdraw(ETH);
        assertEq(city.ownerOf(1), buyer);
        assertSolvent();
    }

    /* ------------------------------- rentals --------------------------- */

    function test_rentPaysOwnerAndGivesRenterTheCreative() public {
        vm.prank(seller);
        market.setRentTerms(address(city), 1, address(usdg), 10e6, 1, 30);

        vm.prank(renter);
        vm.expectRevert(Market.BadDays.selector);
        market.rent(address(city), 1, 31, address(usdg), 10e6);

        vm.prank(renter);
        market.rent(address(city), 1, 7, address(usdg), 10e6);
        assertEq(city.userOf(1), renter);
        assertEq(city.userExpires(1), block.timestamp + 7 days);
        // Fee only, no royalty: 70 USDG less 2.5%.
        assertEq(market.credits(seller, address(usdg)), 68.25e6);
        assertEq(market.credits(treasury, address(usdg)), 1.75e6);
        assertSolvent();

        vm.prank(renter);
        city.setCreative(1, AgentcityPlacements.Creative("ipfs://ad.png", "", "Rented ad", ""));

        // No second rental while one runs.
        vm.prank(bidder2);
        vm.expectRevert(Market.StillRented.selector);
        market.rent(address(city), 1, 1, address(usdg), 10e6);

        vm.warp(block.timestamp + 7 days);
        vm.prank(bidder2);
        market.rent(address(city), 1, 1, address(usdg), 10e6);
        assertEq(city.userOf(1), bidder2);
    }

    function test_rentalSurvivesSale_andOldTermsLapse() public {
        vm.prank(seller);
        market.setRentTerms(address(city), 1, ETH, 0.1 ether, 1, 10);
        vm.prank(renter);
        market.rent{value: 0.3 ether}(address(city), 1, 3, ETH, 0.1 ether);

        vm.prank(seller);
        market.list(address(city), 1, ETH, 5 ether, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        market.buy{value: 5 ether}(address(city), 1, ETH, 5 ether);
        assertEq(city.ownerOf(1), buyer);
        assertEq(city.userOf(1), renter, "the renter keeps the board");

        // The seller's rent terms no longer apply to the new holder's token.
        vm.warp(block.timestamp + 3 days);
        vm.prank(bidder2);
        vm.expectRevert(Market.NotRentable.selector);
        market.rent{value: 0.1 ether}(address(city), 1, 1, ETH, 0.1 ether);
        assertSolvent();
    }

    function test_cannotRentWithoutRentalOperatorRole() public {
        vm.prank(admin);
        city.setRentalOperator(address(market), false);
        vm.prank(seller);
        market.setRentTerms(address(city), 2, ETH, 0.1 ether, 1, 10);
        vm.prank(renter);
        vm.expectRevert(AgentcityPlacements.NotRentalOperator.selector);
        market.rent{value: 0.1 ether}(address(city), 2, 1, ETH, 0.1 ether);
    }

    /* ------------------------------- admin ----------------------------- */

    function test_feeIsCapped() public {
        vm.prank(admin);
        vm.expectRevert(Market.FeeTooHigh.selector);
        market.setFee(501, treasury);
    }

    /* -------------------------------- fuzz ----------------------------- */

    function testFuzz_saleSplitsAddUp(uint96 price) public {
        price = uint96(bound(price, 1, 1_000 ether));
        vm.deal(buyer, price);
        vm.prank(seller);
        market.list(address(city), 2, ETH, price, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        market.buy{value: price}(address(city), 2, ETH, price);
        assertEq(market.credits(seller, ETH) + market.credits(treasury, ETH), price);
        assertSolvent();
    }
}
