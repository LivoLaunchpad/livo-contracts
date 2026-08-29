# Events per Entry Point

Reference for indexers, subgraphs, monitoring and auditing: which Livo events are emitted by each core user-facing entry point, in the order they occur on-chain.

## Scope and current fee-handler model

This document describes the active source tree after the legacy implementations were removed:

- `src/feeHandlers/LivoFeeHandler.sol` — removed from active source.
- `src/feeSplitters/LivoFeeSplitter.sol` — removed from active source.
- `ILivoFeeHandler` / `ILivoFeeSplitter` interfaces may remain for legacy deployed-contract interaction, but no active factory/token path deploys or imports those implementations.

All new tokens use the singleton `LivoMasterFeeHandler`.

Pre-graduation trading fees are no longer global launchpad state. Each token carries its own LP
(trading) fee — split treasury/creator by `treasuryShareBps` — plus, on taxable variants, a creator
tax (100% to the creator), read per-trade by the launchpad via `ILivoToken.getLaunchpadFees` and
reported through `LivoLaunchpad.LpFeesAccrued` / `LivoLaunchpad.CreatorTaxesAccrued` (mirroring the
post-graduation `LivoSwapHook` for accounting parity). The launchpad's global `setTradingFees` /
`TradingFeesUpdated` are removed; the per-token LP-fee config surfaces as
`LivoToken.LaunchpadFeesInitialized` (at creation). The LP fee is immutable after launch (no setter).
The creator tax is configured on taxable variants and surfaces via `LivoTaxableTokenInitialized` /
`TaxBpsUpdated`; its window is creation-anchored (`[launchTimestamp, launchTimestamp + taxDurationSeconds]`)
and applies identically pre- and post-graduation.

Unified factories register fee config automatically during token creation:

`factory.createToken(...) -> _finalizeCreation(...) -> LivoToken.registerFees(...) -> LivoMasterFeeHandler.registerToken(...)`

`LivoMasterFeeHandler.registerToken` emits any initial direct-receiver events first, then `SharesUpdated`.

## Active event emitters covered here

- `LivoFactoryUniV2Unified` / `LivoFactoryUniV4Unified`
- `LivoLaunchpad`
- `LivoToken` / `LivoTaxableTokenUniV4` / `LivoTaxableTokenUniV2` / sniper-protected variants
- `LivoGraduatorUniswapV2` / `LivoGraduatorUniswapV4` — the ARC variant `LivoGraduatorUniswapV2Arc` shares `LivoGraduatorUniswapV2Base` and emits the identical events in the identical order; every `LivoGraduatorUniswapV2` mention below applies to it unchanged.
- `LivoMasterFeeHandler`
- `LivoSwapHook`

External ERC20 / Uniswap / WETH / Permit2 events still occur in traces, but this file focuses on Livo-owned events and notes the main external-operation points.

## Table of contents

1. [`createToken` — unified factory paths](#1-createtoken--unified-factory-paths)
2. [`buyTokensWithExactEth` — pre-graduation](#2-buytokenswithexacteth--pre-graduation)
3. [`buyTokensWithExactEth` that triggers V2 graduation](#3-buytokenswithexacteth-that-triggers-v2-graduation)
4. [`buyTokensWithExactEth` that triggers V4 graduation](#4-buytokenswithexacteth-that-triggers-v4-graduation)
5. [`sellExactTokens` — pre-graduation](#5-sellexacttokens--pre-graduation)
6. [V4 post-graduation swaps](#6-v4-post-graduation-swaps)
7. [`LivoMasterFeeHandler.claim`](#7-livomasterfeehandlerclaimaddress-tokens)
8. [`LivoMasterFeeHandler.setShares`](#8-livomasterfeehandlersetsharesaddress-token-feeshare-feeshares)
9. [Direct-fee behavior](#9-direct-fee-behavior)
10. [`LivoTaxableToken.setTaxBps`](#10-livotaxabletokensettaxbpsuint16-newbuytaxbps-uint16-newselltaxbps)

---

## 1. `createToken` — unified factory paths

Each unified factory exposes four `createToken` overloads with different selectors:
- **Legacy positional** (deprecated): `(name, symbol, salt, feeReceivers, supplyShares, taxCfg, antiSniperCfg)` on V2 and the same plus `renounceOwnership_` on V4. Never creates creator vaults. Takes the legacy `TaxConfigInit` (static tax only) and always uses `LiquidityTier.DEFAULT`.
- **Struct-based, tiered** (backwards-compat): `(TokenSetupTiered, TaxConfigs, [UniV4Configs,] SupplyShare[], AntiSniperConfigs, CreatorVault[])` — struct-grouped inputs (to keep the ABI extensible without hitting stack-too-deep) plus a trailing `CreatorVault[]` (empty for none) that locks supply in vesting vaults. `TokenSetupTiered` carries the `liquidityTier` field selecting the post-graduation pool depth. Takes the full `TaxConfigs` (static tax + the three launch-tax-decay fields).
- **Struct-based, tiered + referral** (current/recommended): the same shape plus a trailing `address referral` for relayers that forward the creation and are entitled to a cut of the fees. When `referral != address(0)` it additionally emits `LivoFactory.TokenReferral` (see §1.1 step 7). No token storage or on-chain payout is wired to the referral yet — it is purely an off-chain signal for now.
- **Struct-based, tiered + referral + earnings allocation**: the referral overload's shape but with `TaxConfigsWithAllocation` in place of `TaxConfigs` — the flat `TaxConfigs` fields plus a nested `earningsAllocation` = `{burnBps, dividendsBps, liquidityBps, dividendTokens[3], dividendWeightsBps[3]}` (post-graduation earnings routed to buy-back-and-burn / holder dividends / liquidity; the fund wallets take the remainder). The split is stored on the token at creation via a factory-guarded `initializeEarningsAllocation` call, emitting `EarningsAllocationInitialized` and — when `dividendsBps != 0` — `DividendsInitialized` (see §1.1 step 6b). A non-zero split requires a taxable token (the split machinery lives on the taxable impl); otherwise the overload reverts `EarningsAllocationRequiresTax`. A non-zero `dividendsBps` must come with a payout configuration: `dividendWeightsBps` summing to 10 000 and left-packed, distinct assets, and a curated `SwapRouteRegistry` route for any third-party asset — otherwise the token reverts `InvalidDividendConfig` / `UnsupportedDividendAsset` at creation, because a clone cannot be patched afterwards. An asset may be `address(0)` (native), `DividendDistribution.DIVIDEND_SELF_TOKEN` or the token's own address (paid in the token itself), or a routed ERC20. An all-zero `earningsAllocation` behaves exactly like the referral overload (no extra call, no event).

The legacy positional overload internally lifts its `TaxConfigInit` into a `TaxConfigs` (decay fields zeroed) before dispatch, so all three share the same internal flow and emit the events listed below in the same order; only the two struct-based overloads can emit the creator-vault events in §1 step 4b.

### 1.1 Common sequence

For both unified factories, the common Livo event order is:

1. **`LivoFactory.TokenCreated`** (`token, name, symbol, tokenOwner, launchpad, graduator, feeHandler=LivoMasterFeeHandler`) — emitted before token initialization so indexers see the token entity before initializer-side events. `LivoFactoryUniV2Unified` always emits `tokenOwner = address(0)`; `LivoFactoryUniV4Unified` emits `address(0)` only when ownership is renounced.
2. **Graduator initialization events**:
   - V2: **`LivoGraduator.PairInitialized`** (`token, pair`) — pair address is predicted; pair deployment can happen later at graduation.
   - V4: **`LivoGraduator.PairInitialized`** (`token, pair=PoolManager`) then **`LivoGraduatorUniswapV4.PoolIdRegistered`** (`token, poolId, swapHookAddress`).
3. Implementation initializer events (emitted during the token's `initialize`, after the initial mint(s)):
   - Always: **`LivoToken.LaunchpadFeesInitialized`** (`lpFeeBps, treasuryShareBps`) — the per-token pre-graduation LP-fee config the launchpad reads each trade. A single LP fee applies to both buys and sells (mirroring the post-graduation hook). The creator tax (if any) is reported separately by `LivoTaxableTokenInitialized` below. Emitted before the tax/sniper events below.
   - Tax token: **`LivoTaxableTokenInitialized`** (`buyTaxBps, sellTaxBps, taxDurationSeconds, startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps, taxDecayDuration`). `startTaxFromLaunch` tells the indexer the tax-window anchor: `true` → window runs `[launchTimestamp, launchTimestamp + taxDurationSeconds]` (creation-anchored, spans graduation); `false` → `[graduationTimestamp, +taxDurationSeconds]` (no tax pre-graduation). The three `*Decay*` fields configure the optional linear launch-tax decay, anchored at the SAME point as the static window: each direction's rate decays linearly from `*TaxDecayStartBps` (`buyTaxDecayStartBps + sellTaxDecayStartBps` ≤ 2000 = 20% combined) at the anchor to 0 over `taxDecayDuration` (≤1200 s = 20 min). The effective tax a trade pays is `max(decay, static)` per direction, so a token may emit non-zero decay fields with zero static fields (a "decay-only" token — a non-taxable token that opted into the launch decay; it is still deployed as a taxable-impl clone). A token may also configure both, or neither (all six fields 0).
   - Sniper-protected token: **`SniperProtectionInitialized`** (`maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, whitelist`).
4. **`LivoLaunchpad.TokenLaunched`** (`token, graduationThreshold, maxExcessOverThreshold`). For a creator-vault token the registered bonding curve is the allocation-specific one, but the graduation threshold/excess are identical to the base curve.
4a. **`LivoFactory.BondingCurveAssigned`** (`token, bondingCurve`) — records which bonding curve the token was launched on (the allocation-specific curve for creator-vault tokens, the base curve otherwise). Emitted immediately after `TokenLaunched`; both fields are indexed. This is the only event carrying the curve address — combine it with the curve's own `LivoBondingCurveDeployed` (emitted at curve-deploy time, see note below) to reconstruct reserves off-chain.
4b. Creator vaults only (non-empty `CreatorVault[]`): the factory deploys and funds the vaults. Per vault, in order: **`LivoCreatorVaultFactory.CreatorVaultDeployed`** (`vault, token, owner, amount, cliffSeconds, vestingSeconds`) followed by an ERC20 `Transfer` (factory → vault). After all vaults: **`LivoFactory.CreatorVaultsCreated`** (`token, totalVaultAllocation, vaults, amounts`).
5. Initial fee config is registered through the token into `LivoMasterFeeHandler`:
   - Zero or more **`LivoMasterFeeHandler.DirectReceiverRegistered`** (`token, receiver`) — one per initial direct receiver.
   - **`LivoMasterFeeHandler.SharesUpdated`** (`token, recipients, sharesBps`).
6. V4 only: **`LivoFactory.LpFeeBpsSet`** (`token, lpFeeBps`) — emitted by `LivoFactoryUniV4Unified` for every created token, unconditionally (presence of the event is itself the V4-origin signal). `LivoFactoryUniV2Unified` never emits it. With `msg.value > 0`, this fires *after* the deployer-buy events listed in 1.2.
6b. Earnings-allocation overload only, and only when `earningsAllocation` is non-zero: **`EarningsAllocation.EarningsAllocationInitialized`** (`burnBps, dividendsBps, liquidityBps`) — the creation-time earnings split. Emitted by the token itself from the factory-guarded `initializeEarningsAllocation` call, which the factory makes *after* the shared creation body — so it fires after the fee registration (step 5), any deployer-buy events (§1.2) and `LpFeeBpsSet` (step 6, V4), and before `TokenReferral` (step 7). Both factories emit it (via the token); an all-zero allocation, or any other overload, emits nothing here.

6c. Same call, immediately after 6b, and only when `dividendsBps != 0`: **`DividendDistribution.DividendsInitialized`** (`dividendTokens[3], weightsBps[3]`) — which assets holders are paid in and how the dividends slice divides across them. The self-token sentinel is already resolved to the token's own address in the emitted array. Nothing else fires here: the first dividend ROUND opens at graduation, not at creation (see §graduation).
7. Referral overload only, and only when `referral != address(0)`: **`LivoFactory.TokenReferral`** (`token, referral`, both indexed) — records the relayer/referrer that forwarded the creation. Emitted last of all factory events (after `LpFeeBpsSet` on V4, and after `EarningsAllocationInitialized` on the allocation overload). Both factories emit it; the common no-referral deploy emits nothing here.

Notes:

- The bonding curve contracts (`ConstantProductBondingCurve`, `ConstantProductBondingCurveConfigurable`) emit **`LivoBondingCurveDeployed`** (`k, t0, e0, ethGraduationThreshold, maxExcessOverThreshold`) once from their constructor — in the curve's own deploy tx, NOT during `createToken`. The `Livo` prefix gives the event a unique topic so it can be wildcard-indexed (from any curve address). Indexers join it to `BondingCurveAssigned` (step 4a) by curve address to reconstruct token reserves at any eth reserves `e`: `t = k / (e + e0) - t0`.
- Single-recipient and multi-recipient fee configs use the same master-handler registration path.
- There is no `FeeSplitterCreated` event and no splitter initialization event in the active source path.
- ERC20 mint and OpenZeppelin `Initialized` events also appear during token clone initialization. For creator-vault tokens the initial mint is split: `TOTAL_SUPPLY - vaultAllocation` is minted to the launchpad and `vaultAllocation` is minted to the factory (which then funds the vaults in step 4b). For non-vault tokens the full supply is minted to the launchpad, unchanged.

### 1.2 With deployer buy (`msg.value > 0`)

After the common sequence above, the factory performs the buy and distribution:

1. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer=factory, ethAmount=msg.value, tokenAmount=tokensBought, ethFee`).
2. **`LivoFactory.BuyOnDeploy`** (`token, buyer=msg.sender, ethSpent, tokensBought, recipients, amounts`).

ERC20 `Transfer` events occur from launchpad to factory and then from factory to each supply-share recipient.

---

## 2. `buyTokensWithExactEth` — pre-graduation

The pre-graduation fee policy is read per-trade from the token (`ILivoToken.getLaunchpadFees`) and
capped by the launchpad. The LP (trading) fee is split treasury/creator by `treasuryShareBps`; the
optional tax goes 100% to the creator. The treasury share is pushed; the creator total (LP creator
share + tax) is routed through `LivoToken.accrueFees` into `LivoMasterFeeHandler`. The event
vocabulary mirrors the post-graduation `LivoSwapHook` for accounting parity.

When the buy does not graduate the token:

1. ERC20 transfer from `LivoLaunchpad` to buyer.
2. **`LivoLaunchpad.LpFeesAccrued`** (`token, creatorShare, treasuryShare`) — emitted whenever a fee is taken.
3. **`LivoLaunchpad.CreatorTaxesAccrued`** (`token, taxAmount`) — only when the tax is non-zero.
4. Creator total (LP creator share + tax), when non-zero, routed through `LivoToken.accrueFees` → `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) on a successful direct forward.
5. Treasury share sent via a native ETH call (no Livo event for the ETH transfer).
6. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount=msg.value, tokenAmount, ethFee`) — `ethFee` is the total (LP fee + tax).

A token with `treasuryShareBps = 100%` and no tax (the launchpad's legacy-equivalent default) has
`creatorShare == 0` and no tax, so steps 3–4 are skipped; its only addition vs. the legacy flow is
the `LpFeesAccrued` in step 2.

If the buy crosses the graduation threshold, append the relevant graduation sequence from §3 or §4.

---

## 3. `buyTokensWithExactEth` that triggers V2 graduation

The initial buy emits the pre-graduation buy sequence from §2, then graduation begins in `LivoLaunchpad._graduateToken`.

Livo event order:

1. The triggering buy first emits its full §2 sequence — ERC20 transfer to buyer, the fee events (**`LivoLaunchpad.LpFeesAccrued`**, optional **`CreatorTaxesAccrued`**, and the creator-share `CreatorFeesDeposited` when applicable), and **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`).
2. ERC20 transfer of the remaining launchpad token balance from `LivoLaunchpad` to `LivoGraduatorUniswapV2`.
3. **`LivoGraduator.CreatorGraduationFeeCollected`** (`token, amount=creatorCompensation`).
4. Creator compensation is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorCompensation`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) if the configured receiver is direct and the forward succeeds.
5. **`LivoGraduator.TreasuryGraduationFeeCollected`** (`token, amount=treasuryShare`).
6. **`LivoToken.Graduated`**.
7. External Uniswap V2 pair creation / liquidity / LP-token events may occur.
8. **`LivoGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`).
9. Optional **`LivoGraduatorUniswapV2.SweepedRemainingEth`** (`token, amount`) if triggerer compensation failed or residual ETH remains.
10. **`LivoLaunchpad.TokenGraduated`** (`token, ethCollected, tokensForGraduation`).

---

## 4. `buyTokensWithExactEth` that triggers V4 graduation

The initial buy emits the pre-graduation buy sequence from §2, then graduation begins in `LivoLaunchpad._graduateToken`.

Livo event order:

1. The triggering buy first emits its full §2 sequence — ERC20 transfer to buyer, the fee events (**`LivoLaunchpad.LpFeesAccrued`**, optional **`CreatorTaxesAccrued`**, and the creator-share `CreatorFeesDeposited` when applicable), and **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`).
2. ERC20 transfer of the remaining launchpad token balance from `LivoLaunchpad` to `LivoGraduatorUniswapV4`.
3. **`LivoGraduator.CreatorGraduationFeeCollected`** (`token, amount=creatorCompensation`).
4. Creator compensation is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorCompensation`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) if the configured receiver is direct and the forward succeeds.
5. **`LivoGraduator.TreasuryGraduationFeeCollected`** (`token, amount=treasuryShare`).
6. **`LivoToken.Graduated`**.
   - Tax tokens emit this same event from the override and also record `graduationTimestamp`.
7. External Uniswap V4 PoolManager / PositionManager / Permit2 events occur while liquidity positions are minted.
8. **`LivoGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`).
9. **`LivoLaunchpad.TokenGraduated`** (`token, ethCollected, tokensForGraduation`).

---

## 5. `sellExactTokens` — pre-graduation

When a token is not graduated yet, sells happen against launchpad reserves. As with buys, the fee
policy is read per-trade from the token: the LP fee is split treasury/creator, the tax goes 100% to
the creator. The treasury share is pushed and the creator total is routed through `accrueFees`.

The event order matches buys (§2) and the post-graduation `LivoSwapHook` (§6): the fee events come
first and the trade event closes the sequence.

Livo event order:

1. ERC20 transfer from seller to launchpad.
2. **`LivoLaunchpad.LpFeesAccrued`** (`token, creatorShare, treasuryShare`) — emitted whenever a fee is taken.
3. **`LivoLaunchpad.CreatorTaxesAccrued`** (`token, taxAmount`) — only when the tax is non-zero.
4. Creator total, when non-zero, via `LivoToken.accrueFees` → `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) on a successful direct forward.
5. **`LivoLaunchpad.LivoTokenSell`** (`token, seller, tokenAmount, ethAmount, ethFee`) — `ethFee` is the total (LP fee + tax).
6. Treasury share sent via native ETH call (no Livo event for the ETH transfer).
7. Seller receives ETH via native ETH call (no Livo event for the ETH transfer).

---

## 6. V4 post-graduation swaps

V4 swaps are mediated by `LivoSwapHook`. Swaps before graduation revert with `NoSwapsBeforeGraduation` and emit no Livo swap/fee events.

The hook reads the per-token fees via `LivoToken.getSwapFees(isBuy)` (LP fee + currently-effective tax for
that direction). The LP fee is forwarded whole to `LivoLpFeeRouter`, which splits it between treasury and
creator by a marketcap tier; the tax (if any) is forwarded to the token's master fee handler. The LP fee and
the tax are accrued in **separate** `accrueFees` calls, so the creator can see up to two
`CreatorFeesDeposited`.

### 6.1 Buy (`ETH -> token`)

The fee is withheld from the ETH leg (`beforeSwap` for exact-input, `afterSwap` for exact-output); the
routing and all events below are emitted in `afterSwap`.

Livo event order (LP fee `> 0`, buy tax active, router healthy):

1. **`LivoSwapHook.LpFeesForwarded`** (`token, amount`) — the whole LP fee handed to the router.
2. **`LivoLpFeeRouter.LpFeesRouted`** (`token, creatorShare, treasuryShare, liquidityShare=0`) — the tier split.
3. Treasury LP share is sent to the router's treasury via native ETH call (no event).
4. Creator LP share is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) per successful direct forward.
5. Optional **`LivoSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if buy tax is active and non-zero, then the
   tax is routed through `LivoToken.accrueFees()` (a second **`CreatorFeesDeposited`** / optional `CreatorClaimed`).
6. **`LivoSwapHook.LivoSwapBuy`** (`token, txOrigin, ethIn, tokensOut, ethFees`).

Router-failure fallback: if `LivoLpFeeRouter.depositLpFees` reverts, step 2 (`LpFeesRouted`) and step 4 are
absent — the hook instead pushes the **entire** LP fee to the protocol treasury via a native ETH call (no
event). Indexers detect the fallback by the presence of `LpFeesForwarded` without a matching `LpFeesRouted`.

### 6.2 Sell (`token -> ETH`)

The fee is taken from the ETH leg (`afterSwap` for exact-input, withheld in `beforeSwap` for exact-output);
the routing and all events below are emitted in `afterSwap`.

Livo event order (LP fee `> 0`, sell tax active, router healthy):

1. **`LivoSwapHook.LpFeesForwarded`** (`token, amount`) — the whole LP fee handed to the router.
2. **`LivoLpFeeRouter.LpFeesRouted`** (`token, creatorShare, treasuryShare, liquidityShare=0`) — the tier split.
3. Treasury LP share is sent to the router's treasury via native ETH call (no event).
4. Creator LP share is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) per successful direct forward.
5. Optional **`LivoSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if sell tax is active and non-zero, then the
   tax is routed through `LivoToken.accrueFees()` (a second **`CreatorFeesDeposited`** / optional `CreatorClaimed`).
6. **`LivoSwapHook.LivoSwapSell`** (`token, txOrigin, tokensIn, ethOut, ethFees`).

Router-failure fallback: same as §6.1 — `LpFeesRouted` + step 4 absent, full LP fee pushed to treasury.

### 6.3 V2 post-graduation swaps on tax variants

Tax tokens deployed on V2 (`LivoTaxableTokenUniV2`, `LivoTaxableTokenUniV2SniperProtected`) take taxes intrinsically inside `_update`. There is no V2 hook; the token contract diverts a portion of every pair-touching transfer into its own balance, then auto-swaps the accumulated tokens to ETH on a sell once the contract balance crosses `SWAP_THRESHOLD = TOTAL_SUPPLY / 2000` (= 500_000e18).

Indexer-relevant points:

- **Buy (ETH → token)** within the tax window emits an extra `Transfer(pair, address(token), buyTaxAmount)` for the tax slice in addition to `Transfer(pair, buyer, netAmount)`. No Livo event is emitted at this point — the tax accrual is reported later, at swap-back time.
- **Sell (token → ETH)** within the tax window emits an extra `Transfer(seller, address(token), sellTaxAmount)` for the tax slice in addition to `Transfer(seller, pair, netAmount)`. The auto-swap-back, if triggered, fires *before* the tax slice transfers, while `inSwap` is true. No Livo event is emitted at this point either; the accrual is reported by `CreatorTaxSwapback` from the auto-swap-back below.
- **Auto- or manual-triggered swap-back** burns the burn-allocation share as tokens in-place first, sets the liquidity-allocation share aside as tokens (kept on the contract, tracked by `liquidityPendingTokens` — no event), then runs `IUniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens` on the remainder, then routes the ETH through the earnings-allocation split. Livo event order:
  1. Burn allocation only (`burnBps > 0`): ERC20 `Transfer(address(token), address(0), burnAmount)` then **`LivoTaxableToken.CreatorTaxBurn`** (`ethSpent = 0, tokensBurned = burnAmount`) — the burn share removed from total supply *before* the swap. The shared two-field signature; `ethSpent` is 0 here because V2 burns in token-space with no ETH→token round trip.
  2. ERC20 transfer from `address(token)` to `pair` for the swap input (the remainder after the burn and liquidity shares).
  3. External Uniswap V2 `Sync` / `Swap` events on the pair, plus `Withdrawal` on WETH.
  4. **`LivoTaxableTokenUniV2.CreatorTaxSwapback`** (`tokenAmountIn, ethAmount, ethToFund`) — `tokenAmountIn` is the amount actually swapped (net of the burn and liquidity shares); `ethAmount` is this swap's ETH proceeds (a balance delta, matching the pair's `Swap`); `ethToFund` is the slice of the routed ETH that reaches the fee handler as creator fees (the full routed balance may exceed `ethAmount` when stray/refund ETH is swept in on top). `ethAmount` and `ethToFund` are equal for a token with no earnings allocation.
  5. Fund deposit of `ethToFund`: **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount = ethToFund`), plus optional **`CreatorClaimed`** per direct forward — always AFTER `CreatorTaxSwapback` (historical order preserved). The dividends bucket is accrue-only and emits nothing on this path — its slice is buffered as native (or, for a V2 self-token leg, set aside as TOKENS alongside the liquidity buffer) and converted out-of-band by `processDividends`. So a token still emits exactly one `CreatorFeesDeposited` (the liquidity slice, and any self-token dividend slice, were already set aside as tokens above, not carved from this ETH).
- The token's `swapBack(uint256 swapAmount, uint256 amountOutMinWei)` external function is owner/launchpad-owner gated and reverts `NotGraduated` before graduation; it produces the same event sequence as the auto-trigger. Factory-deployed V2 tokens are ownerless, so the launchpad owner is the only reachable manual caller.
- The token's **`processLiquidity(uint256 amountOutMinWei)`** external function (permissionless; reverts `NotGraduated` / `NothingToAdd` / `ProcessCooldown` when already run this block; processes at most `2 * SWAP_THRESHOLD` tokens per call, remainder stays buffered) turns the set-aside liquidity tokens into a locked LP position: under `inSwap` it sells half through `UniswapV2Venue.swapTaxToNative()`, then adds the retained half plus the proceeds through `UniswapV2Venue.supplyLiquidity()` and sends the LP to `0xdEaD`. The venue lib is import-swapped per chain, so ETH-family builds take the WETH `swapExactTokensForETHSupportingFeeOnTransferTokens` / `addLiquidityETH` path while ARC builds pair `<token, USDC-ERC20>` via `swapExactTokensForTokensSupportingFeeOnTransferTokens` / two-ERC20 `addLiquidity` — the emitted event sequence is the same either way. Emits the external V2 `Sync` / `Swap` / pair `Mint` / `Transfer` events, then **`LivoTaxableToken.LiquidityAdded`** (`ethIn, tokensAdded, liquidity`) — the shared event; here `liquidity` is the V2 LP tokens minted, and `ethIn` / `tokensAdded` are the router's ACTUAL deposited amounts (they match the pair's `Mint`), not the requested ones: V2 adds at whatever ratio the pool is at and the router refunds the excess side back to the token.
- Past the tax window (`block.timestamp > graduationTimestamp + taxDurationSeconds`), no tax transfer is taken and the swap-back path is not entered.

### 6.4 V4 earnings-allocation burn and liquidity buckets and their entry points

For a V4 token with a burn or liquidity allocation, the swap-time `CreatorTaxesAccrued` → `token.accrueFees` splits the tax on the ETH side: the burn slice is buffered in `burnPendingEth` and the liquidity slice in `liquidityPendingEth` (no event beyond the fund-wallet `CreatorFeesDeposited`), the rest routes to the fund wallets. Permissionless entry points then process each buffer:

- **`processBurn(uint256 minTokensOut)`** — buys back tokens with `burnPendingEth` via the universal router and burns them. Emits, in order: **`LivoTaxableTokenUniV4.BuyBackInitiated`** (`ethIn`) — a precursor marker emitted BEFORE the swap so indexers can classify the following hook `LivoSwapBuy` (which carries the keeper's `tx.origin`) as a protocol buy-back rather than a trade — then the external V4 buy-back swap events (`Swap`, plus the hook's own LP-fee/tax events since the buy-back is an ordinary swap), an ERC20 `Transfer(address(token), address(0), tokensBought)`, then **`LivoTaxableToken.CreatorTaxBurn`** (`ethSpent, tokensBurned`) — the same shared event V2 emits, with a non-zero `ethSpent` here since V4 does buy the tokens back before burning. Reverts `NothingToBurn` when the buffer is empty and `ProcessCooldown` when already run this block; spends at most `MAX_EARNINGS_PER_PROCESS` per call (remainder stays buffered).
- **`processLiquidity()`** — deposits `liquidityPendingEth` as a single-sided ETH position just below the current price (a bid wall) via the shared `LivoUniV4LiquidityAdder`. Emits the external V4 position-mint events (`ModifyLiquidity`, settlement `Transfer`s), then **`LivoTaxableToken.LiquidityAdded`** (`ethIn, tokensAdded, liquidity`) — the shared event; `tokensAdded` is always 0 (ETH-only wall) and `liquidity` is the V4 liquidity units minted. Reverts `NothingToAdd` when the buffer is empty and `ProcessCooldown` when already run this block; spends at most `MAX_EARNINGS_PER_PROCESS` per call (remainder stays buffered). The minted position NFT is held by the token (permanent depth).
- **`sweepStrayEth()`** — routes the token's ETH balance beyond `burnPendingEth` and `liquidityPendingEth` back through the earnings-allocation split (same events as an `accrueFees` split), so stray ETH becomes token earnings instead of being stuck.

---

## 7. `LivoMasterFeeHandler.claim(address[] tokens)`

Entry point for claimable fee recipients to withdraw accumulated ETH across any registered tokens.

For each token in `tokens` where `msg.sender` has a non-zero claimable balance:

1. **`LivoMasterFeeHandler.CreatorClaimed`** (`token, account=msg.sender, amount`).

After iterating all tokens, a single native ETH transfer pays the sum to `msg.sender`. If the sum is zero, no events are emitted and no ETH transfer is attempted.

Duplicate token entries do not double-pay because the first matching entry clears the caller's claimable balance for that token.

---

## 8. `LivoMasterFeeHandler.setShares(address token, FeeShare[] feeShares)`

Callable only by the master handler owner or the token's current non-zero owner. The token must already be registered.

Event order on a successful update:

1. Zero or more **`LivoMasterFeeHandler.DirectReceiverRemoved`** (`token, receiver`) — for addresses that were direct before the update and are no longer direct after it.
2. Zero or more **`LivoMasterFeeHandler.DirectReceiverRegistered`** (`token, receiver`) — for addresses that were not direct before the update and are direct after it.
3. **`LivoMasterFeeHandler.SharesUpdated`** (`token, recipients, sharesBps`).

A BPS-only rebalance with an unchanged direct set emits only `SharesUpdated`.

---

## 9. Direct-fee behavior

Direct fees are configured per token through `FeeShare.directFeesEnabled` at token creation or through `LivoMasterFeeHandler.setShares`.

For every successful non-zero `depositFees(token)` against a registered config:

1. **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
2. For each direct receiver with a non-zero slice:
   - If the ETH forward succeeds, **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, sliceAmount`) is emitted immediately.
   - If the ETH forward fails, no `CreatorClaimed` event is emitted for that slice; the slice is stored as pending and can later be recovered through `claim()`.
3. Claimable recipients do not emit per-deposit claim events; they accrue through the master handler accumulator and emit `CreatorClaimed` only when they call `claim()`.

Zero-value `depositFees(token)` calls are no-ops and emit no fee events, including for unregistered tokens.

---

## 10. `LivoTaxableToken.setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps)`

Owner-only entry point on both `LivoTaxableTokenUniV2` (and its sniper-protected variant) and `LivoTaxableTokenUniV4` (and its sniper-protected variant). Callable by the token owner OR `launchpad.owner()` — on factory-deployed tokens (`owner == address(0)`) only the launchpad-owner branch is reachable.

The function is decrease-only: `newBuyTaxBps` and `newSellTaxBps` must both be `<= ` their current values, otherwise the call reverts with `TaxBpsCanOnlyDecrease`. Equal values are accepted (no-op for that side). `taxDurationSeconds` and `graduationTimestamp` are untouched.

On success:

1. **`LivoTaxableToken.TaxBpsUpdated`** (`newBuyTaxBps, newSellTaxBps`) — emitted before the storage write. Old values can be reconstructed from the preceding `LivoTaxableTokenInitialized` event at creation time and the chain of any prior `TaxBpsUpdated` events.

---

## Holder dividends (out-of-band)

None of these fire on a trade. The dividend module accrues on the earnings path and does everything
else in separate, permissionless transactions, so an indexer sees them on their own.

**At graduation**, after `Graduated`: **`DividendRoundOpened`** (`roundId, totalShares`) — the first
round opens here rather than at creation, because at creation the launchpad holds the whole supply
and every bonding-curve buyer would look like a mid-round arrival worth zero. `totalShares` is the
AUTHORITATIVE opening denominator; a replica must seed from it and never compute its own.

**`processDividends(uint256[3] minOut)`** — permissionless, threshold-gated per leg:
1. Per leg frozen, in leg order: **`DividendRoundFunded`** (`roundId, asset, nativeIn, assetOut,
   totalShares`). Only legs over `DIVIDEND_THRESHOLD` freeze, and the set is derived, never
   caller-chosen. `totalShares` is the frozen denominator, snapshotted on the round's FIRST freeze
   and reused by any leg that freezes later in the same round.
2. V4 self-token leg only, immediately BEFORE its buy-back swap: **`DividendBuyBackInitiated`**
   (`ethIn`), followed by the pool's own `LivoSwapHook.LivoSwapBuy`. Same contract as
   `BuyBackInitiated`: the precursor must be classified as it arrives, so the keeper's PnL is not
   credited with a bag it never bought.

**`distributeDividends(address[])` / `claimRound()`** — one **`DividendPaid`**
(`roundId, holder, asset, amount`) per holder per frozen leg. A holder already paid this round, a
holder below the relative dust floor, and a failed native send all emit nothing.

**`finalizeRound()`** — **`DividendRoundFinalized`** (`roundId, residualRolled`) followed by
**`DividendRoundOpened`** for the next round, in that order.
