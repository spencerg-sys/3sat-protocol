// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { TreasuryRouter } from "./TreasuryRouter.sol";
import { VerifierRegistry } from "./VerifierRegistry.sol";

/// @title BountyManager
/// @notice Token-denominated bounty escrow with solver commit-reveal, verifier quorum, and finalization.
contract BountyManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_VERIFIER_REWARD_BPS = 1_000;

    enum SubmissionState {
        None,
        Committed,
        Revealed,
        PendingAccepted,
        PendingRejected,
        Invalid,
        Finalized
    }

    enum SolutionKind {
        None,
        SatAssignment,
        UnsatProof
    }

    enum ProofFormat {
        None,
        DRAT,
        FRAT,
        LRAT
    }

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

    struct Submission {
        address solver;
        bytes32 commitHash;
        string solutionRef;
        bytes32 solutionDigest;
        SolutionKind solutionKind;
        ProofFormat proofFormat;
        address bondToken;
        uint256 solverBond;
        uint64 committedAt;
        uint64 revealedAt;
        uint64 quorumReachedAt;
        uint16 forVotes;
        uint16 againstVotes;
        bool bondSettled;
        bool bondSlashed;
        SubmissionState state;
    }

    struct Attestation {
        address verifier;
        bool support;
        SolutionKind solutionKind;
        ProofFormat proofFormat;
        bytes32 solutionDigest;
        string solutionRef;
        uint64 timestamp;
    }

    struct FinalizationSettlement {
        bool solverWon;
        address rewardRecipient;
        uint256 bondRefund;
        uint256 solverSlash;
    }

    IERC20 public immutable token;
    VerifierRegistry public verifierRegistry;
    TreasuryRouter public treasuryRouter;

    uint256 public solverBond;
    uint16 public verifierRewardBps;
    mapping(address paymentToken => bool accepted) public acceptedPaymentToken;
    mapping(address paymentToken => uint256 bondAmount) public solverBondForToken;

    uint256 public nextBountyId = 1;
    mapping(uint256 bountyId => uint256 submissionId) public finalizedWinningSubmissionId;
    mapping(uint256 bountyId => address solver) public finalizedWinningSolver;
    mapping(uint256 bountyId => uint64 window) public bountyCommitWindow;
    mapping(uint256 bountyId => uint64 window) public bountyRevealWindow;
    mapping(uint256 bountyId => uint64 window) public bountyVerificationWindow;
    mapping(uint256 bountyId => uint256 submissionId) public activeSubmissionId;

    mapping(uint256 bountyId => Bounty) private bounties;
    mapping(uint256 bountyId => mapping(uint256 submissionId => Submission)) private submissions;
    mapping(uint256 bountyId => mapping(uint256 submissionId => Attestation[])) private attestations;
    mapping(uint256 bountyId => mapping(uint256 submissionId => mapping(address verifier => bool))) public hasAttested;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed issuer,
        address indexed paymentToken,
        string instanceCID,
        bytes32 instanceDigest,
        string metadataURI,
        bytes32 metadataDigest,
        uint256 reward,
        uint256 verifierRewardPool,
        uint256 postingFee
    );
    event SolutionCommitted(
        uint256 indexed bountyId, uint256 indexed submissionId, address indexed solver, bytes32 commitHash
    );
    event SolutionRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        address indexed solver,
        string solutionRef,
        bytes32 solutionDigest,
        SolutionKind solutionKind,
        ProofFormat proofFormat
    );
    event Attested(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        address indexed verifier,
        bool support,
        SolutionKind solutionKind,
        ProofFormat proofFormat,
        uint16 forVotes,
        uint16 againstVotes
    );
    event QuorumReached(uint256 indexed bountyId, uint256 indexed submissionId, bool accepted);
    event Finalized(uint256 indexed bountyId, uint256 indexed submissionId, bool solverWon);
    event BountyReopened(
        uint256 indexed bountyId, uint64 commitDeadline, uint64 revealDeadline, uint64 verificationDeadline
    );
    event RewardPaid(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        address indexed solver,
        address paymentToken,
        uint256 reward
    );
    event VerifierRewardPaid(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        address indexed verifier,
        address paymentToken,
        uint256 amount
    );
    event VerifierRewardRefunded(
        uint256 indexed bountyId, address indexed issuer, address paymentToken, uint256 amount
    );
    event BondRefunded(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        address indexed solver,
        address bondToken,
        uint256 amount
    );
    event BondSlashed(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        address indexed solver,
        address bondToken,
        uint256 amount
    );
    event FeeRouted(uint256 indexed bountyId, address indexed paymentToken, uint256 amount);
    event ProtocolParamsUpdated(uint256 solverBond);
    event PaymentTokenConfigured(address indexed paymentToken, bool accepted, uint256 solverBond);
    event VerifierRewardBpsUpdated(uint16 verifierRewardBps);
    event VerifierRegistryUpdated(address indexed verifierRegistry);
    event TreasuryRouterUpdated(address indexed treasuryRouter);

    error InvalidBountyConfig();
    error InvalidProtocolConfig();
    error UnknownBounty();
    error UnknownSubmission();
    error BountyAlreadyFinalized();
    error InvalidState(SubmissionState state);
    error WindowClosed();
    error WindowNotClosed();
    error InvalidReveal();
    error DuplicateAttestation();
    error IneligibleVerifier(address verifier);
    error ConflictedVerifier(address verifier);
    error NotFinalizable();

    modifier onlyExistingBounty(uint256 bountyId) {
        _checkExistingBounty(bountyId);
        _;
    }

    constructor(
        IERC20 token_,
        VerifierRegistry verifierRegistry_,
        TreasuryRouter treasuryRouter_,
        uint256 solverBond_,
        uint16 verifierRewardBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            address(token_) == address(0) || address(verifierRegistry_) == address(0)
                || address(treasuryRouter_) == address(0) || solverBond_ == 0
                || address(verifierRegistry_.token()) != address(token_) || verifierRewardBps_ > MAX_VERIFIER_REWARD_BPS
        ) {
            revert InvalidProtocolConfig();
        }
        token = token_;
        verifierRegistry = verifierRegistry_;
        treasuryRouter = treasuryRouter_;
        solverBond = solverBond_;
        acceptedPaymentToken[address(token_)] = true;
        solverBondForToken[address(token_)] = solverBond_;
        verifierRewardBps = verifierRewardBps_;
    }

    function createBounty(
        address paymentToken,
        string calldata instanceCID,
        bytes32 instanceDigest,
        string calldata metadataURI,
        bytes32 metadataDigest,
        uint256 reward,
        uint256 postingFee,
        uint64 commitWindow,
        uint64 revealWindow,
        uint64 verificationWindow,
        uint16 verifierQuorum
    ) external nonReentrant returns (uint256 bountyId) {
        if (
            paymentToken == address(0) || !acceptedPaymentToken[paymentToken] || solverBondForToken[paymentToken] == 0
                || bytes(instanceCID).length == 0 || instanceDigest == bytes32(0) || bytes(metadataURI).length == 0
                || metadataDigest == bytes32(0) || reward == 0 || commitWindow == 0 || revealWindow == 0
                || verificationWindow == 0 || verifierQuorum == 0
        ) {
            revert InvalidBountyConfig();
        }

        bountyId = nextBountyId++;
        uint256 verifierRewardPool = verifierRewardPoolFor(reward);
        uint64 commitDeadline = uint64(block.timestamp) + commitWindow;
        uint64 revealDeadline = commitDeadline + revealWindow;
        uint64 verificationDeadline = revealDeadline + verificationWindow;
        bountyCommitWindow[bountyId] = commitWindow;
        bountyRevealWindow[bountyId] = revealWindow;
        bountyVerificationWindow[bountyId] = verificationWindow;

        bounties[bountyId] = Bounty({
            issuer: msg.sender,
            paymentToken: paymentToken,
            instanceCID: instanceCID,
            instanceDigest: instanceDigest,
            metadataURI: metadataURI,
            metadataDigest: metadataDigest,
            reward: reward,
            verifierRewardPool: verifierRewardPool,
            postingFee: postingFee,
            commitDeadline: commitDeadline,
            revealDeadline: revealDeadline,
            verificationDeadline: verificationDeadline,
            verifierQuorum: verifierQuorum,
            submissionCount: 0,
            acceptedCandidateCount: 0,
            finalized: false,
            postingFeeRouted: false
        });

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), reward + verifierRewardPool + postingFee);

        emit BountyCreated(
            bountyId,
            msg.sender,
            paymentToken,
            instanceCID,
            instanceDigest,
            metadataURI,
            metadataDigest,
            reward,
            verifierRewardPool,
            postingFee
        );
    }

    function commitSolution(uint256 bountyId, bytes32 commitHash)
        external
        onlyExistingBounty(bountyId)
        nonReentrant
        returns (uint256 submissionId)
    {
        Bounty storage bounty = bounties[bountyId];
        _requireBountyOpen(bounty);
        uint256 currentActiveSubmissionId = activeSubmissionId[bountyId];
        if (currentActiveSubmissionId != 0) {
            revert InvalidState(submissions[bountyId][currentActiveSubmissionId].state);
        }
        if (block.timestamp > bounty.commitDeadline) {
            revert WindowClosed();
        }
        if (commitHash == bytes32(0)) {
            revert InvalidBountyConfig();
        }

        submissionId = ++bounty.submissionCount;
        uint256 bondAmount = solverBondForToken[bounty.paymentToken];
        submissions[bountyId][submissionId] = Submission({
            solver: msg.sender,
            commitHash: commitHash,
            solutionRef: "",
            solutionDigest: bytes32(0),
            solutionKind: SolutionKind.None,
            proofFormat: ProofFormat.None,
            bondToken: bounty.paymentToken,
            solverBond: bondAmount,
            committedAt: uint64(block.timestamp),
            revealedAt: 0,
            quorumReachedAt: 0,
            forVotes: 0,
            againstVotes: 0,
            bondSettled: false,
            bondSlashed: false,
            state: SubmissionState.Committed
        });

        IERC20(bounty.paymentToken).safeTransferFrom(msg.sender, address(this), bondAmount);
        activeSubmissionId[bountyId] = submissionId;
        bounty.commitDeadline = uint64(block.timestamp);
        bounty.revealDeadline = uint64(block.timestamp) + bountyRevealWindow[bountyId];
        bounty.verificationDeadline = bounty.revealDeadline + bountyVerificationWindow[bountyId];
        emit SolutionCommitted(bountyId, submissionId, msg.sender, commitHash);
    }

    function revealSolution(
        uint256 bountyId,
        uint256 submissionId,
        SolutionKind solutionKind,
        ProofFormat proofFormat,
        string calldata solutionRef,
        bytes32 solutionDigest,
        bytes32 salt
    ) external onlyExistingBounty(bountyId) nonReentrant {
        Bounty storage bounty = bounties[bountyId];
        _requireBountyOpen(bounty);
        Submission storage submission = _submission(bountyId, submissionId);
        if (submission.state != SubmissionState.Committed) {
            revert InvalidState(submission.state);
        }
        if (activeSubmissionId[bountyId] != submissionId) {
            revert InvalidState(submission.state);
        }
        if (msg.sender != submission.solver) {
            revert InvalidReveal();
        }
        if (block.timestamp > bounty.revealDeadline) {
            revert WindowClosed();
        }
        _validateSolutionDescriptor(solutionKind, proofFormat);
        if (bytes(solutionRef).length == 0 || solutionDigest == bytes32(0)) {
            revert InvalidReveal();
        }

        bytes32 expected =
            computeCommitHash(bountyId, msg.sender, solutionKind, proofFormat, solutionRef, solutionDigest, salt);
        if (expected != submission.commitHash) {
            submission.state = SubmissionState.Invalid;
            _slashSolverBondToRouter(bountyId, submissionId, submission);
            _reopenCommitWindow(bountyId, bounty);
            return;
        }

        submission.solutionRef = solutionRef;
        submission.solutionDigest = solutionDigest;
        submission.solutionKind = solutionKind;
        submission.proofFormat = proofFormat;
        submission.revealedAt = uint64(block.timestamp);
        submission.state = SubmissionState.Revealed;
        bounty.revealDeadline = uint64(block.timestamp);
        bounty.verificationDeadline = uint64(block.timestamp) + bountyVerificationWindow[bountyId];
        emit SolutionRevealed(
            bountyId, submissionId, msg.sender, solutionRef, solutionDigest, solutionKind, proofFormat
        );
    }

    function slashExpiredSubmission(uint256 bountyId, uint256 submissionId)
        external
        onlyExistingBounty(bountyId)
        nonReentrant
    {
        Bounty storage bounty = bounties[bountyId];
        Submission storage submission = _submission(bountyId, submissionId);
        if (submission.state != SubmissionState.Committed) {
            revert InvalidState(submission.state);
        }
        if (block.timestamp <= bounty.revealDeadline) {
            revert WindowNotClosed();
        }
        submission.state = SubmissionState.Invalid;
        _slashSolverBondToRouter(bountyId, submissionId, submission);
        if (activeSubmissionId[bountyId] == submissionId) {
            _reopenCommitWindow(bountyId, bounty);
        }
    }

    function attest(
        uint256 bountyId,
        uint256 submissionId,
        bool support,
        SolutionKind solutionKind,
        ProofFormat proofFormat,
        string calldata solutionRef,
        bytes32 solutionDigest
    ) external onlyExistingBounty(bountyId) nonReentrant {
        Bounty storage bounty = bounties[bountyId];
        _requireBountyOpen(bounty);
        Submission storage submission = _submission(bountyId, submissionId);
        if (submission.state != SubmissionState.Revealed) {
            revert InvalidState(submission.state);
        }
        if (activeSubmissionId[bountyId] != submissionId) {
            revert InvalidState(submission.state);
        }
        if (block.timestamp > bounty.verificationDeadline) {
            revert WindowClosed();
        }
        if (!verifierRegistry.isEligible(msg.sender)) {
            revert IneligibleVerifier(msg.sender);
        }
        if (msg.sender == bounty.issuer || msg.sender == submission.solver) {
            revert ConflictedVerifier(msg.sender);
        }
        if (hasAttested[bountyId][submissionId][msg.sender]) {
            revert DuplicateAttestation();
        }
        _validateSolutionDescriptor(solutionKind, proofFormat);
        if (
            solutionKind != submission.solutionKind || proofFormat != submission.proofFormat
                || solutionDigest != submission.solutionDigest
                || keccak256(bytes(solutionRef)) != keccak256(bytes(submission.solutionRef))
        ) {
            revert InvalidReveal();
        }

        hasAttested[bountyId][submissionId][msg.sender] = true;
        if (support) {
            submission.forVotes++;
        } else {
            submission.againstVotes++;
        }
        attestations[bountyId][submissionId].push(
            Attestation({
                verifier: msg.sender,
                support: support,
                solutionKind: solutionKind,
                proofFormat: proofFormat,
                solutionDigest: solutionDigest,
                solutionRef: solutionRef,
                timestamp: uint64(block.timestamp)
            })
        );

        emit Attested(
            bountyId,
            submissionId,
            msg.sender,
            support,
            solutionKind,
            proofFormat,
            submission.forVotes,
            submission.againstVotes
        );

        if (submission.state == SubmissionState.Revealed) {
            if (submission.forVotes >= bounty.verifierQuorum) {
                _markQuorum(bountyId, submissionId, bounty, submission, true);
            } else if (submission.againstVotes >= bounty.verifierQuorum) {
                _markQuorum(bountyId, submissionId, bounty, submission, false);
            }
        }
    }

    function finalize(uint256 bountyId, uint256 submissionId) external onlyExistingBounty(bountyId) nonReentrant {
        Bounty storage bounty = bounties[bountyId];
        _requireBountyOpen(bounty);

        if (submissionId == 0) {
            _requireNoWinnerFinalizable(bountyId, bounty);
            bounty.finalized = true;
            _routePostingFee(bountyId, bounty);
            _refundVerifierRewardPool(bountyId, bounty);
            IERC20(bounty.paymentToken).safeTransfer(bounty.issuer, bounty.reward);
            emit Finalized(bountyId, 0, false);
            return;
        }

        Submission storage submission = _submission(bountyId, submissionId);
        FinalizationSettlement memory settlement = _prepareFinalization(bountyId, submissionId, bounty, submission);
        bounty.finalized = true;
        _routePostingFee(bountyId, bounty);
        if (settlement.solverWon) {
            _payWinningVerifierRewards(bountyId, submissionId, bounty);
        } else {
            _refundVerifierRewardPool(bountyId, bounty);
        }
        IERC20(bounty.paymentToken).safeTransfer(settlement.rewardRecipient, bounty.reward);
        if (settlement.solverWon) {
            finalizedWinningSubmissionId[bountyId] = submissionId;
            finalizedWinningSolver[bountyId] = submission.solver;
            emit RewardPaid(bountyId, submissionId, submission.solver, bounty.paymentToken, bounty.reward);
        }
        if (settlement.bondRefund != 0) {
            IERC20(submission.bondToken).safeTransfer(submission.solver, settlement.bondRefund);
            emit BondRefunded(bountyId, submissionId, submission.solver, submission.bondToken, settlement.bondRefund);
        }
        if (settlement.solverSlash != 0) {
            _routeSlashRemainder(submission.bondToken, settlement.solverSlash);
            emit BondSlashed(bountyId, submissionId, submission.solver, submission.bondToken, settlement.solverSlash);
        }
        emit Finalized(bountyId, submissionId, settlement.solverWon);
    }

    function claimSolverBond(uint256 bountyId, uint256 submissionId)
        external
        onlyExistingBounty(bountyId)
        nonReentrant
    {
        Bounty storage bounty = bounties[bountyId];
        if (!bounty.finalized) {
            revert NotFinalizable();
        }
        Submission storage submission = _submission(bountyId, submissionId);
        if (msg.sender != submission.solver) {
            revert InvalidReveal();
        }
        if (submission.bondSettled) {
            revert InvalidState(submission.state);
        }
        if (submission.state == SubmissionState.Committed && block.timestamp > bounty.revealDeadline) {
            submission.state = SubmissionState.Invalid;
            _slashSolverBondToRouter(bountyId, submissionId, submission);
        } else if (submission.state == SubmissionState.PendingRejected || submission.state == SubmissionState.Invalid) {
            _slashSolverBondToRouter(bountyId, submissionId, submission);
        } else {
            _refundSolverBond(bountyId, submissionId, submission);
        }
    }

    function setProtocolParams(uint256 solverBond_) external onlyOwner {
        if (solverBond_ == 0) {
            revert InvalidProtocolConfig();
        }
        solverBond = solverBond_;
        solverBondForToken[address(token)] = solverBond_;
        emit ProtocolParamsUpdated(solverBond_);
    }

    function setPaymentTokenConfig(address paymentToken, bool accepted, uint256 solverBond_) external onlyOwner {
        if (paymentToken == address(0) || (accepted && solverBond_ == 0)) {
            revert InvalidProtocolConfig();
        }
        acceptedPaymentToken[paymentToken] = accepted;
        solverBondForToken[paymentToken] = solverBond_;
        if (paymentToken == address(token)) {
            solverBond = solverBond_;
        }
        emit PaymentTokenConfigured(paymentToken, accepted, solverBond_);
    }

    function setVerifierRewardBps(uint16 verifierRewardBps_) external onlyOwner {
        if (verifierRewardBps_ > MAX_VERIFIER_REWARD_BPS) {
            revert InvalidProtocolConfig();
        }
        verifierRewardBps = verifierRewardBps_;
        emit VerifierRewardBpsUpdated(verifierRewardBps_);
    }

    function setVerifierRegistry(VerifierRegistry verifierRegistry_) external onlyOwner {
        if (
            address(verifierRegistry_) == address(0) || address(verifierRegistry_.token()) != address(token)
                || verifierRegistry_.bountyManager() != address(this)
        ) {
            revert InvalidProtocolConfig();
        }
        verifierRegistry = verifierRegistry_;
        emit VerifierRegistryUpdated(address(verifierRegistry_));
    }

    function setTreasuryRouter(TreasuryRouter treasuryRouter_) external onlyOwner {
        if (address(treasuryRouter_) == address(0)) {
            revert InvalidProtocolConfig();
        }
        treasuryRouter = treasuryRouter_;
        emit TreasuryRouterUpdated(address(treasuryRouter_));
    }

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return bounties[bountyId];
    }

    function getSubmission(uint256 bountyId, uint256 submissionId) external view returns (Submission memory) {
        return submissions[bountyId][submissionId];
    }

    function getAttestations(uint256 bountyId, uint256 submissionId) external view returns (Attestation[] memory) {
        return attestations[bountyId][submissionId];
    }

    function computeCommitHash(
        uint256 bountyId,
        address solver,
        SolutionKind solutionKind,
        ProofFormat proofFormat,
        string memory solutionRef,
        bytes32 solutionDigest,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(bountyId, solver, solutionKind, proofFormat, solutionRef, solutionDigest, salt)
        );
    }

    function verifierRewardPoolFor(uint256 reward) public view returns (uint256) {
        return (reward * verifierRewardBps) / BPS_DENOMINATOR;
    }

    function isFinalizable(uint256 bountyId, uint256 submissionId) external view returns (bool) {
        Bounty storage bounty = bounties[bountyId];
        if (bounty.issuer == address(0) || bounty.finalized) {
            return false;
        }
        if (submissionId == 0) {
            return _isNoWinnerFinalizable(bountyId, bounty);
        }
        Submission storage submission = submissions[bountyId][submissionId];
        if (submission.solver == address(0)) {
            return false;
        }
        if (submission.state == SubmissionState.PendingAccepted) {
            return true;
        }
        if (submission.state == SubmissionState.Invalid) {
            return _isNoWinnerFinalizable(bountyId, bounty);
        }
        if (submission.state == SubmissionState.Committed) {
            return block.timestamp > bounty.revealDeadline && _isNoWinnerFinalizable(bountyId, bounty);
        }
        if (submission.state == SubmissionState.PendingRejected) {
            return _isNoWinnerFinalizable(bountyId, bounty);
        }
        if (submission.state == SubmissionState.Revealed) {
            return _isNoWinnerFinalizable(bountyId, bounty);
        }
        return false;
    }

    function _submission(uint256 bountyId, uint256 submissionId) internal view returns (Submission storage submission) {
        submission = submissions[bountyId][submissionId];
        if (submission.solver == address(0)) {
            revert UnknownSubmission();
        }
    }

    function _requireBountyOpen(Bounty storage bounty) internal view {
        if (bounty.finalized) {
            revert BountyAlreadyFinalized();
        }
    }

    function _checkExistingBounty(uint256 bountyId) internal view {
        if (bounties[bountyId].issuer == address(0)) {
            revert UnknownBounty();
        }
    }

    function _validateSolutionDescriptor(SolutionKind solutionKind, ProofFormat proofFormat) internal pure {
        if (solutionKind == SolutionKind.None) {
            revert InvalidReveal();
        }
        if (solutionKind == SolutionKind.SatAssignment && proofFormat != ProofFormat.None) {
            revert InvalidReveal();
        }
        if (solutionKind == SolutionKind.UnsatProof && proofFormat == ProofFormat.None) {
            revert InvalidReveal();
        }
    }

    function _markQuorum(
        uint256 bountyId,
        uint256 submissionId,
        Bounty storage bounty,
        Submission storage submission,
        bool accepted
    ) internal {
        submission.state = accepted ? SubmissionState.PendingAccepted : SubmissionState.PendingRejected;
        submission.quorumReachedAt = uint64(block.timestamp);
        if (accepted) {
            bounty.acceptedCandidateCount++;
        } else {
            _slashSolverBondToRouter(bountyId, submissionId, submission);
            _reopenCommitWindow(bountyId, bounty);
        }
        emit QuorumReached(bountyId, submissionId, accepted);
    }

    function _prepareFinalization(
        uint256 bountyId,
        uint256 submissionId,
        Bounty storage bounty,
        Submission storage submission
    ) internal returns (FinalizationSettlement memory settlement) {
        if (submission.state == SubmissionState.PendingAccepted) {
            return _prepareWinningFinalization(bounty, submission);
        }

        _requireNoWinnerFinalizable(bountyId, bounty);
        settlement.rewardRecipient = bounty.issuer;
        if (submission.state == SubmissionState.Committed) {
            if (block.timestamp <= bounty.revealDeadline) {
                revert NotFinalizable();
            }
            submission.state = SubmissionState.Finalized;
            settlement.solverSlash = _takeSolverBond(bountyId, submissionId, submission);
            if (settlement.solverSlash != 0) {
                submission.bondSlashed = true;
            }
            return settlement;
        }
        if (submission.state == SubmissionState.PendingRejected) {
            submission.state = SubmissionState.Finalized;
            settlement.solverSlash = _takeSolverBond(bountyId, submissionId, submission);
            if (settlement.solverSlash != 0) {
                submission.bondSlashed = true;
            }
            return settlement;
        }
        if (submission.state == SubmissionState.Revealed) {
            submission.state = SubmissionState.Finalized;
            settlement.bondRefund = _takeSolverBond(bountyId, submissionId, submission);
            return settlement;
        }
        if (submission.state == SubmissionState.Invalid) {
            submission.state = SubmissionState.Finalized;
            settlement.solverSlash = _takeSolverBond(bountyId, submissionId, submission);
            if (settlement.solverSlash != 0) {
                submission.bondSlashed = true;
            }
            return settlement;
        }
        revert InvalidState(submission.state);
    }

    function _prepareWinningFinalization(Bounty storage bounty, Submission storage submission)
        internal
        returns (FinalizationSettlement memory settlement)
    {
        settlement.solverWon = true;
        settlement.rewardRecipient = submission.solver;
        settlement.bondRefund = _takeSolverBond(0, 0, submission);
        submission.state = SubmissionState.Finalized;
        bounty.acceptedCandidateCount = 0;
    }

    function _requireNoWinnerFinalizable(uint256 bountyId, Bounty storage bounty) internal view {
        if (!_isNoWinnerFinalizable(bountyId, bounty)) {
            revert NotFinalizable();
        }
    }

    function _isNoWinnerFinalizable(uint256 bountyId, Bounty storage bounty) internal view returns (bool) {
        if (bounty.acceptedCandidateCount != 0) {
            return false;
        }

        uint256 currentActiveSubmissionId = activeSubmissionId[bountyId];
        if (currentActiveSubmissionId == 0) {
            return block.timestamp > bounty.commitDeadline;
        }

        Submission storage submission = submissions[bountyId][currentActiveSubmissionId];
        return submission.state == SubmissionState.Revealed && block.timestamp > bounty.verificationDeadline;
    }

    function _reopenCommitWindow(uint256 bountyId, Bounty storage bounty) internal {
        activeSubmissionId[bountyId] = 0;
        uint64 commitDeadline = uint64(block.timestamp) + bountyCommitWindow[bountyId];
        uint64 revealDeadline = commitDeadline + bountyRevealWindow[bountyId];
        uint64 verificationDeadline = revealDeadline + bountyVerificationWindow[bountyId];
        bounty.commitDeadline = commitDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.verificationDeadline = verificationDeadline;
        emit BountyReopened(bountyId, commitDeadline, revealDeadline, verificationDeadline);
    }

    function _refundSolverBond(uint256 bountyId, uint256 submissionId, Submission storage submission) internal {
        uint256 amount = _takeSolverBond(bountyId, submissionId, submission);
        if (amount != 0) {
            IERC20(submission.bondToken).safeTransfer(submission.solver, amount);
            emit BondRefunded(bountyId, submissionId, submission.solver, submission.bondToken, amount);
        }
    }

    function _slashSolverBondToRouter(uint256 bountyId, uint256 submissionId, Submission storage submission)
        internal
        returns (uint256 amount)
    {
        amount = _takeSolverBond(bountyId, submissionId, submission);
        if (amount != 0) {
            submission.bondSlashed = true;
            _routeSlashRemainder(submission.bondToken, amount);
            emit BondSlashed(bountyId, submissionId, submission.solver, submission.bondToken, amount);
        }
    }

    function _takeSolverBond(uint256, uint256, Submission storage submission) internal returns (uint256 amount) {
        if (submission.bondSettled) {
            return 0;
        }
        submission.bondSettled = true;
        amount = submission.solverBond;
    }

    function _routePostingFee(uint256 bountyId, Bounty storage bounty) internal {
        if (bounty.postingFeeRouted || bounty.postingFee == 0) {
            return;
        }
        bounty.postingFeeRouted = true;
        IERC20(bounty.paymentToken).safeTransfer(address(treasuryRouter), bounty.postingFee);
        treasuryRouter.routePostingFee(bounty.paymentToken, bounty.postingFee);
        emit FeeRouted(bountyId, bounty.paymentToken, bounty.postingFee);
    }

    function _payWinningVerifierRewards(uint256 bountyId, uint256 submissionId, Bounty storage bounty) internal {
        uint256 pool = bounty.verifierRewardPool;
        if (pool == 0) {
            return;
        }

        Attestation[] storage votes = attestations[bountyId][submissionId];
        uint256 correctCount = 0;
        for (uint256 i = 0; i < votes.length; i++) {
            if (votes[i].support) {
                correctCount++;
            }
        }

        if (correctCount == 0) {
            _refundVerifierRewardPool(bountyId, bounty);
            return;
        }

        uint256 share = pool / correctCount;
        uint256 paid = share * correctCount;
        if (share != 0) {
            for (uint256 i = 0; i < votes.length; i++) {
                if (votes[i].support) {
                    IERC20(bounty.paymentToken).safeTransfer(votes[i].verifier, share);
                    emit VerifierRewardPaid(bountyId, submissionId, votes[i].verifier, bounty.paymentToken, share);
                }
            }
        }

        uint256 remainder = pool - paid;
        if (remainder != 0) {
            IERC20(bounty.paymentToken).safeTransfer(bounty.issuer, remainder);
            emit VerifierRewardRefunded(bountyId, bounty.issuer, bounty.paymentToken, remainder);
        }
    }

    function _refundVerifierRewardPool(uint256 bountyId, Bounty storage bounty) internal {
        if (bounty.verifierRewardPool != 0) {
            IERC20(bounty.paymentToken).safeTransfer(bounty.issuer, bounty.verifierRewardPool);
            emit VerifierRewardRefunded(bountyId, bounty.issuer, bounty.paymentToken, bounty.verifierRewardPool);
        }
    }

    function _routeSlashRemainder(address paymentToken, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        IERC20(paymentToken).safeTransfer(address(treasuryRouter), amount);
        treasuryRouter.routeSlashRemainder(paymentToken, amount);
    }
}
