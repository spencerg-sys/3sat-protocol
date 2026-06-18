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
import { ArtifactAccessController, IBountyManagerAccessView } from "../src/ArtifactAccessController.sol";

contract ArtifactAccessControllerTest is Test {
    uint256 internal constant S_MAX = 1_000_000_000 ether;
    uint64 internal constant GENESIS = 1_700_000_000;
    uint64 internal constant MONTH = 30 days;
    uint64 internal constant COMMIT_WINDOW = 1 days;
    uint64 internal constant REVEAL_WINDOW = 1 days;
    uint64 internal constant VERIFICATION_WINDOW = 1 days;
    uint64 internal constant UNBONDING_DELAY = 15 days;
    uint16 internal constant VERIFIER_REWARD_BPS = 200;
    uint16 internal constant DEFAULT_SOLVER_ACCESS_REWARD_BPS = 100;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0x710);
    address internal liquidity = address(0x500);
    address internal issuer = address(0x111);
    address internal solver = address(0x222);
    address internal buyer = address(0x333);
    address internal verifierA = address(0x444);
    address internal verifierB = address(0x445);

    SATToken internal token;
    TreasuryRouter internal router;
    VerifierRegistry internal registry;
    BountyManager internal manager;
    ArtifactAccessController internal access;

    bytes32 internal salt = keccak256("salt");
    string internal solutionRef = "r2://3sat-artifacts-dev/solutions/answer.cnf";
    bytes32 internal solutionDigest = keccak256("solution-bytes");

    uint256 internal reward = 1_000 ether;
    uint256 internal postingFee = 10 ether;
    uint256 internal solverBond = 50 ether;
    uint256 internal minimumStake = 100 ether;
    uint16 internal solverRoyaltyBps = 5_000;

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
        access = new ArtifactAccessController(
            token,
            IBountyManagerAccessView(address(manager)),
            router,
            DEFAULT_SOLVER_ACCESS_REWARD_BPS,
            solverRoyaltyBps,
            owner
        );

        vm.prank(owner);
        registry.setBountyManager(address(manager));

        _fund(issuer, 20_000 ether);
        _fund(solver, 2_000 ether);
        _fund(buyer, 2_000 ether);
        _fund(verifierA, 2_000 ether);
        _fund(verifierB, 2_000 ether);

        _stakeVerifier(verifierA);
        _stakeVerifier(verifierB);
    }

    function testCannotPurchaseSolutionBeforeBountyFinalized() public {
        uint256 bountyId = _createBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.startPrank(buyer);
        token.approve(address(access), _defaultAccessPrice());
        vm.expectRevert(ArtifactAccessController.BountyNotFinalized.selector);
        access.purchaseAccess(bountyId, solutionArtifact);
        vm.stopPrank();
    }

    function testPurchaseSolutionAccessAfterFinalizationSplitsFeeBetweenSolverAndRouter() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint256 solverBefore = token.balanceOf(solver);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 supplyBefore = token.totalSupply();

        (uint256 price, address royaltyRecipient, uint256 solverAmount, uint256 routedAmount) =
            access.accessDistribution(bountyId, access.ARTIFACT_SOLUTION());
        assertEq(price, _defaultAccessPrice());
        assertEq(royaltyRecipient, solver);
        assertEq(solverAmount, 10 ether);
        assertEq(routedAmount, 10 ether);

        vm.startPrank(buyer);
        token.approve(address(access), _defaultAccessPrice());
        access.purchaseAccess(bountyId, access.ARTIFACT_SOLUTION());
        vm.stopPrank();

        assertTrue(access.hasAccess(buyer, bountyId, access.ARTIFACT_SOLUTION()));
        assertTrue(access.canAccess(buyer, bountyId, access.ARTIFACT_SOLUTION()));
        assertEq(token.balanceOf(solver), solverBefore + 10 ether);
        assertEq(token.balanceOf(treasury), treasuryBefore + 8 ether);
        assertEq(token.totalSupply(), supplyBefore - 2 ether);
    }

    function testIssuerCanAccessFinalizedSolutionWithoutPayment() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();
        uint256 issuerBefore = token.balanceOf(issuer);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 supplyBefore = token.totalSupply();

        assertTrue(access.canAccess(issuer, bountyId, solutionArtifact));

        vm.prank(issuer);
        access.purchaseAccess(bountyId, solutionArtifact);

        assertTrue(access.hasAccess(issuer, bountyId, solutionArtifact));
        assertEq(token.balanceOf(issuer), issuerBefore);
        assertEq(token.balanceOf(treasury), treasuryBefore);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function testOwnerCanGrantAccessWithoutPayment() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.prank(owner);
        access.grantAccess(buyer, bountyId, solutionArtifact);

        assertTrue(access.hasAccess(buyer, bountyId, solutionArtifact));
        assertTrue(access.canAccess(buyer, bountyId, solutionArtifact));
    }

    function testDisabledArtifactTypeCannotBePurchased() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.prank(owner);
        access.setArtifactTypeEnabled(solutionArtifact, false);

        vm.startPrank(buyer);
        token.approve(address(access), _defaultAccessPrice());
        vm.expectRevert(ArtifactAccessController.ArtifactTypeDisabled.selector);
        access.purchaseAccess(bountyId, solutionArtifact);
        vm.stopPrank();
    }

    function testCannotPurchaseSolutionWhenFinalizedWithoutWinner() public {
        uint256 bountyId = _createBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();
        vm.warp(GENESIS + COMMIT_WINDOW + REVEAL_WINDOW + VERIFICATION_WINDOW + 1);
        manager.finalize(bountyId, 0);

        assertFalse(access.canAccess(buyer, bountyId, solutionArtifact));

        vm.startPrank(buyer);
        token.approve(address(access), _defaultAccessPrice());
        vm.expectRevert(ArtifactAccessController.NoFinalizedSolution.selector);
        access.purchaseAccess(bountyId, solutionArtifact);
        vm.stopPrank();
    }

    function testOwnerCanLowerSolverRoyaltyBps() public {
        vm.prank(owner);
        access.setSolverRoyaltyBps(2_500);

        (uint256 bountyId,) = _finalizedBounty();
        (, address royaltyRecipient, uint256 solverAmount, uint256 routedAmount) =
            access.accessDistribution(bountyId, access.ARTIFACT_SOLUTION());

        assertEq(access.solverRoyaltyBps(), 2_500);
        assertEq(royaltyRecipient, solver);
        assertEq(solverAmount, 10 ether);
        assertEq(routedAmount, 30 ether);
    }

    function testOwnerCanUpdateDefaultSolverAccessRewardBps() public {
        vm.prank(owner);
        access.setDefaultSolverAccessRewardBps(250);

        (uint256 bountyId,) = _finalizedBounty();
        assertEq(access.defaultSolverAccessRewardBps(), 250);
        assertEq(access.accessPrice(bountyId, access.ARTIFACT_SOLUTION()), 50 ether);
    }

    function testDefaultSolverAccessRewardBpsCannotExceedCap() public {
        vm.prank(owner);
        vm.expectRevert(ArtifactAccessController.InvalidAccessConfig.selector);
        access.setDefaultSolverAccessRewardBps(1_001);
    }

    function testDefaultInstanceAndEvidenceAccessPriceIsZero() public {
        uint256 bountyId = _createBounty();
        assertEq(access.accessPrice(bountyId, access.ARTIFACT_INSTANCE()), 0);
        assertEq(access.accessPrice(bountyId, access.ARTIFACT_EVIDENCE()), 0);
    }

    function testOwnerCanSetCustomFixedAccessPriceForBounty() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.prank(owner);
        access.setAccessPrice(bountyId, solutionArtifact, 3 ether);

        (uint256 price, address royaltyRecipient, uint256 solverAmount, uint256 routedAmount) =
            access.accessDistribution(bountyId, solutionArtifact);
        assertEq(price, 3 ether);
        assertEq(royaltyRecipient, solver);
        assertEq(solverAmount, 1.5 ether);
        assertEq(routedAmount, 1.5 ether);
    }

    function testSolverRoyaltyBpsCannotExceedCap() public {
        vm.prank(owner);
        vm.expectRevert(ArtifactAccessController.InvalidAccessConfig.selector);
        access.setSolverRoyaltyBps(5_001);
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
        token.approve(address(manager), reward + manager.verifierRewardPoolFor(reward) + postingFee);
        bountyId = manager.createBounty(
            "r2://3sat-artifacts-dev/instances/question.cnf",
            keccak256("instance"),
            "r2://3sat-artifacts-dev/metadata/question.json",
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

    function _defaultAccessPrice() internal view returns (uint256) {
        uint256 targetSolverReward = (reward * access.defaultSolverAccessRewardBps()) / 10_000;
        return (targetSolverReward * 10_000) / access.solverRoyaltyBps();
    }

    function _finalizedBounty() internal returns (uint256 bountyId, uint256 submissionId) {
        bountyId = _createBounty();
        bytes32 commitHash = manager.computeCommitHash(bountyId, solver, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest, salt);

        vm.startPrank(solver);
        token.approve(address(manager), solverBond);
        submissionId = manager.commitSolution(bountyId, commitHash);
        vm.stopPrank();

        vm.prank(solver);
        manager.revealSolution(bountyId, submissionId, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest, salt);

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, true, BountyManager.SolutionKind.SatAssignment, BountyManager.ProofFormat.None, solutionRef, solutionDigest);

        manager.finalize(bountyId, submissionId);
    }
}
