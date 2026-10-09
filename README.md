# Stock-token fee hooks for Uniswap v4

Reference implementations of the four fee designs from [The Memecoin Bots Behind NVDA's Volume](https://slvr-fun.github.io/stock-fee-hooks/) (SLVR Vaults, October 2026). The article and its interactive charts live in `docs/` and are served by GitHub Pages.

Tokenized stocks trade around the clock, but their price is set on an exchange with business hours. LPs lose the most in the first and last half hour of the NYSE session and on trades that close a gap to the market price. These hooks price those moments instead of charging every trade the same.

These are unaudited reference implementations written to illustrate the designs. Don't deploy them with real funds without an audit, and check the holiday calendar against NYSE's published calendar first.

## Contracts

| File | What it is |
|---|---|
| `src/OpeningBellFeeHook.sol` | Designs 1 and 2. Raises the fee in the first and last half hour of the NYSE session, with an optional opening auction that starts high at 09:30 ET and halves every N seconds. No oracle and no owner. |
| `src/OracleDirectionalFeeHook.sol` | Design 3. A keeper writes a reference price into storage. Swaps that move the pool toward it pay `alpha` times the gap; every other swap pays the session schedule fee. Falls back to the schedule when the reference is stale, and charges a halt fee when the keeper flags a halt. The owner can only rotate the keeper. |
| `src/LowToxicitySpreadHook.sol` | Design 4. No oracle. Emulates a bid/ask spread with the fee, after the [low-toxicity AMM](https://ethresear.ch/t/low-toxicity-amm/13560) proposed on ethresear.ch: a swap moves one side of the quote with the price and leaves the other where it was, so a trade that reverses a recent move pays the gap back, and the gap halves every `halfLife` seconds. The spread sits on top of the session schedule. No owner, no keeper. |
| `src/SessionFeeSchedule.sol` | The immutable fee schedule (base, open, close, window lengths, auction start fee and half-life) that all three hooks use. |
| `src/MarketClock.sol` | New York time from `block.timestamp`, with US daylight saving computed on chain and the holiday and early-close list fixed at deployment. Also contains the `CivilDate` library. |
| `src/NyseCalendar.sol` | NYSE holidays and 13:00 early closes for 2026 and 2027. |
| `src/BaseHook.sol` | Minimal v4 hook base that validates the hook address flags. |
| `test/StockFeeHooks.t.sol` | 22 Foundry tests against a real PoolManager, including two fuzz tests. |
| `test/LowToxicitySpreadHook.t.sol` | 10 tests for Design 4, including a sandwich back leg and a fuzz test. |
| `test/utils/HookMiner.sol` | Finds a CREATE2 salt for a valid hook address. |

Fees are in pips (hundredths of a basis point), the unit Uniswap v4 uses: 500 = 5 bps. Pools must be created with `LPFeeLibrary.DYNAMIC_FEE_FLAG`; every hook rejects static-fee pools.

## Build and test

```bash
git clone --recursive https://github.com/slvr-fun/stock-fee-hooks.git
cd stock-fee-hooks
forge build lib/v4-core/src/PoolManager.sol
forge test
```

The tests deploy the PoolManager from its prebuilt artifact, so the PoolManager build has to run once before `forge test`.

Dependencies are pinned as submodules: v4-core `e50237c`, OpenZeppelin Contracts v5.5.0, forge-std v1.12.0.

## Gas

Measured on the same exact-in swap in the test harness:

| Pool | Gas per swap |
|---|---|
| Plain v4 pool, static fee | 121,336 |
| `OpeningBellFeeHook` | 132,090 (+10,754) |
| `OracleDirectionalFeeHook` | 139,408 (+18,072) |
| `LowToxicitySpreadHook` | about +24,000 (144,842 against 120,808 for a plain pool, measured on a repeat swap one second later) |

## The reference price for Design 3

Design 3 needs a fresh price. In our replay it nets LPs +1.42 bps per dollar traded with a reference about a minute old, +0.78 at two minutes and nothing at five. Chainlink's push feed for NVDA on Robinhood Chain updates on 0.5% moves, which can be hours apart, so it is too coarse for a fee measured in basis points. Chainlink Data Streams publishes sub-second 24/5 equity reports with a market-status field, but it is pull-based and sold by subscription, so a keeper has to fetch each report and push it into the hook. At 0.02 gwei a push costs about $0.002 in gas, about $3 a day once a minute. The keeper can only move the fee within `maxFee`, never funds, and the hook falls back to the schedule when the price goes stale. Design 4 needs none of this.

## Routing

Uniswap reviews dynamic-fee hooks before routing to them. The hooks are written to meet the published criteria: immutable (no proxy), no custom hook data (Design 3 reads the reference price from storage), and the protocol fee is left alone.

## License

MIT
