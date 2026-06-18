// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { SATToken } from "../src/SATToken.sol";
import { TokenVesting } from "../src/TokenVesting.sol";
import { CommunityIncentivesController } from "../src/CommunityIncentivesController.sol";
import { TreasuryReserveController } from "../src/TreasuryReserveController.sol";
import { TreasuryRouter } from "../src/TreasuryRouter.sol";
import { VerifierRegistry } from "../src/VerifierRegistry.sol";
import { BountyManager } from "../src/BountyManager.sol";

contract BountyManagerTest is Test {
    uint256 internal constant S_MAX = 1_000_000_000 ether;
    uint64 internal constant GENESIS = 1_700_000_000;
    uint64 internal constant MONTH = 30 days;
    uint64 internal constant COMMIT_WINDOW = 1 days;
    uint64 internal constant REVEAL_WINDOW = 1 days;
    uint64 internal constant VERIFICATION_WINDOW = 1 days;
    uint64 internal constant UNBONDING_DELAY = 15 days;
    uint16 internal constant VERIFIER_REWARD_BPS = 200;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0x710);
    address internal liquidity = address(0x500);
    address internal issuer = address(0x111);
    address internal solver = address(0x222);
    address internal solverTwo = address(0x223);
    address internal verifierA = address(0x444);
    address internal verifierB = address(0x445);
    address internal verifierC = address(0x446);
    address internal nonVerifier = address(0x999);

    SATToken internal token;
    TreasuryRouter internal router;
    VerifierRegistry internal registry;
    BountyManager internal manager;

    bytes32 internal salt = keccak256("salt");
    string internal solutionRef = "ipfs://solution";
    bytes32 internal solutionDigest = keccak256("solution-bytes");

    uint256 internal reward = 1_000 ether;
    uint256 internal postingFee = 10 ether;
    uint256 internal solverBond = 50 ether;
    uint256 internal minimumStake = 100 ether;

    function setUp() public {
        vm.warp(GENESIS);

        token = new SATToken(S_MAX, owner);
        TokenVesting teamVesting = new TokenVesting(
            token, address(0x1001), GENESIS, 12 * MONTH, 24 * MONTH, token.allocationAmount(token.TEAM_BPS())
        );
        TokenVesting investorVesting = new TokenVesting(
            token, address(0x1002), GENESIS, 6 * MONTH, 24 * MONTH, token.allocationAmount(token.INVESTOR_BPS())
        );
        CommunityIncentivesController community = new CommunityIncentivesController(token, S_MAX, GENESIS, owner);
        TreasuryReserveController reserve = new TreasuryReserveController(token, S_MAX, GENESIS, treasury, owner);

        vm.prank(owner);
        token.initializeGenesisAllocations(
            address(community), address(reserve), address(teamVesting), address(investorVesting), liquidity
        );

        router = new TreasuryRouter(token, treasury, 2_000, owner);
        registry = new VerifierRegistry(token, minimumStake, UNBONDING_DELAY, owner);
        manager = new BountyManager(token, registry, router, solverBond, VERIFIER_REWARD_BPS, owner);

        vm.prank(owner);
        registry.setBountyManager(address(manager));

        _fund(issuer, 20_000 ether);
        _fund(solver, 2_000 ether);
        _fund(solverTwo, 2_000 ether);
        _fund(verifierA, 2_000 ether);
        _fund(verifierB, 2_000 ether);
        _fund(verifierC, 2_000 ether);

        _stakeVerifier(verifierA);
        _stakeVerifier(verifierB);
        _stakeVerifier(verifierC);
    }

    function testBountyCreationBindsCidDigestAndEscrowsRewardAndPostingFee() public {
        uint256 bountyId = _createBounty();
        BountyManager.Bounty memory bounty = manager.getBounty(bountyId);

        assertEq(bounty.issuer, issuer);
        assertEq(bounty.instanceCID, "bafy-instance");
        assertEq(bounty.instanceDigest, keccak256("instance"));
        assertEq(bounty.metadataURI, "ipfs://metadata");
        assertEq(bounty.metadataDigest, keccak256("metadata"));
        assertEq(bounty.verifierRewardPool, _verifierRewardPool());
        assertEq(bounty.commitDeadline, GENESIS + COMMIT_WINDOW);
        assertEq(bounty.revealDeadline, GENESIS + COMMIT_WINDOW + REVEAL_WINDOW);
        assertEq(bounty.verificationDeadline, GENESIS + COMMIT_WINDOW + REVEAL_WINDOW + VERIFICATION_WINDOW);
        assertEq(token.balanceOf(address(manager)), reward + _verifierRewardPool() + postingFee);
    }

    function testSolverCommitRevealSuccess() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);

        assertEq(submission.solver, solver);
        assertEq(submission.solutionRef, solutionRef);
        assertEq(submission.solutionDigest, solutionDigest);
        assertEq(uint256(submission.solutionKind), uint256(BountyManager.SolutionKind.SatAssignment));
        assertEq(uint256(submission.proofFormat), uint256(BountyManager.ProofFormat.None));
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.Revealed));
    }

    function testUnsatProofCommitRevealAndFinalize() public {
        uint256 bountyId = _createBounty();
        string memory proofRef = "ipfs://proof.frat";
        bytes32 proofDigest = keccak256("frat-proof");
        bytes32 proofSalt = keccak256("proof-salt");
        bytes32 commitHash = manager.computeCommitHash(
            bountyId,
            solver,
            BountyManager.SolutionKind.UnsatProof,
            BountyManager.ProofFormat.FRAT,
            proofRef,
            proofDigest,
            proofSalt
        );

        vm.startPrank(solver);
        token.approve(address(manager), solverBond);
        uint256 submissionId = manager.commitSolution(bountyId, commitHash);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.UnsatProof,
            BountyManager.ProofFormat.FRAT,
            proofRef,
            proofDigest,
            proofSalt
        );
        vm.stopPrank();

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.solutionKind), uint256(BountyManager.SolutionKind.UnsatProof));
        assertEq(uint256(submission.proofFormat), uint256(BountyManager.ProofFormat.FRAT));

        vm.prank(verifierA);
        manager.attest(
            bountyId,
            submissionId,
            true,
            BountyManager.SolutionKind.UnsatProof,
            BountyManager.ProofFormat.FRAT,
            proofRef,
            proofDigest
        );
        vm.prank(verifierB);
        manager.attest(
            bountyId,
            submissionId,
            true,
            BountyManager.SolutionKind.UnsatProof,
            BountyManager.ProofFormat.FRAT,
            proofRef,
            proofDigest
        );

        manager.finalize(bountyId, submissionId);
        BountyManager.Submission memory finalized = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(finalized.state), uint256(BountyManager.SubmissionState.Finalized));
        assertEq(manager.finalizedWinningSubmissionId(bountyId), submissionId);
    }

    function testCommitAllowsImmediateRevealAndStartsVerificationWindow() public {
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionRef, solutionDigest, salt);
        BountyManager.Bounty memory afterCommit = manager.getBounty(bountyId);
        assertEq(afterCommit.commitDeadline, block.timestamp);
        assertEq(afterCommit.revealDeadline, block.timestamp + REVEAL_WINDOW);
        assertEq(manager.activeSubmissionId(bountyId), submissionId);

        vm.prank(solver);
        manager.revealSolution(bountyId, submissionId, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest, salt);

        BountyManager.Bounty memory afterReveal = manager.getBounty(bountyId);
        assertEq(afterReveal.revealDeadline, block.timestamp);
        assertEq(afterReveal.verificationDeadline, block.timestamp + VERIFICATION_WINDOW);
    }

    function testActiveSubmissionBlocksCompetingCommitUntilResolved() public {
        uint256 bountyId = _createBounty();
        _commit(bountyId, solver, solutionRef, solutionDigest, salt);

        bytes32 competingCommitHash = manager.computeCommitHash(
            bountyId,
            solverTwo,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            "ipfs://solution-two",
            keccak256("solution-two"),
            keccak256("salt-two")
        );
        vm.startPrank(solverTwo);
        token.approve(address(manager), solverBond);
        vm.expectRevert();
        manager.commitSolution(bountyId, competingCommitHash);
        vm.stopPrank();
    }

    function testWrongSaltRevealSlashesSolverBond() public {
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionRef, solutionDigest, salt);
        uint256 supplyBefore = token.totalSupply();
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(solver);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionRef,
            solutionDigest,
            keccak256("wrong")
        );

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.Invalid));
        assertTrue(submission.bondSlashed);
        assertEq(token.totalSupply(), supplyBefore - ((solverBond * 2_000) / 10_000));
        assertEq(token.balanceOf(treasury), treasuryBefore + ((solverBond * 8_000) / 10_000));
        assertEq(manager.activeSubmissionId(bountyId), 0);
    }

    function testWrongSolutionDigestRevealSlashesSolverBond() public {
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionRef, solutionDigest, salt);
        vm.prank(solver);
        manager.revealSolution(bountyId, submissionId, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, keccak256("different-solution"), salt);

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.Invalid));
        assertTrue(submission.bondSlashed);
        assertEq(submission.solutionRef, "");
        assertEq(submission.solutionDigest, bytes32(0));
        assertEq(manager.activeSubmissionId(bountyId), 0);
    }

    function testNonRevealTimeoutSlashesSolver() public {
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionRef, solutionDigest, salt);

        vm.warp(GENESIS + REVEAL_WINDOW + 1);
        manager.slashExpiredSubmission(bountyId, submissionId);

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.Invalid));
        assertTrue(submission.bondSlashed);
        assertEq(manager.activeSubmissionId(bountyId), 0);
    }

    function testVerifierStakingEligibilityAndUnbonding() public {
        assertTrue(registry.isEligible(verifierA));

        vm.prank(verifierA);
        registry.requestUnstake(10 ether);
        assertFalse(registry.isEligible(verifierA));

        vm.prank(verifierA);
        vm.expectRevert();
        registry.withdrawUnstaked();

        vm.warp(block.timestamp + UNBONDING_DELAY + 1);
        vm.prank(verifierA);
        registry.withdrawUnstaked();
        assertEq(token.balanceOf(verifierA), 2_000 ether - minimumStake + 10 ether);
    }

    function testNonVerifierCannotAttestAndDuplicateAttestRejected() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();

        vm.prank(nonVerifier);
        vm.expectRevert();
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);

        vm.prank(verifierA);
        vm.expectRevert(BountyManager.DuplicateAttestation.selector);
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);
    }

    function testSolverAndIssuerCannotAttestConflictedSubmission() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();

        _stakeVerifier(solver);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(BountyManager.ConflictedVerifier.selector, solver));
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);

        _stakeVerifier(issuer);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(BountyManager.ConflictedVerifier.selector, issuer));
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);
    }

    function testQuorumAcceptedIsImmediatelyFinalizable() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        _attestFor(bountyId, submissionId);

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.PendingAccepted));
        assertEq(submission.quorumReachedAt, block.timestamp);

        assertTrue(manager.isFinalizable(bountyId, submissionId));
        manager.finalize(bountyId, submissionId);

        BountyManager.Submission memory finalized = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(finalized.state), uint256(BountyManager.SubmissionState.Finalized));
        assertEq(manager.finalizedWinningSubmissionId(bountyId), submissionId);
        assertEq(manager.finalizedWinningSolver(bountyId), solver);
    }

    function testQuorumRejectedSlashesSolverAndReopensBounty() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, false, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, false, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.PendingRejected));
        assertTrue(submission.bondSlashed);
        assertTrue(submission.bondSettled);
        assertEq(manager.activeSubmissionId(bountyId), 0);

        BountyManager.Bounty memory bounty = manager.getBounty(bountyId);
        assertEq(bounty.commitDeadline, block.timestamp + COMMIT_WINDOW);

        uint256 nextSubmissionId =
            _commit(bountyId, solverTwo, "ipfs://solution-two", keccak256("solution-two"), keccak256("salt-two"));
        assertEq(nextSubmissionId, 2);
    }

    function testValidFinalizationPaysSolverRewardRefundsBondAndRoutesPostingFee() public {
        uint256 solverBefore = token.balanceOf(solver);
        uint256 verifierABefore = token.balanceOf(verifierA);
        uint256 verifierBBefore = token.balanceOf(verifierB);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 supplyBefore = token.totalSupply();

        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        _attestFor(bountyId, submissionId);

        manager.finalize(bountyId, submissionId);

        assertEq(token.balanceOf(solver), solverBefore + reward);
        assertEq(token.balanceOf(verifierA), verifierABefore + (_verifierRewardPool() / 2));
        assertEq(token.balanceOf(verifierB), verifierBBefore + (_verifierRewardPool() / 2));
        assertEq(token.balanceOf(treasury), treasuryBefore + ((postingFee * 8_000) / 10_000));
        assertEq(token.totalSupply(), supplyBefore - ((postingFee * 2_000) / 10_000));
        assertEq(token.balanceOf(address(manager)), 0);
    }

    function testNoRevealTimeoutReopensThenNoWinnerFinalizationRefundsIssuer() public {
        uint256 issuerBefore = token.balanceOf(issuer);
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionRef, solutionDigest, salt);

        vm.warp(GENESIS + REVEAL_WINDOW + 1);
        manager.slashExpiredSubmission(bountyId, submissionId);
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        manager.finalize(bountyId, 0);

        assertEq(token.balanceOf(issuer), issuerBefore - postingFee);
        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertTrue(submission.bondSlashed);
    }

    function testNoWinnerFinalizeCannotBypassAcceptedSubmission() public {
        uint256 solverBefore = token.balanceOf(solver);
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        _attestFor(bountyId, submissionId);

        vm.expectRevert(BountyManager.NotFinalizable.selector);
        manager.finalize(bountyId, 0);

        manager.finalize(bountyId, submissionId);
        assertEq(token.balanceOf(solver), solverBefore + reward);
    }

    function testRejectedSubmissionCannotPrematurelyCloseBounty() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, false, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, false, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);

        vm.expectRevert(BountyManager.NotFinalizable.selector);
        manager.finalize(bountyId, submissionId);

        BountyManager.Bounty memory bounty = manager.getBounty(bountyId);
        assertFalse(bounty.finalized);
        assertEq(manager.activeSubmissionId(bountyId), 0);
    }

    function testNoWinnerFinalizeWithNoQuorumRefundsRevealedSolverBond() public {
        uint256 issuerBefore = token.balanceOf(issuer);
        uint256 solverBefore = token.balanceOf(solver);
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);

        _warpPastVerificationDeadline();
        manager.finalize(bountyId, 0);
        assertEq(token.balanceOf(issuer), issuerBefore - postingFee);

        vm.prank(solver);
        manager.claimSolverBond(bountyId, submissionId);
        assertEq(token.balanceOf(solver), solverBefore);
    }

    function testVerifierRegistryRejectsZeroUnbondingDelay() public {
        vm.expectRevert(VerifierRegistry.InvalidRegistryConfig.selector);
        new VerifierRegistry(token, minimumStake, 0, owner);

        vm.prank(owner);
        vm.expectRevert(VerifierRegistry.InvalidRegistryConfig.selector);
        registry.setUnbondingDelay(0);
    }

    function testOwnerCannotSetVerifierRegistryBeforeManagerAuthorization() public {
        VerifierRegistry newRegistry = new VerifierRegistry(token, minimumStake, UNBONDING_DELAY, owner);

        vm.prank(owner);
        vm.expectRevert(BountyManager.InvalidProtocolConfig.selector);
        manager.setVerifierRegistry(newRegistry);

        vm.prank(owner);
        newRegistry.setBountyManager(address(manager));
        vm.prank(owner);
        manager.setVerifierRegistry(newRegistry);

        assertEq(address(manager.verifierRegistry()), address(newRegistry));
    }

    function testOwnerCannotSetRouterForDifferentToken() public {
        SATToken otherToken = new SATToken(S_MAX, owner);
        TreasuryRouter badRouter = new TreasuryRouter(otherToken, treasury, 2_000, owner);

        vm.prank(owner);
        vm.expectRevert(BountyManager.InvalidProtocolConfig.selector);
        manager.setTreasuryRouter(badRouter);
    }

    function testOwnerCanUpdateSolverBond() public {
        vm.prank(owner);
        manager.setProtocolParams(75 ether);

        assertEq(manager.solverBond(), 75 ether);
    }

    function testOwnerCanUpdateVerifierRewardBpsForNewBounties() public {
        vm.prank(owner);
        manager.setVerifierRewardBps(300);

        uint256 bountyId = _createBounty();
        BountyManager.Bounty memory bounty = manager.getBounty(bountyId);
        assertEq(manager.verifierRewardBps(), 300);
        assertEq(bounty.verifierRewardPool, (reward * 300) / 10_000);
    }

    function testOwnerCanSlashAndDisableVerifierByDefaultHalfStake() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(owner);
        registry.slashAndDisable(verifierA);

        VerifierRegistry.Verifier memory verifier = registry.getVerifier(verifierA);
        assertEq(verifier.activeStake, minimumStake / 2);
        assertFalse(verifier.enabled);
        assertFalse(registry.isEligible(verifierA));
        assertEq(token.totalSupply(), supplyBefore - (minimumStake / 2));
    }

    function testOwnerCanSlashPendingUnstakeDuringUnbondingDelay() public {
        vm.prank(verifierA);
        registry.requestUnstake(80 ether);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(owner);
        registry.slashAndDisable(verifierA);

        VerifierRegistry.Verifier memory verifier = registry.getVerifier(verifierA);
        assertEq(verifier.activeStake, 0);
        assertEq(verifier.pendingUnstake, 50 ether);
        assertFalse(verifier.enabled);
        assertEq(token.totalSupply(), supplyBefore - 50 ether);
    }

    function testRejectedSubmissionReopensAndNextSolverCanWin() public {
        uint256 bountyId = _createBounty();
        uint256 rejectedSubmissionId =
            _commit(bountyId, solverTwo, "ipfs://bad", keccak256("bad"), keccak256("bad-salt"));
        vm.prank(solverTwo);
        manager.revealSolution(bountyId, rejectedSubmissionId, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, "ipfs://bad", keccak256("bad"), keccak256("bad-salt"));
        vm.prank(verifierA);
        manager.attest(bountyId, rejectedSubmissionId, false, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, "ipfs://bad", keccak256("bad"));
        vm.prank(verifierB);
        manager.attest(bountyId, rejectedSubmissionId, false, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, "ipfs://bad", keccak256("bad"));

        uint256 winningSubmissionId = _commit(bountyId, solver, solutionRef, solutionDigest, salt);
        vm.prank(solver);
        manager.revealSolution(bountyId, winningSubmissionId, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest, salt);

        _attestFor(bountyId, winningSubmissionId);
        manager.finalize(bountyId, winningSubmissionId);

        BountyManager.Submission memory rejected = manager.getSubmission(bountyId, rejectedSubmissionId);
        assertTrue(rejected.bondSlashed);
        assertTrue(rejected.bondSettled);
        vm.expectRevert();
        vm.prank(solverTwo);
        manager.claimSolverBond(bountyId, rejectedSubmissionId);
    }

    function testAccountingInvariantAcceptedFlowLeavesNoManagerEscrow() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        _attestFor(bountyId, submissionId);
        manager.finalize(bountyId, submissionId);

        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function _fund(address account, uint256 amount) internal {
        vm.prank(liquidity);
        assertTrue(token.transfer(account, amount));
    }

    function _stakeVerifier(address verifier) internal {
        vm.startPrank(verifier);
        token.approve(address(registry), minimumStake);
        registry.stake(minimumStake, "ipfs://verifier");
        vm.stopPrank();
    }

    function _createBounty() internal returns (uint256 bountyId) {
        vm.startPrank(issuer);
        token.approve(address(manager), reward + _verifierRewardPool() + postingFee);
        bountyId = manager.createBounty(
            "bafy-instance",
            keccak256("instance"),
            "ipfs://metadata",
            keccak256("metadata"),
            reward,
            postingFee,
            COMMIT_WINDOW,
            REVEAL_WINDOW,
            VERIFICATION_WINDOW,
            2
        );
        vm.stopPrank();
    }

    function _verifierRewardPool() internal view returns (uint256) {
        return manager.verifierRewardPoolFor(reward);
    }

    function _commit(uint256 bountyId, address solver_, string memory ref, bytes32 digest_, bytes32 salt_)
        internal
        returns (uint256 submissionId)
    {
        bytes32 commitHash = manager.computeCommitHash(bountyId, solver_, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, ref, digest_, salt_);
        vm.startPrank(solver_);
        token.approve(address(manager), solverBond);
        submissionId = manager.commitSolution(bountyId, commitHash);
        vm.stopPrank();
    }

    function _createCommitReveal() internal returns (uint256 bountyId, uint256 submissionId, bytes32 commitHash) {
        bountyId = _createBounty();
        commitHash = manager.computeCommitHash(bountyId, solver, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest, salt);
        vm.startPrank(solver);
        token.approve(address(manager), solverBond);
        submissionId = manager.commitSolution(bountyId, commitHash);
        vm.stopPrank();

        vm.prank(solver);
        manager.revealSolution(bountyId, submissionId, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest, salt);
    }

    function _attestFor(uint256 bountyId, uint256 submissionId) internal {
        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);
    }

    function _warpPastVerificationDeadline() internal {
        vm.warp(block.timestamp + VERIFICATION_WINDOW + 1);
    }
}
