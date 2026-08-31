# Deployment

## Positioning

Deploying these contracts does not deploy a new blockchain. `3SAT` is an ERC-20 on the target EVM chain. On Ethereum mainnet, users pay gas in ETH. On Arbitrum One, users pay gas in ETH on Arbitrum.

No production deployment should be performed until final parameters, production addresses, multisig ownership, explorer verification, and security review are complete.

## Required Environment Variables

`contracts/script/Deploy.s.sol` reads:

- `S_MAX`: max supply in wei units, divisible by `10000`.
- `COMMUNITY_PROGRAM_OWNER`: owner for community release authorization, intended project-controlled owner or multisig.
- `TREASURY_ADDRESS`: treasury recipient for reserve releases and router transfers.
- `TEAM_BENEFICIARY`: team vesting beneficiary.
- `INVESTOR_BENEFICIARY`: investor vesting beneficiary.
- `LIQUIDITY_ADDRESS`: liquidity recipient or liquidity manager.
- `OWNER_ADDRESS`: final protocol owner, intended project-controlled owner or multisig.

Optional deployment parameters:

- `DEPLOYER_PRIVATE_KEY`: temporary deployer key for Foundry broadcasting. Do not commit it.
- `OFFICIAL_VERIFIER_ADDRESS`: optional initial official verifier. The zero address leaves the fresh registry with no eligible verifier; a non-zero address is approved before ownership is transferred.
- `VERIFIER_MINIMUM_STAKE`: defaults to `1000 ether`.
- `VERIFIER_UNBONDING_DELAY`: defaults to `15 days`.
- `SOLVER_BOND`: defaults to `10 ether`.
- `VERIFIER_REWARD_BPS`: defaults to `200`.
- `TREASURY_BURN_BPS`: defaults to `2000`.
- `DEFAULT_SOLVER_ACCESS_REWARD_BPS`: defaults to `100`.
- `SOLVER_ROYALTY_BPS`: defaults to `5000`.
- `PRODUCTION_DEPLOYMENT_APPROVED`: must be `true` on Ethereum mainnet or Arbitrum One.

If `DEPLOYER_PRIVATE_KEY` is omitted, Foundry uses the configured broadcaster.

Verifier admission deliberately has no deployment parameter that silently opens it. A fresh `VerifierRegistry` always starts with `permissionlessVerificationEnabled() == false`. The script may add the single optional `OFFICIAL_VERIFIER_ADDRESS`, but approval does not register the address, deposit stake, or make an under-staked address eligible. Additional official verifiers must be approved by the final owner through `setOfficialVerifier(address, true)`.

## Local Commands

```bash
cd contracts
forge fmt
forge test
```

## Arbitrum Sepolia

Arbitrum Sepolia is the preferred final test environment before Arbitrum One. It validates deployment, explorer verification, and bounty smoke tests without production funds.

```bash
cd contracts
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$ARBITRUM_SEPOLIA_RPC_URL" \
  --broadcast \
  --verify
```

## Arbitrum One

Arbitrum One is the intended production chain for protocol v1.

Before Arbitrum One:

- Finalize `S_MAX`.
- Finalize treasury, liquidity, team, investor, owner, and community program owner addresses.
- Use a project Safe multisig or reviewed owner address as `OWNER_ADDRESS`.
- Use project-controlled addresses for `COMMUNITY_PROGRAM_OWNER` and `TREASURY_ADDRESS`.
- Select independent official verifier operators, set the initial `OFFICIAL_VERIFIER_ADDRESS` if desired, and ensure the final owner can approve the rest.
- Keep verification official-only for launch. Do not enable permissionless verification until audit finding C-01 is remediated or its fixed-stake, one-address-one-attestation Sybil risk is explicitly accepted and disclosed.
- Set `PRODUCTION_DEPLOYMENT_APPROVED=true` only for the final reviewed run.
- Verify all contracts on Arbiscan.
- Run independent security review or audit.
- Run deployment simulation and post-deployment allocation validation.

Example:

```bash
cd contracts
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$ARBITRUM_RPC_URL" \
  --broadcast \
  --verify
```

## Ethereum Mainnet

Ethereum mainnet is supported by the deployment script but is not the recommended first production chain for bounty operations because the workflow requires many user transactions.

Before Ethereum mainnet, decide whether Ethereum is the canonical token deployment or whether Arbitrum remains canonical.

```bash
cd contracts
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$MAINNET_RPC_URL" \
  --broadcast \
  --verify
```

## Post-Deployment Checks

The deployment script validates:

- Community controller balance = 35%.
- Treasury reserve controller balance = 20%.
- Team vesting balance = 15%.
- Investor vesting balance = 25%.
- Liquidity recipient balance = 5%.
- `totalSupply == S_MAX`.
- The fresh verifier registry remains in official-only mode.
- A non-zero `OFFICIAL_VERIFIER_ADDRESS` was approved.

It writes a deployment JSON file under `contracts/deployments/3sat-<chainId>.json`, including `permissionlessVerificationEnabled` and `OFFICIAL_VERIFIER_ADDRESS` alongside contract addresses.

Before publishing a deployment address set:

- Confirm each contract owner is the expected project owner or Safe.
- Confirm `VerifierRegistry.bountyManager()` points to the deployed `BountyManager`.
- Confirm `VerifierRegistry.permissionlessVerificationEnabled()` is `false` for launch.
- Confirm every intended operator has `officialVerifier(operator) == true`.
- From each official operator, approve the registry to spend `3SAT`, call `stake(...)`, and confirm `getVerifier(operator)` is registered and enabled with `activeStake >= minimumStake`.
- Confirm `VerifierRegistry.isEligible(operator) == true` for every launch verifier and `false` for a staked but unapproved test address.
- Confirm the maximum bounty `verifierQuorum` exposed by launch clients does not exceed the number of live, independent, eligible official verifiers. If there is only one, enforce quorum `1`.
- Confirm `ArtifactAccessController` points to the deployed `BountyManager` and `TreasuryRouter`.
- Confirm token allocation balances match the release record.
- Confirm source verification is complete on the block explorer.

Fund each operational verifier with enough native gas token as well as the required `3SAT` stake. Monitor its eligibility, stake, gas balance, uptime, and attestation latency. An official-only launch with fewer live eligible operators than a bounty's quorum cannot finalize an accepted solution.

### Admission-mode changes

After deployment, the owner can call `setPermissionlessVerificationEnabled(true)` or switch back to `false` without redeploying any contract or changing client addresses. The switch changes eligibility immediately for all registered stakers. Enabling it can make every registered, enabled, sufficiently staked address eligible at once; disabling it can remove non-official verifiers while bounties are awaiting attestations. Make mode changes through the project Safe during a maintenance window with no active reveal or verification phase, then re-read `isEligible` for all operators.

Official-only mode is containment, not a repair of C-01. Permissionless mode must remain disabled until the verifier economics are upgraded or the risk is formally accepted.

## General Migration Notes

`VerifierRegistry` is not proxy-upgradeable, so a testnet registry deployed before official-only admission cannot be changed in place. Deploy a new registry; do not assume source verification or an ABI update changes code already at the old address. The full `Deploy.s.sol` script creates a new token and full protocol stack, so use a dedicated migration script or reviewed Safe transaction batch when retaining an existing token and manager.

For a registry-only migration:

1. Deploy `VerifierRegistry(existingSATToken, minimumStake, unbondingDelay, temporaryOrFinalOwner)`.
2. Approve the intended official verifier addresses on the new registry.
3. Have each official verifier approve and stake the existing `3SAT` token in the new registry.
4. Call `newRegistry.setBountyManager(existingBountyManager)`.
5. Call `existingBountyManager.setVerifierRegistry(newRegistry)` from the manager owner.
6. Verify the token match, back-pointer, admission mode, official approvals, stake, and `isEligible` results before resuming bounty issuance.

The current `BountyManager.setVerifierRegistry(...)` accepts a replacement only when its token matches the manager's immutable `3SAT` token and the new registry already points back to that manager. Registry stakes do not migrate: users must separately unstake from the old registry after its delay, and the old registry must remain reachable until withdrawals finish. Perform the cutover with no active revealed submissions because the manager consults the current registry at attestation time.

If the latest audited `BountyManager` is also required, it too must be newly deployed because it is non-upgradeable. Point the existing `ArtifactAccessController` to it with `setBountyManager(...)` only after reviewing the controller's manager-epoch transition, or deploy a new access controller as part of a full-stack migration.

## API, Indexer, and Client Cutover

Treat the reviewed deployment JSON as one atomic address set. Before restoring the API or website, verify chain ID and non-empty bytecode at every configured address, and reconcile all testnet environment files rather than combining addresses from different deployments.

For a registry-only migration, the `BountyManager` event source and its indexer start block remain unchanged. Update the website's verifier-registry address and every verifier client's `VERIFIER_REGISTRY_ADDRESS`, then restart those services. Existing verifier authorization and startup checks call `isEligible(address)`, so they automatically enforce official-only or permissionless admission once they point to the new registry. The generic issuer/solver CLI does not need a registry ABI change unless it begins displaying admission state.

For a new `BountyManager`, update its address in the website, API, keeper, CLI, and access-controller configuration. Start a fresh index namespace or explicitly reindex from the new manager's deployment block; do not let reused numeric bounty IDs inherit cached state from the old manager. Verify the access-controller epoch and new manager pointer before enabling paid artifact access.

Before opening the testnet UI or API, run an end-to-end smoke test: create a quorum-appropriate bounty, commit, reveal, attest with an eligible official verifier, finalize, and retrieve indexed state. Also confirm a registered and sufficiently staked but unapproved address remains ineligible and cannot attest. Test a permissionless-mode round trip only in a controlled environment; returning to official-only must not require redeployment or an address change.

## Explorer Verification

Use Foundry verification through `--verify`, or verify manually with:

```bash
forge verify-contract <address> <ContractName> \
  --chain <chain> \
  --constructor-args <encoded-args>
```

Store verified source, constructor args, deployment commit, deployment JSON, owner configuration, and final parameters in the production release record.
