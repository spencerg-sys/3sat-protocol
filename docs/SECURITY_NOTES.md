# Security Notes

## Security Model

`3SAT` is an ERC-20 token on the deployment chain. Gas is always paid in the chain's native asset. The protocol does not rely on a bridge, wrapped supply, relayer, validator set, or off-chain finality service.

Security-critical state is on-chain:

- Token supply and genesis allocations.
- Vesting and controller release caps.
- Bounty escrow accounting.
- Solver bonds.
- Verifier staking, eligibility, unbonding, slashing, and owner-authorized disablement.
- Attestation quorum.
- Finalization readiness and settlement.
- Artifact access payment accounting.
- Fee and slash routing.

The API/server layer is untrusted and non-custodial by default. It may prepare calldata, store artifacts, cache/index state, and help clients discover protocol data, but it must not custody funds or decide finality.

## Main Risks

- Parameter risk: `S_MAX`, accepted payment assets, verifier stake, solver bond per payment asset, verifier reward bps, artifact access pricing, routing bps, and time windows must be reviewed before production.
- Owner risk: protocol owner powers should be held by a reviewed project-controlled account or Safe multisig before production.
- Verifier quality risk: verifier clients and operator policies must reduce false accept/reject attestations.
- Automation risk: keeper and indexer infrastructure must be monitored because finalization is permissionless but not self-executing.
- Gas risk: bounty systems with many submissions or attestations need production gas review.
- Economic risk: slashing, bond, reward, and quorum parameters must be calibrated against attack costs.
- Metadata risk: references and digests are binding, but off-chain content availability still depends on storage operators.
- Privacy risk: sensitive enterprise SAT instances require encryption and access policy beyond the public research data flow.
- Time risk: vesting uses deterministic seconds-based months and years, not calendar months.

## Controls Implemented

- No public faucet.
- No discretionary post-genesis mint.
- Genesis allocation can only initialize once.
- Allocation sum must equal `S_MAX`.
- Vesting transfers already-held tokens only.
- Community and treasury release caps are enforced on-chain.
- Bounty rewards, verifier reward pools, posting fees, solver bonds, and verifier slashes use `SafeERC20`.
- Reentrancy protection on escrow, release, finalization, and access purchase flows.
- Solver commitments bind bounty id, solver address, solution reference, solution digest, and salt.
- Wrong reveal marks the submission invalid and slashes solver bond.
- Non-revealed committed submissions can be slashed after the protocol windows close.
- Verifier attestation eligibility is checked on-chain.
- Duplicate attestations are rejected.
- Solvers cannot attest to their own submissions.
- Issuers cannot attest on submissions for their own bounties.
- Accepted quorum is immediately finalizable by any account.
- No-winner finalization is blocked while any accepted candidate exists.
- Posting fees, slashed solver bonds, and routed access fees flow through burn/treasury logic.
- Issuer answer access is free after finalization; third-party answer access is paid and recorded on-chain.

## Production TODOs

- External audit before production value is at risk.
- Formal parameter review for `S_MAX`, `minimumStake`, `solverBond`, `verifierRewardBps`, quorum, windows, access pricing, and routing bps.
- Decide final treasury, liquidity, team, investor, owner, and community program owner addresses.
- Confirm liquidity recipient is a reviewed address or manager contract.
- Add monitoring for finalizable bounties, failed keeper transactions, release caps, verifier slashing, and artifact access payments.
- Add deployment runbook sign-off and explorer verification artifacts.
- Harden verifier client releases with checksums, signed builds, and reproducible release notes.
- Consider encrypted artifact support for enterprise SAT workloads.
- Consider IPFS or other decentralized mirrors for public finalized research artifacts.
- Consider pausable emergency controls only if the project accepts the centralization tradeoff.

## Audit Checklist

- Supply immutability and one-time allocation.
- Controller release math and timestamp assumptions.
- Bounty state transitions and edge cases around commit, reveal, attest, finalization, and no-winner settlement.
- Commit hash parity between Solidity, clients, and API code.
- All token flows and stuck-fund scenarios.
- Solver bond refund/slash accounting.
- Verifier reward pool payout/refund accounting.
- Artifact access price and royalty distribution.
- Treasury/burn routing.
- Owner role transfer and emergency authority configuration.
