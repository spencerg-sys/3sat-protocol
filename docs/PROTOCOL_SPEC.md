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
- Treasury reserve: `2000` bps.
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

`CommunityIncentivesController` holds 35% of `S_MAX`. Only the owner, intended to be a project-controlled owner or multisig in production, may release tokens.

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

`BountyManager` escrows token-denominated rewards, verifier reward pools, posting fees, and solver bonds in the bounty payment asset selected by the issuer. The accepted payment assets are owner-controlled ERC-20 addresses, with reference support for USDC and `3SAT`.

Bounty creation stores issuer, payment asset, instance reference, instance digest, metadata URI, metadata digest, reward, verifier reward pool, posting fee, timing windows, and verifier quorum. Issuer transfers `reward + verifierRewardPool + postingFee` in the selected payment asset to escrow.

`verifierQuorum` must be between `1` and `100`, inclusive. The upper bound keeps the synchronous verifier-reward settlement path within a tested transaction gas budget; it is not a verifier-trust or allowlist control.

Verifier reward pool defaults to:

```solidity
verifierRewardPool = reward * verifierRewardBps / 10000
```

The deployment default is `verifierRewardBps = 200`, or 2% of bounty reward.

## Commit and Reveal

Solvers first commit a hidden solution. The commitment is exactly the following Solidity expression from `BountyManager.computeCommitHash(...)`:

```solidity
commitHash = keccak256(abi.encode(
    block.chainid,
    address(this),
    bountyId,
    solver,
    solutionKind,
    proofFormat,
    solutionDigest,
    salt
));
```

The canonically ABI-encoded fields, in their binding order, are:

| Position | Field | Exact Solidity type | ABI representation |
| ---: | --- | --- | --- |
| 1 | `block.chainid` | `uint256` | 32-byte ABI word |
| 2 | `address(this)` | `address` | Left-padded 32-byte ABI word for the deployed `BountyManager` |
| 3 | `bountyId` | `uint256` | 32-byte ABI word |
| 4 | `solver` | `address` | Left-padded 32-byte ABI word |
| 5 | `solutionKind` | `SolutionKind`, encoded as `uint8` | 32-byte ABI word: `1` = `SatAssignment`, `2` = `UnsatProof` |
| 6 | `proofFormat` | `ProofFormat`, encoded as `uint8` | 32-byte ABI word: `0` = `None`, `1` = `DRAT`, `2` = `FRAT`, `3` = `LRAT` |
| 7 | `solutionDigest` | `bytes32` | 32 bytes |
| 8 | `salt` | `bytes32` | 32 bytes |

Client implementations must use canonical `abi.encode`, not packed encoding, and must not omit or reorder any field. The equivalent viem type list is:

```typescript
["uint256", "address", "uint256", "address", "uint8", "uint8", "bytes32", "bytes32"]
```

The first value is the deployment chain ID and the second is the deployed `BountyManager` address. A commitment therefore cannot be replayed against another chain or another manager deployment.

### Fixed encoding vector

Every conforming implementation must produce the following fixed vector:

| Field | Value |
| --- | --- |
| `chainId` | `31337` (local EVM development chain) |
| `bountyManager` | `0x4444444444444444444444444444444444444444` |
| `bountyId` | `42` |
| `solver` | `0x1111111111111111111111111111111111111111` |
| `solutionKind` | `2` (`UnsatProof`) |
| `proofFormat` | `2` (`FRAT`) |
| `solutionDigest` | `0x2222222222222222222222222222222222222222222222222222222222222222` |
| `salt` | `0x3333333333333333333333333333333333333333333333333333333333333333` |

The 256-byte canonical ABI encoding is:

```text
0x0000000000000000000000000000000000000000000000000000000000007a690000000000000000000000004444444444444444444444444444444444444444000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000011111111111111111111111111111111111111110000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000222222222222222222222222222222222222222222222222222222222222222223333333333333333333333333333333333333333333333333333333333333333
```

The expected commitment is:

```text
0xeba2066d89faa2e842382a7e3c81a055205660aab1ad1b4510c5f20fb52d2046
```

Creating a bounty snapshots the then-current `solverBondForToken(paymentToken)` into `bountySolverBond(bountyId)`. Every solver committing to that bounty posts the snapshotted amount, so later owner changes affect only newly created bounties. The reference deployment default is `10 3SAT` for `3SAT` bounties and `10 USDC` for USDC bounties.

Reveal verifies the commitment and stores `solutionDigest`, `solutionKind`, and `proofFormat`. A wrong reveal marks the submission invalid and slashes the solver bond through `TreasuryRouter`.

Artifact identifiers, object keys, bucket names, presigned URLs, and other storage references are deliberately absent from the commitment, submission, events, and every other on-chain interface. An authenticated off-chain artifact service associates uploaded bytes with the chain/deployment/bounty/submission tuple, checks that the uploader is the submission solver, and enforces an exact digest/kind/format match before serving those bytes. The artifact's `keccak256` digest is the on-chain integrity anchor; storage location is not protocol state.

If a solver commits but never reveals, the submission can be finalized through the no-winner path after the reveal and verification windows close. That path slashes the solver bond.

### Arbitrum timing profile

Normal Arbitrum One transactions are typically sequenced quickly, but protocol deadlines must also account for sequencer downtime or censorship. The Arbitrum Nitro whitepaper documents the Delayed Inbox fallback and states that a message can be force-included after the threshold period, currently 24 hours. That threshold is reached before the force-inclusion transaction and its L1 confirmation, so a 24-hour application deadline does not provide a complete forced-inclusion recovery path.

The current contracts enforce a **1-hour minimum for each of `commitWindow`, `revealWindow`, and `verificationWindow`** as the fast initial-launch profile. This is a timeout floor, not a mandatory wait: commit, reveal, attest, and accepted finalization can still happen immediately.

The 1-hour profile deliberately does not cover the Delayed Inbox force-inclusion path. A sequencer outage or censorship period lasting through a deadline can therefore cause a valid participant to miss that phase. Deployments that require force-inclusion resilience should configure materially longer per-bounty windows (48 hours remains the conservative reference setting) and re-check live Arbitrum parameters before deployment.

Reference: [Arbitrum Nitro whitepaper, section 2.1](https://docs.arbitrum.io/nitro-whitepaper.pdf).

## Off-chain artifact admission and delivery

The current companion service/client profile accepts raw CNF instances and SAT
unit-assignment files up to 256 MiB and UNSAT proofs up to 1 GiB. Multipart file
parts go directly to R2; the website handles small authenticated reservation,
completion and status messages. A separate artifact worker validates streamed
raw-byte Keccak, size and CNF/assignment syntax before marking the upload `ready`.
UNSAT upload admission is a byte/digest check, not proof acceptance. The official
verifier independently validates the revealed answer before any attestation.

DIMACS processing is bounded to 5,000,000 variables, 20,000,000 clauses,
100,000,000 literal occurrences, 25,000,000 physical lines, 1 MiB per physical
line and 5,000,000 literals per clause. Native checker preparation may produce a
comment-free normalized copy, but commitments and stored object metadata remain
bound to the original uploaded bytes. Upload limits and checker timeouts do not
change Solidity state, the commitment preimage or fee/bond accounting.

Finalized original answers can be delivered as `3sat-answer-manifest-v1`, with
individually signed R2 URLs, names, kinds, byte sizes and raw on-chain digests.
Clients stream and verify each file before assembling a local ZIP (release
profile: 1.5 GiB). Answer-access authorization is unchanged. Interactive
structural matching remains limited to 3.5 MiB / 50,000 variables / 100,000
clauses / 300,000 literals; larger or count-heavy instances use raw-only search.
Large variable-renaming matching is outside that interactive profile.

## Verifier Attestation

Verifiers must be eligible in `VerifierRegistry`. Eligibility always requires registration, enabled status, and active stake at or above `minimumStake`. In the default official-only mode it additionally requires `officialVerifier(verifier) == true`; in permissionless mode the official-approval condition is waived, but the other three conditions remain.

Attestation rules:

- A verifier cannot attest twice to the same submission.
- A solver cannot attest to its own submission.
- An issuer cannot attest on submissions for its own bounty.
- An attestation accepts only `(bountyId, submissionId, support)` and therefore binds to the immutable digest, kind, and format stored in that submission.
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

User-facing payouts are attempted immediately. If the payment token rejects a solver, issuer, or verifier recipient, finalization and bond settlement continue and the amount is recorded in `claimablePayout(beneficiary, paymentToken)`. The beneficiary can later call `claimPayout(paymentToken, recipient, amount)` and redirect the funds to a receivable address. Posting-fee and slash routing remain protocol dependencies and must succeed for the surrounding settlement transaction to complete.

## Artifact Access

`ArtifactAccessController` records paid access rights for private protocol artifacts.

Solution access is available only after bounty finalization with a winning solver. Issuers can access their own finalized answer without payment. Clients first call `accessQuoteWithEpoch(bountyId, ARTIFACT_SOLUTION, paymentToken)`, which atomically returns the current manager epoch plus an explicit `Unconfigured`, `Public`, `Priced`, or `Disabled` status. A numeric zero must never be treated as public access unless the status is explicitly `Public`.

For a `Priced` quote, clients call `purchaseAccess(bountyId, ARTIFACT_SOLUTION, paymentToken, maxPrice, deadline, expectedManagerEpoch)`. `maxPrice` is the price shown to the user, `expectedManagerEpoch` comes from the same atomic quote, and `deadline` is a short client-selected expiry; the reference website and CLI use 30 minutes. If the owner raises the price or replaces `BountyManager` before execution, the transaction reverts instead of charging more or purchasing a reused ID from a different manager. A lower price in the same epoch is accepted. Legacy two- and three-argument purchase selectors remain callable for issuer, already-owned, and public paths, but intentionally reject a paid purchase so older clients cannot silently bypass price protection.

Default solution access pricing targets a recurring solver royalty:

```solidity
targetSolverReward = bounty.reward * defaultSolverAccessRewardBps / 10000
price = ceil(targetSolverReward * 10000 / solverRoyaltyBps)
```

Reference defaults:

- Answer access uses the bounty payment asset by default.
- `defaultSolverAccessRewardBps = 100`, so the winning solver receives 1% of bounty reward per paid answer download, denominated in the bounty payment asset.
- `solverRoyaltyBps = 5000`, so the solver receives 50% of the access price.
- The remaining 50% routes through `TreasuryRouter`.

With defaults, answer access costs 2% of the bounty reward in the same asset as the bounty: 1% goes to the winning solver, and 1% is routed to treasury/burn. USDC routed fees go fully to treasury; `3SAT` routed fees can burn a configured share and send the remainder to treasury.

Access prices and purchased rights are namespaced by `bountyManagerEpoch`. Replacing `BountyManager` increments the epoch, so a reused numeric bounty ID cannot inherit a price or access right from the previous manager. Historical rights remain queryable through `hasAccessAtEpoch`; they do not authorize artifacts in the current epoch.

## Verifier Registry

Verifiers stake `3SAT`, can request unstake, wait through the unbonding delay, then withdraw. Staking is open in both admission modes, but staking alone does not confer eligibility in official-only mode.

A fresh registry is fail-closed: `permissionlessVerificationEnabled()` is `false` and no address is in `officialVerifier`. The owner may approve or revoke an address with `setOfficialVerifier(verifier, approved)`. Approval may happen before registration or staking. An approved verifier still must be registered, enabled, and sufficiently staked.

The owner may later call `setPermissionlessVerificationEnabled(true)` to admit every registered, enabled, sufficiently staked verifier without redeploying the registry. Switching it back to `false` immediately restores the official-approval requirement. `setVerifierEligibility(verifier, false)` remains the suspension mechanism in both modes; merely revoking official status does not suspend an otherwise eligible verifier while permissionless mode is enabled.

Official-only admission is the v1 launch containment for audit finding C-01, not a repair of permissionless economics. In permissionless mode, eligibility remains one-address-one-attestation at a fixed minimum stake that does not scale with bounty value. One operator can fund multiple verifier addresses and attempt to form quorum. Permissionless mode must not be enabled until that mechanism is upgraded or protocol governance explicitly accepts and discloses the resulting risk.

Only the registry owner may call `slashAndDisable(...)`; the current contracts do not automatically slash verifiers for an incorrect attestation. Owner-authorized slashing and disablement therefore depends on the project's verifier policy and governance process.

## Treasury Router

`TreasuryRouter` receives posting fees, slashed solver bonds, and routed artifact access fees. Routing is configured per ERC-20 token. For tokens with a non-zero burn share, it burns `burnBps[token]` and transfers the remainder to treasury. Routing basis points cannot exceed `10000`.

Reference defaults:

- USDC: `burnBps = 0`, so 100% of routed USDC transfers to treasury.
- `3SAT`: `burnBps = 2000`, so 20% of routed `3SAT` burns and 80% transfers to treasury.
