# Events per Entry Point

Reference for indexers, subgraphs, monitoring and auditing: which events — both Livo's own and those of external protocols (Uniswap V2/V4, WETH, Permit2, OpenZeppelin) — are emitted by each core user-facing entry point, in the order they occur on-chain.

- **Scope**: core user flows only (`createToken*`, `buyTokensWithExactEth`, `sellExactTokens`, graduations, post-graduation V4 swaps, fee claims). Admin / owner-only / token self-service entry points are not covered.
- **Method**: each sequence was captured from `forge test -vvvv` traces against a mainnet fork, then cross-checked against `src/` emit statements. Tests used are cited at the end of each section.
- **Format**: each event line is `[emitter]` `EventName(key args...)`. External protocol events are explicitly labeled as such; absence of label = emitted by a Livo contract.
- **Double emissions** in raw traces caused by `vm.expectEmit` are collapsed to a single entry here.
- **Reproduce**: `forge test --nmc Invariant -vvvv --mt <testName>` — the event ordering below matches the resulting trace.

## Factory consolidation note

The launchpad now whitelists **two unified factories** instead of six:

- `LivoFactoryUniV2Unified` — V2 family. Dispatches between `LivoToken` and `LivoTokenSniperProtected`
  based on `AntiSniperConfigs.protectionWindowSeconds != 0`.
- `LivoFactoryUniV4Unified` — V4 family. Dispatches between `LivoToken`, `LivoTokenSniperProtected`,
  `LivoTaxableTokenUniV4`, and `LivoTaxableTokenUniV4SniperProtected` based on whether
  `TaxConfigInit.taxDurationSeconds != 0` and/or `AntiSniperConfigs.protectionWindowSeconds != 0`.

The on-chain event sequence below is **unchanged** — only the emitter contract address changes
(it's now the unified factory). Entry-point names below referring to old factory contracts
(`LivoFactoryUniV2`, `LivoFactoryUniV4`, `LivoFactoryTaxToken`, etc.) are kept for indexer
back-compatibility — the events match what `LivoFactoryUniV2Unified` / `LivoFactoryUniV4Unified`
now emit on the dispatch path that produces the same token variant.

## Table of contents

1. [createToken — V2 graduator + `LivoToken` (no anti-sniper)](#1-createtoken--livofactoryuniv2-v2-graduator-livotoken)
2. [createToken — V4 graduator + `LivoToken` (no tax, no anti-sniper)](#2-createtoken--livofactoryuniv4-v4-graduator-livotoken)
3. [createToken — V4 graduator + `LivoTaxableTokenUniV4` (tax, no anti-sniper)](#3-createtoken--livofactorytaxtoken--livofactoryextendedtax-v4-graduator-livotaxabletokenuniv4)
4. [createToken with a fee splitter — any dispatch path](#4-createtoken-with-a-fee-splitter--any-factory)
5. [buyTokensWithExactEth (pre-graduation)](#5-buytokenswithexacteth--pre-graduation)
6. [buyTokensWithExactEth that triggers V2 graduation](#6-buytokenswithexacteth-that-triggers-v2-graduation)
7. [buyTokensWithExactEth that triggers V4 graduation](#7-buytokenswithexacteth-that-triggers-v4-graduation)
8. [sellExactTokens (pre-graduation)](#8-sellexacttokens-pre-graduation)
9. [V4 post-graduation buy — no creator tax](#9-v4-post-graduation-buy--no-creator-tax)
10. [V4 post-graduation buy — with creator tax](#10-v4-post-graduation-buy--with-creator-tax)
11. [V4 post-graduation sell](#11-v4-post-graduation-sell)
12. [`LivoFeeHandler.claim`](#12-livofeehandlerclaimaddress-tokens)
13. [`LivoFeeSplitter.claim`](#13-livofeesplitterclaimaddress-tokens)
14. [Anti-sniper dispatch paths](#14-sniper-protected-factory-variants-createtoken)
15. [Direct-fees variants (auto-forwarded creator fees)](#15-direct-fees-variants-auto-forwarded-creator-fees)

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

## 1. createToken — `LivoFactoryUniV2Unified` (V2 graduator, `LivoToken`)

Dispatched by `LivoFactoryUniV2Unified.createToken(...)` when `antiSniperCfg.protectionWindowSeconds == 0` (no anti-sniper). For the anti-sniper variant of this same factory, see §14.2.

Signature: `createToken(string name, string symbol, bytes32 salt, FeeShare[] feeReceivers, SupplyShare[] supplyShares, AntiSniperConfigs antiSniperCfg)` (payable).

Same dispatch shape as every other factory: `feeReceivers.length == 1` → direct receiver, `>= 2` → splitter clone is deployed; `msg.value > 0` triggers a deployer buy distributed across `supplyShares`. The one V2-specific behaviour is `tokenOwner = address(0)` (ownership always renounced at creation), which makes the fee receiver permanent — there is no `setFeeReceiver` path later.

### 1a. Single fee receiver, no deployer buy (`msg.value == 0`, `feeReceivers.length == 1`)

1. **`LivoFactory.TokenCreated`** (`token, name, symbol, tokenOwner=address(0), launchpad, graduator, feeHandler=LivoFeeHandler, feeReceiver=feeReceivers[0].account`) — emitted by the factory *before* `initialize()` so indexers see the entity first.
2. **`LivoGraduator.PairInitialized`** (`token, pair`) — graduator records the **precomputed** CREATE2 pair address. The pair contract itself is **NOT** deployed at this point; it is deployed lazily at graduation (see §6). Off-chain consumers should read `LivoToken.pair()` to obtain the pair address pre-graduation rather than `UniswapV2Factory.getPair(token, WETH)` (which returns `address(0)` until the pair is deployed).
3. **`ERC20.Transfer`** (from `0x0` to `LivoLaunchpad`, `value = 1e27`) — initial `1_000_000_000 * 1e18` mint to the launchpad.
4. **`Initializable.Initialized`** (OpenZeppelin, `version=1`) — token clone marked initialized.
5. **`LivoLaunchpad.TokenLaunched`** (`token, graduationThreshold=3.75e18, maxExcessOverThreshold=5e16`) — launchpad registers the token.

Test: `test/launchpad/createTokens.t.sol::testDeployLivoToken_happyPath`.

### 1b. Multiple fee receivers (`feeReceivers.length >= 2`)

All of 1a (with `feeHandler` = `feeReceiver` = the splitter clone in the `TokenCreated` event), then append the splitter tail from §4:

6. **`LivoFactory.FeeSplitterCreated`** (`token, feeSplitter, recipients, sharesBps`) — emitted *before* the splitter's `initialize()`.
7. **`LivoFeeSplitter.SharesUpdated`** (`recipients, sharesBps`).
8. **`Initializable.Initialized`** (splitter clone, `version=1`).

### 1c. With deployer buy (`msg.value > 0`)

Append after the above (after 1a's step 6, or after 1b's step 9 when a splitter is present):

- **`ERC20.Transfer`** (from `LivoLaunchpad` to `factory`, `value = tokensBought`).
- **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer=factory, ethAmount, tokenAmount, ethFee`).
- One **`ERC20.Transfer`** per entry in `supplyShares` (from `factory` to `supplyShares[i].account`, `value = shareAmount`).
- **`LivoFactory.BuyOnDeploy`** (`token, buyer=msg.sender, ethSpent, tokensBought, recipients, amounts`).

Note: the treasury also receives the buy fee via a bare `.call{value}` — no event from that transfer.

Test: `test/factories/LivoFactoryDeployerBuy.t.sol::LivoFactoryUniV4DeployerBuyTest::test_createToken_deployerBuy`.

---

## 2. createToken — `LivoFactoryUniV4Unified` (V4 graduator, `LivoToken`)

Dispatched by `LivoFactoryUniV4Unified.createToken(...)` when both `taxCfg.taxDurationSeconds == 0` and `antiSniperCfg.protectionWindowSeconds == 0`. For the tax / anti-sniper / both variants of this same factory, see §3 and §14.

Signature: `createToken(string name, string symbol, bytes32 salt, FeeShare[] feeReceivers, SupplyShare[] supplyShares, bool renounceOwnership, TaxConfigInit taxCfg, AntiSniperConfigs antiSniperCfg)` (payable).

Differs from §1 by using the Uniswap V4 graduator: no V2 pair is created, instead a V4 pool is initialized. `tokenOwner` in the `TokenCreated` event below is `msg.sender` when `renounceOwnership == false` and `address(0)` when `renounceOwnership == true`.

### 2a. Without deployer buy

1. **`LivoFactory.TokenCreated`** (`token, name, symbol, tokenOwner, launchpad, graduator, feeHandler, feeReceiver`).
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

## 3. createToken — `LivoFactoryUniV4Unified` (V4 graduator, `LivoTaxableTokenUniV4`)

Dispatched by `LivoFactoryUniV4Unified.createToken(...)` when `taxCfg.taxDurationSeconds != 0` and `antiSniperCfg.protectionWindowSeconds == 0` (tax-only variant). For the tax + anti-sniper combo, see §14.3.

Signature: same as §2 (full unified `createToken`). `renounceOwnership` follows the same convention as §2: `address(0)` when `true`, `msg.sender` when `false`.

Differs from §2 only by adding one extra event from the taxable-token initializer.

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
- `test/e2e/variants/E2E_FactoryTaxToken.t.sol`
- `test/factories/LivoFactoryDeployerBuy.t.sol::LivoFactoryTaxTokenDeployerBuyTest::test_createToken_deployerBuy`

---

## 4. createToken with a fee splitter — any factory

Triggered when `feeReceivers.length >= 2` is passed to `createToken` on any of `LivoFactoryUniV2`, `LivoFactoryUniV4`, `LivoFactoryTaxToken`, or `LivoFactoryExtendedTax`. A `LivoFeeSplitter` clone is deployed and used as both `feeHandler` and `feeReceiver` on the token. The factory emits `FeeSplitterCreated` *before* the splitter's `initialize()`, so the event ordering is specifically:

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
6. **`LivoGraduator.TreasuryGraduationFeeCollected`** (`token, amount = 1.23e17` for V2). The treasury share is `GRADUATION_ETH_FEE - CREATOR_GRADUATION_COMPENSATION - TRIGGERER_GRADUATION_COMPENSATION = 0.123 ether`. The graduator also performs a best-effort, non-reverting push of `TRIGGERER_GRADUATION_COMPENSATION = 0.002 ether` to `tx.origin` (the original buyer's transaction origin) right before this step — no Livo event is emitted for that transfer; if it fails the 0.002 stays in the graduator and is later swept to treasury via `SweepedRemainingEth` (see note below).
7. **`UniswapV2Factory.PairCreated`** (external) — **conditional**: only fires when no outside actor pre-created the pair. The pair is no longer deployed at token creation (see §1a); the graduator deploys it lazily here via `factory.createPair(token, WETH)` only when `factory.getPair(token, WETH) == address(0)`. The deployed address always equals `LivoToken.pair()` (precomputed CREATE2).
8. **`ILivoToken.Graduated`** (no args) — from `LivoToken.markGraduated()`.
9. **`ERC20.Approval`** (external, from graduator to `UniswapV2Router02`, `value = tokensForGraduation`) — ERC20 approval.
10. **`UniswapV2Pair.Sync`** (external, `reserve0=0, reserve1=0`).
11. **`ERC20.Transfer`** (external, graduator → pair, `value = tokensForGraduation`) — token side of the add-liquidity.
12. **`WETH9.Deposit`** (external, `dst=UniswapV2Router02, wad=ethForLiquidity`).
13. **`WETH9.Transfer`** (external, router → pair, `value = ethForLiquidity`).
14. **`UniswapV2Pair.Transfer`** (external, LP-token mint `from=0x0, to=0x0, value=1000`) — MINIMUM_LIQUIDITY locked to the zero address.
15. **`UniswapV2Pair.Transfer`** (external, LP-token mint `from=0x0, to=DEAD_ADDRESS=0x…dEaD, value=<LP minted>`) — LP tokens permanently burned per Livo design.
16. **`UniswapV2Pair.Sync`** (external, final reserves).
17. **`UniswapV2Pair.Mint`** (external, `sender=router, amount0, amount1`).
18. **`LivoGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`).
19. **`LivoLaunchpad.TokenGraduated`** (`token, ethCollected, tokensForGraduation`) — note: distinct event from `LivoGraduator.TokenGraduated`, same name but different signature.

**Conditional**: if after `addLiquidityETH` the graduator holds leftover ETH, it emits **`LivoGraduator.SweepedRemainingEth`** (`token, amount`) before `TokenGraduated`. Reasons this can fire: (a) the V2 pool was pre-seeded with reserves so `addLiquidityETH` returned dust; (b) `tx.origin` could not receive the 0.002 ether triggerer compensation (see step 6), so that amount fell through to the sweep; or (c) any `addLiquidityETH` rounding leftover. On a clean happy path with an EOA `tx.origin` and no pre-seeded reserves, the sweep does not fire.

Test: `test/graduators/graduation.t.sol::UniswapV2AgnosticGraduationTests::test_graduatedBooleanTurnsTrueInLaunchpad`.

---

## 7. `buyTokensWithExactEth` that triggers V4 graduation

Same entry point as §6, but the token is registered against the V4 graduator. Two NFT LP positions are minted in the V4 PositionManager.

1. **`ERC20.Transfer`** (launchpad → buyer) — tokens for the trade.
2. **`LivoLaunchpad.LivoTokenBuy`**.
3. **`ERC20.Transfer`** (launchpad → V4 graduator, `value = tokensForGraduation`).
4. **`LivoGraduator.CreatorGraduationFeeCollected`** (`token, amount = 1.25e17` for V4).
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

Entry point for fee-split recipients to withdraw their pro-rata share of ETH accumulated by the splitter. For splitter-backed tokens the token's `feeHandler` slot is the splitter itself, so all fees land here directly via `LivoToken.accrueFees() → splitter.depositFees()`. The singleton `LivoFeeHandler` is never in the path; the splitter accrues unaccounted ETH on claim, then pays out per recipient.

For each `token` in the argument list (typically just one — the splitter's own):

1. **`LivoFeeSplitter.FeesAccrued`** (`amount`) — **conditional**: only if unaccounted ETH is sitting in the splitter (e.g. from a swap accrual since the last touch). New ETH is recognized into the splitter's `_ethPerBps` accumulator.
2. **`LivoFeeSplitter.CreatorClaimed`** (`token, account=msg.sender, amount`) — amount for the caller only.

Event #2 uses the same event name as the fee handler's (intentionally, for indexer symmetry) — distinguish by emitter address.

If `msg.sender` is not a recipient, or has already claimed since the last share change, the function returns without emitting #2. If no new ETH has arrived, #1 is absent.

Test: `test/feeSplitters/LivoFeeSplitter.t.sol::test_claim_assertEmitsEvents` (isolated, with a mock token) and the end-to-end `test/graduators/graduationUniv4.claimFees.splitter.t.sol::test_shareholdersCanClaimLpFees` (two `CreatorClaimed` emissions, one per shareholder).

---

## 14. Anti-sniper dispatch paths (`createToken`)

These are the dispatch paths of `LivoFactoryUniV2Unified.createToken` / `LivoFactoryUniV4Unified.createToken` taken when `antiSniperCfg.protectionWindowSeconds != 0`. They emit the exact same sequence as their non-protected twins (§1, §2, §3) **plus one extra event** — `SniperProtectionInitialized` — fired from the token's initializer after the mint (§14.1) or after `LivoTaxableTokenInitialized` (§14.3). Everything else (splitter tail from §4, deployer-buy tail from §1c, post-event ordering of `TokenLaunched`) is unchanged.

### 14.1. `LivoFactoryUniV4Unified.createToken` (V4 graduator, `LivoTokenSniperProtected`)

Dispatch path: `taxCfg.taxDurationSeconds == 0` and `antiSniperCfg.protectionWindowSeconds != 0`. Signature is the full unified V4 `createToken` (see §2). `renounceOwnership` follows the §2 convention.

Same event sequence as §2a, with `SniperProtectionInitialized` inserted between the mint and OZ `Initialized`:

1. **`LivoFactory.TokenCreated`**.
2. **`PoolManager.Initialize`** (external V4).
3. **`LivoGraduator.PairInitialized`**.
4. **`LivoGraduator.PoolIdRegistered`**.
5. **`ERC20.Transfer`** (mint `1e27` to launchpad).
6. **`SniperProtection.SniperProtectionInitialized`** (`maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, whitelist`) — NEW.
7. **`Initializable.Initialized`** (`version=1`).
8. **`LivoLaunchpad.TokenLaunched`**.

With splitter: append §4 tail. With deployer buy: append §1c 4-event tail.

Test: `test/e2e/variants/E2E_FactorySniperProtected.t.sol`.

### 14.2. `LivoFactoryUniV2Unified.createToken` (V2 graduator, `LivoTokenSniperProtected`)

Dispatch path: `antiSniperCfg.protectionWindowSeconds != 0`. Uses the V2 graduator (ownership always renounced at creation, `tokenOwner = address(0)` in `TokenCreated`). Event sequence mirrors §1a plus `SniperProtectionInitialized`. As in §1a, the UniV2 pair is **not** deployed at this point — only its CREATE2 address is reserved; deployment happens at graduation (see §6):

1. **`LivoFactory.TokenCreated`** (`tokenOwner = address(0)`).
2. **`LivoGraduator.PairInitialized`** — precomputed CREATE2 address; pair contract not yet deployed.
3. **`ERC20.Transfer`** (mint `1e27` to launchpad).
4. **`SniperProtection.SniperProtectionInitialized`** — NEW.
5. **`Initializable.Initialized`** (`version=1`).
6. **`LivoLaunchpad.TokenLaunched`**.

Test: `test/e2e/variants/E2E_FactoryUniV2SniperProtected.t.sol`.

### 14.3. `LivoFactoryUniV4Unified.createToken` (V4 graduator, `LivoTaxableTokenUniV4SniperProtected`)

Dispatch path: `taxCfg.taxDurationSeconds != 0` and `antiSniperCfg.protectionWindowSeconds != 0` (tax + anti-sniper). Signature is the full unified V4 `createToken` (see §2). `renounceOwnership` follows the §2 convention.

Same sequence as §3 plus `SniperProtectionInitialized` after `LivoTaxableTokenInitialized`:

1. **`LivoFactory.TokenCreated`**.
2. **`PoolManager.Initialize`** (external V4).
3. **`LivoGraduator.PairInitialized`**.
4. **`LivoGraduator.PoolIdRegistered`**.
5. **`ERC20.Transfer`** (mint `1e27` to launchpad).
6. **`LivoTaxableTokenUniV4.LivoTaxableTokenInitialized`** (`buyTaxBps, sellTaxBps, taxDurationSeconds`).
7. **`SniperProtection.SniperProtectionInitialized`** — NEW.
8. **`Initializable.Initialized`** (`version=1`).
9. **`LivoLaunchpad.TokenLaunched`**.

With splitter: append §4 tail. With deployer buy: append §1c 4-event tail.

Test: `test/e2e/variants/E2E_FactoryTaxTokenSniperProtected.t.sol`.

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
| `DirectReceiverRegistered` (post-init) | `LivoFeeSplitter` | `setShares` (token owner) — emitted per address newly added or promoted to direct. Also emitted during `initialize()` for every initial direct receiver. |
| `DirectReceiverRemoved` | `LivoFeeSplitter` | `setShares` (token owner) — emitted per address that was direct beforehand and is no longer direct (demoted to claimable or removed entirely). Never emitted from `initialize()`. |

---

## 15. Direct-fees variants (auto-forwarded creator fees)

When a `FeeShare` entry passed to `createToken` has `directFeesEnabled = true`, that receiver
opts into synchronous ETH forwarding instead of the pull-based claim flow. At most one direct
receiver per deployment is allowed at create-time (factory enforces with
`MultipleDirectFeeReceivers`); the splitter itself is generic w.r.t. how many direct receivers
it can hold, and `setShares` may add more after init. The direct flag on the singleton handler
path is bound to the slot, not the address: `LivoToken.setFeeReceiver` rotates ownership of the
direct slot to the new receiver via `LivoFeeHandler.migrateDirectReceiver`.

The on-chain effect is purely additive on the existing flows: every section above remains valid;
direct-fees variants insert one extra `CreatorClaimed` event right after the existing accrue event
(`CreatorFeesDeposited` for the singleton path, `FeesAccrued` for the splitter path). The accrue
event always fires first to preserve the original event ordering.

**Failure-fallback rule (applies to every entry point below):** when the direct receiver's
`receive()` reverts, the forward is silently abandoned and the funds are credited as a normal
pending claim — `CreatorClaimed` is **NOT** emitted in that case, and the receiver can recover
the residue via the existing `claim()` flow. Graduations and swaps NEVER revert because of a
hostile direct receiver.

### 15.1. Singleton path: 1 receiver, `directFeesEnabled = true`

The token's `feeHandler` is the singleton `LivoFeeHandler`. The factory calls
`registerDirectReceiver(token, receiver)` between token init and `LAUNCHPAD.launchToken` (no event
emitted from the registration itself).

Wherever the existing flow has `LivoFeeHandler.CreatorFeesDeposited` (e.g. graduation step §6 #5,
§7 #5, post-grad swap step §9 #4 / §10 #5 / §11 #5), append immediately after:

- **`LivoFeeHandler.CreatorClaimed`** (`token, account=feeReceiver, amount = msg.value`) — the
  synchronous forward. Same event signature as the existing `claim()` event; distinguish by tx
  context (no preceding `claim()` call).

### 15.2. Splitter path: ≥2 receivers, one or more with `directFeesEnabled = true`

The splitter holds an arbitrary subset of its recipients as direct receivers (typically one,
since the factory caps direct-flagged entries at 1 per deployment, but the splitter itself is
generic). The set is **mutable** post-init: `setShares` may add, remove, promote, or demote
any address — see §15.4 for the events emitted by those transitions. Existing splitter flow
(§4 + §7's splitter branch) applies as-is; the direct slice is skimmed off `_accrueBalance`.

Wherever the existing flow has `LivoFeeSplitter.FeesAccrued` (graduation §7 #5 conditional,
post-grad §9-§11 conditional), append immediately after — once per direct receiver whose
forward succeeded:

- **`LivoFeeSplitter.CreatorClaimed`** (`token, account=directReceiver, amount = newEth * directBps / 10_000`) —
  the synchronous forward to a direct receiver. Claimable shareholders' shares accumulate
  normally in `_ethPerBps` and are unaffected.

### 15.3. `setFeeReceiver` migration (singleton path only)

`LivoToken.setFeeReceiver` calls `feeHandler.migrateDirectReceiver(newReceiver)` after updating
its local field. For the singleton handler, this rewrites the `directReceiver[token]` mapping to
the new address. Splitter-backed tokens hit a no-op implementation. No new events are emitted; only
the existing `LivoToken.FeeReceiverUpdated` fires (already documented under §Appendix as a
token-self-service event).

### 15.4. `LivoFeeSplitter.setShares` direct-set transitions

`setShares` (token-owner only) may freely change which recipients are direct. Diff-style events
fire so indexers can keep the direct set in sync without re-reading state:

- **`LivoFeeSplitter.DirectReceiverRemoved`** (`token, receiver`) — once per address that was
  direct beforehand and is no longer direct in the new payload (demoted to claimable or removed
  entirely). The address's parked failed-forward residue (in `_pendingClaims`) is preserved and
  remains recoverable via `claim()`.
- **`LivoFeeSplitter.DirectReceiverRegistered`** (`token, receiver`) — once per address that is
  direct in the new payload and was **not** direct beforehand (newly added or promoted from
  claimable). Same event as the one fired during `initialize()` for the initial direct set.
- **`LivoFeeSplitter.SharesUpdated`** (`recipients, sharesBps`) — emitted last, signature
  unchanged.

When `setShares` only rebalances BPS without changing the direct set, neither
`DirectReceiverRemoved` nor `DirectReceiverRegistered` fires — only `SharesUpdated`.

Tests:
- `test/factories/LivoFactoryDirectFees.t.sol` — factory dispatch, registration, max-1 enforcement
- `test/feeHandlers/LivoFeeHandler.directFees.t.sol` — singleton path forwarding + revert fallback
- `test/feeSplitters/LivoFeeSplitter.directFees.t.sol` — splitter math + mutable-set transitions
- `test/e2e/variants/E2E_DirectFees.t.sol` — full graduation + post-grad swap with direct receiver
