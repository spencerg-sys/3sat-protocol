// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

import { SATToken } from "../src/SATToken.sol";
import { TokenVesting } from "../src/TokenVesting.sol";
import { CommunityIncentivesController } from "../src/CommunityIncentivesController.sol";
import { TreasuryReserveController } from "../src/TreasuryReserveController.sol";
import { TreasuryRouter } from "../src/TreasuryRouter.sol";
import { VerifierRegistry } from "../src/VerifierRegistry.sol";
import { BountyManager } from "../src/BountyManager.sol";
import { ArtifactAccessController, IBountyManagerAccessView } from "../src/ArtifactAccessController.sol";

contract Deploy is Script {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    uint64 internal constant MONTH = 30 days;

    error InvalidDeploymentConfig();
    error ProductionDeploymentNotApproved();
    error ProductionGovernanceAddressMustBeContract();

    struct Deployed {
        SATToken token;
        TokenVesting teamVesting;
        TokenVesting investorVesting;
        CommunityIncentivesController community;
        TreasuryReserveController reserve;
        TreasuryRouter router;
        VerifierRegistry registry;
        BountyManager manager;
        ArtifactAccessController accessController;
    }

    function run() external returns (Deployed memory deployed) {
        uint256 maxSupply = vm.envUint("S_MAX");
        address communityProgramOwner = vm.envAddress("COMMUNITY_PROGRAM_OWNER");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address teamBeneficiary = vm.envAddress("TEAM_BENEFICIARY");
        address investorBeneficiary = vm.envAddress("INVESTOR_BENEFICIARY");
        address liquidityAddress = vm.envAddress("LIQUIDITY_ADDRESS");
        address ownerAddress = vm.envAddress("OWNER_ADDRESS");

        uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address deploymentOwner = deployerPrivateKey == 0 ? ownerAddress : vm.addr(deployerPrivateKey);
        uint256 verifierMinimumStake = vm.envOr("VERIFIER_MINIMUM_STAKE", uint256(1_000 ether));
        uint256 verifierUnbondingDelayRaw = vm.envOr("VERIFIER_UNBONDING_DELAY", uint256(15 days));
        uint256 solverBond = vm.envOr("SOLVER_BOND", uint256(10 ether));
        uint256 verifierRewardBpsRaw = vm.envOr("VERIFIER_REWARD_BPS", uint256(200));
        uint256 treasuryBurnBpsRaw = vm.envOr("TREASURY_BURN_BPS", uint256(2_000));
        uint256 defaultSolverAccessRewardBpsRaw = vm.envOr("DEFAULT_SOLVER_ACCESS_REWARD_BPS", uint256(100));
        uint256 solverRoyaltyBpsRaw = vm.envOr("SOLVER_ROYALTY_BPS", uint256(5_000));

        _validateDeploymentConfig(
            maxSupply,
            communityProgramOwner,
            treasury,
            teamBeneficiary,
            investorBeneficiary,
            liquidityAddress,
            ownerAddress,
            verifierMinimumStake,
            verifierUnbondingDelayRaw,
            solverBond,
            verifierRewardBpsRaw,
            treasuryBurnBpsRaw,
            defaultSolverAccessRewardBpsRaw,
            solverRoyaltyBpsRaw
        );
        // Casts are safe after _validateDeploymentConfig bounds checks.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 verifierUnbondingDelay = uint64(verifierUnbondingDelayRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 verifierRewardBps = uint16(verifierRewardBpsRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 treasuryBurnBps = uint16(treasuryBurnBpsRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 defaultSolverAccessRewardBps = uint16(defaultSolverAccessRewardBpsRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 solverRoyaltyBps = uint16(solverRoyaltyBpsRaw);

        if (deployerPrivateKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerPrivateKey);
        }

        deployed.token = new SATToken(maxSupply, deploymentOwner);

        uint64 genesis = uint64(block.timestamp);
        uint256 teamAllocation = deployed.token.allocationAmount(deployed.token.TEAM_BPS());
        uint256 investorAllocation = deployed.token.allocationAmount(deployed.token.INVESTOR_BPS());

        deployed.teamVesting =
            new TokenVesting(deployed.token, teamBeneficiary, genesis, 12 * MONTH, 24 * MONTH, teamAllocation);
        deployed.investorVesting =
            new TokenVesting(deployed.token, investorBeneficiary, genesis, 6 * MONTH, 24 * MONTH, investorAllocation);
        deployed.community = new CommunityIncentivesController(deployed.token, maxSupply, genesis, deploymentOwner);
        deployed.reserve = new TreasuryReserveController(deployed.token, maxSupply, genesis, treasury, deploymentOwner);
        deployed.router = new TreasuryRouter(deployed.token, treasury, treasuryBurnBps, deploymentOwner);
        deployed.registry =
            new VerifierRegistry(deployed.token, verifierMinimumStake, verifierUnbondingDelay, deploymentOwner);
        deployed.manager = new BountyManager(
            deployed.token, deployed.registry, deployed.router, solverBond, verifierRewardBps, deploymentOwner
        );
        deployed.accessController = new ArtifactAccessController(
            deployed.token,
            IBountyManagerAccessView(address(deployed.manager)),
            deployed.router,
            defaultSolverAccessRewardBps,
            solverRoyaltyBps,
            deploymentOwner
        );

        deployed.registry.setBountyManager(address(deployed.manager));
        deployed.token
            .initializeGenesisAllocations(
                address(deployed.community),
                address(deployed.reserve),
                address(deployed.teamVesting),
                address(deployed.investorVesting),
                liquidityAddress
            );

        _validateAllocations(deployed, maxSupply, liquidityAddress);

        deployed.token.transferOwnership(ownerAddress);
        deployed.community.transferOwnership(communityProgramOwner);
        deployed.reserve.transferOwnership(ownerAddress);
        deployed.router.transferOwnership(ownerAddress);
        deployed.registry.transferOwnership(ownerAddress);
        deployed.manager.transferOwnership(ownerAddress);
        deployed.accessController.transferOwnership(ownerAddress);

        vm.stopBroadcast();

        _writeDeploymentJson(deployed, ownerAddress, treasury, liquidityAddress);
        console2.log("3SAT Protocol v1 deployment prepared for chain", block.chainid);
        console2.log("SATToken", address(deployed.token));
        console2.log("BountyManager", address(deployed.manager));
        console2.log("ArtifactAccessController", address(deployed.accessController));
    }

    function _validateDeploymentConfig(
        uint256 maxSupply,
        address communityProgramOwner,
        address treasury,
        address teamBeneficiary,
        address investorBeneficiary,
        address liquidityAddress,
        address ownerAddress,
        uint256 verifierMinimumStake,
        uint256 verifierUnbondingDelayRaw,
        uint256 solverBond,
        uint256 verifierRewardBpsRaw,
        uint256 treasuryBurnBpsRaw,
        uint256 defaultSolverAccessRewardBpsRaw,
        uint256 solverRoyaltyBpsRaw
    ) internal view {
        if (
            maxSupply == 0 || maxSupply % BPS_DENOMINATOR != 0 || communityProgramOwner == address(0)
                || treasury == address(0) || teamBeneficiary == address(0) || investorBeneficiary == address(0)
                || liquidityAddress == address(0) || ownerAddress == address(0) || verifierMinimumStake == 0
                || verifierUnbondingDelayRaw == 0 || verifierUnbondingDelayRaw > type(uint64).max || solverBond == 0
                || verifierRewardBpsRaw > 1_000 || treasuryBurnBpsRaw > BPS_DENOMINATOR || solverRoyaltyBpsRaw > 5_000
                || defaultSolverAccessRewardBpsRaw > 1_000
                || (defaultSolverAccessRewardBpsRaw != 0 && solverRoyaltyBpsRaw == 0)
        ) {
            revert InvalidDeploymentConfig();
        }

        if (_isProductionChain(block.chainid)) {
            if (!vm.envOr("PRODUCTION_DEPLOYMENT_APPROVED", false)) {
                revert ProductionDeploymentNotApproved();
            }
            if (ownerAddress.code.length == 0 || communityProgramOwner.code.length == 0 || treasury.code.length == 0) {
                revert ProductionGovernanceAddressMustBeContract();
            }
        }
    }

    function _isProductionChain(uint256 chainId) internal pure returns (bool) {
        return chainId == ETHEREUM_MAINNET_CHAIN_ID || chainId == ARBITRUM_ONE_CHAIN_ID;
    }

    function _validateAllocations(Deployed memory deployed, uint256 maxSupply, address liquidityAddress) internal view {
        require(deployed.token.balanceOf(address(deployed.community)) == (maxSupply * 3_500) / 10_000, "community");
        require(deployed.token.balanceOf(address(deployed.reserve)) == (maxSupply * 2_000) / 10_000, "treasury");
        require(deployed.token.balanceOf(address(deployed.teamVesting)) == (maxSupply * 1_500) / 10_000, "team");
        require(deployed.token.balanceOf(address(deployed.investorVesting)) == (maxSupply * 2_500) / 10_000, "investor");
        require(deployed.token.balanceOf(liquidityAddress) == (maxSupply * 500) / 10_000, "liquidity");
        require(deployed.token.totalSupply() == maxSupply, "supply");
    }

    function _writeDeploymentJson(
        Deployed memory deployed,
        address ownerAddress,
        address treasuryAddress,
        address liquidityAddress
    ) internal {
        vm.createDir("deployments", true);
        string memory object = "deployment";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "SATToken", address(deployed.token));
        vm.serializeAddress(object, "TeamVesting", address(deployed.teamVesting));
        vm.serializeAddress(object, "InvestorVesting", address(deployed.investorVesting));
        vm.serializeAddress(object, "CommunityIncentivesController", address(deployed.community));
        vm.serializeAddress(object, "TreasuryReserveController", address(deployed.reserve));
        vm.serializeAddress(object, "TreasuryRouter", address(deployed.router));
        vm.serializeAddress(object, "VerifierRegistry", address(deployed.registry));
        vm.serializeAddress(object, "BountyManager", address(deployed.manager));
        vm.serializeAddress(object, "ArtifactAccessController", address(deployed.accessController));
        vm.serializeAddress(object, "OWNER_ADDRESS", ownerAddress);
        vm.serializeAddress(object, "TREASURY_ADDRESS", treasuryAddress);
        string memory json = vm.serializeAddress(object, "LIQUIDITY_ADDRESS", liquidityAddress);
        vm.writeJson(json, string.concat("deployments/3sat-", vm.toString(block.chainid), ".json"));
    }
}
