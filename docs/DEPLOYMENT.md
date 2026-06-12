# Deployment

## Positioning

Deploying these contracts does not deploy a new blockchain. `3SAT` is an ERC-20 on the target EVM chain. On Ethereum mainnet, users pay gas in ETH. On Arbitrum One, users pay gas in ETH on Arbitrum.

No production deployment should be performed until final parameters, production addresses, multisig ownership, explorer verification, and security review are complete.

## Required Environment Variables

`contracts/script/Deploy.s.sol` reads:

- `S_MAX`: max supply in wei units, divisible by `10000`.
- `COMMUNITY_PROGRAM_OWNER`: owner for community release authorization, intended timelock or multisig.
- `TREASURY_ADDRESS`: treasury recipient for reserve releases and router transfers.
- `TEAM_BENEFICIARY`: team vesting beneficiary.
- `INVESTOR_BENEFICIARY`: investor vesting beneficiary.
- `LIQUIDITY_ADDRESS`: liquidity recipient or liquidity manager.
- `OWNER_ADDRESS`: final protocol owner, intended timelock or multisig.

Optional deployment parameters:

- `DEPLOYER_PRIVATE_KEY`: temporary deployer key for Foundry broadcasting. Do not commit it.
- `VERIFIER_MINIMUM_STAKE`: defaults to `1000 ether`.
- `VERIFIER_UNBONDING_DELAY`: defaults to `15 days`.
- `SOLVER_BOND`: defaults to `10 ether`.
- `VERIFIER_REWARD_BPS`: defaults to `200`.
- `TREASURY_BURN_BPS`: defaults to `2000`.
- `DEFAULT_SOLVER_ACCESS_REWARD_BPS`: defaults to `100`.
- `SOLVER_ROYALTY_BPS`: defaults to `5000`.
- `PRODUCTION_DEPLOYMENT_APPROVED`: must be `true` on Ethereum mainnet or Arbitrum One.

If `DEPLOYER_PRIVATE_KEY` is omitted, Foundry uses the configured broadcaster.

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
- Use Safe multisig and/or `ProtocolTimelock` as `OWNER_ADDRESS`.
- Use Safe multisig and/or timelock-controlled addresses for `COMMUNITY_PROGRAM_OWNER` and `TREASURY_ADDRESS`.
- Ensure `OWNER_ADDRESS`, `COMMUNITY_PROGRAM_OWNER`, and `TREASURY_ADDRESS` are deployed contracts; the script rejects EOAs for these on Arbitrum One.
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

It writes a deployment JSON file under `contracts/deployments/3sat-<chainId>.json`.

Before publishing a deployment address set:

- Confirm each contract owner is the expected Safe or timelock.
- Confirm `VerifierRegistry.bountyManager()` points to the deployed `BountyManager`.
- Confirm `ArtifactAccessController` points to the deployed `BountyManager` and `TreasuryRouter`.
- Confirm token allocation balances match the release record.
- Confirm source verification is complete on the block explorer.

## Explorer Verification

Use Foundry verification through `--verify`, or verify manually with:

```bash
forge verify-contract <address> <ContractName> \
  --chain <chain> \
  --constructor-args <encoded-args>
```

Store verified source, constructor args, deployment commit, deployment JSON, Safe owner configuration, and final parameters in the production release record.
