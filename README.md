# 3SAT Protocol

Smart contracts for 3SAT Network: a token-denominated bounty protocol for posting, solving, verifying, and settling SAT/CNF outcomes on EVM chains.

`3SAT` is an ERC-20 token. The protocol does not create a new blockchain, L1, L2, rollup, bridge, validator network, wrapped-token system, faucet, or gas coin. Users pay gas with the native asset of the chain where the contracts are deployed.

## Repository Layout

- `contracts/src`: Solidity contracts.
- `contracts/script`: Foundry deployment script.
- `contracts/test`: Foundry tests.
- `contracts/lib`: vendored Foundry dependencies used by the test suite.
- `contracts/deployments`: generated deployment records; JSON files are ignored unless intentionally added for a release.
- `docs`: protocol, deployment, and security notes.

## Core Contracts

- `SATToken`: fixed-supply `3SAT` ERC-20 with one-time genesis allocation.
- `TokenVesting`: team and investor vesting vault.
- `CommunityIncentivesController`: community allocation controller with cumulative annual caps.
- `TreasuryReserveController`: treasury reserve controller with bootstrap and strategic unlock schedules.
- `TreasuryRouter`: routes protocol fees through burn and treasury distribution.
- `VerifierRegistry`: verifier staking, eligibility, unbonding, governance disablement, and authorized slashing.
- `BountyManager`: bounty escrow, solver commit-reveal, solver bonds, verifier attestations, quorum, finalization, and reward accounting.
- `ArtifactAccessController`: paid access rights for finalized solution artifacts.
- `ProtocolTimelock`: optional OpenZeppelin timelock wrapper for governance ownership.

## Token Allocation

`S_MAX` is immutable and minted exactly once through `SATToken.initializeGenesisAllocations(...)`.

| Allocation | Share | Recipient |
| --- | ---: | --- |
| Community incentives | 35% | `CommunityIncentivesController` |
| Treasury / DAO reserve | 20% | `TreasuryReserveController` |
| Team & contributors | 15% | `TokenVesting` |
| Investors / strategic partners | 25% | `TokenVesting` |
| Liquidity / market making | 5% | liquidity address or manager |

Unlocks transfer already-minted tokens from holder/controller contracts. Unlocks never mint new supply.

## Current Protocol Parameters

Deployment defaults can be overridden by environment variables.

| Parameter | Default |
| --- | ---: |
| Verifier minimum stake | `1000 3SAT` |
| Verifier unbonding delay | `15 days` |
| Solver bond | `10 3SAT` |
| Verifier reward pool | `2%` of bounty reward |
| TreasuryRouter burn | `20%` of routed fees |
| Default solver access reward | `1%` of bounty reward |
| Solver share of answer access fee | `50%` |

With the default answer-access settings, a finalized solution download costs `2%` of the bounty reward: `1%` goes to the winning solver and `1%` is routed through `TreasuryRouter`, where `20%` burns and `80%` goes to treasury.

## Development

Install Foundry, then run:

```bash
cd contracts
forge fmt
forge test
```

The repository vendors the required Foundry dependencies in `contracts/lib` for reproducible local testing.

## Deployment

Copy the environment template and fill production values outside git:

```bash
cd contracts
cp .env.example .env
```

Use `script/Deploy.s.sol` for local, Sepolia, Arbitrum Sepolia, Arbitrum One, and Ethereum mainnet deployments. Mainnet and Arbitrum One deployments require `PRODUCTION_DEPLOYMENT_APPROVED=true` and contract-based governance addresses.

See:

- `docs/PROTOCOL_SPEC.md`
- `docs/DEPLOYMENT.md`
- `docs/SECURITY_NOTES.md`

## Security

These contracts should be externally audited before handling production value. The repository is intended to make protocol logic inspectable and verifiable; it is not a substitute for an audit, operational monitoring, or multisig/timelock governance.
