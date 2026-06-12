// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title 3SAT fixed-supply ERC-20 token
/// @notice Supply is minted exactly once through genesis allocations. There is no post-genesis mint path.
contract SATToken is ERC20, ERC20Burnable, Ownable {
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant COMMUNITY_BPS = 3_500;
    uint16 public constant TREASURY_BPS = 2_000;
    uint16 public constant TEAM_BPS = 1_500;
    uint16 public constant INVESTOR_BPS = 2_500;
    uint16 public constant LIQUIDITY_BPS = 500;

    bytes32 public constant COMMUNITY_ALLOCATION = keccak256("COMMUNITY_ALLOCATION");
    bytes32 public constant TREASURY_ALLOCATION = keccak256("TREASURY_ALLOCATION");
    bytes32 public constant TEAM_ALLOCATION = keccak256("TEAM_ALLOCATION");
    bytes32 public constant INVESTOR_ALLOCATION = keccak256("INVESTOR_ALLOCATION");
    bytes32 public constant LIQUIDITY_ALLOCATION = keccak256("LIQUIDITY_ALLOCATION");

    uint256 public immutable S_MAX;
    bool public genesisAllocationsInitialized;

    event GenesisAllocationsInitialized(uint256 indexed totalSupply);
    event GenesisAllocation(bytes32 indexed allocationId, address indexed recipient, uint256 amount, uint16 bps);

    error InvalidMaxSupply();
    error GenesisAlreadyInitialized();
    error InvalidGenesisRecipient();
    error AllocationSumMismatch(uint256 expected, uint256 actual);

    constructor(uint256 maxSupply_, address initialOwner) ERC20("3SAT Coin", "3SAT") Ownable(initialOwner) {
        if (maxSupply_ == 0 || maxSupply_ % BPS_DENOMINATOR != 0) {
            revert InvalidMaxSupply();
        }
        S_MAX = maxSupply_;
    }

    function initializeGenesisAllocations(
        address communityController,
        address treasuryReserveController,
        address teamVesting,
        address investorVesting,
        address liquidityRecipient
    ) external onlyOwner {
        if (genesisAllocationsInitialized) {
            revert GenesisAlreadyInitialized();
        }
        if (
            communityController == address(0) || treasuryReserveController == address(0) || teamVesting == address(0)
                || investorVesting == address(0) || liquidityRecipient == address(0)
        ) {
            revert InvalidGenesisRecipient();
        }

        genesisAllocationsInitialized = true;

        uint256 communityAmount = allocationAmount(COMMUNITY_BPS);
        uint256 treasuryAmount = allocationAmount(TREASURY_BPS);
        uint256 teamAmount = allocationAmount(TEAM_BPS);
        uint256 investorAmount = allocationAmount(INVESTOR_BPS);
        uint256 liquidityAmount = allocationAmount(LIQUIDITY_BPS);
        uint256 total = communityAmount + treasuryAmount + teamAmount + investorAmount + liquidityAmount;
        if (total != S_MAX) {
            revert AllocationSumMismatch(S_MAX, total);
        }

        _mintAllocation(COMMUNITY_ALLOCATION, communityController, communityAmount, COMMUNITY_BPS);
        _mintAllocation(TREASURY_ALLOCATION, treasuryReserveController, treasuryAmount, TREASURY_BPS);
        _mintAllocation(TEAM_ALLOCATION, teamVesting, teamAmount, TEAM_BPS);
        _mintAllocation(INVESTOR_ALLOCATION, investorVesting, investorAmount, INVESTOR_BPS);
        _mintAllocation(LIQUIDITY_ALLOCATION, liquidityRecipient, liquidityAmount, LIQUIDITY_BPS);

        emit GenesisAllocationsInitialized(totalSupply());
    }

    function allocationAmount(uint16 bps) public view returns (uint256) {
        return (S_MAX * bps) / BPS_DENOMINATOR;
    }

    function _mintAllocation(bytes32 allocationId, address recipient, uint256 amount, uint16 bps) internal {
        _mint(recipient, amount);
        emit GenesisAllocation(allocationId, recipient, amount, bps);
    }
}
