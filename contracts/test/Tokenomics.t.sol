// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { SATToken } from "../src/SATToken.sol";
import { TokenVesting } from "../src/TokenVesting.sol";
import { CommunityIncentivesController } from "../src/CommunityIncentivesController.sol";
import { TreasuryReserveController } from "../src/TreasuryReserveController.sol";

contract TokenomicsTest is Test {
    uint256 internal constant S_MAX = 1_000_000_000 ether;
    uint64 internal constant GENESIS = 1_700_000_000;
    uint64 internal constant MONTH = 30 days;
    uint64 internal constant YEAR = 365 days;

    address internal owner = address(0xA11CE);
    address internal team = address(0x1001);
    address internal investor = address(0x1002);
    address internal treasury = address(0x1003);
    address internal communityRecipient = address(0x1004);
    address internal liquidity = address(0x1005);

    SATToken internal token;
    TokenVesting internal teamVesting;
    TokenVesting internal investorVesting;
    CommunityIncentivesController internal community;
    TreasuryReserveController internal reserve;

    function setUp() public {
        vm.warp(GENESIS);
        token = new SATToken(S_MAX, owner);
        teamVesting =
            new TokenVesting(token, team, GENESIS, 12 * MONTH, 24 * MONTH, token.allocationAmount(token.TEAM_BPS()));
        investorVesting = new TokenVesting(
            token, investor, GENESIS, 6 * MONTH, 24 * MONTH, token.allocationAmount(token.INVESTOR_BPS())
        );
        community = new CommunityIncentivesController(token, S_MAX, GENESIS, owner);
        reserve = new TreasuryReserveController(token, S_MAX, GENESIS, treasury, owner);

        vm.prank(owner);
        token.initializeGenesisAllocations(
            address(community), address(reserve), address(teamVesting), address(investorVesting), liquidity
        );
    }

    function testGenesisAllocationCanOnlyInitializeOnceAndTotalSupplyEqualsMax() public {
        assertTrue(token.genesisAllocationsInitialized());
        assertEq(token.totalSupply(), S_MAX);

        vm.prank(owner);
        vm.expectRevert(SATToken.GenesisAlreadyInitialized.selector);
        token.initializeGenesisAllocations(
            address(community), address(reserve), address(teamVesting), address(investorVesting), liquidity
        );
    }

    function testAllocationSumMustEqualSMaxByRejectingNonBpsDivisibleSupply() public {
        vm.expectRevert(SATToken.InvalidMaxSupply.selector);
        new SATToken(S_MAX + 1, owner);
    }

    function testNoAccountCanMintAfterGenesisAllocation() public {
        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", address(this), 1 ether);
        (bool ok,) = address(token).call(callData);
        assertFalse(ok);
        assertEq(token.totalSupply(), S_MAX);
    }

    function testFixedSupplyAllocationBalances() public view {
        assertEq(token.balanceOf(address(community)), (S_MAX * 3_500) / 10_000);
        assertEq(token.balanceOf(address(reserve)), (S_MAX * 2_000) / 10_000);
        assertEq(token.balanceOf(address(teamVesting)), (S_MAX * 1_500) / 10_000);
        assertEq(token.balanceOf(address(investorVesting)), (S_MAX * 2_500) / 10_000);
        assertEq(token.balanceOf(liquidity), (S_MAX * 500) / 10_000);
    }

    function testTeamCannotReleaseBeforeTwelveMonthCliff() public {
        vm.warp(GENESIS + 12 * MONTH - 1);
        assertEq(teamVesting.releasable(), 0);
        vm.expectRevert(TokenVesting.NothingToRelease.selector);
        teamVesting.release();
    }

    function testTeamReleasesLinearlyAfterCliffAndFullyAfterThirtySixMonths() public {
        uint256 allocation = token.allocationAmount(token.TEAM_BPS());

        vm.warp(GENESIS + 24 * MONTH);
        uint256 firstRelease = teamVesting.releasable();
        assertApproxEqAbs(firstRelease, allocation / 2, 2);
        uint256 supplyBefore = token.totalSupply();
        teamVesting.release();
        assertEq(token.balanceOf(team), firstRelease);
        assertEq(token.totalSupply(), supplyBefore);

        vm.warp(GENESIS + 30 * MONTH);
        uint256 secondRelease = teamVesting.releasable();
        assertApproxEqAbs(secondRelease, allocation / 4, 2);
        teamVesting.release();
        assertEq(token.balanceOf(team), firstRelease + secondRelease);

        vm.warp(GENESIS + 36 * MONTH);
        teamVesting.release();
        assertEq(token.balanceOf(team), allocation);
        assertEq(teamVesting.releasable(), 0);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function testInvestorCannotReleaseBeforeSixMonthCliff() public {
        vm.warp(GENESIS + 6 * MONTH - 1);
        assertEq(investorVesting.releasable(), 0);
        vm.expectRevert(TokenVesting.NothingToRelease.selector);
        investorVesting.release();
    }

    function testInvestorReleasesLinearlyAfterCliffAndFullyAfterThirtyMonths() public {
        uint256 allocation = token.allocationAmount(token.INVESTOR_BPS());

        vm.warp(GENESIS + 18 * MONTH);
        investorVesting.release();
        assertApproxEqAbs(token.balanceOf(investor), allocation / 2, 2);

        vm.warp(GENESIS + 30 * MONTH);
        investorVesting.release();
        assertEq(token.balanceOf(investor), allocation);
        assertEq(token.totalSupply(), S_MAX);
    }

    function testCommunityGenesisAndYearlyCapsAreEnforced() public {
        uint256 genesisCap = (S_MAX * 100) / 10_000;
        assertEq(community.availableToRelease(), genesisCap);

        vm.prank(owner);
        vm.expectRevert();
        community.release(communityRecipient, genesisCap + 1, keccak256("too-much"));

        vm.prank(owner);
        community.release(communityRecipient, genesisCap, keccak256("genesis"));
        assertEq(token.balanceOf(communityRecipient), genesisCap);
        assertEq(community.availableToRelease(), 0);

        vm.warp(GENESIS + YEAR);
        uint256 yearOneCap = (S_MAX * 600) / 10_000;
        assertEq(community.availableToRelease(), yearOneCap);

        vm.prank(owner);
        community.release(communityRecipient, yearOneCap, keccak256("year-one"));
        assertEq(token.balanceOf(communityRecipient), genesisCap + yearOneCap);
    }

    function testCommunityOptionalEpochCapCannotExceedCurrentAnnualAvailability() public {
        vm.prank(owner);
        community.setEpochReleaseCap(30 days, (S_MAX * 50) / 10_000);

        uint256 epochCap = (S_MAX * 50) / 10_000;
        vm.prank(owner);
        community.release(communityRecipient, epochCap, keccak256("epoch"));

        vm.prank(owner);
        vm.expectRevert();
        community.release(communityRecipient, 1, keccak256("epoch-over"));
    }

    function testTreasuryBootstrapAndStrategicAvailability() public {
        uint256 bootstrap = (S_MAX * 400) / 10_000;
        uint256 strategic = (S_MAX * 1_600) / 10_000;

        assertEq(reserve.availableTreasuryAmount(GENESIS), bootstrap);
        assertEq(reserve.availableTreasuryAmount(GENESIS + 6 * MONTH - 1), bootstrap);
        assertEq(reserve.releasable(), bootstrap);

        vm.prank(owner);
        vm.expectRevert();
        reserve.releaseToTreasury(bootstrap + 1);

        vm.prank(owner);
        reserve.releaseToTreasury(bootstrap);
        assertEq(token.balanceOf(treasury), bootstrap);

        vm.warp(GENESIS + 36 * MONTH);
        uint256 expectedHalfStrategic = strategic / 2;
        assertApproxEqAbs(reserve.releasable(), expectedHalfStrategic, 2);

        vm.warp(GENESIS + 66 * MONTH);
        assertEq(reserve.availableTreasuryAmount(uint64(block.timestamp)), bootstrap + strategic);
    }
}
