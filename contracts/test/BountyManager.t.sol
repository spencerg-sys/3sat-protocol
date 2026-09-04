// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SATToken } from "../src/SATToken.sol";
import { TokenVesting } from "../src/TokenVesting.sol";
import { CommunityIncentivesController } from "../src/CommunityIncentivesController.sol";
import { TreasuryReserveController } from "../src/TreasuryReserveController.sol";
import { TreasuryRouter } from "../src/TreasuryRouter.sol";
import { VerifierRegistry } from "../src/VerifierRegistry.sol";
import { BountyManager } from "../src/BountyManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract BountyManagerTest is Test {
    uint256 internal constant S_MAX = 1_000_000_000 ether;
    uint64 internal constant GENESIS = 1_700_000_000;
    uint64 internal constant MONTH = 30 days;
    uint64 internal constant COMMIT_WINDOW = 1 hours;
    uint64 internal constant REVEAL_WINDOW = 1 hours;
    uint64 internal constant VERIFICATION_WINDOW = 1 hours;
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
    MockERC20 internal usdc;
    TreasuryRouter internal router;
    VerifierRegistry internal registry;
    BountyManager internal manager;

    bytes32 internal salt = keccak256("salt");
    bytes32 internal solutionDigest = keccak256("solution-bytes");

    uint256 internal reward = 1_000 ether;
    uint256 internal postingFee = 10 ether;
    uint256 internal solverBond = 50 ether;
    uint256 internal usdcReward = 1_000e6;
    uint256 internal usdcPostingFee = 10e6;
    uint256 internal usdcSolverBond = 50e6;
    uint256 internal minimumStake = 100 ether;

    function setUp() public {
        vm.warp(GENESIS);

        token = new SATToken(S_MAX, owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
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

        router = new TreasuryRouter(treasury, owner);
        vm.prank(owner);
        router.setTokenRouting(address(token), 2_000);
        vm.prank(owner);
        router.setTokenRouting(address(usdc), 0);
        registry = new VerifierRegistry(token, minimumStake, UNBONDING_DELAY, owner);
        manager = new BountyManager(token, registry, router, solverBond, VERIFIER_REWARD_BPS, owner);
        vm.prank(owner);
        manager.setPaymentTokenConfig(address(usdc), true, usdcSolverBond);

        vm.prank(owner);
        registry.setBountyManager(address(manager));

        _fund(issuer, 20_000 ether);
        _fund(solver, 2_000 ether);
        _fund(solverTwo, 2_000 ether);
        _fund(verifierA, 2_000 ether);
        _fund(verifierB, 2_000 ether);
        _fund(verifierC, 2_000 ether);
        usdc.mint(issuer, 20_000e6);
        usdc.mint(solver, 2_000e6);
        usdc.mint(solverTwo, 2_000e6);

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

    function testBountyCreationEnforcesWindowFloorsAndQuorumCap() public {
        assertEq(manager.MIN_COMMIT_WINDOW(), 1 hours);
        assertEq(manager.MIN_REVEAL_WINDOW(), 1 hours);
        assertEq(manager.MIN_VERIFICATION_WINDOW(), 1 hours);
        assertEq(manager.MAX_VERIFIER_QUORUM(), 100);

        _expectInvalidBountyConfig(COMMIT_WINDOW - 1, REVEAL_WINDOW, VERIFICATION_WINDOW, 2);
        _expectInvalidBountyConfig(COMMIT_WINDOW, REVEAL_WINDOW - 1, VERIFICATION_WINDOW, 2);
        _expectInvalidBountyConfig(COMMIT_WINDOW, REVEAL_WINDOW, VERIFICATION_WINDOW - 1, 2);
        _expectInvalidBountyConfig(COMMIT_WINDOW, REVEAL_WINDOW, VERIFICATION_WINDOW, 101);

        uint256 cappedBountyId = _createBountyWithQuorum(100);
        assertEq(manager.getBounty(cappedBountyId).verifierQuorum, 100);
    }

    function testBountySnapshotsSolverBondAtCreation() public {
        uint256 bountyId = _createBounty();
        assertEq(manager.bountySolverBond(bountyId), solverBond);

        vm.prank(owner);
        manager.setPaymentTokenConfig(address(token), false, 0);

        uint256 submissionId = _commit(bountyId, solver, solutionDigest, salt);
        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(submission.solverBond, solverBond);
        assertFalse(manager.acceptedPaymentToken(address(token)));
        assertEq(manager.solverBondForToken(address(token)), 0);
    }

    function testMaxVerifierQuorumCanFinalizeWithinGasBudget() public {
        uint256 bountyId = _createBountyWithQuorum(manager.MAX_VERIFIER_QUORUM());
        uint256 submissionId = _commit(bountyId, solver, solutionDigest, salt);
        vm.prank(solver);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );

        // Exercise the largest possible attestation array: quorum - 1 incorrect
        // votes followed by quorum correct votes.
        for (uint160 i = 0; i < manager.MAX_VERIFIER_QUORUM() - 1; i++) {
            address verifier = address(uint160(0x20_000) + i);
            _fund(verifier, minimumStake);
            _stakeVerifier(verifier);
            vm.prank(verifier);
            manager.attest(bountyId, submissionId, false);
        }

        for (uint160 i = 0; i < manager.MAX_VERIFIER_QUORUM(); i++) {
            address verifier = address(uint160(0x10_000) + i);
            _fund(verifier, minimumStake);
            _stakeVerifier(verifier);
            vm.prank(verifier);
            manager.attest(bountyId, submissionId, true);
        }
        assertEq(manager.getAttestations(bountyId, submissionId).length, 199);

        uint256 gasBefore = gasleft();
        manager.finalize(bountyId, submissionId);
        uint256 finalizationGas = gasBefore - gasleft();

        assertLt(finalizationGas, 8_000_000);
        assertEq(token.balanceOf(address(manager)), 0);
    }

    function testSolverCommitRevealSuccess() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);

        assertEq(submission.solver, solver);
        assertEq(submission.solutionDigest, solutionDigest);
        assertEq(uint256(submission.solutionKind), uint256(BountyManager.SolutionKind.SatAssignment));
        assertEq(uint256(submission.proofFormat), uint256(BountyManager.ProofFormat.None));
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.Revealed));
    }

    function testCommitHashUsesCanonicalEncodingAndDomainSeparation() public {
        uint256 bountyId = 42;
        bytes32 proofDigest = keccak256("frat-proof");
        bytes32 proofSalt = keccak256("proof-salt");
        bytes32 expected = keccak256(
            abi.encode(
                block.chainid,
                address(manager),
                bountyId,
                solver,
                BountyManager.SolutionKind.UnsatProof,
                BountyManager.ProofFormat.FRAT,
                proofDigest,
                proofSalt
            )
        );
        bytes32 actual = manager.computeCommitHash(
            bountyId,
            solver,
            BountyManager.SolutionKind.UnsatProof,
            BountyManager.ProofFormat.FRAT,
            proofDigest,
            proofSalt
        );
        assertEq(actual, expected);

        BountyManager otherManager = new BountyManager(token, registry, router, solverBond, VERIFIER_REWARD_BPS, owner);
        assertNotEq(
            otherManager.computeCommitHash(
                bountyId,
                solver,
                BountyManager.SolutionKind.UnsatProof,
                BountyManager.ProofFormat.FRAT,
                proofDigest,
                proofSalt
            ),
            actual
        );

        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        assertNotEq(
            manager.computeCommitHash(
                bountyId,
                solver,
                BountyManager.SolutionKind.UnsatProof,
                BountyManager.ProofFormat.FRAT,
                proofDigest,
                proofSalt
            ),
            actual
        );
        vm.chainId(originalChainId);
    }

    function testFixedLocalCommitEncodingVector() public {
        uint256 originalChainId = block.chainid;
        vm.chainId(31_337);

        address vectorManager = 0x4444444444444444444444444444444444444444;
        bytes32 expectedCommitment = 0xeba2066d89faa2e842382a7e3c81a055205660aab1ad1b4510c5f20fb52d2046;
        bytes32 actualCommitment = keccak256(
            abi.encode(
                block.chainid,
                vectorManager,
                uint256(42),
                0x1111111111111111111111111111111111111111,
                BountyManager.SolutionKind.UnsatProof,
                BountyManager.ProofFormat.FRAT,
                bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222)),
                bytes32(uint256(0x3333333333333333333333333333333333333333333333333333333333333333))
            )
        );

        assertEq(actualCommitment, expectedCommitment);
        vm.chainId(originalChainId);
    }

    function testUnsatProofCommitRevealAndFinalize() public {
        uint256 bountyId = _createBounty();
        bytes32 proofDigest = keccak256("frat-proof");
        bytes32 proofSalt = keccak256("proof-salt");
        bytes32 commitHash = manager.computeCommitHash(
            bountyId,
            solver,
            BountyManager.SolutionKind.UnsatProof,
            BountyManager.ProofFormat.FRAT,
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
            proofDigest,
            proofSalt
        );
        vm.stopPrank();

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.solutionKind), uint256(BountyManager.SolutionKind.UnsatProof));
        assertEq(uint256(submission.proofFormat), uint256(BountyManager.ProofFormat.FRAT));

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, true);

        manager.finalize(bountyId, submissionId);
        BountyManager.Submission memory finalized = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(finalized.state), uint256(BountyManager.SubmissionState.Finalized));
        assertEq(manager.finalizedWinningSubmissionId(bountyId), submissionId);
    }

    function testCommitAllowsImmediateRevealAndStartsVerificationWindow() public {
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionDigest, salt);
        BountyManager.Bounty memory afterCommit = manager.getBounty(bountyId);
        assertEq(afterCommit.commitDeadline, block.timestamp);
        assertEq(afterCommit.revealDeadline, block.timestamp + REVEAL_WINDOW);
        assertEq(manager.activeSubmissionId(bountyId), submissionId);

        vm.prank(solver);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );

        BountyManager.Bounty memory afterReveal = manager.getBounty(bountyId);
        assertEq(afterReveal.revealDeadline, block.timestamp);
        assertEq(afterReveal.verificationDeadline, block.timestamp + VERIFICATION_WINDOW);
    }

    function testActiveSubmissionBlocksCompetingCommitUntilResolved() public {
        uint256 bountyId = _createBounty();
        _commit(bountyId, solver, solutionDigest, salt);

        bytes32 competingCommitHash = manager.computeCommitHash(
            bountyId,
            solverTwo,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
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
        uint256 submissionId = _commit(bountyId, solver, solutionDigest, salt);
        uint256 supplyBefore = token.totalSupply();
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(solver);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
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
        uint256 submissionId = _commit(bountyId, solver, solutionDigest, salt);
        vm.prank(solver);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            keccak256("different-solution"),
            salt
        );

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.Invalid));
        assertTrue(submission.bondSlashed);
        assertEq(submission.solutionDigest, bytes32(0));
        assertEq(manager.activeSubmissionId(bountyId), 0);
    }

    function testNonRevealTimeoutSlashesSolver() public {
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionDigest, salt);

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

    function testVerifierRegistryDefaultsToOfficialOnlyAndStakeDoesNotAutoAuthorize() public {
        address candidate = address(0xA001);
        _stakeUnapprovedVerifier(candidate, minimumStake);

        VerifierRegistry.Verifier memory verifier = registry.getVerifier(candidate);
        assertFalse(registry.permissionlessVerificationEnabled());
        assertFalse(registry.officialVerifier(candidate));
        assertTrue(verifier.registered);
        assertTrue(verifier.enabled);
        assertEq(verifier.activeStake, minimumStake);
        assertFalse(registry.isEligible(candidate));

        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        vm.prank(candidate);
        vm.expectRevert(abi.encodeWithSelector(BountyManager.IneligibleVerifier.selector, candidate));
        manager.attest(bountyId, submissionId, true);
    }

    function testOwnerCanPreapproveAndRevokeOfficialVerifier() public {
        address candidate = address(0xA002);

        vm.prank(owner);
        registry.setOfficialVerifier(candidate, true);
        assertTrue(registry.officialVerifier(candidate));
        assertFalse(registry.isEligible(candidate));

        _stakeUnapprovedVerifier(candidate, minimumStake - 1);
        assertFalse(registry.isEligible(candidate));
        _stakeUnapprovedVerifier(candidate, 1);
        assertTrue(registry.isEligible(candidate));

        vm.prank(owner);
        registry.setOfficialVerifier(candidate, false);
        assertFalse(registry.officialVerifier(candidate));
        assertFalse(registry.isEligible(candidate));

        vm.prank(candidate);
        vm.expectRevert();
        registry.setOfficialVerifier(candidate, true);

        vm.prank(owner);
        vm.expectRevert(VerifierRegistry.InvalidRegistryConfig.selector);
        registry.setOfficialVerifier(address(0), true);
    }

    function testOwnerCanEnablePermissionlessVerificationWithoutRedeployingRegistry() public {
        address candidate = address(0xA003);
        _stakeUnapprovedVerifier(candidate, minimumStake);
        assertFalse(registry.isEligible(candidate));

        vm.prank(candidate);
        vm.expectRevert();
        registry.setPermissionlessVerificationEnabled(true);

        vm.prank(owner);
        registry.setPermissionlessVerificationEnabled(true);
        assertTrue(registry.permissionlessVerificationEnabled());
        assertTrue(registry.isEligible(candidate));

        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();
        vm.prank(candidate);
        manager.attest(bountyId, submissionId, true);
        assertEq(manager.getAttestations(bountyId, submissionId).length, 1);

        vm.prank(owner);
        registry.setPermissionlessVerificationEnabled(false);
        assertFalse(registry.permissionlessVerificationEnabled());
        assertFalse(registry.isEligible(candidate));
        assertTrue(registry.isEligible(verifierA));
    }

    function testPermissionlessVerificationKeepsDisabledVerifierIneligible() public {
        address candidate = address(0xA004);
        _stakeUnapprovedVerifier(candidate, minimumStake * 3);

        vm.prank(owner);
        registry.setPermissionlessVerificationEnabled(true);
        assertTrue(registry.isEligible(candidate));

        vm.prank(owner);
        registry.slashAndDisable(candidate);

        VerifierRegistry.Verifier memory verifier = registry.getVerifier(candidate);
        assertEq(verifier.activeStake, (minimumStake * 3) / 2);
        assertFalse(verifier.enabled);
        assertFalse(registry.isEligible(candidate));

        vm.prank(owner);
        registry.setVerifierEligibility(candidate, true);
        assertTrue(registry.isEligible(candidate));
    }

    function testNonVerifierCannotAttestAndDuplicateAttestRejected() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();

        vm.prank(nonVerifier);
        vm.expectRevert();
        manager.attest(bountyId, submissionId, true);

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true);

        vm.prank(verifierA);
        vm.expectRevert(BountyManager.DuplicateAttestation.selector);
        manager.attest(bountyId, submissionId, true);
    }

    function testSolverAndIssuerCannotAttestConflictedSubmission() public {
        (uint256 bountyId, uint256 submissionId,) = _createCommitReveal();

        _stakeVerifier(solver);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(BountyManager.ConflictedVerifier.selector, solver));
        manager.attest(bountyId, submissionId, true);

        _stakeVerifier(issuer);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(BountyManager.ConflictedVerifier.selector, issuer));
        manager.attest(bountyId, submissionId, true);
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
        manager.attest(bountyId, submissionId, false);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, false);

        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(uint256(submission.state), uint256(BountyManager.SubmissionState.PendingRejected));
        assertTrue(submission.bondSlashed);
        assertTrue(submission.bondSettled);
        assertEq(manager.activeSubmissionId(bountyId), 0);

        BountyManager.Bounty memory bounty = manager.getBounty(bountyId);
        assertEq(bounty.commitDeadline, block.timestamp + COMMIT_WINDOW);

        uint256 nextSubmissionId = _commit(bountyId, solverTwo, keccak256("solution-two"), keccak256("salt-two"));
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

    function testUsdcBountyPaysRewardVerifierPoolBondAndTreasuryWithoutBurn() public {
        uint256 solverBefore = usdc.balanceOf(solver);
        uint256 verifierABefore = usdc.balanceOf(verifierA);
        uint256 verifierBBefore = usdc.balanceOf(verifierB);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 supplyBefore = usdc.totalSupply();

        uint256 bountyId = _createUsdcBounty();
        bytes32 commitHash = manager.computeCommitHash(
            bountyId,
            solver,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );

        vm.startPrank(solver);
        usdc.approve(address(manager), usdcSolverBond);
        uint256 submissionId = manager.commitSolution(bountyId, commitHash);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );
        vm.stopPrank();

        _attestFor(bountyId, submissionId);
        manager.finalize(bountyId, submissionId);

        uint256 verifierPool = manager.verifierRewardPoolFor(usdcReward);
        assertEq(usdc.balanceOf(solver), solverBefore + usdcReward);
        assertEq(usdc.balanceOf(verifierA), verifierABefore + verifierPool / 2);
        assertEq(usdc.balanceOf(verifierB), verifierBBefore + verifierPool / 2);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + usdcPostingFee);
        assertEq(usdc.totalSupply(), supplyBefore);
        assertEq(usdc.balanceOf(address(manager)), 0);
        assertEq(manager.totalClaimablePayout(address(usdc)), 0);

        BountyManager.Bounty memory bounty = manager.getBounty(bountyId);
        BountyManager.Submission memory submission = manager.getSubmission(bountyId, submissionId);
        assertEq(bounty.paymentToken, address(usdc));
        assertEq(submission.bondToken, address(usdc));
        assertEq(submission.solverBond, usdcSolverBond);
    }

    function testDefersRejectedVerifierPayoutWithoutBlockingFinalizationAndAllowsRedirect() public {
        uint256 solverBefore = usdc.balanceOf(solver);
        uint256 verifierBBefore = usdc.balanceOf(verifierB);
        address payoutRecipient = address(0xB0B);
        (uint256 bountyId, uint256 submissionId) = _createUsdcCommitReveal();
        _attestFor(bountyId, submissionId);

        uint256 share = manager.verifierRewardPoolFor(usdcReward) / 2;
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, verifierA, share),
            abi.encodePacked("recipient blocked")
        );

        manager.finalize(bountyId, submissionId);

        assertTrue(manager.getBounty(bountyId).finalized);
        assertEq(manager.finalizedWinningSubmissionId(bountyId), submissionId);
        assertEq(usdc.balanceOf(solver), solverBefore + usdcReward);
        assertEq(usdc.balanceOf(verifierB), verifierBBefore + share);
        assertEq(manager.claimablePayout(verifierA, address(usdc)), share);
        assertEq(manager.totalClaimablePayout(address(usdc)), share);
        assertEq(usdc.balanceOf(address(manager)), share);

        vm.prank(nonVerifier);
        vm.expectRevert(
            abi.encodeWithSelector(BountyManager.InsufficientClaimablePayout.selector, uint256(0), uint256(1))
        );
        manager.claimPayout(address(usdc), payoutRecipient, 1);

        vm.prank(verifierA);
        vm.expectRevert();
        manager.claimPayout(address(usdc), verifierA, share);
        assertEq(manager.claimablePayout(verifierA, address(usdc)), share);

        uint256 firstClaim = share / 2;
        vm.prank(verifierA);
        manager.claimPayout(address(usdc), payoutRecipient, firstClaim);
        assertEq(manager.claimablePayout(verifierA, address(usdc)), share - firstClaim);
        assertEq(manager.totalClaimablePayout(address(usdc)), share - firstClaim);

        vm.prank(verifierA);
        manager.claimPayout(address(usdc), payoutRecipient, share - firstClaim);
        assertEq(usdc.balanceOf(payoutRecipient), share);
        assertEq(manager.claimablePayout(verifierA, address(usdc)), 0);
        assertEq(manager.totalClaimablePayout(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(manager)), 0);
    }

    function testDefersRejectedSolverRewardAndBondTogether() public {
        uint256 solverBefore = usdc.balanceOf(solver);
        uint256 recipientBefore = usdc.balanceOf(solverTwo);
        (uint256 bountyId, uint256 submissionId) = _createUsdcCommitReveal();
        _attestFor(bountyId, submissionId);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, solver, usdcReward),
            abi.encodePacked("solver blocked")
        );
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, solver, usdcSolverBond),
            abi.encodePacked("solver blocked")
        );

        manager.finalize(bountyId, submissionId);

        uint256 deferred = usdcReward + usdcSolverBond;
        assertEq(manager.finalizedWinningSolver(bountyId), solver);
        assertEq(usdc.balanceOf(solver), solverBefore - usdcSolverBond);
        assertEq(manager.claimablePayout(solver, address(usdc)), deferred);
        assertEq(manager.totalClaimablePayout(address(usdc)), deferred);
        assertEq(usdc.balanceOf(address(manager)), deferred);

        vm.prank(solver);
        manager.claimPayout(address(usdc), solverTwo, deferred);
        assertEq(usdc.balanceOf(solverTwo), recipientBefore + deferred);
        assertEq(manager.claimablePayout(solver, address(usdc)), 0);
        assertEq(manager.totalClaimablePayout(address(usdc)), 0);
    }

    function testDefersRejectedIssuerNoWinnerRefund() public {
        address payoutRecipient = address(0xB0B1);
        uint256 bountyId = _createUsdcBounty();
        uint256 verifierPool = manager.verifierRewardPoolFor(usdcReward);
        vm.warp(GENESIS + COMMIT_WINDOW + 1);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, issuer, verifierPool),
            abi.encodePacked("issuer blocked")
        );
        vm.mockCall(
            address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, issuer, usdcReward), abi.encode(false)
        );

        manager.finalize(bountyId, 0);

        uint256 deferred = usdcReward + verifierPool;
        assertTrue(manager.getBounty(bountyId).finalized);
        assertEq(manager.claimablePayout(issuer, address(usdc)), deferred);
        assertEq(manager.totalClaimablePayout(address(usdc)), deferred);
        assertEq(usdc.balanceOf(address(manager)), deferred);

        vm.prank(issuer);
        manager.claimPayout(address(usdc), payoutRecipient, deferred);
        assertEq(usdc.balanceOf(payoutRecipient), deferred);
        assertEq(manager.totalClaimablePayout(address(usdc)), 0);
    }

    function testDefersRejectedPostFinalizationSolverBondClaim() public {
        address payoutRecipient = address(0xB0B2);
        (uint256 bountyId, uint256 submissionId) = _createUsdcCommitReveal();
        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true);

        _warpPastVerificationDeadline();
        manager.finalize(bountyId, 0);
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, solver, usdcSolverBond),
            abi.encodePacked("solver blocked")
        );

        vm.prank(solver);
        manager.claimSolverBond(bountyId, submissionId);

        assertEq(manager.claimablePayout(solver, address(usdc)), usdcSolverBond);
        assertEq(manager.totalClaimablePayout(address(usdc)), usdcSolverBond);
        assertEq(usdc.balanceOf(address(manager)), usdcSolverBond);

        vm.prank(solver);
        manager.claimPayout(address(usdc), payoutRecipient, usdcSolverBond);
        assertEq(usdc.balanceOf(payoutRecipient), usdcSolverBond);
        assertEq(manager.totalClaimablePayout(address(usdc)), 0);
    }

    function testClaimPayoutRejectsInvalidArguments() public {
        vm.expectRevert(BountyManager.InvalidPayoutClaim.selector);
        manager.claimPayout(address(0), solver, 1);
        vm.expectRevert(BountyManager.InvalidPayoutClaim.selector);
        manager.claimPayout(address(usdc), address(0), 1);
        vm.expectRevert(BountyManager.InvalidPayoutClaim.selector);
        manager.claimPayout(address(usdc), solver, 0);
    }

    function testNoRevealTimeoutReopensThenNoWinnerFinalizationRefundsIssuer() public {
        uint256 issuerBefore = token.balanceOf(issuer);
        uint256 bountyId = _createBounty();
        uint256 submissionId = _commit(bountyId, solver, solutionDigest, salt);

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
        manager.attest(bountyId, submissionId, false);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, false);

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
        manager.attest(bountyId, submissionId, true);

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

    function testOwnerCanSetTreasuryRouter() public {
        TreasuryRouter newRouter = new TreasuryRouter(treasury, owner);
        vm.prank(owner);
        manager.setTreasuryRouter(newRouter);

        assertEq(address(manager.treasuryRouter()), address(newRouter));
    }

    function testOwnerCanUpdateSolverBond() public {
        vm.prank(owner);
        manager.setProtocolParams(75 ether);

        assertEq(manager.solverBond(), 75 ether);
        assertEq(manager.solverBondForToken(address(token)), 75 ether);
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
        uint256 rejectedSubmissionId = _commit(bountyId, solverTwo, keccak256("bad"), keccak256("bad-salt"));
        vm.prank(solverTwo);
        manager.revealSolution(
            bountyId,
            rejectedSubmissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            keccak256("bad"),
            keccak256("bad-salt")
        );
        vm.prank(verifierA);
        manager.attest(bountyId, rejectedSubmissionId, false);
        vm.prank(verifierB);
        manager.attest(bountyId, rejectedSubmissionId, false);

        uint256 winningSubmissionId = _commit(bountyId, solver, solutionDigest, salt);
        vm.prank(solver);
        manager.revealSolution(
            bountyId,
            winningSubmissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );

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
        assertEq(manager.totalClaimablePayout(address(token)), 0);
    }

    function _fund(address account, uint256 amount) internal {
        vm.prank(liquidity);
        assertTrue(token.transfer(account, amount));
    }

    function _stakeVerifier(address verifier) internal {
        vm.prank(owner);
        registry.setOfficialVerifier(verifier, true);
        vm.startPrank(verifier);
        token.approve(address(registry), minimumStake);
        registry.stake(minimumStake, "ipfs://verifier");
        vm.stopPrank();
    }

    function _stakeUnapprovedVerifier(address verifier, uint256 amount) internal {
        _fund(verifier, amount);
        vm.startPrank(verifier);
        token.approve(address(registry), amount);
        registry.stake(amount, "ipfs://candidate");
        vm.stopPrank();
    }

    function _createBounty() internal returns (uint256 bountyId) {
        return _createBountyWithQuorum(2);
    }

    function _createBountyWithQuorum(uint16 verifierQuorum) internal returns (uint256 bountyId) {
        vm.startPrank(issuer);
        token.approve(address(manager), reward + _verifierRewardPool() + postingFee);
        bountyId = manager.createBounty(
            address(token),
            "bafy-instance",
            keccak256("instance"),
            "ipfs://metadata",
            keccak256("metadata"),
            reward,
            postingFee,
            COMMIT_WINDOW,
            REVEAL_WINDOW,
            VERIFICATION_WINDOW,
            verifierQuorum
        );
        vm.stopPrank();
    }

    function _createUsdcBounty() internal returns (uint256 bountyId) {
        vm.startPrank(issuer);
        usdc.approve(address(manager), usdcReward + manager.verifierRewardPoolFor(usdcReward) + usdcPostingFee);
        bountyId = manager.createBounty(
            address(usdc),
            "bafy-usdc-instance",
            keccak256("usdc-instance"),
            "ipfs://usdc-metadata",
            keccak256("usdc-metadata"),
            usdcReward,
            usdcPostingFee,
            COMMIT_WINDOW,
            REVEAL_WINDOW,
            VERIFICATION_WINDOW,
            2
        );
        vm.stopPrank();
    }

    function _expectInvalidBountyConfig(
        uint64 commitWindow,
        uint64 revealWindow,
        uint64 verificationWindow,
        uint16 verifierQuorum
    ) internal {
        vm.startPrank(issuer);
        token.approve(address(manager), reward + _verifierRewardPool() + postingFee);
        vm.expectRevert(BountyManager.InvalidBountyConfig.selector);
        manager.createBounty(
            address(token),
            "bafy-instance",
            keccak256("instance"),
            "ipfs://metadata",
            keccak256("metadata"),
            reward,
            postingFee,
            commitWindow,
            revealWindow,
            verificationWindow,
            verifierQuorum
        );
        vm.stopPrank();
    }

    function _verifierRewardPool() internal view returns (uint256) {
        return manager.verifierRewardPoolFor(reward);
    }

    function _commit(uint256 bountyId, address solver_, bytes32 digest_, bytes32 salt_)
        internal
        returns (uint256 submissionId)
    {
        bytes32 commitHash = manager.computeCommitHash(
            bountyId, solver_, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, digest_, salt_
        );
        vm.startPrank(solver_);
        token.approve(address(manager), solverBond);
        submissionId = manager.commitSolution(bountyId, commitHash);
        vm.stopPrank();
    }

    function _createCommitReveal() internal returns (uint256 bountyId, uint256 submissionId, bytes32 commitHash) {
        bountyId = _createBounty();
        commitHash = manager.computeCommitHash(
            bountyId,
            solver,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );
        vm.startPrank(solver);
        token.approve(address(manager), solverBond);
        submissionId = manager.commitSolution(bountyId, commitHash);
        vm.stopPrank();

        vm.prank(solver);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );
    }

    function _createUsdcCommitReveal() internal returns (uint256 bountyId, uint256 submissionId) {
        bountyId = _createUsdcBounty();
        bytes32 commitHash = manager.computeCommitHash(
            bountyId,
            solver,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );
        vm.startPrank(solver);
        usdc.approve(address(manager), usdcSolverBond);
        submissionId = manager.commitSolution(bountyId, commitHash);
        manager.revealSolution(
            bountyId,
            submissionId,
            BountyManager.SolutionKind.SatAssignment,
            BountyManager.ProofFormat.None,
            solutionDigest,
            salt
        );
        vm.stopPrank();
    }

    function _attestFor(uint256 bountyId, uint256 submissionId) internal {
        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, true);
    }

    function _warpPastVerificationDeadline() internal {
        vm.warp(block.timestamp + VERIFICATION_WINDOW + 1);
    }
}
