// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice ERC-4907: rentable NFTs. A "user" may use a token until `expires`
/// without owning it. For an Agentcity placement the user is the renter, and
/// using it means choosing the ad it shows.
interface IERC4907 {
    event UpdateUser(uint256 indexed tokenId, address indexed user, uint64 expires);

    function setUser(uint256 tokenId, address user, uint64 expires) external;

    /// @return The current user, or address(0) when nobody rents the token.
    function userOf(uint256 tokenId) external view returns (address);

    function userExpires(uint256 tokenId) external view returns (uint256);
}
