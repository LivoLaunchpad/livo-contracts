# Events per Entry Point

Reference for indexers, subgraphs, monitoring and auditing: which events — both Livo's own and those of external protocols (Uniswap V2/V4, WETH, Permit2, OpenZeppelin) — are emitted by each core user-facing entry point, in the order they occur on-chain.

- **Scope**: core user flows only (`createToken*`, `buyTokensWithExactEth`, `sellExactTokens`, graduations, post-graduation V4 swaps, fee claims). Admin / owner-only / token self-service entry points are not covered.
- **Method**: each sequence was captured from `forge test -vvvv` traces against a mainnet fork, then cross-checked against `src/` emit statements. Tests used are cited at the end of each section.
- **Format**: each event line is `[emitter]` `EventName(key args...)`. External protocol events are explicitly labeled as such; absence of label = emitted by a Livo contract.
- **Double emissions** in raw traces caused by `vm.expectEmit` are collapsed to a single entry here.
- **Reproduce**: `forge test --nmc Invariant -vvvv --mt <testName>` — the event ordering below matches the resulting trace.

## Table of contents

1. [createToken — `LivoFactoryUniV2` (V2 graduator, LivoToken)](#1-createtoken--livofactoryuniv2-v2-graduator-livotoken)
2. [createToken — `LivoFactoryBase` (V4 graduator, LivoToken)](#2-createtoken--livofactorybase-v4-graduator-livotoken)
3. [createToken — `LivoFactoryTaxToken` / `LivoFactoryExtendedTax`](#3-createtoken--livofactorytaxtoken--livofactoryextendedtax-v4-graduator-livotaxabletokenuniv4)
4. [createTokenWithFeeSplit — any V4 factory](#4-createtokenwithfeesplit--any-v4-factory)
5. [buyTokensWithExactEth (pre-graduation)](#5-buytokenswithexacteth--pre-graduation)
6. [buyTokensWithExactEth that triggers V2 graduation](#6-buytokenswithexacteth-that-triggers-v2-graduation)
7. [buyTokensWithExactEth that triggers V4 graduation](#7-buytokenswithexacteth-that-triggers-v4-graduation)
8. [sellExactTokens (pre-graduation)](#8-sellexacttokens-pre-graduation)
9. [V4 post-graduation buy — no creator tax](#9-v4-post-graduation-buy--no-creator-tax)
10. [V4 post-graduation buy — with creator tax](#10-v4-post-graduation-buy--with-creator-tax)
11. [V4 post-graduation sell](#11-v4-post-graduation-sell)
12. [`LivoFeeHandler.claim`](#12-livofeehandlerclaimaddress-tokens)
13. [`LivoFeeSplitter.claim`](#13-livofeesplitterclaimaddress-tokens)

---

## External contract legend

| Label in trace | Address / contract |
|---|---|
| `UniswapV2Factory` | `IUniswapV2Factory` mainnet |
| `UniswapV2Pair` | Pair created by the factory for `<token, WETH>` |
| `UniswapV2Router02` | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| `WETH9` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| `PoolManager` (V4) | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| `PositionManager` (V4) | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` (ERC721 holding LP positions) |
| `UniversalRouter` | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` (used by traders post-graduation) |
| `Permit2` | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

---

## 1. createToken — `LivoFactoryUniV2` (V2 graduator, `LivoToken`)

Signature: `createToken(string name, string symbol, bytes32 salt)` (payable).

If `msg.value == 0` — pure deploy. If `msg.value > 0` — also performs a deployer buy on the bonding curve for the sender.

### 1a. Without deployer buy (`msg.value == 0`)

1. **`LivoFactory.TokenCreated`** (`token, name, symbol, tokenOwner=address(0), launchpad, graduator, feeHandler, feeReceiver=msg.sender`) — emitted by the factory *before* `initialize()` so indexers see the entity first.
2. **`UniswapV2Factory.PairCreated`** (external) — pair for `<token, WETH>` created by graduator's `initialize()`.
3. **`LivoGraduator.PairInitialized`** (`token, pair`) — graduator records the pair.
4. **`ERC20.Transfer`** (from `0x0` to `LivoLaunchpad`, `value = 1e27`) — initial `1_000_000_000 * 1e18` mint to the launchpad.
5. **`Initializable.Initialized`** (OpenZeppelin, `version=1`) — token clone marked initialized.
6. **`LivoLaunchpad.TokenLaunched`** (`token, graduationThreshold=3.75e18, maxExcessOverThreshold=5e16`) — launchpad registers the token.

Test: `test/launchpad/createTokens.t.sol::testDeployLivoToken_happyPath`.

### 1b. With deployer buy (`msg.value > 0`)

All of 1a, then:

7. **`ERC20.Transfer`** (from `LivoLaunchpad` to `factory`, `value = tokensBought`) — launchpad transfers bought tokens to the factory.
8. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer=factory, ethAmount, tokenAmount, ethFee`).
9. **`ERC20.Transfer`** (from `factory` to `msg.sender`, `value = tokensBought`) — factory forwards the bought tokens to the caller.
10. **`LivoFactory.DeployerBuy`** (`token, buyer=msg.sender, ethSpent, tokensBought`).

Note: the treasury also receives the buy fee via a bare `.call{value}` — no event from that transfer.

Test: `test/factories/LivoFactoryDeployerBuy.t.sol::LivoFactoryBaseDeployerBuyTest::test_createToken_deployerBuy`.

---

## 2. createToken — `LivoFactoryBase` (V4 graduator, `LivoToken`)

Signature: `createToken(string name, string symbol, address feeReceiver, bytes32 salt)` (payable).

Differs from §1 by using the Uniswap V4 graduator: no V2 pair is created, instead a V4 pool is initialized.

### 2a. Without deployer buy

1. **`LivoFactory.TokenCreated`** (`token, name, symbol, tokenOwner=msg.sender, launchpad, graduator, feeHandler, feeReceiver`).
2. **`PoolManager.Initialize`** (external V4: `id, currency0=0x0, currency1=token, fee=0, tickSpacing=200, hooks=LivoSwapHook, sqrtPriceX96, tick`) — V4 pool initialized at graduation price by graduator.
3. **`LivoGraduator.PairInitialized`** (`token, pair=PoolManager`).
4. **`LivoGraduator.PoolIdRegistered`** (`token, poolId`) — V4-specific, maps token → `PoolId`.
5. **`ERC20.Transfer`** (from `0x0` to `LivoLaunchpad`, `value = 1e27`).
6. **`Initializable.Initialized`** (`version=1`).
7. **`LivoLaunchpad.TokenLaunched`** (`token, graduationThreshold, maxExcessOverThreshold`).

Test: `test/launchpad/createTokens.t.sol::test_createToken_v4_happyPath`.

### 2b. With deployer buy

Same as 2a plus the deployer-buy tail (same 4 events as §1b: `Transfer`, `LivoTokenBuy`, `Transfer`, `DeployerBuy`).

---

## 3. createToken — `LivoFactoryTaxToken` / `LivoFactoryExtendedTax` (V4 graduator, `LivoTaxableTokenUniV4`)

Signature: `createToken(string name, string symbol, address feeReceiver, bytes32 salt, uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds)` (payable).

Differs from §2 only by adding one extra event from the taxable-token initializer. `LivoFactoryExtendedTax` is owner-gated and lifts caps but emits the same events in the same order.

1. **`LivoFactory.TokenCreated`**.
2. **`PoolManager.Initialize`** (external V4).
3. **`LivoGraduator.PairInitialized`**.
4. **`LivoGraduator.PoolIdRegistered`**.
5. **`LivoTaxableTokenUniV4.LivoTaxableTokenInitialized`** (`buyTaxBps, sellTaxBps, taxDurationSeconds`) — NEW, only present for taxable tokens.
6. **`ERC20.Transfer`** (mint `1e27` to launchpad).
7. **`Initializable.Initialized`** (`version=1`).
8. **`LivoLaunchpad.TokenLaunched`**.

With deployer buy: append the same 4-event buy tail as §1b.

Tests:
- `test/factories/LivoFactoryTaxToken.t.sol::test_createToken_assertMaxSellTaxAccepted`
- `test/factories/LivoFactoryExtendedTax.t.sol::test_createToken_succeedsWhenCallerIsOwner`
- `test/factories/LivoFactoryDeployerBuy.t.sol::LivoFactoryTaxTokenDeployerBuyTest::test_createToken_deployerBuy`

---

## 4. createTokenWithFeeSplit — any V4 factory

Signature: `createTokenWithFeeSplit(string name, string symbol, address[] recipients, uint256[] sharesBps, bytes32 salt, ...)` on `LivoFactoryBase`, `LivoFactoryTaxToken`, and `LivoFactoryExtendedTax`.

Differs from the plain `createToken` flow in that the fee receiver is a freshly deployed `LivoFeeSplitter` clone. The factory emits `FeeSplitterCreated` *before* the splitter's `initialize()`, so the event ordering is specifically:

1. **`LivoFactory.TokenCreated`**.
2. **`PoolManager.Initialize`** (external V4).
3. **`LivoGraduator.PairInitialized`**.
4. **`LivoGraduator.PoolIdRegistered`**.
5. *(taxable variants only)* **`LivoTaxableTokenUniV4.LivoTaxableTokenInitialized`**.
6. **`ERC20.Transfer`** (mint `1e27` to launchpad).
7. **`Initializable.Initialized`** (token clone, `version=1`).
8. **`LivoLaunchpad.TokenLaunched`**.
9. **`LivoFactory.FeeSplitterCreated`** (`token, feeSplitter, recipients, sharesBps`) — **emitted before splitter init**, by design.
10. **`LivoFeeSplitter.SharesUpdated`** (`recipients, sharesBps`).
11. **`Initializable.Initialized`** (splitter clone, `version=1`).

With deployer buy: append the §1b 4-event tail.

Tests: `test/graduators/graduationUniv4.claimFees.splitter.t.sol::test_shareholdersCanClaimLpFees` (normal) and `::test_shareholdersCanClaimLpFees_taxToken`.

---

## 5. `buyTokensWithExactEth` — pre-graduation

Signature: `buyTokensWithExactEth(address token, uint256 minTokens, uint256 deadline)` (payable) on `LivoLaunchpad`.

Simple buy below graduation threshold. The same two events are emitted regardless of graduator type (V2 or V4).

1. **`ERC20.Transfer`** (from `LivoLaunchpad` to `buyer`, `value = tokensOut`).
2. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`).

The treasury receives the `ethFee` via `.call{value}` — no event.

Tests:
- `test/launchpad/buyTokens.t.sol::BuyTokenTests_Univ2::testBuyTokensWithExactEth_happyPath`
- `test/launchpad/buyTokens.t.sol::BuyTokenTests_Univ4::testBuyTokensWithExactEth_happyPath`

---

## 6. `buyTokensWithExactEth` that triggers V2 graduation

When the buy pushes `ethCollected` over the threshold, the same call continues into graduation against the V2 graduator.

1. **`ERC20.Transfer`** (launchpad → buyer): buy's portion of tokens.
2. **`LivoLaunchpad.LivoTokenBuy`**.
3. **`ERC20.Transfer`** (launchpad → graduator, `value = tokensForGraduation`): launchpad forwards graduation-reserved tokens.
4. **`LivoGraduator.CreatorGraduationFeeCollected`** (`token, amount = 1.25e17` for V2).
5. **`LivoFeeHandler.CreatorFeesDeposited`** (`token, account=creator, amount`) — creator share routed through `token.accrueFees()` → `feeHandler.depositFees()`. *For fee-split tokens this is instead `LivoFeeSplitter.FeesAccrued` — see §6 note below.*
6. **`LivoGraduator.TreasuryGraduationFeeCollected`** (`token, amount`).
7. **`ILivoToken.Graduated`** (no args) — from `LivoToken.markGraduated()`.
8. **`ERC20.Approval`** (external, from graduator to `UniswapV2Router02`, `value = tokensForGraduation`) — ERC20 approval.
9. **`UniswapV2Pair.Sync`** (external, `reserve0=0, reserve1=0`).
10. **`ERC20.Transfer`** (external, graduator → pair, `value = tokensForGraduation`) — token side of the add-liquidity.
11. **`WETH9.Deposit`** (external, `dst=UniswapV2Router02, wad=ethForLiquidity`).
12. **`WETH9.Transfer`** (external, router → pair, `value = ethForLiquidity`).
13. **`UniswapV2Pair.Transfer`** (external, LP-token mint `from=0x0, to=0x0, value=1000`) — MINIMUM_LIQUIDITY locked to the zero address.
14. **`UniswapV2Pair.Transfer`** (external, LP-token mint `from=0x0, to=DEAD_ADDRESS=0x…dEaD, value=<LP minted>`) — LP tokens permanently burned per Livo design.
15. **`UniswapV2Pair.Sync`** (external, final reserves).
16. **`UniswapV2Pair.Mint`** (external, `sender=router, amount0, amount1`).
17. **`LivoGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`).
18. **`LivoLaunchpad.TokenGraduated`** (`token, ethCollected, tokensForGraduation`) — note: distinct event from `LivoGraduator.TokenGraduated`, same name but different signature.

**Conditional**: if after `addLiquidityETH` the graduator holds leftover ETH, it emits **`LivoGraduator.SweepedRemainingEth`** (`token, amount`) before `TokenGraduated`. This is rare on the happy path (excess was already capped by `MAX_EXCESS`) but possible when the V2 pool is pre-seeded with reserves.

Test: `test/graduators/graduation.t.sol::UniswapV2AgnosticGraduationTests::test_graduatedBooleanTurnsTrueInLaunchpad`.

---

## 7. `buyTokensWithExactEth` that triggers V4 graduation

Same entry point as §6, but the token is registered against the V4 graduator. Two NFT LP positions are minted in the V4 PositionManager.

1. **`ERC20.Transfer`** (launchpad → buyer) — tokens for the trade.
2. **`LivoLaunchpad.LivoTokenBuy`**.
3. **`ERC20.Transfer`** (launchpad → V4 graduator, `value = tokensForGraduation`).
4. **`LivoGraduator.CreatorGraduationFeeCollected`** (`token, amount = 5e16` for V4).
5. **`LivoFeeHandler.CreatorFeesDeposited`** *(or `LivoFeeSplitter.FeesAccrued` if the token uses a splitter — see note below)*.
6. **`LivoGraduator.TreasuryGraduationFeeCollected`**.
7. **`ILivoToken.Graduated`**.
8. **`ERC20.Approval`** (external, graduator → Permit2, `value = max uint160`).
9. **`Permit2.Approval`** (external, graduator/owner, token, spender=PositionManager, amount, expiration).
10. **`ERC721.Transfer`** (external, PositionManager mint: `from=0x0, to=graduator, id=<position1Id>`) — LP NFT #1 minted to graduator.
11. **`PoolManager.ModifyLiquidity`** (external, `id=poolId, sender=PositionManager, tickLower=-7000, tickUpper=203600, liquidity, ...`) — primary token+ETH position across the trading range.
12. **`ERC20.Transfer`** (external, graduator → PoolManager, `value ≈ tokensForGraduation`) — token side of the position.
13. **`ERC721.Transfer`** (external, mint LP NFT #2 to graduator).
14. **`PoolManager.ModifyLiquidity`** (external, tick range `182400..193400`) — secondary ETH-only position above current price to absorb excess ETH.
15. **`LivoGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`).
16. **`LivoLaunchpad.TokenGraduated`**.

**Conditional — fee-splitter tokens**: if the token was deployed with `createTokenWithFeeSplit`, step 5 is **`LivoFeeSplitter.FeesAccrued`** (`amount`) instead of `LivoFeeHandler.CreatorFeesDeposited`. Reason: when a splitter is used, the token's `feeHandler` storage slot is the splitter itself, so `token.accrueFees()` sends the ETH straight into the splitter's `receive()` path (which emits `FeesAccrued`) rather than into the actual `LivoFeeHandler`.

Tests:
- `test/graduators/graduationUniv4.graduation.t.sol::UniswapV4GraduationTests_NormalToken::test_successfulGraduation_happyPath` (no splitter)
- `test/graduators/graduationUniv4.graduation.t.sol::UniswapV4GraduationTests_TaxToken::test_successfulGraduation_happyPath` (tax token, no splitter)
- `test/graduators/graduationUniv4.claimFees.splitter.t.sol::test_shareholdersCanClaimLpFees_taxToken` (with splitter — shows `FeesAccrued` branch)

---

## 8. `sellExactTokens` pre-graduation

Signature: `sellExactTokens(address token, uint256 tokenAmount, uint256 minEth, uint256 deadline)` on `LivoLaunchpad`.

Only valid before graduation. Graduators never sell back.

1. **`LivoLaunchpad.LivoTokenSell`** (`token, seller, tokenAmount, ethAmount, ethFee`).
2. **`ERC20.Transfer`** (seller → launchpad, `value = tokenAmount`) — seller returns tokens to the launchpad.

Order note: `LivoTokenSell` is emitted *before* the token inbound transfer because the launchpad emits the event after computing amounts but before pulling tokens; the ETH payout to the seller uses `.call{value}` and produces no event. The treasury fee is similarly event-less.

Tests:
- `test/launchpad/sellTokens.t.sol::SellTokenTests_Univ2::testSellExactTokens_happyPath`
- `test/launchpad/sellTokens.t.sol::SellTokenTests_Univ4::testSellExactTokens_happyPath`

---

## 9. V4 post-graduation buy — no creator tax

After graduation, users swap on the Uniswap V4 pool through the `UniversalRouter`. `LivoSwapHook.beforeSwap` is called by the `PoolManager` and charges the 1% LP fee (split creator/treasury). Only Livo-relevant hook events + relevant external events are listed.

Trigger: a buy swap through `UniversalRouter` on the graduated pool (ETH → token).

1. **`ERC20.Approval`** (external, buyer → Permit2) — one-time approval of the token to Permit2.
2. **`Permit2.Approval`** (external, buyer → UniversalRouter for the token).
3. **`LivoSwapHook.LpFeesAccrued`** (`token, creatorShare, treasuryShare`) — 1% fee split 50/50.
4. **`LivoFeeHandler.CreatorFeesDeposited`** (`token, account=creator, amount=creatorShare`). *For splitter-backed tokens: `LivoFeeSplitter.FeesAccrued` instead — same mechanism as §7.*
5. **`PoolManager.Swap`** (external, `id=poolId, sender=UniversalRouter, amount0, amount1, sqrtPriceX96, liquidity, tick, fee`) — actual swap effects.
6. **`LivoSwapHook.LivoSwapBuy`** (`token, txOrigin, ethIn, tokensOut, ethFees`).
7. **`ERC20.Transfer`** (external, `PoolManager → buyer`, `value = tokensOut`).

Test: `test/graduators/graduationUniv4.claimFees.t.sol::test_claimFees_happyPath_ethBalanceIncrease` (event prefix up to step 7).

---

## 10. V4 post-graduation buy — with creator tax

Same as §9 but the token has a non-zero `buyTaxBps` and the tax window is still open. Adds one event:

1. **`ERC20.Approval`** (external, buyer → Permit2).
2. **`Permit2.Approval`** (external, buyer → UniversalRouter).
3. **`LivoSwapHook.LpFeesAccrued`** (`token, creatorShare, treasuryShare`).
4. **`LivoSwapHook.CreatorTaxesAccrued`** (`token, amount = taxAmount`) — new event, only present when buy tax > 0 during the tax window.
5. **`LivoFeeHandler.CreatorFeesDeposited`** (`token, account=creator, amount = lpCreatorShare + taxAmount`) *(or `LivoFeeSplitter.FeesAccrued` for splitter-backed).*
6. **`PoolManager.Swap`** (external).
7. **`LivoSwapHook.LivoSwapBuy`** (`token, txOrigin, ethIn, tokensOut, ethFees`).
8. **`ERC20.Transfer`** (external, PoolManager → buyer).

Test: `test/hooks/LivoSwapHookLpFees.t.sol::test_buyChargesBuyTaxAndLpFee`.

---

## 11. V4 post-graduation sell

Mirror of §9/§10 but for token → ETH. Captured statically from `src/hooks/LivoSwapHook.sol` (lines 143-190 in `afterSwap`); the canonical test `test/hooks/LivoSwapHookLpFees.t.sol::test_sellStacksLpFeeAndSellTax` (not bundled in the trace run) exercises it.

1. **`Permit2.Approval`** / **`ERC20.Approval`** (external, one-time) — if not already approved.
2. **`PoolManager.Swap`** (external) — emitted inside `afterSwap`'s frame.
3. **`LivoSwapHook.LpFeesAccrued`** (`token, creatorShare, treasuryShare`).
4. **`LivoSwapHook.CreatorTaxesAccrued`** (`token, amount`) — **only** if `sellTaxBps > 0` and the tax window is open.
5. **`LivoFeeHandler.CreatorFeesDeposited`** (or `LivoFeeSplitter.FeesAccrued` for splitter tokens).
6. **`LivoSwapHook.LivoSwapSell`** (`token, txOrigin, tokensIn, ethOut, ethFees`).

The Uniswap V4 `Swap` event carries the raw swap deltas; Livo's `LivoSwapSell` is the aggregated view for indexers.

---

## 12. `LivoFeeHandler.claim(address[] tokens)`

Entry point for creators (or any fee-receiver EOA) to withdraw accumulated ETH fees for a set of tokens. Per-token short-circuit on zero pending means silent tokens emit nothing.

For each `token` in the argument list whose pending balance for `msg.sender` is non-zero:

1. **`LivoFeeHandler.CreatorClaimed`** (`token, account=msg.sender, amount`).

After iterating all tokens, ETH is transferred with a bare `.call{value}` — no event.

Tokens with zero pending are skipped silently (no event). If the total aggregate claim is zero the function returns without the ETH transfer call.

Test: `test/graduators/graduationUniv4.claimFees.t.sol::test_claimFees_happyPath_ethBalanceIncrease` — the final `CreatorClaimed` event in the trace is this one.

---

## 13. `LivoFeeSplitter.claim(address[] tokens)`

Entry point for fee-split recipients to withdraw their pro-rata share of ETH accumulated by the splitter. The splitter is **upstream** of `LivoFeeHandler`: on claim it first pulls its own balance from the handler (potentially emitting a `CreatorClaimed` on the handler and then a `FeesAccrued` on itself), then accrues fresh balance, then pays out per recipient.

For each `token` in the argument list (typically just one — the splitter's own):

1. **`LivoFeeHandler.CreatorClaimed`** (`token, account=splitter, amount`) — **conditional**: only if the handler has a non-zero pending balance for this splitter. Happens when creator fees from bonding-curve trades or the graduation creator fee arrived via `depositFees()`.
2. **`LivoFeeSplitter.FeesAccrued`** (`amount`) — new ETH recognized into the splitter's `_ethPerBps` accumulator.
3. **`LivoFeeSplitter.CreatorClaimed`** (`token, account=msg.sender, amount`) — amount for the caller only.

Event #3 uses the same event name as the fee handler's (intentionally, for indexer symmetry) — distinguish by emitter address.

If `msg.sender` is not a recipient, or has already claimed since the last share change, the function returns without emitting #3. If no new ETH has arrived, #1 and #2 are both absent.

Test: `test/feeSplitters/LivoFeeSplitter.t.sol::test_claim_assertEmitsEvents` (isolated, with a mock token) and the end-to-end `test/graduators/graduationUniv4.claimFees.splitter.t.sol::test_shareholdersCanClaimLpFees` (two `CreatorClaimed` emissions, one per shareholder).

---

## Appendix — events NOT reachable from any core user flow

These events exist in `src/` but are only emitted via out-of-scope (admin / owner) entry points, so they do not appear in the sections above. Listed here for completeness.

| Event | Source | Emitted by |
|---|---|---|
| `FactoryWhitelisted` | `LivoLaunchpad` | `whitelistFactory` (owner) |
| `FactoryBlacklisted` | `LivoLaunchpad` | `blacklistFactory` (owner) |
| `TradingFeesUpdated` | `LivoLaunchpad` | constructor + `setTradingFees` (owner) |
| `TreasuryAddressUpdated` | `LivoLaunchpad` | constructor + `setTreasuryAddress` (owner) |
| `CommunityTakeOver` | `LivoLaunchpad` | `communityTakeOver` (owner) |
| `MaxDeployerBuyBpsUpdated` | `LivoFactoryAbstract` | `setMaxDeployerBuyBps` (owner) |
| `TokenImplementationUpdated` | `LivoFactoryAbstract` | `setTokenImplementation` (owner) |
| `NewOwnerProposed` | `LivoToken` / `LivoTaxableTokenUniV4` | `proposeNewOwner` (token owner) |
| `OwnershipTransferred` | `LivoToken` / `LivoTaxableTokenUniV4` | `acceptTokenOwnership`, `renounceOwnership` |
| `FeeReceiverUpdated` | `LivoToken` / `LivoTaxableTokenUniV4` | `setFeeReceiver` (token owner) |
| `SharesUpdated` (post-init) | `LivoFeeSplitter` | `setShares` (token owner). Also emitted during `initialize()` — see §4. |
