// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ILegacyBountyManager, MigrateArbitrumSepolia } from "../script/MigrateArbitrumSepolia.s.sol";
import { TreasuryRouter } from "../src/TreasuryRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract MockSettledLegacyBountyManager {
    uint256 public constant nextBountyId = 12;
    bool public settleBountyNineSubmission = true;

    function setSettleBountyNineSubmission(bool settled) external {
        settleBountyNineSubmission = settled;
    }

    function getBounty(uint256 bountyId) external pure returns (ILegacyBountyManager.Bounty memory bounty) {
        if (bountyId > 0 && bountyId < nextBountyId) {
            bounty.issuer = address(0x111);
            bounty.finalized = true;
            bounty.submissionCount = 1;
        }
    }

    function getSubmission(uint256 bountyId, uint256 submissionId)
        external
        view
        returns (ILegacyBountyManager.Submission memory submission)
    {
        if (bountyId > 0 && bountyId < nextBountyId && submissionId == 1) {
            submission.solver = address(0x222);
            submission.bondSettled = bountyId != 9 || settleBountyNineSubmission;
        }
    }
}

contract MigrateArbitrumSepoliaTest is Test {
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant TEST_SIGNER_SEED = 0xA11CE;
    uint256 internal constant MINIMUM_STAKE = 200 ether;

    address internal deployer;
    address internal finalOwner = address(0xF1A1);
    address internal treasury = address(0x710);
    address internal unapprovedVerifier = address(0xBEEF);

    MockERC20 internal sat;
    MockERC20 internal usdc;
    TreasuryRouter internal router;
    MockSettledLegacyBountyManager internal legacyManager;

    function setUp() public {
        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        deployer = vm.addr(TEST_SIGNER_SEED);

        sat = new MockERC20("3SAT Coin", "3SAT", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new TreasuryRouter(treasury, finalOwner);
        vm.startPrank(finalOwner);
        router.setTokenRouting(address(sat), 2_000);
        router.setTokenRouting(address(usdc), 0);
        vm.stopPrank();
        legacyManager = new MockSettledLegacyBountyManager();

        vm.setEnv("MIGRATION_BROADCAST_APPROVED", "true");
        vm.setEnv("MIGRATION_ALLOW_ADDRESS_OVERRIDE", "true");
        vm.setEnv("MIGRATION_DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("MIGRATION_SAT_TOKEN_ADDRESS", vm.toString(address(sat)));
        vm.setEnv("MIGRATION_TREASURY_ROUTER_ADDRESS", vm.toString(address(router)));
        vm.setEnv("MIGRATION_USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("MIGRATION_LEGACY_BOUNTY_MANAGER_ADDRESS", vm.toString(address(legacyManager)));
        vm.setEnv("MIGRATION_EXPECTED_LEGACY_NEXT_BOUNTY_ID", "12");
        vm.setEnv("MIGRATION_FINAL_OWNER_ADDRESS", vm.toString(finalOwner));
        vm.setEnv("MIGRATION_EXPECTED_TREASURY_ADDRESS", vm.toString(treasury));
        vm.setEnv("MIGRATION_VERIFIER_MINIMUM_STAKE", vm.toString(MINIMUM_STAKE));
        vm.setEnv("MIGRATION_OUTPUT_PATH", "deployments/arbitrum-sepolia-migration-test.json");
        sat.mint(deployer, MINIMUM_STAKE);
        vm.setEnv("MIGRATION_OFFICIAL_VERIFIER_ADDRESS", vm.toString(deployer));
        vm.setEnv("MIGRATION_STAKE_OFFICIAL_VERIFIER", "true");
        vm.setEnv("MIGRATION_OFFICIAL_VERIFIER_STAKE_AMOUNT", vm.toString(MINIMUM_STAKE));
        vm.setEnv("MIGRATION_OFFICIAL_VERIFIER_METADATA_URI", "r2://official-verifier");
    }

    function testMigrationSafetyGatesAndOfficialOnlyConfiguration() public {
        vm.chainId(1);
        MigrateArbitrumSepolia wrongChainMigration = new MigrateArbitrumSepolia();
        vm.expectRevert(abi.encodeWithSelector(MigrateArbitrumSepolia.WrongChain.selector, uint256(1)));
        wrongChainMigration.run();

        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        legacyManager.setSettleBountyNineSubmission(false);
        MigrateArbitrumSepolia unsettledBondMigration = new MigrateArbitrumSepolia();
        vm.expectRevert(
            abi.encodeWithSelector(
                MigrateArbitrumSepolia.LegacySubmissionBondNotSettled.selector, uint256(9), uint256(1)
            )
        );
        unsettledBondMigration.run();

        legacyManager.setSettleBountyNineSubmission(true);
        MigrateArbitrumSepolia migration = new MigrateArbitrumSepolia();
        MigrateArbitrumSepolia.MigrationResult memory result = migration.run();

        assertEq(result.expectedTransactionCount, 13);
        assertEq(vm.getNonce(deployer), result.firstBroadcastNonce + result.expectedTransactionCount);
        assertEq(result.registry.owner(), finalOwner);
        assertEq(result.manager.owner(), finalOwner);
        assertEq(result.accessController.owner(), finalOwner);
        assertEq(address(result.registry.token()), address(sat));
        assertEq(address(result.manager.treasuryRouter()), address(router));
        assertEq(result.registry.bountyManager(), address(result.manager));
        assertTrue(result.registry.officialVerifier(deployer));
        assertFalse(result.registry.permissionlessVerificationEnabled());
        assertTrue(result.officialVerifierEligible);
        assertTrue(result.registry.isEligible(deployer));
        assertEq(sat.balanceOf(deployer), 0);
        assertEq(sat.balanceOf(address(result.registry)), MINIMUM_STAKE);
        assertEq(sat.allowance(deployer, address(result.registry)), 0);
        assertEq(result.manager.solverBondForToken(address(sat)), 10 ether);
        assertEq(result.manager.solverBondForToken(address(usdc)), 10_000_000);
        assertEq(result.manager.verifierRewardBps(), 50);
        assertEq(result.accessController.defaultPaymentToken(), address(usdc));
        assertTrue(result.accessController.acceptedPaymentToken(address(sat)));
        assertTrue(result.accessController.defaultAccessUsesBountyPaymentToken());

        // A third party can register and stake, but official-only admission still prevents it from attesting.
        sat.mint(unapprovedVerifier, MINIMUM_STAKE);
        vm.startPrank(unapprovedVerifier);
        sat.approve(address(result.registry), MINIMUM_STAKE);
        result.registry.stake(MINIMUM_STAKE, "r2://unapproved-verifier");
        vm.stopPrank();

        assertFalse(result.registry.officialVerifier(unapprovedVerifier));
        assertFalse(result.registry.isEligible(unapprovedVerifier));
        assertEq(result.registry.getVerifier(unapprovedVerifier).activeStake, MINIMUM_STAKE);
    }
}
