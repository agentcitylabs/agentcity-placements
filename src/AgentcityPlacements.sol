// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC4907} from "./IERC4907.sol";

/// @title Agentcity ad placements
/// @notice One NFT per advertising surface in a city: billboards and banners.
/// The supply is fixed at deploy and every token is minted to the treasury
/// then; there is no minting afterwards. Each city deploys its own
/// collection, and the marketplace trades only collections it whitelists.
///
/// The holder chooses the ad (the "creative"). While a token is rented the
/// renter chooses it instead, until the rental ends. Rentals are granted only
/// by approved operators (the marketplace) after payment, and survive a sale.
contract AgentcityPlacements is ERC721, ERC2981, Ownable2Step, IERC4907 {
    using Strings for uint256;

    struct Creative {
        string mediaURI; // image (png, jpg, webp) or silent looping video (mp4, webm)
        string linkURI;
        string title;
        string description;
    }

    struct Placement {
        string placementId; // the city's id, e.g. "central-north", "banner-writing-1"
        string kind; // "billboard" or "banner"
    }

    struct Rental {
        address user;
        uint64 expires;
    }

    uint256 public immutable maxSupply;
    uint96 public constant MAX_ROYALTY_BPS = 1_000; // 10%

    mapping(uint256 => Placement) private _placements;
    mapping(uint256 => Creative) private _creatives;
    mapping(uint256 => uint64) public creativeUpdatedAt;
    mapping(uint256 => address) public creativeUpdatedBy;
    mapping(uint256 => bool) public flagged;
    mapping(uint256 => Rental) private _rentals;

    mapping(address => bool) public isModerator;
    mapping(address => bool) public isRentalOperator;

    event PlacementSet(uint256 indexed tokenId, string placementId, string kind);
    event CreativeUpdated(uint256 indexed tokenId, address indexed by, string mediaURI);
    event Flagged(uint256 indexed tokenId, address indexed by, string reason);
    event Unflagged(uint256 indexed tokenId, address indexed by);
    event ModeratorSet(address indexed account, bool allowed);
    event RentalOperatorSet(address indexed operator, bool allowed);

    error ZeroSupply();
    error ZeroAddress();
    error NotModerator();
    error NotRentalOperator();
    error PlacementAlreadySet(uint256 tokenId);
    error StillRented(uint256 tokenId, address user, uint64 expires);
    error NotAllowedToEdit(uint256 tokenId);
    error FieldTooLong(string field);
    error RoyaltyTooHigh();
    error BadExpiry();

    constructor(
        string memory name_,
        string memory symbol_,
        address admin,
        address treasury,
        uint256 supply,
        uint96 royaltyBps
    ) ERC721(name_, symbol_) Ownable(admin) {
        if (supply == 0) revert ZeroSupply();
        if (treasury == address(0)) revert ZeroAddress();
        if (royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        maxSupply = supply;
        _setDefaultRoyalty(treasury, royaltyBps);
        for (uint256 id = 1; id <= supply; ++id) {
            _mint(treasury, id);
        }
    }

    function totalSupply() external view returns (uint256) {
        return maxSupply;
    }

    /* ----------------------------- admin ----------------------------- */

    /// @notice Name a token after the city surface it is. Set once, then fixed.
    function setPlacement(uint256 tokenId, string calldata placementId, string calldata kind) public onlyOwner {
        _requireOwned(tokenId);
        if (bytes(_placements[tokenId].placementId).length != 0) revert PlacementAlreadySet(tokenId);
        if (bytes(placementId).length == 0 || bytes(placementId).length > 64) revert FieldTooLong("placementId");
        if (bytes(kind).length == 0 || bytes(kind).length > 16) revert FieldTooLong("kind");
        _placements[tokenId] = Placement(placementId, kind);
        emit PlacementSet(tokenId, placementId, kind);
    }

    function setPlacements(uint256[] calldata tokenIds, string[] calldata placementIds, string[] calldata kinds)
        external
        onlyOwner
    {
        require(tokenIds.length == placementIds.length && tokenIds.length == kinds.length, "length");
        for (uint256 i; i < tokenIds.length; ++i) {
            setPlacement(tokenIds[i], placementIds[i], kinds[i]);
        }
    }

    function setModerator(address account, bool allowed) external onlyOwner {
        isModerator[account] = allowed;
        emit ModeratorSet(account, allowed);
    }

    /// @notice The marketplace is the operator: it grants rentals after payment.
    function setRentalOperator(address operator, bool allowed) external onlyOwner {
        isRentalOperator[operator] = allowed;
        emit RentalOperatorSet(operator, allowed);
    }

    function setDefaultRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        _setDefaultRoyalty(receiver, bps);
    }

    /* ---------------------------- creatives -------------------------- */

    /// @notice The renter edits while a rental runs; otherwise the holder (or
    /// anyone the holder approved) does.
    function setCreative(uint256 tokenId, Creative calldata c) external {
        if (!canEditCreative(tokenId, msg.sender)) revert NotAllowedToEdit(tokenId);
        if (bytes(c.mediaURI).length > 512) revert FieldTooLong("mediaURI");
        if (bytes(c.linkURI).length > 512) revert FieldTooLong("linkURI");
        if (bytes(c.title).length > 120) revert FieldTooLong("title");
        if (bytes(c.description).length > 600) revert FieldTooLong("description");
        _creatives[tokenId] = c;
        creativeUpdatedAt[tokenId] = uint64(block.timestamp);
        creativeUpdatedBy[tokenId] = msg.sender;
        // A new creative goes back up; moderators can flag it again.
        if (flagged[tokenId]) {
            flagged[tokenId] = false;
            emit Unflagged(tokenId, msg.sender);
        }
        emit CreativeUpdated(tokenId, msg.sender, c.mediaURI);
    }

    function canEditCreative(uint256 tokenId, address account) public view returns (bool) {
        address owner_ = _requireOwned(tokenId);
        address renter = userOf(tokenId);
        if (renter != address(0)) return account == renter;
        return _isAuthorized(owner_, account, tokenId);
    }

    function creativeOf(uint256 tokenId) external view returns (Creative memory) {
        _requireOwned(tokenId);
        return _creatives[tokenId];
    }

    function placementOf(uint256 tokenId) external view returns (Placement memory) {
        _requireOwned(tokenId);
        return _placements[tokenId];
    }

    /// @notice Stop the city showing an ad. Moves no token and no funds.
    function flag(uint256 tokenId, string calldata reason) external {
        if (!isModerator[msg.sender]) revert NotModerator();
        _requireOwned(tokenId);
        flagged[tokenId] = true;
        emit Flagged(tokenId, msg.sender, reason);
    }

    function unflag(uint256 tokenId) external {
        if (!isModerator[msg.sender]) revert NotModerator();
        flagged[tokenId] = false;
        emit Unflagged(tokenId, msg.sender);
    }

    /* ----------------------------- ERC-4907 -------------------------- */

    /// @notice Only an approved operator grants a rental, and never over one
    /// that is still running: a paid rental cannot be cut short.
    function setUser(uint256 tokenId, address user, uint64 expires) external {
        if (!isRentalOperator[msg.sender]) revert NotRentalOperator();
        _requireOwned(tokenId);
        Rental memory current = _rentals[tokenId];
        if (current.user != address(0) && current.expires > block.timestamp) {
            revert StillRented(tokenId, current.user, current.expires);
        }
        if (user != address(0) && expires <= block.timestamp) revert BadExpiry();
        _rentals[tokenId] = Rental(user, expires);
        emit UpdateUser(tokenId, user, expires);
    }

    function userOf(uint256 tokenId) public view returns (address) {
        Rental memory r = _rentals[tokenId];
        return r.expires > block.timestamp ? r.user : address(0);
    }

    function userExpires(uint256 tokenId) public view returns (uint256) {
        Rental memory r = _rentals[tokenId];
        return r.expires > block.timestamp ? r.expires : 0;
    }

    /* ----------------------------- metadata -------------------------- */

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Placement memory p = _placements[tokenId];
        Creative memory c = _creatives[tokenId];
        string memory title =
            bytes(c.title).length != 0 ? c.title : string.concat("Agentcity placement #", tokenId.toString());
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _escape(title),
            '","description":"',
            _escape(c.description),
            '","image":"',
            _escape(flagged[tokenId] ? "" : c.mediaURI),
            '","external_url":"',
            _escape(flagged[tokenId] ? "" : c.linkURI),
            '","attributes":[{"trait_type":"Placement","value":"',
            _escape(p.placementId),
            '"},{"trait_type":"Kind","value":"',
            _escape(p.kind),
            '"},{"trait_type":"Rented","value":"',
            userOf(tokenId) != address(0) ? "yes" : "no",
            '"},{"trait_type":"Flagged","value":"',
            flagged[tokenId] ? "yes" : "no",
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// @dev JSON string escaping for the fields people write themselves, so a
    /// quote in a title cannot break or rewrite the metadata.
    function _escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch == '"' || ch == "\\") extra += 1;
            else if (uint8(ch) < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        bytes16 hexChars = "0123456789abcdef";
        uint256 j;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch == '"' || ch == "\\") {
                out[j++] = "\\";
                out[j++] = ch;
            } else if (uint8(ch) < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(ch) >> 4];
                out[j++] = hexChars[uint8(ch) & 0x0f];
            } else {
                out[j++] = ch;
            }
        }
        return string(out);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return interfaceId == type(IERC4907).interfaceId || super.supportsInterface(interfaceId);
    }
}
