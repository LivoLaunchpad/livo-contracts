# LivoSwapHook

A singleton Uniswap V4 hook that intercepts swaps on graduated Livo token pools to collect two types of fees:

1. **LP fee (1%)** — hardcoded as `LP_FEE_BPS = 100`. Charged on every swap, split 50/50 between token creator and protocol treasury.
2. **Sell/buy tax** — read dynamically per-token from `ILivoToken(tokenAddress).getTaxConfig()`, which returns a `TaxConfig` struct with `buyTaxBps`, `sellTaxBps`, `taxDurationSeconds`, and `graduationTimestamp`. Tax is time-limited (only active while `block.timestamp <= graduationTimestamp + taxDurationSeconds`). 100% goes to the token creator.

## Key mechanics

- **Buys** (`zeroForOne=true`): fees deducted from ETH input in `_beforeSwap()` before the swap executes.
- **Sells** (`!zeroForOne`): fees deducted from ETH output in `_afterSwap()` after knowing the actual output amount.
- Blocks all swaps on tokens that haven't graduated yet.
- Fees forwarded immediately: creator share via `ILivoToken.accrueFees{value}()`, treasury share via direct ETH transfer to `ILivoLaunchpad(LAUNCHPAD).treasury()`.
- Emits `LivoSwapBuy`/`LivoSwapSell` events with amounts and fees for off-chain indexing.

## Design notes

- Ownerless — no admin functions.
- Stateless across transactions — uses `transient` storage only for caching buy fees within a single tx.
- Treasury address resolved dynamically from the launchpad contract.
- Tax and fees going to the token creator do not go to an arbitrary address, they go through a feeHandler which is a Livo deployed contract (to avoid reentrancy / swap-DOS attacks).