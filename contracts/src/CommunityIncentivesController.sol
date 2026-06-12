// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Community incentives release controller
/// @notice Enforces cumulative on-chain release caps over the 35% community allocation.
contract CommunityIncentivesController is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint64 public constant YEAR = 365 days;

    IERC20 public immutable token;
    uint256 public immutable maxSupply;
    uint64 public immutable genesisTimestamp;
    uint256 public immutable totalCommunityAllocation;

    uint256 public cumulativeReleased;
    uint64 public epochDuration;
    uint256 public maxReleasePerEpoch;

    mapping(uint256 epoch => uint256 amount) public releasedByEpoch;

    event CommunityIncentiveReleased(
        address indexed recipient, uint256 amount, bytes32 indexed programId, uint256 cumulativeReleased
    );
    event EpochReleaseCapUpdated(uint64 epochDuration, uint256 maxReleasePerEpoch);

    error InvalidControllerConfig();
    error InvalidRecipient();
    error ReleaseAboveAvailable(uint256 requested, uint256 available);
    error EpochCapExceeded(uint256 requested, uint256 remaining);

    constructor(IERC20 token_, uint256 maxSupply_, uint64 genesisTimestamp_, address initialOwner)
        Ownable(initialOwner)
    {
        if (address(token_) == address(0) || maxSupply_ == 0) {
            revert InvalidControllerConfig();
        }
        token = token_;
        maxSupply = maxSupply_;
        genesisTimestamp = genesisTimestamp_;
        totalCommunityAllocation = (maxSupply_ * 3_500) / BPS_DENOMINATOR;
    }

    function availableToRelease() public view returns (uint256) {
        uint256 cap = cumulativeCapAt(uint64(block.timestamp));
        if (cap <= cumulativeReleased) {
            return 0;
        }
        return cap - cumulativeReleased;
    }

    function cumulativeCapAt(uint64 timestamp) public view returns (uint256) {
        uint16[9] memory annualBps = [uint16(100), 600, 600, 500, 500, 400, 300, 300, 200];
        uint256 elapsedYears = timestamp <= genesisTimestamp ? 0 : (timestamp - genesisTimestamp) / YEAR;
        if (elapsedYears > 8) {
            elapsedYears = 8;
        }

        uint256 bps = 0;
        for (uint256 i = 0; i <= elapsedYears; i++) {
            bps += annualBps[i];
        }
        uint256 cap = (maxSupply * bps) / BPS_DENOMINATOR;
        return cap > totalCommunityAllocation ? totalCommunityAllocation : cap;
    }

    function setEpochReleaseCap(uint64 epochDuration_, uint256 maxReleasePerEpoch_) external onlyOwner {
        if ((epochDuration_ == 0 && maxReleasePerEpoch_ != 0) || maxReleasePerEpoch_ > totalCommunityAllocation) {
            revert InvalidControllerConfig();
        }
        epochDuration = epochDuration_;
        maxReleasePerEpoch = maxReleasePerEpoch_;
        emit EpochReleaseCapUpdated(epochDuration_, maxReleasePerEpoch_);
    }

    function release(address recipient, uint256 amount, bytes32 programId) external onlyOwner nonReentrant {
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }
        uint256 available = availableToRelease();
        if (amount == 0 || amount > available) {
            revert ReleaseAboveAvailable(amount, available);
        }
        if (epochDuration != 0 && maxReleasePerEpoch != 0) {
            uint256 epoch = (block.timestamp - genesisTimestamp) / epochDuration;
            uint256 remaining =
                maxReleasePerEpoch > releasedByEpoch[epoch] ? maxReleasePerEpoch - releasedByEpoch[epoch] : 0;
            if (amount > remaining) {
                revert EpochCapExceeded(amount, remaining);
            }
            releasedByEpoch[epoch] += amount;
        }

        cumulativeReleased += amount;
        token.safeTransfer(recipient, amount);
        emit CommunityIncentiveReleased(recipient, amount, programId, cumulativeReleased);
    }
}
