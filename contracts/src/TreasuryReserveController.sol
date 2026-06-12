// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Treasury reserve release controller
/// @notice Holds the 20% reserve and releases already-minted tokens to treasury according to the bootstrap/reserve schedule.
contract TreasuryReserveController is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint64 public constant MONTH = 30 days;

    IERC20 public immutable token;
    uint256 public immutable maxSupply;
    uint64 public immutable genesisTimestamp;
    uint256 public immutable bootstrapAllocation;
    uint256 public immutable strategicAllocation;
    uint64 public immutable strategicCliffDuration;
    uint64 public immutable strategicVestingDuration;

    address public treasury;
    uint256 public released;

    event TreasuryReleased(address indexed treasury, uint256 amount, uint256 releasedTotal);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    error InvalidTreasuryConfig();
    error ReleaseAboveAvailable(uint256 requested, uint256 available);

    constructor(IERC20 token_, uint256 maxSupply_, uint64 genesisTimestamp_, address treasury_, address initialOwner)
        Ownable(initialOwner)
    {
        if (address(token_) == address(0) || maxSupply_ == 0 || treasury_ == address(0)) {
            revert InvalidTreasuryConfig();
        }
        token = token_;
        maxSupply = maxSupply_;
        genesisTimestamp = genesisTimestamp_;
        treasury = treasury_;
        bootstrapAllocation = (maxSupply_ * 400) / BPS_DENOMINATOR;
        strategicAllocation = (maxSupply_ * 1_600) / BPS_DENOMINATOR;
        strategicCliffDuration = 6 * MONTH;
        strategicVestingDuration = 60 * MONTH;
    }

    function availableTreasuryAmount(uint64 timestamp) public view returns (uint256) {
        uint256 strategicAvailable = 0;
        uint64 strategicStart = genesisTimestamp + strategicCliffDuration;
        if (timestamp >= strategicStart) {
            uint64 strategicEnd = strategicStart + strategicVestingDuration;
            if (timestamp >= strategicEnd) {
                strategicAvailable = strategicAllocation;
            } else {
                strategicAvailable = (strategicAllocation * (timestamp - strategicStart)) / strategicVestingDuration;
            }
        }
        return bootstrapAllocation + strategicAvailable;
    }

    function releasable() public view returns (uint256) {
        return availableTreasuryAmount(uint64(block.timestamp)) - released;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) {
            revert InvalidTreasuryConfig();
        }
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function releaseToTreasury(uint256 amount) external onlyOwner nonReentrant {
        uint256 available = releasable();
        if (amount == 0 || amount > available) {
            revert ReleaseAboveAvailable(amount, available);
        }
        released += amount;
        token.safeTransfer(treasury, amount);
        emit TreasuryReleased(treasury, amount, released);
    }
}
