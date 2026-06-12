// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20Burnable } from "./interfaces/IERC20Burnable.sol";

/// @title VerifierRegistry
/// @notice Verifiers stake 3SAT to become eligible for bounty attestations.
contract VerifierRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant DEFAULT_OFFICIAL_SLASH_BPS = 5_000;

    struct Verifier {
        uint256 activeStake;
        uint256 pendingUnstake;
        uint64 unstakeReadyAt;
        string metadataURI;
        bool registered;
        bool enabled;
    }

    IERC20 public immutable token;
    uint256 public minimumStake;
    uint64 public unbondingDelay;
    address public bountyManager;

    mapping(address verifier => Verifier) private verifiers;

    event VerifierRegistered(address indexed verifier, string metadataURI);
    event StakeDeposited(address indexed verifier, uint256 amount, uint256 activeStake);
    event UnstakeRequested(address indexed verifier, uint256 amount, uint64 readyAt);
    event StakeWithdrawn(address indexed verifier, uint256 amount);
    event VerifierEligibilityChanged(address indexed verifier, bool eligible);
    event VerifierSlashed(address indexed verifier, uint256 amount, uint16 slashBps);
    event MinimumStakeUpdated(uint256 minimumStake);
    event UnbondingDelayUpdated(uint64 unbondingDelay);
    event BountyManagerUpdated(address indexed bountyManager);

    error InvalidRegistryConfig();
    error InvalidAmount();
    error InsufficientStake();
    error NothingToWithdraw();
    error UnbondingDelayNotElapsed(uint64 readyAt);

    constructor(IERC20 token_, uint256 minimumStake_, uint64 unbondingDelay_, address initialOwner)
        Ownable(initialOwner)
    {
        if (address(token_) == address(0) || minimumStake_ == 0 || unbondingDelay_ == 0) {
            revert InvalidRegistryConfig();
        }
        token = token_;
        minimumStake = minimumStake_;
        unbondingDelay = unbondingDelay_;
    }

    function getVerifier(address verifier) external view returns (Verifier memory) {
        return verifiers[verifier];
    }

    function isEligible(address verifier) public view returns (bool) {
        Verifier storage data = verifiers[verifier];
        return data.registered && data.enabled && data.activeStake >= minimumStake;
    }

    function stake(uint256 amount, string calldata metadataURI) external nonReentrant {
        if (amount == 0) {
            revert InvalidAmount();
        }

        Verifier storage data = verifiers[msg.sender];
        bool wasEligible = isEligible(msg.sender);

        if (!data.registered) {
            data.registered = true;
            data.enabled = true;
            data.metadataURI = metadataURI;
            emit VerifierRegistered(msg.sender, metadataURI);
        } else if (bytes(metadataURI).length != 0) {
            data.metadataURI = metadataURI;
        }

        data.activeStake += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);

        emit StakeDeposited(msg.sender, amount, data.activeStake);
        _emitEligibilityIfChanged(msg.sender, wasEligible);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        Verifier storage data = verifiers[msg.sender];
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (amount > data.activeStake) {
            revert InsufficientStake();
        }

        bool wasEligible = isEligible(msg.sender);
        data.activeStake -= amount;
        data.pendingUnstake += amount;
        data.unstakeReadyAt = uint64(block.timestamp) + unbondingDelay;

        emit UnstakeRequested(msg.sender, amount, data.unstakeReadyAt);
        _emitEligibilityIfChanged(msg.sender, wasEligible);
    }

    function withdrawUnstaked() external nonReentrant {
        Verifier storage data = verifiers[msg.sender];
        uint256 amount = data.pendingUnstake;
        if (amount == 0) {
            revert NothingToWithdraw();
        }
        if (block.timestamp < data.unstakeReadyAt) {
            revert UnbondingDelayNotElapsed(data.unstakeReadyAt);
        }

        data.pendingUnstake = 0;
        data.unstakeReadyAt = 0;
        token.safeTransfer(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount);
    }

    function setVerifierEligibility(address verifier, bool enabled) external onlyOwner {
        bool wasEligible = isEligible(verifier);
        Verifier storage data = verifiers[verifier];
        data.enabled = enabled;
        bool eligible = isEligible(verifier);
        if (eligible != wasEligible) {
            emit VerifierEligibilityChanged(verifier, eligible);
        }
    }

    function slashAndDisable(address verifier, uint16 slashBps) external onlyOwner nonReentrant {
        _slashAndDisable(verifier, slashBps);
    }

    function slashAndDisable(address verifier) external onlyOwner nonReentrant {
        _slashAndDisable(verifier, DEFAULT_OFFICIAL_SLASH_BPS);
    }

    function setMinimumStake(uint256 minimumStake_) external onlyOwner {
        if (minimumStake_ == 0) {
            revert InvalidRegistryConfig();
        }
        minimumStake = minimumStake_;
        emit MinimumStakeUpdated(minimumStake_);
    }

    function setUnbondingDelay(uint64 unbondingDelay_) external onlyOwner {
        if (unbondingDelay_ == 0) {
            revert InvalidRegistryConfig();
        }
        unbondingDelay = unbondingDelay_;
        emit UnbondingDelayUpdated(unbondingDelay_);
    }

    function setBountyManager(address bountyManager_) external onlyOwner {
        if (bountyManager_ == address(0)) {
            revert InvalidRegistryConfig();
        }
        bountyManager = bountyManager_;
        emit BountyManagerUpdated(bountyManager_);
    }

    function _slashAndDisable(address verifier, uint16 slashBps) internal {
        if (slashBps > BPS_DENOMINATOR) {
            revert InvalidAmount();
        }

        Verifier storage data = verifiers[verifier];
        bool wasEligible = isEligible(verifier);
        uint256 slashBase = data.activeStake + data.pendingUnstake;
        uint256 slashAmount = (slashBase * slashBps) / BPS_DENOMINATOR;

        data.enabled = false;
        uint256 remaining = slashAmount;
        if (remaining != 0) {
            if (data.activeStake >= remaining) {
                data.activeStake -= remaining;
                remaining = 0;
            } else {
                remaining -= data.activeStake;
                data.activeStake = 0;
            }

            if (remaining != 0) {
                data.pendingUnstake -= remaining;
                if (data.pendingUnstake == 0) {
                    data.unstakeReadyAt = 0;
                }
            }
            IERC20Burnable(address(token)).burn(slashAmount);
        }

        emit VerifierSlashed(verifier, slashAmount, slashBps);
        _emitEligibilityIfChanged(verifier, wasEligible);
    }

    function _emitEligibilityIfChanged(address verifier, bool wasEligible) internal {
        bool eligible = isEligible(verifier);
        if (eligible != wasEligible) {
            emit VerifierEligibilityChanged(verifier, eligible);
        }
    }
}
