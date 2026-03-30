# Fortune Market

<p align="center">
  <img src="docs/fortune-market.png" alt="Fortune Market" width="1200" />
</p>

Foundry workspace for the Fortune Market contracts and Base fork tests.

## Quick Start

```bash
cp .env.example .env
forge build
forge test --match-contract ForkLifecycleTest -vv
```

That fork suite covers deploy, market creation, swaps, resolution, sell gating, and claims on Base.

Set these before the first deploy:

- `PRIVATE_KEY`
- `PROTOCOL_TREASURY`
- `BASE_RPC_URL`

Set these before creating a market:

- `FACTORY_ADDRESS`
- `MARKET_QUESTION`
- `RESOLVER` (optional, defaults to deployer)
- `MARKET_NOTES` (optional)
- `OUTCOME_TOKENS_SELLABLE`

`BASE_FORK_BLOCK_NUMBER` is optional for fork tests.

## Factory Parameters

`CreateMarketScript` calls `factory.createMarket(...)` with a mix of script inputs and fixed config:

- `lpFeePpm`, `tickSpacing`, `tokenSupplyEach`, and both tick ranges come from `src/MarketConfig.sol`
- `resolver` comes from `RESOLVER` and defaults to the deployer if unset
- `marketQuestion` comes from `MARKET_QUESTION`
- `marketNotes` comes from `MARKET_NOTES`
- `outcomeTokensSellable` comes from `OUTCOME_TOKENS_SELLABLE` and defaults to `true`

The most important toggle is `OUTCOME_TOKENS_SELLABLE`:

- `true`: traders can buy and sell YES/NO outcome tokens against the USDC pools while the market is open
- `false`: traders can still buy YES/NO with USDC, but they cannot swap YES/NO back into the pool for USDC before resolution

In other words, `false` makes the market buy-only during the open phase. It does not disable resolution or winner claims after the market resolves.

## Deploy Flow

Deploy the hook and factory once:

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url $BASE_RPC_URL --broadcast
```

With the current scripts, that broadcast sends 4 transactions:

1. Deploy `Create2Deployer`
2. Deploy `FortuneMarketHook` via `CREATE2`
3. Deploy `FortuneMarketFactory`
4. Call `hook.setFactory(factory)`

Create the first market:

```bash
forge script script/CreateMarket.s.sol:CreateMarketScript --rpc-url $BASE_RPC_URL --broadcast
```

That is 1 transaction: `factory.createMarket(...)`.
So the first live market takes 5 top-level transactions in total with the current scripts.

Inside that single call, the factory:

- deploys the market
- registers the YES and NO pools with the hook
- initializes both pools and seeds liquidity

After the hook and factory are live, every additional market is the same single `createMarket(...)` call.

## Files

- `src/FortuneMarket.sol`: market, hook, factory, CREATE2 deployer, and outcome token contracts
- `src/FortuneMarketSwapRouter.sol`: minimal swap helper used by the fork test
- `src/MarketConfig.sol`: Base addresses and deployment constants
- `script/Deploy.s.sol`: hook and factory deployment
- `script/CreateMarket.s.sol`: market creation from an existing factory
- `test/ForkLifecycle.t.sol`: Base fork deploy, swap, resolve, sell-gating, and claim coverage

## Security

Run your own review before using this in production:

- [ai-web3-security](https://github.com/pashov/ai-web3-security)
- manual audits

<p align="center">
  <img src="docs/cliza.png" alt="Cliza artwork" width="420" />
</p>
