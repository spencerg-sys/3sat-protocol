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
import { MockERC20 } from "./mocks/MockERC20.sol";

contract MockBountyManagerAccessView is IBountyManagerAccessView {
    mapping(uint256 bountyId => Bounty bounty) private bounties;
    mapping(uint256 bountyId => address solver) private winningSolvers;

    function setBounty(uint256 bountyId, Bounty calldata bounty, address winningSolver) external {
        bounties[bountyId] = bounty;
        winningSolvers[bountyId] = winningSolver;
    }

    function getBounty(uint256 bountyId) external view override returns (Bounty memory) {
        return bounties[bountyId];
    }

    function finalizedWinningSolver(uint256 bountyId) external view override returns (address) {
        return winningSolvers[bountyId];
    }
}

contract ArtifactAccessControllerTest is Test {
    uint256 internal constant S_MAX = 1_000_000_000 ether;
    uint64 internal constant GENESIS = 1_700_000_000;
    uint64 internal constant MONTH = 30 days;
    uint64 internal constant COMMIT_WINDOW = 1 hours;
    uint64 internal constant REVEAL_WINDOW = 1 hours;
    uint64 internal constant VERIFICATION_WINDOW = 1 hours;
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
    MockERC20 internal usdc;
    TreasuryRouter internal router;
    VerifierRegistry internal registry;
    BountyManager internal manager;
    ArtifactAccessController internal access;

    bytes32 internal salt = keccak256("salt");
    bytes32 internal solutionDigest = keccak256("solution-bytes");

    uint256 internal reward = 1_000 ether;
    uint256 internal postingFee = 10 ether;
    uint256 internal solverBond = 50 ether;
    uint256 internal usdcReward = 1_000e6;
    uint256 internal usdcPostingFee = 10e6;
    uint256 internal usdcSolverBond = 50e6;
    uint256 internal minimumStake = 100 ether;
    uint16 internal solverRoyaltyBps = 5_000;

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
        access = new ArtifactAccessController(
            IBountyManagerAccessView(address(manager)),
            router,
            address(token),
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
        usdc.mint(issuer, 20_000e6);
        usdc.mint(solver, 2_000e6);
        usdc.mint(buyer, 2_000e6);

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
        access.purchaseAccess(
            bountyId,
            access.ARTIFACT_SOLUTION(),
            address(token),
            _defaultAccessPrice(),
            block.timestamp + 30 minutes,
            access.bountyManagerEpoch()
        );
        vm.stopPrank();

        assertTrue(access.hasAccess(buyer, bountyId, access.ARTIFACT_SOLUTION()));
        assertTrue(access.canAccess(buyer, bountyId, access.ARTIFACT_SOLUTION()));
        assertEq(token.balanceOf(solver), solverBefore + 10 ether);
        assertEq(token.balanceOf(treasury), treasuryBefore + 8 ether);
        assertEq(token.totalSupply(), supplyBefore - 2 ether);
    }

    function testUsdcSolutionAccessRoutesTreasuryShareWithoutBurn() public {
        vm.startPrank(owner);
        access.setPaymentTokenConfig(address(usdc), true);
        access.setDefaultPaymentToken(address(usdc));
        vm.stopPrank();

        (uint256 bountyId,) = _finalizedUsdcBounty();
        uint256 solverBefore = usdc.balanceOf(solver);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 supplyBefore = usdc.totalSupply();

        (uint256 price, address royaltyRecipient, uint256 solverAmount, uint256 routedAmount) =
            access.accessDistribution(bountyId, access.ARTIFACT_SOLUTION());
        assertEq(price, 20e6);
        assertEq(royaltyRecipient, solver);
        assertEq(solverAmount, 10e6);
        assertEq(routedAmount, 10e6);

        vm.startPrank(buyer);
        usdc.approve(address(access), price);
        access.purchaseAccess(
            bountyId,
            access.ARTIFACT_SOLUTION(),
            address(usdc),
            price,
            block.timestamp + 30 minutes,
            access.bountyManagerEpoch()
        );
        vm.stopPrank();

        assertTrue(access.hasAccess(buyer, bountyId, access.ARTIFACT_SOLUTION()));
        assertEq(usdc.balanceOf(solver), solverBefore + 10e6);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + 10e6);
        assertEq(usdc.totalSupply(), supplyBefore);
    }

    function testUnpricedCrossTokenSolutionAccessCannotBePurchased() public {
        vm.prank(owner);
        access.setPaymentTokenConfig(address(usdc), true);

        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.startPrank(buyer);
        vm.expectRevert(ArtifactAccessController.AccessPriceUnconfigured.selector);
        access.purchaseAccess(bountyId, solutionArtifact, address(usdc));
        vm.stopPrank();

        vm.prank(owner);
        access.setAccessPrice(bountyId, solutionArtifact, address(usdc), 20e6);

        vm.startPrank(buyer);
        usdc.approve(address(access), 20e6);
        access.purchaseAccess(
            bountyId, solutionArtifact, address(usdc), 20e6, block.timestamp + 30 minutes, access.bountyManagerEpoch()
        );
        vm.stopPrank();

        assertTrue(access.hasAccess(buyer, bountyId, solutionArtifact));
    }

    function testDefaultAnswerAccessUsesBountyPaymentToken() public {
        vm.startPrank(owner);
        access.setPaymentTokenConfig(address(usdc), true);
        access.setDefaultPaymentToken(address(usdc));
        vm.stopPrank();

        (uint256 bountyId,) = _finalizedBounty();

        assertEq(access.accessPrice(bountyId, access.ARTIFACT_SOLUTION()), _defaultAccessPrice());

        vm.startPrank(buyer);
        token.approve(address(access), _defaultAccessPrice());
        access.purchaseAccess(
            bountyId,
            access.ARTIFACT_SOLUTION(),
            address(token),
            _defaultAccessPrice(),
            block.timestamp + 30 minutes,
            access.bountyManagerEpoch()
        );
        vm.stopPrank();

        assertTrue(access.hasAccess(buyer, bountyId, access.ARTIFACT_SOLUTION()));
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
        access.setAccessPrice(bountyId, solutionArtifact, address(token), 3 ether);

        (uint256 price, address royaltyRecipient, uint256 solverAmount, uint256 routedAmount) =
            access.accessDistribution(bountyId, solutionArtifact);
        assertEq(price, 3 ether);
        assertEq(royaltyRecipient, solver);
        assertEq(solverAmount, 1.5 ether);
        assertEq(routedAmount, 1.5 ether);
    }

    function testAccessQuoteDistinguishesDefaultPublicAndPricedPaths() public {
        uint256 bountyId = _createBounty();

        (ArtifactAccessController.AccessStatus solutionStatus, address solutionToken, uint256 solutionPrice) =
            access.accessQuote(bountyId, access.ARTIFACT_SOLUTION());
        (ArtifactAccessController.AccessStatus instanceStatus, address instanceToken, uint256 instancePrice) =
            access.accessQuote(bountyId, access.ARTIFACT_INSTANCE());
        (ArtifactAccessController.AccessStatus evidenceStatus, address evidenceToken, uint256 evidencePrice) =
            access.accessQuote(bountyId, access.ARTIFACT_EVIDENCE());

        assertEq(uint256(solutionStatus), uint256(ArtifactAccessController.AccessStatus.Priced));
        assertEq(solutionToken, address(token));
        assertEq(solutionPrice, _defaultAccessPrice());
        assertEq(uint256(instanceStatus), uint256(ArtifactAccessController.AccessStatus.Public));
        assertEq(instanceToken, address(token));
        assertEq(instancePrice, 0);
        assertEq(uint256(evidenceStatus), uint256(ArtifactAccessController.AccessStatus.Public));
        assertEq(evidenceToken, address(token));
        assertEq(evidencePrice, 0);
        assertTrue(access.canAccess(buyer, bountyId, access.ARTIFACT_INSTANCE()));
        assertTrue(access.canAccess(buyer, bountyId, access.ARTIFACT_EVIDENCE()));
    }

    function testUnconfiguredAlternativeTokenCannotGrantAnyArtifactAccess() public {
        vm.prank(owner);
        access.setPaymentTokenConfig(address(usdc), true);
        (uint256 bountyId,) = _finalizedBounty();
        uint8[3] memory artifactTypes =
            [access.ARTIFACT_INSTANCE(), access.ARTIFACT_SOLUTION(), access.ARTIFACT_EVIDENCE()];
        uint256 currentEpoch = access.bountyManagerEpoch();

        vm.startPrank(buyer);
        for (uint256 i = 0; i < artifactTypes.length; i++) {
            (ArtifactAccessController.AccessStatus status, uint256 price) =
                access.accessQuote(bountyId, artifactTypes[i], address(usdc));
            assertEq(uint256(status), uint256(ArtifactAccessController.AccessStatus.Unconfigured));
            assertEq(price, 0);

            (uint256 distributedPrice,, uint256 solverAmount, uint256 routedAmount) =
                access.accessDistribution(bountyId, artifactTypes[i], address(usdc));
            assertEq(distributedPrice, 0);
            assertEq(solverAmount, 0);
            assertEq(routedAmount, 0);

            vm.expectRevert(ArtifactAccessController.AccessPriceUnconfigured.selector);
            access.purchaseAccess(
                bountyId, artifactTypes[i], address(usdc), 0, block.timestamp + 30 minutes, currentEpoch
            );
            assertFalse(access.hasAccess(buyer, bountyId, artifactTypes[i]));
        }
        vm.stopPrank();
    }

    function testCustomPricedPublicByDefaultArtifactsCannotBeBypassedWithAlternativeToken() public {
        vm.startPrank(owner);
        access.setPaymentTokenConfig(address(usdc), true);
        vm.stopPrank();
        uint256 bountyId = _createBounty();
        uint8[2] memory artifactTypes = [access.ARTIFACT_INSTANCE(), access.ARTIFACT_EVIDENCE()];
        uint256 currentEpoch = access.bountyManagerEpoch();

        for (uint256 i = 0; i < artifactTypes.length; i++) {
            vm.prank(owner);
            access.setAccessPrice(bountyId, artifactTypes[i], address(token), 5 ether);

            assertFalse(access.canAccess(buyer, bountyId, artifactTypes[i]));
            (ArtifactAccessController.AccessStatus defaultStatus,, uint256 defaultPrice) =
                access.accessQuote(bountyId, artifactTypes[i]);
            (ArtifactAccessController.AccessStatus alternativeStatus, uint256 alternativePrice) =
                access.accessQuote(bountyId, artifactTypes[i], address(usdc));
            assertEq(uint256(defaultStatus), uint256(ArtifactAccessController.AccessStatus.Priced));
            assertEq(defaultPrice, 5 ether);
            assertEq(uint256(alternativeStatus), uint256(ArtifactAccessController.AccessStatus.Unconfigured));
            assertEq(alternativePrice, 0);

            vm.prank(buyer);
            vm.expectRevert(ArtifactAccessController.AccessPriceUnconfigured.selector);
            access.purchaseAccess(
                bountyId, artifactTypes[i], address(usdc), 0, block.timestamp + 30 minutes, currentEpoch
            );
            assertFalse(access.hasAccess(buyer, bountyId, artifactTypes[i]));
        }
    }

    function testDisabledPaymentTokenDoesNotMakeSolutionPublicAndKeepsPurchasedRights() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.startPrank(buyer);
        token.approve(address(access), _defaultAccessPrice());
        access.purchaseAccess(
            bountyId,
            solutionArtifact,
            address(token),
            _defaultAccessPrice(),
            block.timestamp + 30 minutes,
            access.bountyManagerEpoch()
        );
        vm.stopPrank();

        vm.prank(owner);
        access.setPaymentTokenConfig(address(token), false);

        address newBuyer = address(0x334);
        (ArtifactAccessController.AccessStatus status, uint256 quotedPrice) =
            access.accessQuote(bountyId, solutionArtifact, address(token));
        (uint256 price, address royaltyRecipient, uint256 solverAmount, uint256 routedAmount) =
            access.accessDistribution(bountyId, solutionArtifact, address(token));
        assertEq(uint256(status), uint256(ArtifactAccessController.AccessStatus.Disabled));
        assertEq(quotedPrice, 0);
        assertEq(price, 0);
        assertEq(royaltyRecipient, solver);
        assertEq(solverAmount, 0);
        assertEq(routedAmount, 0);
        assertTrue(access.canAccess(buyer, bountyId, solutionArtifact));
        assertFalse(access.canAccess(newBuyer, bountyId, solutionArtifact));

        uint256 currentEpoch = access.bountyManagerEpoch();
        vm.prank(newBuyer);
        vm.expectRevert(ArtifactAccessController.PaymentTokenDisabled.selector);
        access.purchaseAccess(bountyId, solutionArtifact, address(token), 0, block.timestamp + 30 minutes, currentEpoch);
        assertFalse(access.hasAccess(newBuyer, bountyId, solutionArtifact));
    }

    function testLegacyPaidPurchaseRequiresProtectedOverload() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.startPrank(buyer);
        vm.expectRevert(ArtifactAccessController.ProtectedPurchaseRequired.selector);
        access.purchaseAccess(bountyId, solutionArtifact);
        vm.expectRevert(ArtifactAccessController.ProtectedPurchaseRequired.selector);
        access.purchaseAccess(bountyId, solutionArtifact, address(token));
        vm.stopPrank();

        assertFalse(access.hasAccess(buyer, bountyId, solutionArtifact));
    }

    function testProtectedPurchaseRejectsPriceIncreaseAboveQuoteAndExpiredDeadline() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();
        (uint256 quotedEpoch, ArtifactAccessController.AccessStatus status, address paymentToken, uint256 quotedPrice) =
            access.accessQuoteWithEpoch(bountyId, solutionArtifact);
        assertEq(uint256(status), uint256(ArtifactAccessController.AccessStatus.Priced));

        uint256 increasedPrice = quotedPrice + 1 ether;
        vm.prank(owner);
        access.setAccessPrice(bountyId, solutionArtifact, paymentToken, increasedPrice);

        uint256 buyerBefore = token.balanceOf(buyer);
        vm.startPrank(buyer);
        token.approve(address(access), increasedPrice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactAccessController.AccessPriceAboveMaximum.selector, increasedPrice, quotedPrice
            )
        );
        access.purchaseAccess(
            bountyId, solutionArtifact, paymentToken, quotedPrice, block.timestamp + 30 minutes, quotedEpoch
        );

        uint256 expiredDeadline = block.timestamp - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactAccessController.AccessDeadlineExpired.selector, expiredDeadline, block.timestamp
            )
        );
        access.purchaseAccess(bountyId, solutionArtifact, paymentToken, increasedPrice, expiredDeadline, quotedEpoch);
        vm.stopPrank();

        assertFalse(access.hasAccess(buyer, bountyId, solutionArtifact));
        assertEq(token.balanceOf(buyer), buyerBefore);
    }

    function testZeroDefaultFormulaIsUnconfiguredUntilExplicitlyMadePublic() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.prank(owner);
        access.setDefaultSolverAccessRewardBps(0);

        (ArtifactAccessController.AccessStatus unconfiguredStatus, uint256 unconfiguredPrice) =
            access.accessQuote(bountyId, solutionArtifact, address(token));
        assertEq(uint256(unconfiguredStatus), uint256(ArtifactAccessController.AccessStatus.Unconfigured));
        assertEq(unconfiguredPrice, 0);
        assertFalse(access.canAccess(buyer, bountyId, solutionArtifact));

        vm.prank(buyer);
        vm.expectRevert(ArtifactAccessController.AccessPriceUnconfigured.selector);
        access.purchaseAccess(bountyId, solutionArtifact);

        vm.prank(owner);
        access.setAccessPrice(bountyId, solutionArtifact, address(token), 0);

        (ArtifactAccessController.AccessStatus publicStatus, uint256 publicPrice) =
            access.accessQuote(bountyId, solutionArtifact, address(token));
        assertEq(uint256(publicStatus), uint256(ArtifactAccessController.AccessStatus.Public));
        assertEq(publicPrice, 0);
        assertTrue(access.canAccess(buyer, bountyId, solutionArtifact));

        vm.prank(buyer);
        access.purchaseAccess(bountyId, solutionArtifact);
        assertTrue(access.hasAccess(buyer, bountyId, solutionArtifact));
    }

    function testBountyManagerEpochIsolatesReusedIdsPricesAndAccessRights() public {
        (uint256 bountyId,) = _finalizedBounty();
        uint8 solutionArtifact = access.ARTIFACT_SOLUTION();

        vm.startPrank(owner);
        access.setAccessPrice(bountyId, solutionArtifact, address(token), 3 ether);
        access.grantAccess(buyer, bountyId, solutionArtifact);
        vm.stopPrank();

        (uint256 oldEpoch, ArtifactAccessController.AccessStatus oldStatus, address oldPaymentToken, uint256 oldPrice) =
            access.accessQuoteWithEpoch(bountyId, solutionArtifact);
        assertEq(oldEpoch, 1);
        assertEq(uint256(oldStatus), uint256(ArtifactAccessController.AccessStatus.Priced));
        assertEq(oldPaymentToken, address(token));
        assertEq(oldPrice, 3 ether);
        assertEq(access.bountyManagerForEpoch(oldEpoch), address(manager));
        assertTrue(access.hasAccessAtEpoch(oldEpoch, buyer, bountyId, solutionArtifact));

        MockBountyManagerAccessView replacement = new MockBountyManagerAccessView();
        IBountyManagerAccessView.Bounty memory reusedBounty =
            IBountyManagerAccessView(address(manager)).getBounty(bountyId);
        reusedBounty.issuer = address(0x999);
        reusedBounty.reward = 2_000 ether;
        replacement.setBounty(bountyId, reusedBounty, address(0x777));

        vm.prank(owner);
        access.setBountyManager(IBountyManagerAccessView(address(replacement)));

        uint256 newEpoch = access.bountyManagerEpoch();
        assertEq(newEpoch, 2);
        assertEq(access.bountyManagerForEpoch(newEpoch), address(replacement));
        assertFalse(access.hasAccess(buyer, bountyId, solutionArtifact));
        assertTrue(access.hasAccessAtEpoch(oldEpoch, buyer, bountyId, solutionArtifact));
        assertFalse(access.canAccess(buyer, bountyId, solutionArtifact));

        uint256 buyerBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ArtifactAccessController.BountyManagerEpochMismatch.selector, oldEpoch, newEpoch)
        );
        access.purchaseAccess(
            bountyId, solutionArtifact, oldPaymentToken, oldPrice, block.timestamp + 30 minutes, oldEpoch
        );
        assertEq(token.balanceOf(buyer), buyerBefore);
        assertFalse(access.hasAccess(buyer, bountyId, solutionArtifact));

        (ArtifactAccessController.AccessStatus newStatus,, uint256 newPrice) =
            access.accessQuote(bountyId, solutionArtifact);
        assertEq(uint256(newStatus), uint256(ArtifactAccessController.AccessStatus.Priced));
        assertEq(newPrice, 40 ether);

        vm.prank(owner);
        access.grantAccess(buyer, bountyId, solutionArtifact);
        assertTrue(access.hasAccessAtEpoch(newEpoch, buyer, bountyId, solutionArtifact));

        vm.prank(owner);
        access.setBountyManager(IBountyManagerAccessView(address(replacement)));
        assertEq(access.bountyManagerEpoch(), newEpoch);
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
        vm.prank(owner);
        registry.setOfficialVerifier(verifier, true);
        vm.startPrank(verifier);
        token.approve(address(registry), minimumStake);
        registry.stake(minimumStake, "ipfs://verifier");
        vm.stopPrank();
    }

    function _createBounty() internal returns (uint256 bountyId) {
        vm.startPrank(issuer);
        token.approve(address(manager), reward + manager.verifierRewardPoolFor(reward) + postingFee);
        bountyId = manager.createBounty(
            address(token),
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

    function _createUsdcBounty() internal returns (uint256 bountyId) {
        vm.startPrank(issuer);
        usdc.approve(address(manager), usdcReward + manager.verifierRewardPoolFor(usdcReward) + usdcPostingFee);
        bountyId = manager.createBounty(
            address(usdc),
            "r2://3sat-artifacts-dev/instances/usdc-question.cnf",
            keccak256("usdc-instance"),
            "r2://3sat-artifacts-dev/metadata/usdc-question.json",
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

    function _defaultAccessPrice() internal view returns (uint256) {
        uint256 targetSolverReward = (reward * access.defaultSolverAccessRewardBps()) / 10_000;
        return (targetSolverReward * 10_000) / access.solverRoyaltyBps();
    }

    function _finalizedBounty() internal returns (uint256 bountyId, uint256 submissionId) {
        bountyId = _createBounty();
        bytes32 commitHash = manager.computeCommitHash(
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

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, true);

        manager.finalize(bountyId, submissionId);
    }

    function _finalizedUsdcBounty() internal returns (uint256 bountyId, uint256 submissionId) {
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

        vm.prank(verifierA);
        manager.attest(bountyId, submissionId, true);
        vm.prank(verifierB);
        manager.attest(bountyId, submissionId, true);

        manager.finalize(bountyId, submissionId);
    }
}
