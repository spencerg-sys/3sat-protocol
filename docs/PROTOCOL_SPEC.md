# Protocol Spec

## Scope

`3SAT` is an ERC-20 token plus bounty protocol for EVM chains. It does not create a new chain, consensus layer, validator set, L2, rollup, bridge, wrapped token, faucet, relayer, or custom gas asset.

Security-critical state lives on-chain: token supply, allocation controllers, vesting, bounty escrow, solver bonds, verifier eligibility, attestations, quorum, finalization, slashing, artifact access payments, and treasury routing. API and indexer layers are helpers and must be treated as untrusted caches.

## Token Supply

`SATToken` is named `3SAT Coin`, symbol `3SAT`, decimals `18`.

`S_MAX` is immutable. The deployment flow is:

1. Deploy `SATToken(S_MAX, deploymentOwner)`.
2. Deploy vesting and controller contracts.
3. Call `initializeGenesisAllocations(...)` once.
4. Mint exact allocations to controllers, vesting contracts, and liquidity recipient.
5. No external minting function remains usable after genesis.

Unlocks release already-held tokens. Vesting and controller contracts never mint.

## Allocation Logic

- Community incentives: `3500` bps.
- Treasury / DAO reserve: `2000` bps.
- Team & contributors: `1500` bps.
- Investors / strategic partners: `2500` bps.
- Liquidity / market making: `500` bps.

`S_MAX` must be divisible by `10000` so all basis-point allocations sum exactly to `S_MAX`.

## Vesting

`TokenVesting` releases to one immutable beneficiary. Anyone may call `release()`, but tokens can only go to the beneficiary.

Team vesting:

- 15% of `S_MAX`.
- 12-month cliff.
- 24-month linear vesting after cliff.
- Fully vested after 36 months from genesis.

Investor vesting:

- 25% of `S_MAX`.
- 6-month cliff.
- 24-month linear vesting after cliff.
- Fully vested after 30 months from genesis.

The implementation uses 30-day months for deterministic EVM time math.

## Community Incentives

`CommunityIncentivesController` holds 35% of `S_MAX`. Only the owner, intended to be a timelock or multisig in production, may release tokens.

Cumulative caps use 365-day years:

| Time | Incremental Cap |
| --- | ---: |
| Genesis | 1% |
| Year 1 | 6% |
| Year 2 | 6% |
| Year 3 | 5% |
| Year 4 | 5% |
| Year 5 | 4% |
| Year 6 | 3% |
| Year 7 | 3% |
| Year 8 | 2% |

An optional epoch cap can further restrict per-epoch release.

## Treasury Reserve

`TreasuryReserveController` holds 20% of `S_MAX`.

- Bootstrap operating treasury: 4%, available at genesis, owner-released only.
- Strategic reserve / insurance tranche: 16%, 6-month cliff, 60-month linear availability, fully available after 66 months.

Releases transfer already-held tokens to the configured treasury address.

## Bounty Protocol

`BountyManager` escrows token-denominated rewards, verifier reward pools, posting fees, and solver bonds in `3SAT`.

Bounty creation stores issuer, instance reference, instance digest, metadata URI, metadata digest, reward, verifier reward pool, posting fee, timing windows, and verifier quorum. Issuer transfers `reward + verifierRewardPool + postingFee` to escrow.

Verifier reward pool defaults to:

```solidity
verifierRewardPool = reward * verifierRewardBps / 10000
```

The deployment default is `verifierRewardBps = 200`, or 2% of bounty reward.

## Commit and Reveal

Solvers first commit a hidden solution:

```solidity
commitHash = keccak256(abi.encodePacked(
    bountyId,
    solver,
    solutionRef,
    solutionDigest,
    salt
));
```

The solver locks the current protocol `solverBond` when committing. The deployment default is `10 3SAT`.

Reveal verifies the commitment and stores `solutionRef` and `solutionDigest`. A wrong reveal marks the submission invalid and slashes the solver bond through `TreasuryRouter`.

If a solver commits but never reveals, the submission can be finalized through the no-winner path after the reveal and verification windows close. That path slashes the solver bond.

## Verifier Attestation

Verifiers must be eligible in `VerifierRegistry`.

Attestation rules:

- A verifier cannot attest twice to the same submission.
- A solver cannot attest to its own submission.
- An issuer cannot attest on submissions for its own bounty.
- Attestations bind to the revealed `solutionRef` and `solutionDigest`.
- Accept quorum marks a submission `PendingAccepted`.
- Reject quorum marks a submission `PendingRejected`.

Accepted quorum makes the submission immediately finalizable. Finalization can be called by any account, including an automation keeper.

Rejected submissions and no-winner outcomes still wait until the verification window closes.

## Finalization

Accepted finalization:

- Pays bounty reward to the winning solver.
- Refunds the winning solver bond.
- Pays verifier reward pool pro rata to verifiers who supported the finalized winning submission.
- Routes posting fee through `TreasuryRouter`.

No-winner finalization:

- Requires no accepted candidate.
- Requires the verification window to be closed.
- Refunds bounty reward to the issuer.
- Refunds or slashes solver bonds depending on submission state.
- Refunds unused verifier reward pool to the issuer.
- Routes posting fee through `TreasuryRouter`.

`BountyManager.isFinalizable(bountyId, submissionId)` exposes finalization readiness for keepers and indexers.

## Artifact Access

`ArtifactAccessController` records paid access rights for private protocol artifacts.

Solution access is available only after bounty finalization with a winning solver. Issuers can access their own finalized answer without payment. Other users call `purchaseAccess(bountyId, ARTIFACT_SOLUTION)`.

Default solution access pricing targets a recurring solver royalty:

```solidity
targetSolverReward = bounty.reward * defaultSolverAccessRewardBps / 10000
price = ceil(targetSolverReward * 10000 / solverRoyaltyBps)
```

Deployment defaults:

- `defaultSolverAccessRewardBps = 100`, so the winning solver receives 1% of bounty reward per paid answer download.
- `solverRoyaltyBps = 5000`, so the solver receives 50% of the access price.
- The remaining 50% routes through `TreasuryRouter`.

With defaults, answer access costs 2% of the bounty reward: 1% goes to the winning solver, and 1% is routed to treasury/burn.

## Verifier Registry

Verifiers stake `3SAT`, can request unstake, wait through the unbonding delay, then withdraw. Eligibility requires registration, enabled status, and active stake at or above `minimumStake`.

Only the authorized `BountyManager` may call `slash(...)` for protocol-detected invalid behavior. The owner can also slash and disable a verifier for off-chain or operational misconduct, subject to governance policy.

## Treasury Router

`TreasuryRouter` receives posting fees, slashed solver bonds, and routed artifact access fees. It burns `burnBps` and transfers the remainder to treasury. Routing basis points cannot exceed `10000`.

Deployment default:

- `burnBps = 2000`, so 20% of routed fees burn and 80% transfer to treasury.
