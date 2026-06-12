# 3SAT Protocol

3SAT Protocol is an open-source smart contract system for SAT problem markets on EVM chains.

The protocol lets an issuer escrow a token-denominated bounty for a SAT/CNF instance, lets solvers submit solutions through a commit-reveal flow, lets staked verifiers attest to revealed submissions, and settles rewards once the verification rules are satisfied.

`3SAT` is an ERC-20 token. The protocol is not a new blockchain, rollup, bridge, validator network, wrapped-token system, faucet, or gas coin. Users pay gas with the native asset of the chain where the contracts are deployed.

## What The Protocol Does

- Issuers post SAT/CNF bounties and escrow the bounty reward.
- Solvers commit to a solution before revealing the solution reference and digest.
- Verifiers stake `3SAT`, check revealed submissions, and attest accept or reject.
- Accepted submissions can be finalized by protocol automation or any eligible caller.
- Finalized answers can be made available through paid artifact access.
- Protocol fees can be routed between burn and treasury.

The web application, indexer, storage service, solver clients, and verifier clients are separate from this contract repository.

## Repository Layout

- `contracts/src`: Solidity contracts.
- `contracts/script`: Foundry deployment script.
- `contracts/test`: Foundry tests.
- `contracts/lib`: vendored Foundry dependencies used by the test suite.
- `contracts/deployments`: optional generated deployment records; JSON files are ignored by default.
- `docs`: supplementary protocol notes.

## Core Contracts

- `SATToken`: fixed-supply `3SAT` ERC-20 with one-time genesis allocation.
- `TokenVesting`: token vesting vault used for team and investor allocations.
- `CommunityIncentivesController`: community allocation controller with cumulative annual caps.
- `TreasuryReserveController`: treasury reserve controller with bootstrap and strategic unlock schedules.
- `TreasuryRouter`: routes protocol fees between token burn and treasury distribution.
- `VerifierRegistry`: verifier staking, eligibility, unbonding, disablement, and authorized slashing.
- `BountyManager`: bounty escrow, solver commit-reveal, solver bonds, verifier attestations, quorum, finalization, and reward accounting.
- `ArtifactAccessController`: paid access rights for finalized solution artifacts.
- `ProtocolTimelock`: optional OpenZeppelin timelock wrapper for future governance ownership.

## Token Allocation

`S_MAX` is immutable after deployment and is minted exactly once through `SATToken.initializeGenesisAllocations(...)`.

| Allocation | Share | Recipient |
| --- | ---: | --- |
| Community incentives | 35% | `CommunityIncentivesController` |
| Treasury / DAO reserve | 20% | `TreasuryReserveController` |
| Team & contributors | 15% | `TokenVesting` |
| Investors / strategic partners | 25% | `TokenVesting` |
| Liquidity / market making | 5% | liquidity address or manager |

Unlocks transfer already-minted tokens from holder/controller contracts. Unlocks never mint new supply.

## Current Protocol Parameters

The table below reflects the current reference configuration used by the protocol contracts. Governance-controlled values can be changed by the contract owner or future governance owner after deployment.

### Token Parameters

| Parameter | Current reference value | Notes |
| --- | ---: | --- |
| Token standard | ERC-20 | `SATToken` |
| Token decimals | `18` | Standard ERC-20 precision |
| Reference max supply | `1,000,000,000 3SAT` | Set through immutable `S_MAX` at deployment |
| Genesis minting | one-time only | No account can mint after genesis allocation |

### Bounty Parameters

These are set per bounty by the issuer when a bounty is created.

| Parameter | Meaning |
| --- | --- |
| Reward | Main bounty reward escrowed for the winning solver |
| Commit window | Time available for solvers to commit solution hashes |
| Reveal window | Time available for committed solvers to reveal solution references and digests |
| Verification window | Time available for eligible verifiers to attest to revealed submissions |
| Verifier quorum | Number of accept attestations required for an accepted candidate |

The protocol uses stage-based timing: commit, reveal, and verification windows are sequential phases.

### Governance-Controlled Parameters

| Parameter | Current reference value | Contract | Notes |
| --- | ---: | --- | --- |
| Verifier minimum stake | `1,000 3SAT` | `VerifierRegistry` | Required for verifier eligibility |
| Verifier unbonding delay | `15 days` | `VerifierRegistry` | Delay before requested unstake can be withdrawn |
| Official verifier slash | `50%` | `VerifierRegistry` | Owner-authorized slash also disables the verifier |
| Solver bond | `10 3SAT` | `BountyManager` | Bond posted when committing a solution |
| Verifier reward pool | `2%` of bounty reward | `BountyManager` | Reserved from issuer escrow and split among correct accepting verifiers |
| Max verifier reward pool | `10%` of bounty reward | `BountyManager` | Contract-level cap |
| Treasury burn share | `20%` of routed fees | `TreasuryRouter` | Remaining routed amount goes to treasury |
| Default solver access reward | `1%` of bounty reward | `ArtifactAccessController` | Target amount paid to the winning solver per answer access purchase |
| Max default solver access reward | `10%` of bounty reward | `ArtifactAccessController` | Contract-level cap |
| Solver royalty share of access fee | `50%` | `ArtifactAccessController` | Remaining access fee is routed through `TreasuryRouter` |
| Max solver royalty share | `50%` | `ArtifactAccessController` | Contract-level cap |

### Answer Access Economics

With the current reference settings, paid answer download works as follows:

| Flow | Amount |
| --- | ---: |
| User pays to access a finalized answer | `2%` of bounty reward |
| Winning solver receives | `1%` of bounty reward |
| Routed through `TreasuryRouter` | `1%` of bounty reward |
| Burned from routed amount | `20%` |
| Sent to treasury from routed amount | `80%` |

In effect, a paid finalized-answer download sends `1%` of the bounty reward to the winning solver, burns `0.2%`, and sends `0.8%` to treasury.

Issuer access to the finalized winning answer is free.

### Finalization Rules

| Case | Result |
| --- | --- |
| Required accept quorum is reached | Submission can be finalized immediately |
| Verification window ends without an accepted candidate | Bounty can finalize without a winner according to contract rules |
| Solver commits but does not reveal | The unrevealed solver bond can be claimed according to timeout rules |
| Solver reveals with invalid preimage or digest | The solver bond is slashed according to contract rules |

## Development

Install Foundry, then run:

```bash
cd contracts
forge fmt
forge test
```

The repository vendors the required Foundry dependencies in `contracts/lib` for reproducible local testing.

## License

MIT
