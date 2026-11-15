// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AgentcityPlacementMarket} from "../src/AgentcityPlacementMarket.sol";

contract MockUSDG is ERC20 {
    constructor() ERC20("Mock USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Burns 1% of every transfer: the market must refuse it.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

/// A receiver that refuses ETH: it must not be able to block a sale.
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

/// A bidder with no onERC721Received, like a contract wallet without the
/// receiver hook: it must not be able to block settlement.
contract NoReceiverBidder {
    function bid(AgentcityPlacementMarket m, address c, uint256 id) external payable {
        m.bid{value: msg.value}(c, id, msg.value);
    }

    function claim(AgentcityPlacementMarket m, address c, uint256 id, address to) external {
        m.claim(c, id, to);
    }
}

/// A seller with no onERC721Received: its token must still come back.
contract NoReceiverSeller {
    function start(AgentcityPlacementMarket m, address c, uint256 id) external {
        IERC721(c).approve(address(m), id);
        m.startAuction(c, id, address(0), 1 ether, 0, uint64(block.timestamp + 1 days));
    }

    function cancel(AgentcityPlacementMarket m, address c, uint256 id) external {
        m.cancelAuction(c, id);
    }
}
