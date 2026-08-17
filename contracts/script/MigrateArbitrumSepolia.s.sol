// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { TreasuryRouter } from "../src/TreasuryRouter.sol";
import { VerifierRegistry } from "../src/VerifierRegistry.sol";
import { BountyManager } from "../src/BountyManager.sol";
import { ArtifactAccessController, IBountyManagerAccessView } from "../src/ArtifactAccessController.sol";

/// @title MigrateArbitrumSepolia
/// @notice Deploys the three non-upgradeable contracts needed for the reviewed Arbitrum Sepolia cutover.
/// @dev The existing SAT token, TreasuryRouter, and USDC are reused and never redeployed or reconfigured.
///      The deployer is a temporary owner. All configuration and invariant checks complete before ownership
///      of the three new contracts is transferred as the final group of transactions.
contract MigrateArbitrumSepolia is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;

    address internal constant CURRENT_SAT_TOKEN = 0x8Fe0e3557773B200995608a43691f3dE9B2e3Fda;
    address internal constant CURRENT_TREASURY_ROUTER = 0x841cD322a95287927a1Abaf6130007659Cc0672E;
    address internal constant CURRENT_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address internal constant CURRENT_BOUNTY_MANAGER = 0x942b326B190d588fE1bb3931502f509c9f9eC767;
    address internal constant CURRENT_PROTOCOL_ADMIN = 0x721b097821EbA304CAd6B43115283081899080ba;
    address internal constant CURRENT_TREASURY = CURRENT_PROTOCOL_ADMIN;
    uint256 internal constant CURRENT_NEXT_BOUNTY_ID = 12;

    uint64 internal constant VERIFIER_UNBONDING_DELAY = 15 days;
    uint256 internal constant SAT_SOLVER_BOND = 10 ether;
    uint256 internal constant USDC_SOLVER_BOND = 10_000_000;
    uint16 internal constant VERIFIER_REWARD_BPS = 50;
    uint16 internal constant SAT_BURN_BPS = 2_000;
    uint16 internal constant USDC_BURN_BPS = 0;
    uint16 internal constant DEFAULT_SOLVER_ACCESS_REWARD_BPS = 100;
    uint16 internal constant SOLVER_ROYALTY_BPS = 5_000;

    string internal constant DEFAULT_OUTPUT_PATH = "deployments/arbitrum-sepolia-migration-421614.json";
    string internal constant BROADCAST_ARTIFACT = "broadcast/MigrateArbitrumSepolia.s.sol/421614/run-latest.json";

    struct MigrationConfig {
        IERC20 satToken;
        IERC20 usdc;
        TreasuryRouter treasuryRouter;
        BountyManager legacyManager;
        address finalOwner;
        address expectedTreasury;
        address officialVerifier;
        address deployer;
        uint256 verifierMinimumStake;
        uint256 expectedLegacyNextBountyId;
        bool stakeOfficialVerifier;
        uint256 officialVerifierStakeAmount;
        string officialVerifierMetadataURI;
        string outputPath;
        bool addressOverrideApproved;
    }

    struct MigrationResult {
        VerifierRegistry registry;
        BountyManager manager;
        ArtifactAccessController accessController;
        uint256 firstBroadcastNonce;
        uint256 expectedTransactionCount;
        bool officialVerifierEligible;
    }

    error WrongChain(uint256 actualChainId);
    error MigrationNotApproved();
    error AddressOverrideNotApproved();
    error InvalidMigrationConfig();
    error MissingCode(address target);
    error ExistingRouterConfigMismatch();
    error LegacyManagerStateMismatch(uint256 actualNextBountyId, uint256 expectedNextBountyId);
    error LegacyBountyNotSettled(uint256 bountyId);
    error LegacySubmissionBondNotSettled(uint256 bountyId, uint256 submissionId);
    error StakeRequiresOfficialVerifierDeployer(address verifier, address deployer);
    error StakeBelowMinimum(uint256 stakeAmount, uint256 minimumStake);
    error InsufficientStakeBalance(uint256 balance, uint256 requiredAmount);
    error MigrationInvariantFailed(bytes32 invariantName);

    function run() external returns (MigrationResult memory result) {
        MigrationConfig memory config = _loadConfig();
        _validatePreflight(config);

        result.firstBroadcastNonce = vm.getNonce(config.deployer);
        result.expectedTransactionCount = config.stakeOfficialVerifier ? 13 : 11;

        // The signer is supplied to Foundry through an encrypted keystore, hardware wallet, or hidden
        // interactive prompt. The script accepts only its public address and never reads a private key.
        vm.startBroadcast(config.deployer);

        // Only these three contracts are created by this migration.
        result.registry = new VerifierRegistry(
            config.satToken, config.verifierMinimumStake, VERIFIER_UNBONDING_DELAY, config.deployer
        );
        result.manager = new BountyManager(
            config.satToken,
            result.registry,
            config.treasuryRouter,
            SAT_SOLVER_BOND,
            VERIFIER_REWARD_BPS,
            config.deployer
        );
        result.accessController = new ArtifactAccessController(
            IBountyManagerAccessView(address(result.manager)),
            config.treasuryRouter,
            address(config.usdc),
            DEFAULT_SOLVER_ACCESS_REWARD_BPS,
            SOLVER_ROYALTY_BPS,
            config.deployer
        );

        // Configure official-only admission. The final owner may later open permissionless admission without
        // redeploying by calling setPermissionlessVerificationEnabled(true).
        result.registry.setPermissionlessVerificationEnabled(false);
        result.registry.setOfficialVerifier(config.officialVerifier, true);
        result.manager.setPaymentTokenConfig(address(config.usdc), true, USDC_SOLVER_BOND);
        result.registry.setBountyManager(address(result.manager));
        result.accessController.setPaymentTokenConfig(address(config.satToken), true);

        if (config.stakeOfficialVerifier) {
            config.satToken.forceApprove(address(result.registry), config.officialVerifierStakeAmount);
            result.registry.stake(config.officialVerifierStakeAmount, config.officialVerifierMetadataURI);
        }

        _validateNewStack(config, result, config.deployer);
        result.officialVerifierEligible = result.registry.isEligible(config.officialVerifier);

        // Ownership transfers are intentionally the final state-changing transactions.
        result.registry.transferOwnership(config.finalOwner);
        result.manager.transferOwnership(config.finalOwner);
        result.accessController.transferOwnership(config.finalOwner);

        vm.stopBroadcast();

        _validateFinalOwnership(config, result);
        _writeDeploymentJson(config, result);

        console2.log("Arbitrum Sepolia migration prepared for chain", block.chainid);
        console2.log("VerifierRegistry", address(result.registry));
        console2.log("BountyManager", address(result.manager));
        console2.log("ArtifactAccessController", address(result.accessController));
        console2.log("Deployment record", config.outputPath);
    }

    function _loadConfig() internal view returns (MigrationConfig memory config) {
        if (!vm.envOr("MIGRATION_BROADCAST_APPROVED", false)) {
            revert MigrationNotApproved();
        }

        config.addressOverrideApproved = vm.envOr("MIGRATION_ALLOW_ADDRESS_OVERRIDE", false);
        config.satToken = IERC20(vm.envOr("MIGRATION_SAT_TOKEN_ADDRESS", CURRENT_SAT_TOKEN));
        config.treasuryRouter = TreasuryRouter(vm.envOr("MIGRATION_TREASURY_ROUTER_ADDRESS", CURRENT_TREASURY_ROUTER));
        config.usdc = IERC20(vm.envOr("MIGRATION_USDC_ADDRESS", CURRENT_USDC));
        config.legacyManager =
            BountyManager(vm.envOr("MIGRATION_LEGACY_BOUNTY_MANAGER_ADDRESS", CURRENT_BOUNTY_MANAGER));
        config.finalOwner = vm.envOr("MIGRATION_FINAL_OWNER_ADDRESS", CURRENT_PROTOCOL_ADMIN);
        config.expectedTreasury = vm.envOr("MIGRATION_EXPECTED_TREASURY_ADDRESS", CURRENT_TREASURY);
        config.expectedLegacyNextBountyId = vm.envOr("MIGRATION_EXPECTED_LEGACY_NEXT_BOUNTY_ID", CURRENT_NEXT_BOUNTY_ID);

        config.deployer = vm.envAddress("MIGRATION_DEPLOYER_ADDRESS");
        config.officialVerifier = vm.envAddress("MIGRATION_OFFICIAL_VERIFIER_ADDRESS");
        config.verifierMinimumStake = vm.envUint("MIGRATION_VERIFIER_MINIMUM_STAKE");
        // The launch operator must make an explicit staking choice. Missing configuration must
        // fail closed instead of silently transferring ownership with no eligible verifier.
        config.stakeOfficialVerifier = vm.envBool("MIGRATION_STAKE_OFFICIAL_VERIFIER");
        if (config.stakeOfficialVerifier) {
            config.officialVerifierStakeAmount = vm.envUint("MIGRATION_OFFICIAL_VERIFIER_STAKE_AMOUNT");
        } else {
            config.officialVerifierStakeAmount = vm.envOr("MIGRATION_OFFICIAL_VERIFIER_STAKE_AMOUNT", uint256(0));
        }
        config.officialVerifierMetadataURI = vm.envOr("MIGRATION_OFFICIAL_VERIFIER_METADATA_URI", string(""));
        config.outputPath = vm.envOr("MIGRATION_OUTPUT_PATH", DEFAULT_OUTPUT_PATH);
    }

    function _validatePreflight(MigrationConfig memory config) internal view {
        if (block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }
        if (
            address(config.satToken) == address(0) || address(config.usdc) == address(0)
                || address(config.treasuryRouter) == address(0) || address(config.satToken) == address(config.usdc)
                || address(config.legacyManager) == address(0) || config.expectedLegacyNextBountyId <= 1
                || config.finalOwner == address(0) || config.expectedTreasury == address(0)
                || config.officialVerifier == address(0) || config.deployer == address(0)
                || config.verifierMinimumStake == 0 || bytes(config.outputPath).length == 0
        ) {
            revert InvalidMigrationConfig();
        }

        if (!config.addressOverrideApproved) {
            if (
                address(config.satToken) != CURRENT_SAT_TOKEN || address(config.usdc) != CURRENT_USDC
                    || address(config.treasuryRouter) != CURRENT_TREASURY_ROUTER
                    || address(config.legacyManager) != CURRENT_BOUNTY_MANAGER
                    || config.expectedLegacyNextBountyId != CURRENT_NEXT_BOUNTY_ID
                    || config.finalOwner != CURRENT_PROTOCOL_ADMIN || config.expectedTreasury != CURRENT_TREASURY
            ) {
                revert AddressOverrideNotApproved();
            }
        }

        _requireCode(address(config.satToken));
        _requireCode(address(config.usdc));
        _requireCode(address(config.treasuryRouter));
        _requireCode(address(config.legacyManager));

        if (
            config.treasuryRouter.owner() != config.finalOwner
                || config.treasuryRouter.treasury() != config.expectedTreasury
                || config.treasuryRouter.burnBps(address(config.satToken)) != SAT_BURN_BPS
                || config.treasuryRouter.burnBps(address(config.usdc)) != USDC_BURN_BPS
        ) {
            revert ExistingRouterConfigMismatch();
        }

        uint256 actualNextBountyId = config.legacyManager.nextBountyId();
        if (actualNextBountyId != config.expectedLegacyNextBountyId) {
            revert LegacyManagerStateMismatch(actualNextBountyId, config.expectedLegacyNextBountyId);
        }
        for (uint256 bountyId = 1; bountyId < actualNextBountyId; bountyId++) {
            BountyManager.Bounty memory legacyBounty = config.legacyManager.getBounty(bountyId);
            if (!legacyBounty.finalized) {
                revert LegacyBountyNotSettled(bountyId);
            }
            for (uint256 submissionId = 1; submissionId <= legacyBounty.submissionCount; submissionId++) {
                if (!config.legacyManager.getSubmission(bountyId, submissionId).bondSettled) {
                    revert LegacySubmissionBondNotSettled(bountyId, submissionId);
                }
            }
        }

        if (!config.stakeOfficialVerifier && config.officialVerifierStakeAmount != 0) {
            revert InvalidMigrationConfig();
        }
        if (config.stakeOfficialVerifier) {
            if (config.officialVerifier != config.deployer) {
                revert StakeRequiresOfficialVerifierDeployer(config.officialVerifier, config.deployer);
            }
            if (config.officialVerifierStakeAmount < config.verifierMinimumStake) {
                revert StakeBelowMinimum(config.officialVerifierStakeAmount, config.verifierMinimumStake);
            }
            uint256 balance = config.satToken.balanceOf(config.deployer);
            if (balance < config.officialVerifierStakeAmount) {
                revert InsufficientStakeBalance(balance, config.officialVerifierStakeAmount);
            }
        }
    }

    function _validateNewStack(
        MigrationConfig memory config,
        MigrationResult memory result,
        address expectedTemporaryOwner
    ) internal view {
        if (
            result.registry.owner() != expectedTemporaryOwner
                || address(result.registry.token()) != address(config.satToken)
                || result.registry.minimumStake() != config.verifierMinimumStake
                || result.registry.unbondingDelay() != VERIFIER_UNBONDING_DELAY
                || result.registry.bountyManager() != address(result.manager)
                || result.registry.permissionlessVerificationEnabled()
                || !result.registry.officialVerifier(config.officialVerifier)
        ) {
            revert MigrationInvariantFailed("registry");
        }

        if (
            result.manager.owner() != expectedTemporaryOwner
                || address(result.manager.token()) != address(config.satToken)
                || address(result.manager.verifierRegistry()) != address(result.registry)
                || address(result.manager.treasuryRouter()) != address(config.treasuryRouter)
                || result.manager.solverBond() != SAT_SOLVER_BOND
                || result.manager.verifierRewardBps() != VERIFIER_REWARD_BPS
                || !result.manager.acceptedPaymentToken(address(config.satToken))
                || !result.manager.acceptedPaymentToken(address(config.usdc))
                || result.manager.solverBondForToken(address(config.satToken)) != SAT_SOLVER_BOND
                || result.manager.solverBondForToken(address(config.usdc)) != USDC_SOLVER_BOND
                || result.manager.nextBountyId() != 1
        ) {
            revert MigrationInvariantFailed("manager");
        }

        if (
            result.accessController.owner() != expectedTemporaryOwner
                || address(result.accessController.bountyManager()) != address(result.manager)
                || result.accessController.bountyManagerEpoch() != 1
                || result.accessController.bountyManagerForEpoch(1) != address(result.manager)
                || address(result.accessController.treasuryRouter()) != address(config.treasuryRouter)
                || result.accessController.defaultPaymentToken() != address(config.usdc)
                || !result.accessController.defaultAccessUsesBountyPaymentToken()
                || result.accessController.defaultSolverAccessRewardBps() != DEFAULT_SOLVER_ACCESS_REWARD_BPS
                || result.accessController.solverRoyaltyBps() != SOLVER_ROYALTY_BPS
                || !result.accessController.acceptedPaymentToken(address(config.satToken))
                || !result.accessController.acceptedPaymentToken(address(config.usdc))
                || !result.accessController.artifactTypeEnabled(result.accessController.ARTIFACT_INSTANCE())
                || !result.accessController.artifactTypeEnabled(result.accessController.ARTIFACT_SOLUTION())
                || !result.accessController.artifactTypeEnabled(result.accessController.ARTIFACT_EVIDENCE())
        ) {
            revert MigrationInvariantFailed("access-controller");
        }

        VerifierRegistry.Verifier memory verifier = result.registry.getVerifier(config.officialVerifier);
        if (config.stakeOfficialVerifier) {
            if (
                !verifier.registered || !verifier.enabled || verifier.activeStake != config.officialVerifierStakeAmount
                    || verifier.pendingUnstake != 0 || !result.registry.isEligible(config.officialVerifier)
                    || config.satToken.allowance(config.deployer, address(result.registry)) != 0
            ) {
                revert MigrationInvariantFailed("official-verifier-stake");
            }
        } else if (
            verifier.registered || verifier.activeStake != 0 || verifier.pendingUnstake != 0
                || result.registry.isEligible(config.officialVerifier)
        ) {
            revert MigrationInvariantFailed("official-verifier-unstaked");
        }
    }

    function _validateFinalOwnership(MigrationConfig memory config, MigrationResult memory result) internal view {
        if (
            result.registry.owner() != config.finalOwner || result.manager.owner() != config.finalOwner
                || result.accessController.owner() != config.finalOwner
        ) {
            revert MigrationInvariantFailed("final-ownership");
        }
    }

    function _requireCode(address target) internal view {
        if (target.code.length == 0) {
            revert MissingCode(target);
        }
    }

    function _writeDeploymentJson(MigrationConfig memory config, MigrationResult memory result) internal {
        vm.createDir("deployments", true);
        string memory object = "arbitrumSepoliaMigration";
        vm.serializeString(object, "migration", "VerifierRegistry+BountyManager+ArtifactAccessController");
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "deployer", config.deployer);
        vm.serializeAddress(object, "finalOwner", config.finalOwner);
        vm.serializeAddress(object, "expectedTreasury", config.expectedTreasury);
        vm.serializeAddress(object, "SATToken", address(config.satToken));
        vm.serializeAddress(object, "TreasuryRouter", address(config.treasuryRouter));
        vm.serializeAddress(object, "USDC", address(config.usdc));
        vm.serializeAddress(object, "legacyBountyManager", address(config.legacyManager));
        vm.serializeUint(object, "legacyNextBountyId", config.expectedLegacyNextBountyId);
        vm.serializeBool(object, "allLegacyBountiesSettled", true);
        vm.serializeBool(object, "allLegacySubmissionBondsSettled", true);
        vm.serializeAddress(object, "VerifierRegistry", address(result.registry));
        vm.serializeAddress(object, "BountyManager", address(result.manager));
        vm.serializeAddress(object, "ArtifactAccessController", address(result.accessController));
        vm.serializeAddress(object, "officialVerifier", config.officialVerifier);
        vm.serializeUint(object, "verifierMinimumStake", config.verifierMinimumStake);
        vm.serializeUint(object, "verifierUnbondingDelay", VERIFIER_UNBONDING_DELAY);
        vm.serializeBool(object, "permissionlessVerificationEnabled", false);
        vm.serializeBool(object, "stakeOfficialVerifier", config.stakeOfficialVerifier);
        vm.serializeUint(object, "officialVerifierStakeAmount", config.officialVerifierStakeAmount);
        vm.serializeBool(object, "officialVerifierEligible", result.officialVerifierEligible);
        vm.serializeString(object, "officialVerifierMetadataURI", config.officialVerifierMetadataURI);
        vm.serializeUint(object, "satSolverBond", SAT_SOLVER_BOND);
        vm.serializeUint(object, "usdcSolverBond", USDC_SOLVER_BOND);
        vm.serializeUint(object, "verifierRewardBps", VERIFIER_REWARD_BPS);
        vm.serializeAddress(object, "defaultAccessPaymentToken", address(config.usdc));
        vm.serializeBool(object, "defaultAccessUsesBountyPaymentToken", true);
        vm.serializeUint(object, "defaultSolverAccessRewardBps", DEFAULT_SOLVER_ACCESS_REWARD_BPS);
        vm.serializeUint(object, "solverRoyaltyBps", SOLVER_ROYALTY_BPS);
        vm.serializeUint(object, "satBurnBps", SAT_BURN_BPS);
        vm.serializeUint(object, "usdcBurnBps", USDC_BURN_BPS);
        vm.serializeUint(object, "firstBroadcastNonce", result.firstBroadcastNonce);
        vm.serializeUint(object, "expectedTransactionCount", result.expectedTransactionCount);
        vm.serializeUint(
            object, "expectedLastBroadcastNonce", result.firstBroadcastNonce + result.expectedTransactionCount - 1
        );
        vm.serializeString(object, "transactionReceiptSource", BROADCAST_ARTIFACT);
        vm.serializeString(
            object,
            "indexerStartBlockSource",
            "Use the BountyManager CREATE receipt blockNumber from transactionReceiptSource"
        );
        vm.serializeBool(object, "containsPrivateKey", false);
        string memory json = vm.serializeBool(object, "addressOverrideApproved", config.addressOverrideApproved);
        vm.writeJson(json, config.outputPath);
    }
}
