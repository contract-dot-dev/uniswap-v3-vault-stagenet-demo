# Uniswap V3 Vault Stagenet Demo

This repo contains a demo Uniswap v3 LP vault that can be deployed to a [Stagenet](https://docs.contract.dev/stagenets). and used to demonstrate a production-grade DeFi testing workflow.

## How the vault works

The vault is an ERC20 whose shares represent pro-rata ownership of a single Uniswap v3 LP position on the Ethereum USDC/WETH 0.05% fee pool.

Users interact with the vault by calling:

- `mint` — mints vault shares and adds liquidity to its position.
- `withdraw` — burns shares and returns a proportional amount of WETH and USDC from the vault’s position.

Two actions keep the position productive:

- `compound()` — claims the fees the position has earned and redeposits them as additional liquidity.
- `rebalance()` — closes the current position and opens a fresh one centred on the live tick.

USD-denominated TVL and share price are derived from Chainlink price feeds and made available in view functions.

## Why deploy it on a Stagenet?

Uniswap v3 LP vaults depend on real DeFi conditions: pool price, liquidity, ticks, token balances, etc.

A Stagenet gives this vault a production-like environment to run in, with built-in tools to inspect and simulate how it behaves before mainnet.

With this demo, you can:

1. Deploy the vault on an Ethereum-replicating Stagenet, configured to use the USDC/WETH 0.05% Uniswap v3 pool
2. Add liquidity to its pool position using tokens obtained from the Stagenet's faucet
3. Simulate periodic swaps using the Stagenet's activity simulator to generate fees
4. Periodically compound and rebalance the position
5. Track and graph TVL, share price, and earned fees over time via the Stagenet's analytics
6. Inspect transactions, balances, state, and more in the vault’s Workspace

## Quickstart

1. Create a project in [contract.dev](https://contract.dev).  
   Each project includes a Stagenet: a private EVM testnet with built-in tools and analytics.

2. Import this GitHub repo from your Stagenet’s **CI/CD** dashboard.  
   It will compile the vault and prepare a Workspace for when it is deployed.

3. Generate a funded wallet using the Stagenet's [Wallet Generator](https://docs.contract.dev/stagenets/tools/wallet-generator).  
   It gives you a private key and ETH for deployment gas in one step.

4. Deploy the vault to your Stagenet:

```bash
export STAGENET_RPC_URL=<YOUR_STAGENET_RPC_URL>
export PRIVATE_KEY=<YOUR_FUNDED_PRIVATE_KEY>

forge script script/Deploy.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

5. Open the vault’s new Workspace via your Stagenet's **Analytics** dashboard.

## Vault Interaction

Once deployed, set a `VAULT` env var to the deployed address and run any of the scripts in `./script`.
Send your wallet some USDC and WETH from the Stagenet's [Faucet](https://docs.contract.dev/stagenets/tools/faucet) if you plan to mint vault shares or run swaps.

```bash
export STAGENET_RPC_URL=<YOUR_STAGENET_RPC_URL>
export PRIVATE_KEY=<YOUR_FUNDED_PRIVATE_KEY>
export VAULT=<DEPLOYED_VAULT_ADDRESS>

# Mint shares and add liquidity to the vault's position
SHARES=50000000000000000 forge script script/Mint.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Swap against the vault's underlying pool to move price and generate fees
AMOUNT_IN=100000000 ZERO_FOR_ONE=true forge script script/Swap.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Claim fees and redeposit them as additional liquidity
forge script script/Compound.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Close the current position and re-open it around the live tick
forge script script/Rebalance.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```