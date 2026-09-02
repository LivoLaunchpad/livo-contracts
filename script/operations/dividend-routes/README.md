# Curated V4 dividend routes

`LivoDividendSwapRegistry` admits a dividend payout asset by measuring it: any ERC20 with a deep
enough Uniswap V2 pair against the chain's quote token is eligible, with nobody's permission. That
test cannot see a Uniswap V4 asset. A V4 pool is identified by a `(fee, tickSpacing, hooks)` tuple
that is not derivable from its two currencies, one pair can have hundreds of pools, and only one of
them is the liquid one — so for V4 somebody has to *name* the pools.

That is what a **route** is: an ordered list of hops from the native coin to the asset, written by a
registry admin with `setRoute`. It is the only admin lever in the registry that admits an asset
rather than refusing one, and the naming itself is the curation — no depth threshold is applied to a
routed asset, because the registry has nothing honest to measure.

The case this exists for is Robinhood Chain, where ~190 tokenized stocks (xStocks) have no V2 pair at
all. Measured against the chain as of the last scan: 189 of them have a live V4 pool against native
ETH and route in one hop; 3 (`GEV`, `PWR`, `SHY`) only have USDG liquidity and need the two-hop
`native -> USDG -> xSTOCK` shape; 2 (`BND`, `SATS`) have no pool with any liquidity at all.

## Rebuilding the routes

```
just discover-dividend-routes
```

`discover_xstock_routes.py` pulls the stock-token list from Robinhood's public asset API, replays
every `Initialize` log on the V4 pool manager that pairs one of those tokens (or USDG) with a
currency we care about, reads each pool's live in-range liquidity out of the singleton, and keeps the
deepest one per pair. A token with a direct native pool gets a one-hop route instead.

Output is `routes.robinhood.mainnet.json`. It carries a `readable` block alongside the encoded
routes — **review that diff**. "Deepest pool right now" is a heuristic, and this is the one place a
wrong answer silently routes a token's dividends through somebody else's pool.

## Writing them on-chain

```
export DIVIDEND_SWAP_REGISTRY=0x…      # the registry proxy on the target chain
just set-dividend-routes               # dry run; add --broadcast when the summary looks right
```

`SetDividendRoutes.s.sol` buys a little of every asset through every candidate against forked state
first, in simulation only, and keeps whichever actually delivers most. Only routes that both work and
differ from what is already live get broadcast, so re-running is cheap and idempotent.

The broadcaster must be a registry admin (or its owner).

## Adding one asset later

Do not regenerate the whole file — narrow the scan and point the script at the result:

```
uv run script/operations/dividend-routes/discover_xstock_routes.py --only NVDA -o /tmp/nvda.json
DIVIDEND_SWAP_REGISTRY=0x… ROUTES_JSON=/tmp/nvda.json just set-dividend-routes
```

`--only` takes ticker symbols or token addresses, comma-separated. The dry run tells you whether the
route it found actually buys the asset before you broadcast anything; that probe — a real swap through
the real registry against forked state — IS the validation. Do not try to reimplement it in Python: an
approximation of the swap can disagree with the contract it is meant to be validating.

## Keeping routes valid

A route is not self-maintaining. Nothing on-chain re-checks that the pool it names still holds depth,
so a pool that gets drained, or liquidity that migrates to a different fee tier, leaves a route that
fails every future conversion for every token configured to be paid in that asset.

The dry run is the health check. It probes the route each asset is ALREADY configured with alongside
the fresh candidates and reports one of:

| line | meaning |
| --- | --- |
| `ok` | the live route still beats every candidate — nothing to do |
| `better route found` | a candidate now delivers more; broadcasting switches to it |
| `BROKEN` | the live route AND every candidate fail — the asset's dividends cannot convert |
| `no candidate route could buy it` | never had a route, still cannot get one |

So the maintenance loop is: re-run discovery, dry-run this script, and act on anything that is not
`ok`. Worth doing on a schedule once routes are live on a chain.

## Known caveat: two-hop routes on Robinhood Chain

Robinhood Chain's universal router rejects the `SWAP_EXACT_IN` (multi-pool) calldata that Ethereum
mainnet's accepts — it is built against a different v4-periphery. `UniversalRouterVenue` therefore
sends a one-hop route as `SWAP_EXACT_IN_SINGLE`, which every router understands, and only reaches for
the multi-pool encoding when a route really has more than one hop. So on Robinhood Chain today the
one-hop routes all work and the three two-hop ones do not: the probe reports them and skips them, and
they become writable when that router is upgraded — no contract change needed, just a re-run.
