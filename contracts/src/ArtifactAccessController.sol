// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { TreasuryRouter } from "./TreasuryRouter.sol";

interface IBountyManagerAccessView {
    struct Bounty {
        address issuer;
        address paymentToken;
        string instanceCID;
        bytes32 instanceDigest;
        string metadataURI;
        bytes32 metadataDigest;
        uint256 reward;
        uint256 verifierRewardPool;
        uint256 postingFee;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint64 verificationDeadline;
        uint16 verifierQuorum;
        uint256 submissionCount;
        uint256 acceptedCandidateCount;
        bool finalized;
        bool postingFeeRouted;
    }

    function getBounty(uint256 bountyId) external view returns (Bounty memory);

    function finalizedWinningSolver(uint256 bountyId) external view returns (address);
}

/// @title ArtifactAccessController
/// @notice Records token-paid access rights for private protocol artifacts such as finalized solutions.
contract ArtifactAccessController is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_DEFAULT_SOLVER_ACCESS_REWARD_BPS = 1_000;
    uint16 public constant MAX_SOLVER_ROYALTY_BPS = 5_000;

    uint8 public constant ARTIFACT_INSTANCE = 1;
    uint8 public constant ARTIFACT_SOLUTION = 2;
    uint8 public constant ARTIFACT_EVIDENCE = 3;

    IBountyManagerAccessView public bountyManager;
    TreasuryRouter public treasuryRouter;
    address public defaultPaymentToken;
    bool public defaultAccessUsesBountyPaymentToken;
    uint16 public defaultSolverAccessRewardBps;
    uint16 public solverRoyaltyBps;

    struct PriceConfig {
        bool set;
        uint256 price;
    }

    mapping(uint8 artifactType => bool enabled) public artifactTypeEnabled;
    mapping(address paymentToken => bool accepted) public acceptedPaymentToken;
    mapping(uint256 bountyId => mapping(uint8 artifactType => mapping(address paymentToken => PriceConfig))) private
        customAccessPrices;
    mapping(address user => mapping(uint256 bountyId => mapping(uint8 artifactType => bool))) private purchasedAccess;

    event AccessPurchased(
        address indexed user, uint256 indexed bountyId, uint8 indexed artifactType, address paymentToken, uint256 price
    );
    event AccessFeeDistributed(
        uint256 indexed bountyId,
        uint8 indexed artifactType,
        address paymentToken,
        address solver,
        uint256 solverAmount,
        uint256 routedAmount
    );
    event AccessGranted(address indexed user, uint256 indexed bountyId, uint8 indexed artifactType);
    event PaymentTokenConfigured(address indexed paymentToken, bool accepted);
    event DefaultPaymentTokenUpdated(address indexed paymentToken);
    event DefaultAccessPaymentPolicyUpdated(bool usesBountyPaymentToken);
    event DefaultSolverAccessRewardBpsUpdated(uint16 rewardBps);
    event AccessPriceUpdated(uint256 indexed bountyId, uint8 indexed artifactType, address paymentToken, uint256 price);
    event ArtifactTypeEnabled(uint8 indexed artifactType, bool enabled);
    event BountyManagerUpdated(address indexed bountyManager);
    event TreasuryRouterUpdated(address indexed treasuryRouter);
    event SolverRoyaltyBpsUpdated(uint16 solverRoyaltyBps);

    error InvalidAccessConfig();
    error InvalidArtifactType();
    error UnknownBounty();
    error BountyNotFinalized();
    error NoFinalizedSolution();
    error ArtifactTypeDisabled();

    constructor(
        IBountyManagerAccessView bountyManager_,
        TreasuryRouter treasuryRouter_,
        address defaultPaymentToken_,
        uint16 defaultSolverAccessRewardBps_,
        uint16 solverRoyaltyBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            address(bountyManager_) == address(0) || address(treasuryRouter_) == address(0)
                || defaultPaymentToken_ == address(0)
                || defaultSolverAccessRewardBps_ > MAX_DEFAULT_SOLVER_ACCESS_REWARD_BPS
                || solverRoyaltyBps_ > MAX_SOLVER_ROYALTY_BPS || initialOwner == address(0)
                || (defaultSolverAccessRewardBps_ != 0 && solverRoyaltyBps_ == 0)
        ) {
            revert InvalidAccessConfig();
        }

        bountyManager = bountyManager_;
        treasuryRouter = treasuryRouter_;
        defaultPaymentToken = defaultPaymentToken_;
        defaultAccessUsesBountyPaymentToken = true;
        acceptedPaymentToken[defaultPaymentToken_] = true;
        defaultSolverAccessRewardBps = defaultSolverAccessRewardBps_;
        solverRoyaltyBps = solverRoyaltyBps_;
        artifactTypeEnabled[ARTIFACT_INSTANCE] = true;
        artifactTypeEnabled[ARTIFACT_SOLUTION] = true;
        artifactTypeEnabled[ARTIFACT_EVIDENCE] = true;
    }

    function setBountyManager(IBountyManagerAccessView bountyManager_) external onlyOwner {
        if (address(bountyManager_) == address(0)) {
            revert InvalidAccessConfig();
        }
        bountyManager = bountyManager_;
        emit BountyManagerUpdated(address(bountyManager_));
    }

    function setTreasuryRouter(TreasuryRouter treasuryRouter_) external onlyOwner {
        if (address(treasuryRouter_) == address(0)) {
            revert InvalidAccessConfig();
        }
        treasuryRouter = treasuryRouter_;
        emit TreasuryRouterUpdated(address(treasuryRouter_));
    }

    function setPaymentTokenConfig(address paymentToken, bool accepted) external onlyOwner {
        if (paymentToken == address(0)) {
            revert InvalidAccessConfig();
        }
        acceptedPaymentToken[paymentToken] = accepted;
        emit PaymentTokenConfigured(paymentToken, accepted);
    }

    function setDefaultPaymentToken(address paymentToken) external onlyOwner {
        if (paymentToken == address(0) || !acceptedPaymentToken[paymentToken]) {
            revert InvalidAccessConfig();
        }
        defaultPaymentToken = paymentToken;
        emit DefaultPaymentTokenUpdated(paymentToken);
    }

    function setDefaultAccessUsesBountyPaymentToken(bool enabled) external onlyOwner {
        defaultAccessUsesBountyPaymentToken = enabled;
        emit DefaultAccessPaymentPolicyUpdated(enabled);
    }

    function setDefaultSolverAccessRewardBps(uint16 rewardBps) external onlyOwner {
        if (rewardBps > MAX_DEFAULT_SOLVER_ACCESS_REWARD_BPS || (rewardBps != 0 && solverRoyaltyBps == 0)) {
            revert InvalidAccessConfig();
        }
        defaultSolverAccessRewardBps = rewardBps;
        emit DefaultSolverAccessRewardBpsUpdated(rewardBps);
    }

    function setSolverRoyaltyBps(uint16 solverRoyaltyBps_) external onlyOwner {
        if (solverRoyaltyBps_ > MAX_SOLVER_ROYALTY_BPS || (defaultSolverAccessRewardBps != 0 && solverRoyaltyBps_ == 0))
        {
            revert InvalidAccessConfig();
        }
        solverRoyaltyBps = solverRoyaltyBps_;
        emit SolverRoyaltyBpsUpdated(solverRoyaltyBps_);
    }

    function setArtifactTypeEnabled(uint8 artifactType, bool enabled) external onlyOwner {
        _requireValidArtifactType(artifactType);
        artifactTypeEnabled[artifactType] = enabled;
        emit ArtifactTypeEnabled(artifactType, enabled);
    }

    function setAccessPrice(uint256 bountyId, uint8 artifactType, address paymentToken, uint256 price)
        external
        onlyOwner
    {
        _requireValidArtifactType(artifactType);
        if (paymentToken == address(0) || !acceptedPaymentToken[paymentToken]) {
            revert InvalidAccessConfig();
        }
        customAccessPrices[bountyId][artifactType][paymentToken] = PriceConfig({ set: true, price: price });
        emit AccessPriceUpdated(bountyId, artifactType, paymentToken, price);
    }

    function grantAccess(address user, uint256 bountyId, uint8 artifactType) external onlyOwner {
        if (user == address(0)) {
            revert InvalidAccessConfig();
        }
        _requireValidArtifactType(artifactType);
        _requireKnownBounty(bountyId);
        purchasedAccess[user][bountyId][artifactType] = true;
        emit AccessGranted(user, bountyId, artifactType);
    }

    function purchaseAccess(uint256 bountyId, uint8 artifactType) external nonReentrant {
        _purchaseAccess(bountyId, artifactType, _defaultPaymentTokenFor(bountyId, artifactType));
    }

    function purchaseAccess(uint256 bountyId, uint8 artifactType, address paymentToken) external nonReentrant {
        _purchaseAccess(bountyId, artifactType, paymentToken);
    }

    function _purchaseAccess(uint256 bountyId, uint8 artifactType, address paymentToken) internal {
        if (paymentToken == address(0) || !acceptedPaymentToken[paymentToken]) {
            revert InvalidAccessConfig();
        }
        IBountyManagerAccessView.Bounty memory bounty = _requirePurchaseAvailable(bountyId, artifactType);

        if (
            artifactType == ARTIFACT_SOLUTION && paymentToken != bounty.paymentToken
                && !customAccessPrices[bountyId][artifactType][paymentToken].set
        ) {
            revert InvalidAccessConfig();
        }

        if (purchasedAccess[msg.sender][bountyId][artifactType]) {
            return;
        }
        if (msg.sender == bounty.issuer) {
            purchasedAccess[msg.sender][bountyId][artifactType] = true;
            emit AccessGranted(msg.sender, bountyId, artifactType);
            return;
        }

        uint256 price = accessPrice(bountyId, artifactType, paymentToken);
        if (price != 0) {
            (, address solver, uint256 solverAmount, uint256 routedAmount) =
                accessDistribution(bountyId, artifactType, paymentToken);
            if (solverAmount != 0) {
                IERC20(paymentToken).safeTransferFrom(msg.sender, solver, solverAmount);
            }
            if (routedAmount != 0) {
                IERC20(paymentToken).safeTransferFrom(msg.sender, address(treasuryRouter), routedAmount);
                treasuryRouter.routePostingFee(paymentToken, routedAmount);
            }
            emit AccessFeeDistributed(bountyId, artifactType, paymentToken, solver, solverAmount, routedAmount);
        }

        purchasedAccess[msg.sender][bountyId][artifactType] = true;
        emit AccessPurchased(msg.sender, bountyId, artifactType, paymentToken, price);
    }

    function accessPrice(uint256 bountyId, uint8 artifactType) public view returns (uint256) {
        return accessPrice(bountyId, artifactType, _defaultPaymentTokenFor(bountyId, artifactType));
    }

    function accessPrice(uint256 bountyId, uint8 artifactType, address paymentToken) public view returns (uint256) {
        _requireValidArtifactType(artifactType);
        if (paymentToken == address(0) || !acceptedPaymentToken[paymentToken]) {
            return 0;
        }
        PriceConfig memory config = customAccessPrices[bountyId][artifactType][paymentToken];
        if (config.set) {
            return config.price;
        }
        if (artifactType != ARTIFACT_SOLUTION || defaultSolverAccessRewardBps == 0) {
            return 0;
        }
        IBountyManagerAccessView.Bounty memory bounty = _requireKnownBounty(bountyId);
        if (paymentToken != bounty.paymentToken) {
            return 0;
        }
        uint256 targetSolverReward = (bounty.reward * defaultSolverAccessRewardBps) / BPS_DENOMINATOR;
        return _ceilDiv(targetSolverReward * BPS_DENOMINATOR, solverRoyaltyBps);
    }

    function accessDistribution(uint256 bountyId, uint8 artifactType)
        public
        view
        returns (uint256 price, address solver, uint256 solverAmount, uint256 routedAmount)
    {
        return accessDistribution(bountyId, artifactType, _defaultPaymentTokenFor(bountyId, artifactType));
    }

    function accessDistribution(uint256 bountyId, uint8 artifactType, address paymentToken)
        public
        view
        returns (uint256 price, address solver, uint256 solverAmount, uint256 routedAmount)
    {
        price = accessPrice(bountyId, artifactType, paymentToken);
        if (artifactType == ARTIFACT_SOLUTION) {
            solver = bountyManager.finalizedWinningSolver(bountyId);
            solverAmount = (price * solverRoyaltyBps) / BPS_DENOMINATOR;
        }
        routedAmount = price - solverAmount;
    }

    function hasAccess(address user, uint256 bountyId, uint8 artifactType) public view returns (bool) {
        return purchasedAccess[user][bountyId][artifactType];
    }

    function canAccess(address user, uint256 bountyId, uint8 artifactType) external view returns (bool) {
        if (!_isValidArtifactType(artifactType) || !artifactTypeEnabled[artifactType]) {
            return false;
        }
        IBountyManagerAccessView.Bounty memory bounty = bountyManager.getBounty(bountyId);
        if (bounty.issuer == address(0)) {
            return false;
        }
        if (artifactType == ARTIFACT_SOLUTION) {
            if (!bounty.finalized || bountyManager.finalizedWinningSolver(bountyId) == address(0)) {
                return false;
            }
        }
        if (user == bounty.issuer) {
            return true;
        }
        if (hasAccess(user, bountyId, artifactType)) {
            return true;
        }
        return accessPrice(bountyId, artifactType, bounty.paymentToken) == 0;
    }

    function _defaultPaymentTokenFor(uint256 bountyId, uint8 artifactType) internal view returns (address) {
        IBountyManagerAccessView.Bounty memory bounty = _requireKnownBounty(bountyId);
        if (defaultAccessUsesBountyPaymentToken) {
            return bounty.paymentToken;
        }
        PriceConfig memory config = customAccessPrices[bountyId][artifactType][defaultPaymentToken];
        if (config.set || defaultPaymentToken == bounty.paymentToken) {
            return defaultPaymentToken;
        }
        return bounty.paymentToken;
    }

    function _requirePurchaseAvailable(uint256 bountyId, uint8 artifactType)
        internal
        view
        returns (IBountyManagerAccessView.Bounty memory bounty)
    {
        _requireValidArtifactType(artifactType);
        if (!artifactTypeEnabled[artifactType]) {
            revert ArtifactTypeDisabled();
        }

        bounty = _requireKnownBounty(bountyId);
        if (artifactType == ARTIFACT_SOLUTION && !bounty.finalized) {
            revert BountyNotFinalized();
        }
        if (artifactType == ARTIFACT_SOLUTION && bountyManager.finalizedWinningSolver(bountyId) == address(0)) {
            revert NoFinalizedSolution();
        }
    }

    function _requireKnownBounty(uint256 bountyId)
        internal
        view
        returns (IBountyManagerAccessView.Bounty memory bounty)
    {
        bounty = bountyManager.getBounty(bountyId);
        if (bounty.issuer == address(0)) {
            revert UnknownBounty();
        }
    }

    function _requireValidArtifactType(uint8 artifactType) internal pure {
        if (!_isValidArtifactType(artifactType)) {
            revert InvalidArtifactType();
        }
    }

    function _isValidArtifactType(uint8 artifactType) internal pure returns (bool) {
        return
            artifactType == ARTIFACT_INSTANCE || artifactType == ARTIFACT_SOLUTION || artifactType == ARTIFACT_EVIDENCE;
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (numerator == 0) {
            return 0;
        }
        return ((numerator - 1) / denominator) + 1;
    }
}
