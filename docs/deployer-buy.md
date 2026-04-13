# Deployer Buy on Token Creation

Token deployers can now buy up to `maxDeployerBuyBps` (default 10%) of the total supply in the same transaction as token creation.

## Frontend Flow

1. User picks a % of supply they want to buy (0% to `factory.maxDeployerBuyBps()` / 100)
2. Compute `tokenAmount = totalSupply * desiredBps / 10_000` (where `totalSupply = 1_000_000_000e18`)
3. Call `factory.quoteDeployerBuy(tokenAmount)` → returns `totalEthNeeded`
4. Call `factory.createToken{value: totalEthNeeded}(name, symbol, feeReceiver, salt)` (or `createTokenWithFeeSplit`)
5. If user doesn't want to buy, simply don't send ETH — backward compatible

## Notes

- `quoteDeployerBuy()` uses ceiling math, so the deployer receives **at least** `tokenAmount` tokens (possibly a few wei more due to rounding)
- The `LivoTokenBuy` event from the launchpad will show the **factory** as the buyer. The factory emits a separate `DeployerBuy` event with the actual deployer address
- `maxDeployerBuyBps` is a configurable storage variable (admin-only setter: `setMaxDeployerBuyBps()`)
- Both `LivoFactoryBase` and `LivoFactoryTaxToken` support this feature with the same interface
