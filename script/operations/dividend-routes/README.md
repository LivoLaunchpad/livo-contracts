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

`SetDividendRoutes.s.sol` sets every route and buys a little of every asset against forked state
first, in simulation only, and skips any route whose probe swap reverts. Only the proved ones are
broadcast. Re-running it updates routes in place; it never duplicates them.

The broadcaster must be a registry admin (or its owner).

## Known caveat: two-hop routes on Robinhood Chain

Robinhood Chain's universal router rejects the `SWAP_EXACT_IN` (multi-pool) calldata that Ethereum
mainnet's accepts — it is built against a different v4-periphery. `UniversalRouterVenue` therefore
sends a one-hop route as `SWAP_EXACT_IN_SINGLE`, which every router understands, and only reaches for
the multi-pool encoding when a route really has more than one hop. So on Robinhood Chain today the
one-hop routes all work and the three two-hop ones do not: the probe reports them and skips them, and
they become writable when that router is upgraded — no contract change needed, just a re-run.
