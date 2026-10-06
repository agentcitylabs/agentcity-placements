// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
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
///
/// Metadata is built on chain from the stored creative. Every change emits
/// ERC-4906 MetadataUpdate, so explorers and marketplaces refresh on their own.
contract AgentcityPlacements is ERC721, ERC2981, Ownable2Step, IERC4907, IERC4906 {
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

    // Collection metadata (ERC-7572), served on chain by contractURI().
    string public collectionImage;
    string public externalLink = "https://agentcity.lol";

    event PlacementSet(uint256 indexed tokenId, string placementId, string kind);
    event CreativeUpdated(uint256 indexed tokenId, address indexed by, string mediaURI);
    event Flagged(uint256 indexed tokenId, address indexed by, string reason);
    event Unflagged(uint256 indexed tokenId, address indexed by);
    event ModeratorSet(address indexed account, bool allowed);
    event RentalOperatorSet(address indexed operator, bool allowed);
    /// ERC-7572: the collection's metadata changed.
    event ContractURIUpdated();

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
    error BadRange();

    /// @param treasury receives royalties.
    /// @param initialHolder receives every token at deploy: the treasury for a
    /// new city, or the deployer while migrating from an older collection.
    constructor(
        string memory name_,
        string memory symbol_,
        address admin,
        address treasury,
        address initialHolder,
        uint256 supply,
        uint96 royaltyBps
    ) ERC721(name_, symbol_) Ownable(admin) {
        if (supply == 0) revert ZeroSupply();
        if (treasury == address(0) || initialHolder == address(0)) revert ZeroAddress();
        if (royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        maxSupply = supply;
        _setDefaultRoyalty(treasury, royaltyBps);
        for (uint256 id = 1; id <= supply; ++id) {
            _mint(initialHolder, id);
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
        emit MetadataUpdate(tokenId);
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

    function setCollectionImage(string calldata image) external onlyOwner {
        if (bytes(image).length > 512) revert FieldTooLong("image");
        collectionImage = image;
        emit ContractURIUpdated();
    }

    function setExternalLink(string calldata link) external onlyOwner {
        if (bytes(link).length > 512) revert FieldTooLong("link");
        externalLink = link;
        emit ContractURIUpdated();
    }

    /// @notice Ask platforms to reread a range of tokens (ERC-4906).
    function refreshMetadata(uint256 fromId, uint256 toId) external onlyOwner {
        if (fromId == 0 || toId < fromId || toId > maxSupply) revert BadRange();
        emit BatchMetadataUpdate(fromId, toId);
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
        emit MetadataUpdate(tokenId);
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
        emit MetadataUpdate(tokenId);
    }

    function unflag(uint256 tokenId) external {
        if (!isModerator[msg.sender]) revert NotModerator();
        flagged[tokenId] = false;
        emit Unflagged(tokenId, msg.sender);
        emit MetadataUpdate(tokenId);
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
        emit MetadataUpdate(tokenId);
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

    /// @notice On-chain JSON. An image ad is the `image`; a video ad is the
    /// `animation_url`, with an on-chain card as its `image`. An empty or
    /// flagged placement shows the card alone.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Placement memory p = _placements[tokenId];
        Creative memory c = _creatives[tokenId];
        bool hidden = flagged[tokenId];
        bool hasMedia = !hidden && bytes(c.mediaURI).length != 0;
        bool video = hasMedia && _isVideo(c.mediaURI);
        string memory title =
            bytes(c.title).length != 0 ? c.title : string.concat("Agentcity placement #", tokenId.toString());
        string memory card = _card(tokenId, p, c, hidden, video);
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _escape(title),
            '","description":"',
            _escape(c.description),
            '","image":"',
            hasMedia && !video ? _escape(c.mediaURI) : card,
            video ? string.concat('","animation_url":"', _escape(c.mediaURI)) : "",
            '","external_url":"',
            _escape(hidden ? "" : c.linkURI),
            '","attributes":[{"trait_type":"Placement","value":"',
            _escape(p.placementId),
            '"},{"trait_type":"Kind","value":"',
            _escape(p.kind),
            '"},{"trait_type":"Media","value":"',
            hidden ? "under review" : video ? "video" : hasMedia ? "image" : "none",
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// @notice ERC-7572 collection metadata, on chain.
    function contractURI() external view returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _escape(name()),
            '","description":"Billboards and banners in Agentcity, a town whose residents are AI agents. Each placement is an NFT: buy it, rent it by the day, or make an offer, and choose the ad it shows.","image":"',
            _escape(collectionImage),
            '","external_link":"',
            _escape(externalLink),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// @dev A 16:9 card in Agentcity's black and yellow: what the board is, and
    /// what it shows. The image for empty, video and flagged placements.
    function _card(uint256 tokenId, Placement memory p, Creative memory c, bool hidden, bool video)
        internal
        pure
        returns (string memory)
    {
        bool banner = keccak256(bytes(p.kind)) == keccak256("banner");
        string memory headline = hidden
            ? "Under review"
            : bytes(c.title).length != 0
                ? _xml(_clip(c.title, 34))
                : bytes(c.mediaURI).length != 0 ? "Now showing" : "Your ad here.";
        // Bigger for short headlines, smaller for long ones, so it always fits.
        uint256 len = bytes(headline).length;
        string memory size = len <= 14 ? "120" : len <= 20 ? "100" : len <= 28 ? "78" : "62";
        // Built in two halves: one encodePacked with every piece would not fit the stack.
        bytes memory head = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900"><rect width="1600" height="900" fill="',
            hidden ? "#171717" : "#ffd52a",
            '"/><rect y="760" width="1600" height="140" fill="#171717"/><g font-family="Inter,Helvetica,Arial,sans-serif" font-weight="900"><text x="96" y="170" font-size="48" fill="',
            hidden ? "#ffd52a" : "#171717",
            '">AGENTCITY ',
            banner ? "BANNER" : "BILLBOARD",
            '</text><text x="92" y="430" font-size="',
            size,
            '" fill="',
            hidden ? "#ffffff" : "#171717",
            '">'
        );
        bytes memory tail = abi.encodePacked(
            headline,
            '</text><text x="96" y="530" font-size="44" fill="',
            hidden ? "#aaaaaa" : "#171717",
            '" font-weight="700">',
            video ? "Video ad" : banner ? "800 x 450 &#183; 16:9" : "1600 x 900 &#183; 16:9",
            '</text><text x="96" y="850" font-size="44" fill="#ffd52a">#',
            tokenId.toString(),
            " &#183; ",
            _xml(p.placementId),
            "</text></g></svg>"
        );
        bytes memory svg = bytes.concat(head, tail);
        return string.concat("data:image/svg+xml;base64,", Base64.encode(svg));
    }

    /// @dev At most `max` bytes, cut on a character boundary, with an ellipsis.
    function _clip(string memory s, uint256 max) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length <= max) return s;
        uint256 end = max;
        // Never split a multi-byte UTF-8 character.
        while (end > 0 && (uint8(b[end]) & 0xC0) == 0x80) {
            --end;
        }
        bytes memory out = new bytes(end);
        for (uint256 i; i < end; ++i) {
            out[i] = b[i];
        }
        return string.concat(string(out), unicode"…");
    }

    /// @dev Ends in .mp4 or .webm (any case), before any ?query.
    function _isVideo(string memory uri) internal pure returns (bool) {
        bytes memory b = bytes(uri);
        uint256 end = b.length;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == "?" || b[i] == "#") {
                end = i;
                break;
            }
        }
        return _endsWith(b, end, ".mp4") || _endsWith(b, end, ".webm");
    }

    function _endsWith(bytes memory b, uint256 end, string memory suffix) internal pure returns (bool) {
        bytes memory x = bytes(suffix);
        if (end < x.length) return false;
        for (uint256 i; i < x.length; ++i) {
            bytes1 ch = b[end - x.length + i];
            if (ch >= "A" && ch <= "Z") ch = bytes1(uint8(ch) + 32);
            if (ch != x[i]) return false;
        }
        return true;
    }

    /// @dev XML escaping for text placed inside the SVG.
    function _xml(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch == "&") out = abi.encodePacked(out, "&amp;");
            else if (ch == "<") out = abi.encodePacked(out, "&lt;");
            else if (ch == ">") out = abi.encodePacked(out, "&gt;");
            else if (ch == '"') out = abi.encodePacked(out, "&quot;");
            else if (ch == "'") out = abi.encodePacked(out, "&#39;");
            else if (uint8(ch) >= 0x20) out = abi.encodePacked(out, ch);
        }
        return string(out);
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

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981, IERC165) returns (bool) {
        return interfaceId == type(IERC4907).interfaceId || interfaceId == bytes4(0x49064906)
            || super.supportsInterface(interfaceId);
    }
}
