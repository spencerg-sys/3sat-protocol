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

    /// @notice Describes whether a particular artifact/payment-token route can be used.
    /// @dev The numeric values are part of the external ABI. Keep this order stable.
    enum AccessStatus {
        Unconfigured,
        Public,
        Priced,
        Disabled
    }

    IBountyManagerAccessView public bountyManager;
    uint256 public bountyManagerEpoch;
    mapping(uint256 epoch => address manager) public bountyManagerForEpoch;
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
    mapping(
        uint256 managerEpoch
            => mapping(uint256 bountyId => mapping(uint8 artifactType => mapping(address paymentToken => PriceConfig)))
    ) private customAccessPrices;
    mapping(
        uint256 managerEpoch
            => mapping(address user => mapping(uint256 bountyId => mapping(uint8 artifactType => bool)))
    ) private purchasedAccess;

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
    event BountyManagerEpochUpdated(
        uint256 indexed previousEpoch, uint256 indexed newEpoch, address indexed bountyManager
    );
    event TreasuryRouterUpdated(address indexed treasuryRouter);
    event SolverRoyaltyBpsUpdated(uint16 solverRoyaltyBps);

    error InvalidAccessConfig();
    error InvalidArtifactType();
    error UnknownBounty();
    error BountyNotFinalized();
    error NoFinalizedSolution();
    error ArtifactTypeDisabled();
    error ProtectedPurchaseRequired();
    error AccessPriceUnconfigured();
    error PaymentTokenDisabled();
    error AccessPriceAboveMaximum(uint256 price, uint256 maxPrice);
    error AccessDeadlineExpired(uint256 deadline, uint256 currentTimestamp);
    error BountyManagerEpochMismatch(uint256 expectedEpoch, uint256 currentEpoch);

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
        bountyManagerEpoch = 1;
        bountyManagerForEpoch[1] = address(bountyManager_);
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

        if (address(bountyManager_) == address(bountyManager)) {
            emit BountyManagerUpdated(address(bountyManager_));
            return;
        }

        uint256 previousEpoch = bountyManagerEpoch;
        uint256 newEpoch = previousEpoch + 1;
        bountyManager = bountyManager_;
        bountyManagerEpoch = newEpoch;
        bountyManagerForEpoch[newEpoch] = address(bountyManager_);
        emit BountyManagerUpdated(address(bountyManager_));
        emit BountyManagerEpochUpdated(previousEpoch, newEpoch, address(bountyManager_));
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
        customAccessPrices[bountyManagerEpoch][bountyId][artifactType][paymentToken] =
            PriceConfig({ set: true, price: price });
        emit AccessPriceUpdated(bountyId, artifactType, paymentToken, price);
    }

    function grantAccess(address user, uint256 bountyId, uint8 artifactType) external onlyOwner {
        if (user == address(0)) {
            revert InvalidAccessConfig();
        }
        _requireValidArtifactType(artifactType);
        _requireKnownBounty(bountyId);
        purchasedAccess[bountyManagerEpoch][user][bountyId][artifactType] = true;
        emit AccessGranted(user, bountyId, artifactType);
    }

    function purchaseAccess(uint256 bountyId, uint8 artifactType) external nonReentrant {
        _purchaseAccess(
            bountyId, artifactType, _defaultPaymentTokenFor(bountyId, artifactType), false, type(uint256).max
        );
    }

    function purchaseAccess(uint256 bountyId, uint8 artifactType, address paymentToken) external nonReentrant {
        _purchaseAccess(bountyId, artifactType, paymentToken, false, type(uint256).max);
    }

    /// @notice Purchases access while binding the transaction to a maximum price and deadline.
    /// @dev Paid purchases must use this overload. The legacy overloads remain available for
    ///      issuer, previously granted/purchased, and public access paths only.
    function purchaseAccess(
        uint256 bountyId,
        uint8 artifactType,
        address paymentToken,
        uint256 maxPrice,
        uint256 deadline,
        uint256 expectedManagerEpoch
    ) external nonReentrant {
        uint256 currentEpoch = bountyManagerEpoch;
        if (expectedManagerEpoch != currentEpoch) {
            revert BountyManagerEpochMismatch(expectedManagerEpoch, currentEpoch);
        }
        if (block.timestamp > deadline) {
            revert AccessDeadlineExpired(deadline, block.timestamp);
        }

        _purchaseAccess(bountyId, artifactType, paymentToken, true, maxPrice);
    }

    function _purchaseAccess(
        uint256 bountyId,
        uint8 artifactType,
        address paymentToken,
        bool priceProtected,
        uint256 maxPrice
    ) internal {
        IBountyManagerAccessView.Bounty memory bounty = _requirePurchaseAvailable(bountyId, artifactType);
        uint256 currentEpoch = bountyManagerEpoch;

        if (purchasedAccess[currentEpoch][msg.sender][bountyId][artifactType]) {
            return;
        }
        if (msg.sender == bounty.issuer) {
            purchasedAccess[currentEpoch][msg.sender][bountyId][artifactType] = true;
            emit AccessGranted(msg.sender, bountyId, artifactType);
            return;
        }

        (AccessStatus status, uint256 price) =
            _resolveAccessQuote(currentEpoch, bountyId, artifactType, paymentToken, bounty);
        if (status == AccessStatus.Unconfigured) {
            revert AccessPriceUnconfigured();
        }
        if (status == AccessStatus.Disabled) {
            revert PaymentTokenDisabled();
        }
        if (status == AccessStatus.Priced) {
            if (!priceProtected) {
                revert ProtectedPurchaseRequired();
            }
            if (price > maxPrice) {
                revert AccessPriceAboveMaximum(price, maxPrice);
            }

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

        purchasedAccess[currentEpoch][msg.sender][bountyId][artifactType] = true;
        emit AccessPurchased(msg.sender, bountyId, artifactType, paymentToken, price);
    }

    function accessPrice(uint256 bountyId, uint8 artifactType) public view returns (uint256) {
        (AccessStatus status,, uint256 price) = accessQuote(bountyId, artifactType);
        return status == AccessStatus.Priced ? price : 0;
    }

    function accessPrice(uint256 bountyId, uint8 artifactType, address paymentToken) public view returns (uint256) {
        (AccessStatus status, uint256 price) = accessQuote(bountyId, artifactType, paymentToken);
        return status == AccessStatus.Priced ? price : 0;
    }

    /// @notice Returns the status, selected payment token, and current price for the default route.
    function accessQuote(uint256 bountyId, uint8 artifactType)
        public
        view
        returns (AccessStatus status, address paymentToken, uint256 price)
    {
        paymentToken = _defaultPaymentTokenFor(bountyId, artifactType);
        (status, price) = accessQuote(bountyId, artifactType, paymentToken);
    }

    /// @notice Returns the status and current price for a specific payment-token route.
    /// @dev A zero price is meaningful only when status is Public. Callers must not infer
    ///      authorization from the numeric price alone.
    function accessQuote(uint256 bountyId, uint8 artifactType, address paymentToken)
        public
        view
        returns (AccessStatus status, uint256 price)
    {
        _requireValidArtifactType(artifactType);
        IBountyManagerAccessView.Bounty memory bounty = _requireKnownBounty(bountyId);
        return _resolveAccessQuote(bountyManagerEpoch, bountyId, artifactType, paymentToken, bounty);
    }

    /// @notice Atomically returns the manager epoch and quote for the default payment route.
    /// @dev Pass the returned epoch to the protected purchase overload.
    function accessQuoteWithEpoch(uint256 bountyId, uint8 artifactType)
        public
        view
        returns (uint256 epoch, AccessStatus status, address paymentToken, uint256 price)
    {
        _requireValidArtifactType(artifactType);
        IBountyManagerAccessView.Bounty memory bounty = _requireKnownBounty(bountyId);
        epoch = bountyManagerEpoch;
        paymentToken = _defaultPaymentTokenFor(bountyId, artifactType, bounty);
        (status, price) = _resolveAccessQuote(epoch, bountyId, artifactType, paymentToken, bounty);
    }

    /// @notice Atomically returns the manager epoch and quote for a specific payment route.
    /// @dev Pass the returned epoch to the protected purchase overload.
    function accessQuoteWithEpoch(uint256 bountyId, uint8 artifactType, address paymentToken)
        public
        view
        returns (uint256 epoch, AccessStatus status, uint256 price)
    {
        _requireValidArtifactType(artifactType);
        IBountyManagerAccessView.Bounty memory bounty = _requireKnownBounty(bountyId);
        epoch = bountyManagerEpoch;
        (status, price) = _resolveAccessQuote(epoch, bountyId, artifactType, paymentToken, bounty);
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
        return hasAccessAtEpoch(bountyManagerEpoch, user, bountyId, artifactType);
    }

    /// @notice Returns a stored access right in a specific manager epoch.
    /// @dev Historical rights remain queryable but are not valid for the current manager unless
    ///      the requested epoch equals bountyManagerEpoch.
    function hasAccessAtEpoch(uint256 managerEpoch, address user, uint256 bountyId, uint8 artifactType)
        public
        view
        returns (bool)
    {
        return purchasedAccess[managerEpoch][user][bountyId][artifactType];
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
        address paymentToken = _defaultPaymentTokenFor(bountyId, artifactType, bounty);
        (AccessStatus status,) = _resolveAccessQuote(bountyManagerEpoch, bountyId, artifactType, paymentToken, bounty);
        return status == AccessStatus.Public;
    }

    function _defaultPaymentTokenFor(uint256 bountyId, uint8 artifactType) internal view returns (address) {
        IBountyManagerAccessView.Bounty memory bounty = _requireKnownBounty(bountyId);
        return _defaultPaymentTokenFor(bountyId, artifactType, bounty);
    }

    function _defaultPaymentTokenFor(
        uint256 bountyId,
        uint8 artifactType,
        IBountyManagerAccessView.Bounty memory bounty
    ) internal view returns (address) {
        if (defaultAccessUsesBountyPaymentToken) {
            return bounty.paymentToken;
        }
        PriceConfig memory config = customAccessPrices[bountyManagerEpoch][bountyId][artifactType][defaultPaymentToken];
        if (config.set || defaultPaymentToken == bounty.paymentToken) {
            return defaultPaymentToken;
        }
        return bounty.paymentToken;
    }

    function _resolveAccessQuote(
        uint256 managerEpoch,
        uint256 bountyId,
        uint8 artifactType,
        address paymentToken,
        IBountyManagerAccessView.Bounty memory bounty
    ) internal view returns (AccessStatus status, uint256 price) {
        if (!artifactTypeEnabled[artifactType]) {
            return (AccessStatus.Disabled, 0);
        }

        PriceConfig memory config = customAccessPrices[managerEpoch][bountyId][artifactType][paymentToken];
        address defaultToken = _defaultPaymentTokenFor(bountyId, artifactType, bounty);

        // An alternative token is a distinct purchase route. It must be explicitly configured,
        // even when the artifact's default route is public.
        if (paymentToken != defaultToken && !config.set) {
            return (AccessStatus.Unconfigured, 0);
        }

        // An explicitly configured zero price is the administrator's opt-in to public access.
        if (config.set && config.price == 0) {
            return (AccessStatus.Public, 0);
        }

        // Instance and evidence artifacts retain their existing public-by-default policy.
        if (!config.set && artifactType != ARTIFACT_SOLUTION) {
            return (AccessStatus.Public, 0);
        }

        // Token acceptance is relevant only to a route that would transfer tokens. Public routes
        // above do not depend on ERC-20 configuration.
        if (paymentToken == address(0) || !acceptedPaymentToken[paymentToken]) {
            return (AccessStatus.Disabled, 0);
        }

        if (config.set) {
            return (AccessStatus.Priced, config.price);
        }

        if (
            artifactType != ARTIFACT_SOLUTION || paymentToken != bounty.paymentToken
                || defaultSolverAccessRewardBps == 0 || solverRoyaltyBps == 0
        ) {
            return (AccessStatus.Unconfigured, 0);
        }

        uint256 targetSolverReward = (bounty.reward * defaultSolverAccessRewardBps) / BPS_DENOMINATOR;
        if (targetSolverReward == 0) {
            return (AccessStatus.Unconfigured, 0);
        }

        price = _ceilDiv(targetSolverReward * BPS_DENOMINATOR, solverRoyaltyBps);
        return (AccessStatus.Priced, price);
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
