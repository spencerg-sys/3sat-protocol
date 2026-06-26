// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Burnable } from "./interfaces/IERC20Burnable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Routes protocol fees and slashing remainders between burn and treasury.
/// @notice Routing is configured per ERC-20 token. Burnable tokens such as 3SAT can burn a share; non-burnable
/// stablecoins such as USDC should use burnBps = 0 so the full amount routes to treasury.
contract TreasuryRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    address public treasury;
    mapping(address token => uint16 burnBps) public burnBps;

    event PostingFeeRouted(address indexed token, uint256 amount, uint256 burned, uint256 treasuryAmount);
    event SlashRemainderRouted(address indexed token, uint256 amount, uint256 burned, uint256 treasuryAmount);
    event TokenRoutingUpdated(address indexed token, uint16 burnBps, uint16 treasuryBps);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    error InvalidRouterConfig();

    constructor(address treasury_, address initialOwner) Ownable(initialOwner) {
        if (treasury_ == address(0)) {
            revert InvalidRouterConfig();
        }
        treasury = treasury_;
    }

    function treasuryBps(address token) public view returns (uint16) {
        return BPS_DENOMINATOR - burnBps[token];
    }

    function setTokenRouting(address token, uint16 burnBps_) external onlyOwner {
        if (token == address(0) || burnBps_ > BPS_DENOMINATOR) {
            revert InvalidRouterConfig();
        }
        burnBps[token] = burnBps_;
        emit TokenRoutingUpdated(token, burnBps_, BPS_DENOMINATOR - burnBps_);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) {
            revert InvalidRouterConfig();
        }
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function routePostingFee(address token, uint256 amount) external nonReentrant {
        (uint256 burned, uint256 treasuryAmount) = _route(token, amount);
        emit PostingFeeRouted(token, amount, burned, treasuryAmount);
    }

    function routeSlashRemainder(address token, uint256 amount) external nonReentrant {
        (uint256 burned, uint256 treasuryAmount) = _route(token, amount);
        emit SlashRemainderRouted(token, amount, burned, treasuryAmount);
    }

    function _route(address token, uint256 amount) internal returns (uint256 burned, uint256 treasuryAmount) {
        if (token == address(0)) {
            revert InvalidRouterConfig();
        }
        if (amount == 0) {
            return (0, 0);
        }
        burned = (amount * burnBps[token]) / BPS_DENOMINATOR;
        treasuryAmount = amount - burned;
        if (burned != 0) {
            IERC20Burnable(token).burn(burned);
        }
        if (treasuryAmount != 0) {
            IERC20(token).safeTransfer(treasury, treasuryAmount);
        }
    }
}
