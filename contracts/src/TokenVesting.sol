// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Reusable fixed-allocation ERC-20 vesting contract
/// @notice Releases already-held tokens to one beneficiary. It never mints.
contract TokenVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable beneficiary;
    uint64 public immutable start;
    uint64 public immutable cliffDuration;
    uint64 public immutable vestingDuration;
    uint256 public immutable totalAllocation;

    uint256 public released;

    event TokensReleased(address indexed beneficiary, uint256 amount, uint256 releasedTotal);

    error InvalidVestingConfig();
    error NothingToRelease();

    constructor(
        IERC20 token_,
        address beneficiary_,
        uint64 start_,
        uint64 cliffDuration_,
        uint64 vestingDuration_,
        uint256 totalAllocation_
    ) {
        if (
            address(token_) == address(0) || beneficiary_ == address(0) || vestingDuration_ == 0
                || totalAllocation_ == 0
        ) {
            revert InvalidVestingConfig();
        }
        token = token_;
        beneficiary = beneficiary_;
        start = start_;
        cliffDuration = cliffDuration_;
        vestingDuration = vestingDuration_;
        totalAllocation = totalAllocation_;
    }

    function cliffEnd() public view returns (uint64) {
        return start + cliffDuration;
    }

    function vestingEnd() public view returns (uint64) {
        return start + cliffDuration + vestingDuration;
    }

    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        uint64 cliffEnd_ = cliffEnd();
        if (timestamp < cliffEnd_) {
            return 0;
        }
        uint64 end = vestingEnd();
        if (timestamp >= end) {
            return totalAllocation;
        }
        return (totalAllocation * (timestamp - cliffEnd_)) / vestingDuration;
    }

    function releasable() public view returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released;
    }

    function release() external nonReentrant returns (uint256 amount) {
        amount = releasable();
        if (amount == 0) {
            revert NothingToRelease();
        }
        released += amount;
        token.safeTransfer(beneficiary, amount);
        emit TokensReleased(beneficiary, amount, released);
    }
}
