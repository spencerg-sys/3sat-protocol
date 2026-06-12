// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Burnable } from "./interfaces/IERC20Burnable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Routes protocol fees and slashing remainders between burn and treasury.
contract TreasuryRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable token;
    address public treasury;
    uint16 public burnBps;

    event PostingFeeRouted(uint256 amount, uint256 burned, uint256 treasuryAmount);
    event SlashRemainderRouted(uint256 amount, uint256 burned, uint256 treasuryAmount);
    event RoutingParamsUpdated(uint16 burnBps, uint16 treasuryBps);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    error InvalidRouterConfig();

    constructor(IERC20 token_, address treasury_, uint16 burnBps_, address initialOwner) Ownable(initialOwner) {
        if (address(token_) == address(0) || treasury_ == address(0) || burnBps_ > BPS_DENOMINATOR) {
            revert InvalidRouterConfig();
        }
        token = token_;
        treasury = treasury_;
        burnBps = burnBps_;
    }

    function treasuryBps() public view returns (uint16) {
        return BPS_DENOMINATOR - burnBps;
    }

    function setRoutingParams(uint16 burnBps_) external onlyOwner {
        if (burnBps_ > BPS_DENOMINATOR) {
            revert InvalidRouterConfig();
        }
        burnBps = burnBps_;
        emit RoutingParamsUpdated(burnBps_, BPS_DENOMINATOR - burnBps_);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) {
            revert InvalidRouterConfig();
        }
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function routePostingFee(uint256 amount) external nonReentrant {
        (uint256 burned, uint256 treasuryAmount) = _route(amount);
        emit PostingFeeRouted(amount, burned, treasuryAmount);
    }

    function routeSlashRemainder(uint256 amount) external nonReentrant {
        (uint256 burned, uint256 treasuryAmount) = _route(amount);
        emit SlashRemainderRouted(amount, burned, treasuryAmount);
    }

    function _route(uint256 amount) internal returns (uint256 burned, uint256 treasuryAmount) {
        if (amount == 0) {
            return (0, 0);
        }
        burned = (amount * burnBps) / BPS_DENOMINATOR;
        treasuryAmount = amount - burned;
        if (burned != 0) {
            IERC20Burnable(address(token)).burn(burned);
        }
        if (treasuryAmount != 0) {
            token.safeTransfer(treasury, treasuryAmount);
        }
    }
}
