// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4907} from "./IERC4907.sol";

/// @title Agentcity placement marketplace
/// @notice Buy, sell, make offers on, auction and rent ad placements, for
/// whitelisted NFT collections only: every city deploys its own placements
/// collection, and the owner adds each one here. Nothing else can trade.
///
/// Payments are ETH (address(0)) or whitelisted ERC-20s such as USDG. Every
/// trade pays a protocol fee to the treasury; sales also pay the collection's
/// ERC-2981 royalty. Proceeds and refunds are credited and claimed with
/// withdraw(), so a receiver that reverts can never block a trade.
contract AgentcityPlacementMarket is Ownable2Step, Pausable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    address public constant ETH = address(0);
    uint16 public constant MAX_FEE_BPS = 500; // 5%
    uint16 public constant MAX_ROYALTY_BPS = 1_000; // royalties above 10% are capped
    uint16 public constant MIN_RAISE_BPS = 500; // a new bid beats the last by 5%
    uint64 public constant ANTI_SNIPE = 10 minutes;
    uint64 public constant MAX_AUCTION = 30 days;

    struct Listing {
        address seller;
        address currency;
        uint256 price;
        uint64 expiry;
    }

    struct Offer {
        address currency;
        uint256 amount;
        uint64 expiry;
    }

    struct Auction {
        address seller;
        address currency;
        uint256 reserve;
        uint64 start;
        uint64 end;
        address highBidder;
        uint256 highBid;
    }

    struct RentTerms {
        address owner;
        address currency;
        uint256 pricePerDay;
        uint16 minDays;
        uint16 maxDays;
    }

    address public treasury;
    uint16 public feeBps;

    mapping(address => bool) public isCollectionAllowed;
    mapping(address => bool) public isCurrencyAllowed;

    mapping(address => mapping(uint256 => Listing)) public listings;
    mapping(address => mapping(uint256 => mapping(address => Offer))) public offers;
    mapping(address => mapping(uint256 => Auction)) public auctions;
    mapping(address => mapping(uint256 => RentTerms)) public rentTerms;

    /// @notice Claimable balances: account => currency => amount.
    mapping(address => mapping(address => uint256)) public credits;
    /// @notice Everything held for offers, bids and credits, per currency.
    mapping(address => uint256) public escrowed;

    event CollectionSet(address indexed collection, bool allowed);
    event CurrencySet(address indexed currency, bool allowed);
    event FeeSet(uint16 feeBps, address treasury);

    event Listed(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address currency,
        uint256 price,
        uint64 expiry
    );
    event ListingCancelled(address indexed collection, uint256 indexed tokenId);
    event Sold(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address buyer,
        address currency,
        uint256 price
    );

    event OfferMade(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed bidder,
        address currency,
        uint256 amount,
        uint64 expiry
    );
    event OfferCancelled(address indexed collection, uint256 indexed tokenId, address indexed bidder);
    event OfferAccepted(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed bidder,
        address seller,
        address currency,
        uint256 amount
    );

    event AuctionStarted(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address currency,
        uint256 reserve,
        uint64 start,
        uint64 end
    );
    event BidPlaced(
        address indexed collection, uint256 indexed tokenId, address indexed bidder, uint256 amount, uint64 end
    );
    event AuctionExtended(address indexed collection, uint256 indexed tokenId, uint64 end);
    event AuctionSettled(address indexed collection, uint256 indexed tokenId, address winner, uint256 amount);
    event AuctionCancelled(address indexed collection, uint256 indexed tokenId);

    event RentTermsSet(
        address indexed collection,
        uint256 indexed tokenId,
        address owner,
        address currency,
        uint256 pricePerDay,
        uint16 minDays,
        uint16 maxDays
    );
    event RentTermsCleared(address indexed collection, uint256 indexed tokenId);
    event Rented(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed renter,
        address owner,
        address currency,
        uint256 total,
        uint64 expires
    );

    event Withdrawn(address indexed account, address indexed currency, uint256 amount);

    error CollectionNotAllowed(address collection);
    error CurrencyNotAllowed(address currency);
    error NotTokenOwner();
    error NotApproved();
    error InvalidAmount();
    error InvalidTime();
    error NotListed();
    error ListingChanged();
    error Expired();
    error NoOffer();
    error OfferTooLow();
    error AuctionLive();
    error NoAuction();
    error AuctionNotStarted();
    error AuctionOver();
    error AuctionNotOver();
    error BidTooLow();
    error HasBids();
    error NotRentable();
    error StillRented();
    error BadDays();
    error WrongPayment();
    error FeeTooHigh();
    error ZeroAddress();
    error NotAContract();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address admin, address treasury_, uint16 feeBps_) Ownable(admin) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        treasury = treasury_;
        feeBps = feeBps_;
        isCurrencyAllowed[ETH] = true;
        emit CurrencySet(ETH, true);
        emit FeeSet(feeBps_, treasury_);
    }

    /* ------------------------------ admin ----------------------------- */

    /// @notice Whitelist a city's placements collection (or remove one). A
    /// removed collection can no longer be listed, offered on, auctioned or
    /// rented, but running auctions still settle and every credit can still
    /// be withdrawn.
    function setCollection(address collection, bool allowed) external onlyOwner {
        if (allowed && !ERC165Checker.supportsInterface(collection, type(IERC721).interfaceId)) {
            revert NotAContract();
        }
        isCollectionAllowed[collection] = allowed;
        emit CollectionSet(collection, allowed);
    }

    function setCurrency(address currency, bool allowed) external onlyOwner {
        if (allowed && currency != ETH && currency.code.length == 0) revert NotAContract();
        isCurrencyAllowed[currency] = allowed;
        emit CurrencySet(currency, allowed);
    }

    function setFee(uint16 feeBps_, address treasury_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (treasury_ == address(0)) revert ZeroAddress();
        feeBps = feeBps_;
        treasury = treasury_;
        emit FeeSet(feeBps_, treasury_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ----------------------------- listings --------------------------- */

    function list(address collection, uint256 tokenId, address currency, uint256 price, uint64 expiry)
        external
        whenNotPaused
    {
        _checkTradable(collection, currency);
        if (price == 0) revert InvalidAmount();
        if (expiry <= block.timestamp) revert InvalidTime();
        _checkOwnerAndApproval(collection, tokenId, msg.sender);
        listings[collection][tokenId] = Listing(msg.sender, currency, price, expiry);
        emit Listed(collection, tokenId, msg.sender, currency, price, expiry);
    }

    function cancelListing(address collection, uint256 tokenId) external {
        Listing memory l = listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed();
        // The seller, or anyone once the seller no longer holds the token.
        if (msg.sender != l.seller && IERC721(collection).ownerOf(tokenId) == l.seller) revert NotTokenOwner();
        delete listings[collection][tokenId];
        emit ListingCancelled(collection, tokenId);
    }

    /// @param currency and price are what the buyer saw, so a listing changed
    /// in the same block cannot charge them something else.
    function buy(address collection, uint256 tokenId, address currency, uint256 price)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        Listing memory l = listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.currency != currency || l.price != price) revert ListingChanged();
        if (l.expiry <= block.timestamp) revert Expired();
        _checkTradable(collection, currency);
        _checkOwnerAndApproval(collection, tokenId, l.seller);
        delete listings[collection][tokenId];

        _collect(currency, price, msg.sender);
        IERC721(collection).safeTransferFrom(l.seller, msg.sender, tokenId);
        _payOut(collection, tokenId, l.seller, currency, price, true);
        emit Sold(collection, tokenId, l.seller, msg.sender, currency, price);
    }

    /* ------------------------------ offers ---------------------------- */

    /// @notice Escrows the amount. A new offer from the same bidder replaces
    /// the old one, whose funds are credited back.
    function makeOffer(address collection, uint256 tokenId, address currency, uint256 amount, uint64 expiry)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        _checkTradable(collection, currency);
        if (amount == 0) revert InvalidAmount();
        if (expiry <= block.timestamp) revert InvalidTime();
        IERC721(collection).ownerOf(tokenId); // reverts for a token that does not exist

        Offer memory previous = offers[collection][tokenId][msg.sender];
        if (previous.amount != 0) _credit(msg.sender, previous.currency, previous.amount);

        _collect(currency, amount, msg.sender);
        escrowed[currency] += amount;
        offers[collection][tokenId][msg.sender] = Offer(currency, amount, expiry);
        emit OfferMade(collection, tokenId, msg.sender, currency, amount, expiry);
    }

    /// @notice Works after expiry and after a collection is removed, so funds
    /// are never stuck.
    function cancelOffer(address collection, uint256 tokenId) external nonReentrant {
        Offer memory o = offers[collection][tokenId][msg.sender];
        if (o.amount == 0) revert NoOffer();
        delete offers[collection][tokenId][msg.sender];
        _credit(msg.sender, o.currency, o.amount);
        emit OfferCancelled(collection, tokenId, msg.sender);
    }

    /// @param minAmount guards the holder against an offer swapped for a lower
    /// one in the same block.
    function acceptOffer(address collection, uint256 tokenId, address bidder, address currency, uint256 minAmount)
        external
        nonReentrant
        whenNotPaused
    {
        Offer memory o = offers[collection][tokenId][bidder];
        if (o.amount == 0) revert NoOffer();
        if (o.currency != currency || o.amount < minAmount) revert OfferTooLow();
        if (o.expiry <= block.timestamp) revert Expired();
        _checkTradable(collection, currency);
        _checkOwnerAndApproval(collection, tokenId, msg.sender);

        delete offers[collection][tokenId][bidder];
        delete listings[collection][tokenId];
        escrowed[currency] -= o.amount;

        IERC721(collection).safeTransferFrom(msg.sender, bidder, tokenId);
        _payOut(collection, tokenId, msg.sender, currency, o.amount, true);
        emit OfferAccepted(collection, tokenId, bidder, msg.sender, currency, o.amount);
    }

    /* ----------------------------- auctions --------------------------- */

    /// @notice English auction. The token is held by the market until it is
    /// settled or cancelled.
    function startAuction(
        address collection,
        uint256 tokenId,
        address currency,
        uint256 reserve,
        uint64 start,
        uint64 end
    ) external nonReentrant whenNotPaused {
        _checkTradable(collection, currency);
        if (reserve == 0) revert InvalidAmount();
        if (start < block.timestamp) start = uint64(block.timestamp);
        if (end <= start || end - start > MAX_AUCTION) revert InvalidTime();
        if (auctions[collection][tokenId].seller != address(0)) revert AuctionLive();
        _checkOwnerAndApproval(collection, tokenId, msg.sender);

        delete listings[collection][tokenId];
        auctions[collection][tokenId] = Auction(msg.sender, currency, reserve, start, end, address(0), 0);
        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        emit AuctionStarted(collection, tokenId, msg.sender, currency, reserve, start, end);
    }

    function bid(address collection, uint256 tokenId, uint256 amount) external payable nonReentrant whenNotPaused {
        Auction storage a = auctions[collection][tokenId];
        if (a.seller == address(0)) revert NoAuction();
        if (block.timestamp < a.start) revert AuctionNotStarted();
        if (block.timestamp >= a.end) revert AuctionOver();
        if (!isCurrencyAllowed[a.currency]) revert CurrencyNotAllowed(a.currency);
        uint256 floor = a.highBid == 0 ? a.reserve : a.highBid + (a.highBid * MIN_RAISE_BPS) / 10_000;
        if (amount < floor || (a.highBid != 0 && amount == a.highBid)) revert BidTooLow();

        _collect(a.currency, amount, msg.sender);
        escrowed[a.currency] += amount;
        // The previous leader is refunded through credits, never pushed.
        // Their funds stay in escrow, now as a claimable credit.
        if (a.highBidder != address(0)) _credit(a.highBidder, a.currency, a.highBid);
        a.highBidder = msg.sender;
        a.highBid = amount;
        if (a.end - block.timestamp < ANTI_SNIPE) {
            a.end = uint64(block.timestamp) + ANTI_SNIPE;
            emit AuctionExtended(collection, tokenId, a.end);
        }
        emit BidPlaced(collection, tokenId, msg.sender, amount, a.end);
    }

    /// @notice Anyone can settle once the auction is over. Not paused, so a
    /// pause never traps a token or a bid.
    function settle(address collection, uint256 tokenId) external nonReentrant {
        Auction memory a = auctions[collection][tokenId];
        if (a.seller == address(0)) revert NoAuction();
        if (block.timestamp < a.end) revert AuctionNotOver();
        delete auctions[collection][tokenId];

        if (a.highBidder == address(0)) {
            IERC721(collection).safeTransferFrom(address(this), a.seller, tokenId);
            emit AuctionSettled(collection, tokenId, address(0), 0);
            return;
        }
        escrowed[a.currency] -= a.highBid;
        IERC721(collection).safeTransferFrom(address(this), a.highBidder, tokenId);
        _payOut(collection, tokenId, a.seller, a.currency, a.highBid, true);
        emit AuctionSettled(collection, tokenId, a.highBidder, a.highBid);
    }

    /// @notice The seller can take the token back while nobody has bid.
    function cancelAuction(address collection, uint256 tokenId) external nonReentrant {
        Auction memory a = auctions[collection][tokenId];
        if (a.seller == address(0)) revert NoAuction();
        if (msg.sender != a.seller) revert NotTokenOwner();
        if (a.highBidder != address(0)) revert HasBids();
        delete auctions[collection][tokenId];
        IERC721(collection).safeTransferFrom(address(this), a.seller, tokenId);
        emit AuctionCancelled(collection, tokenId);
    }

    /* ------------------------------ rentals --------------------------- */

    /// @notice Offer the placement for rent, by the day. The collection must
    /// support ERC-4907 and approve this market as its rental operator.
    function setRentTerms(
        address collection,
        uint256 tokenId,
        address currency,
        uint256 pricePerDay,
        uint16 minDays,
        uint16 maxDays
    ) external whenNotPaused {
        _checkTradable(collection, currency);
        if (!ERC165Checker.supportsInterface(collection, type(IERC4907).interfaceId)) revert NotRentable();
        if (pricePerDay == 0) revert InvalidAmount();
        if (minDays == 0 || maxDays < minDays || maxDays > 365) revert BadDays();
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        rentTerms[collection][tokenId] = RentTerms(msg.sender, currency, pricePerDay, minDays, maxDays);
        emit RentTermsSet(collection, tokenId, msg.sender, currency, pricePerDay, minDays, maxDays);
    }

    function clearRentTerms(address collection, uint256 tokenId) external {
        RentTerms memory t = rentTerms[collection][tokenId];
        if (t.owner == address(0)) revert NotRentable();
        if (msg.sender != t.owner && IERC721(collection).ownerOf(tokenId) == t.owner) revert NotTokenOwner();
        delete rentTerms[collection][tokenId];
        emit RentTermsCleared(collection, tokenId);
    }

    /// @notice Pay up front for `days_` days; the renter then chooses the ad
    /// until the rental ends. Terms set by an earlier holder no longer apply.
    function rent(address collection, uint256 tokenId, uint16 days_, address currency, uint256 pricePerDay)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        RentTerms memory t = rentTerms[collection][tokenId];
        if (t.owner == address(0) || IERC721(collection).ownerOf(tokenId) != t.owner) revert NotRentable();
        if (t.currency != currency || t.pricePerDay != pricePerDay) revert ListingChanged();
        if (days_ < t.minDays || days_ > t.maxDays) revert BadDays();
        _checkTradable(collection, currency);
        if (IERC4907(collection).userOf(tokenId) != address(0)) revert StillRented();

        uint256 total = t.pricePerDay * days_;
        uint64 expires = uint64(block.timestamp) + uint64(days_) * 1 days;
        _collect(currency, total, msg.sender);
        IERC4907(collection).setUser(tokenId, msg.sender, expires);
        // Rentals pay the protocol fee but no royalty.
        _payOut(collection, tokenId, t.owner, currency, total, false);
        emit Rented(collection, tokenId, msg.sender, t.owner, currency, total, expires);
    }

    /* ---------------------------- withdrawals ------------------------- */

    function withdraw(address currency) external nonReentrant {
        uint256 amount = credits[msg.sender][currency];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender][currency] = 0;
        escrowed[currency] -= amount;
        if (currency == ETH) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(currency).safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(msg.sender, currency, amount);
    }

    /* ------------------------------ internal -------------------------- */

    function _checkTradable(address collection, address currency) internal view {
        if (!isCollectionAllowed[collection]) revert CollectionNotAllowed(collection);
        if (!isCurrencyAllowed[currency]) revert CurrencyNotAllowed(currency);
    }

    function _checkOwnerAndApproval(address collection, uint256 tokenId, address owner_) internal view {
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != owner_) revert NotTokenOwner();
        if (nft.getApproved(tokenId) != address(this) && !nft.isApprovedForAll(owner_, address(this))) {
            revert NotApproved();
        }
    }

    /// @dev Takes exactly `amount` from `from`. ERC-20s that charge a fee on
    /// transfer are refused, so escrow always matches what is owed.
    function _collect(address currency, uint256 amount, address from) internal {
        if (currency == ETH) {
            if (msg.value != amount) revert WrongPayment();
            return;
        }
        if (msg.value != 0) revert WrongPayment();
        IERC20 token = IERC20(currency);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert WrongPayment();
    }

    function _credit(address account, address currency, uint256 amount) internal {
        credits[account][currency] += amount;
        // Offer and bid funds are already counted in escrow; this keeps the
        // invariant that escrow covers every credit and open offer or bid.
    }

    /// @dev Splits a payment into protocol fee, royalty (sales only, capped)
    /// and the seller's share, all as credits.
    function _payOut(
        address collection,
        uint256 tokenId,
        address seller,
        address currency,
        uint256 amount,
        bool withRoyalty
    ) internal {
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 royalty;
        address royaltyTo;
        if (withRoyalty && ERC165Checker.supportsInterface(collection, type(IERC2981).interfaceId)) {
            try IERC2981(collection).royaltyInfo(tokenId, amount) returns (address receiver, uint256 value) {
                uint256 cap = (amount * MAX_ROYALTY_BPS) / 10_000;
                if (receiver != address(0)) {
                    royaltyTo = receiver;
                    royalty = value > cap ? cap : value;
                }
            } catch {}
        }
        escrowed[currency] += amount;
        if (fee != 0) credits[treasury][currency] += fee;
        if (royalty != 0) credits[royaltyTo][currency] += royalty;
        credits[seller][currency] += amount - fee - royalty;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
