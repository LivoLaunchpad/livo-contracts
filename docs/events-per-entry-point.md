# Events per Entry Point

Reference for indexers, subgraphs, monitoring and auditing: which Livo events are emitted by each core user-facing entry point, in the order they occur on-chain.

## Scope and current fee-handler model

This document describes the active source tree after the legacy implementations were removed:

- `src/feeHandlers/LivoFeeHandler.sol` — removed from active source.
- `src/feeSplitters/LivoFeeSplitter.sol` — removed from active source.
- `ILivoFeeHandler` / `ILivoFeeSplitter` interfaces may remain for legacy deployed-contract interaction, but no active factory/token path deploys or imports those implementations.

All new tokens use the singleton `LivoMasterFeeHandler`.

Unified factories register fee config automatically during token creation:

`factory.createToken(...) -> _finalizeCreation(...) -> LivoToken.registerFees(...) -> LivoMasterFeeHandler.registerToken(...)`

`LivoMasterFeeHandler.registerToken` emits any initial direct-receiver events first, then `SharesUpdated`.

## Active event emitters covered here

- `LivoFactoryUniV2Unified` / `LivoFactoryUniV4Unified`
- `LivoLaunchpad`
- `LivoToken` / `LivoTaxableTokenUniV4` / `LivoTaxableTokenUniV2` / sniper-protected variants
- `LivoGraduatorUniswapV2` / `LivoGraduatorUniswapV4`
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

---

## 1. `createToken` — unified factory paths

Each unified factory exposes two `createToken` overloads with different selectors:
- **Legacy positional**: `(name, symbol, salt, feeReceivers, supplyShares, taxCfg, antiSniperCfg)` on V2 and the same plus `renounceOwnership_` on V4.
- **Struct-based**: `(TokenSetup, TaxConfigInit, [UniV4Configs,] SupplyShare[], AntiSniperConfigs)` — same data, regrouped to keep the ABI extensible without hitting stack-too-deep.

Both overloads share the same internal flow and emit the events listed below in the same order.

### 1.1 Common sequence

For both unified factories, the common Livo event order is:

1. **`LivoFactory.TokenCreated`** (`token, name, symbol, tokenOwner, launchpad, graduator, feeHandler=LivoMasterFeeHandler`) — emitted before token initialization so indexers see the token entity before initializer-side events. `LivoFactoryUniV2Unified` always emits `tokenOwner = address(0)`; `LivoFactoryUniV4Unified` emits `address(0)` only when ownership is renounced.
2. **Graduator initialization events**:
   - V2: **`LivoGraduator.PairInitialized`** (`token, pair`) — pair address is predicted; pair deployment can happen later at graduation.
   - V4: **`LivoGraduator.PairInitialized`** (`token, pair=PoolManager`) then **`LivoGraduatorUniswapV4.PoolIdRegistered`** (`token, poolId`).
3. Optional implementation-specific initializer events:
   - Tax token: **`LivoTaxableTokenInitialized`** (`buyTaxBps, sellTaxBps, taxDurationSeconds`).
   - Sniper-protected token: **`SniperProtectionInitialized`** (`maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, whitelist`).
4. **`LivoLaunchpad.TokenLaunched`** (`token, graduationThreshold, maxExcessOverThreshold`).
5. Initial fee config is registered through the token into `LivoMasterFeeHandler`:
   - Zero or more **`LivoMasterFeeHandler.DirectReceiverRegistered`** (`token, receiver`) — one per initial direct receiver.
   - **`LivoMasterFeeHandler.SharesUpdated`** (`token, recipients, sharesBps`).

Notes:

- Single-recipient and multi-recipient fee configs use the same master-handler registration path.
- There is no `FeeSplitterCreated` event and no splitter initialization event in the active source path.
- ERC20 mint and OpenZeppelin `Initialized` events also appear during token clone initialization.

### 1.2 With deployer buy (`msg.value > 0`)

After the common sequence above, the factory performs the buy and distribution:

1. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer=factory, ethAmount=msg.value, tokenAmount=tokensBought, ethFee`).
2. **`LivoFactory.BuyOnDeploy`** (`token, buyer=msg.sender, ethSpent, tokensBought, recipients, amounts`).

ERC20 `Transfer` events occur from launchpad to factory and then from factory to each supply-share recipient.

---

## 2. `buyTokensWithExactEth` — pre-graduation

When the buy does not graduate the token:

1. ERC20 transfer from `LivoLaunchpad` to buyer.
2. Treasury receives the buy fee via a native ETH call (no Livo event for the ETH transfer).
3. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount=msg.value, tokenAmount, ethFee`).

If the buy crosses the graduation threshold, append the relevant graduation sequence from §3 or §4.

---

## 3. `buyTokensWithExactEth` that triggers V2 graduation

The initial buy emits the pre-graduation buy sequence from §2, then graduation begins in `LivoLaunchpad._graduateToken`.

Livo event order:

1. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`) — from the triggering buy.
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

1. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`) — from the triggering buy.
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

When a token is not graduated yet, sells happen against launchpad reserves.

Livo event order:

1. **`LivoLaunchpad.LivoTokenSell`** (`token, seller, tokenAmount, ethAmount, ethFee`).
2. ERC20 transfer from seller to launchpad.
3. Treasury receives the sell fee via native ETH call (no Livo event for the ETH transfer).
4. Seller receives ETH via native ETH call (no Livo event for the ETH transfer).

---

## 6. V4 post-graduation swaps

V4 swaps are mediated by `LivoSwapHook`. Swaps before graduation revert with `NoSwapsBeforeGraduation` and emit no Livo swap/fee events.

### 6.1 Buy (`ETH -> token`)

Fees are taken in `beforeSwap`; the final trade event is emitted in `afterSwap`.

Livo event order:

1. **`LivoSwapHook.LpFeesAccrued`** (`token, creatorShare, treasuryShare`).
2. Optional **`LivoSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if buy tax is active and non-zero.
3. Creator LP share plus any buy tax is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare + taxAmount`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) for each successful direct forward.
4. Treasury LP share is sent directly via native ETH call.
5. **`LivoSwapHook.LivoSwapBuy`** (`token, txOrigin, ethIn, tokensOut, ethFees`).

### 6.2 Sell (`token -> ETH`)

Fees are computed and taken in `afterSwap`.

Livo event order:

1. **`LivoSwapHook.LpFeesAccrued`** (`token, creatorShare, treasuryShare`).
2. Optional **`LivoSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if sell tax is active and non-zero.
3. Creator LP share plus any sell tax is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare + taxAmount`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) for each successful direct forward.
4. Treasury LP share is sent directly via native ETH call.
5. **`LivoSwapHook.LivoSwapSell`** (`token, txOrigin, tokensIn, ethOut, ethFees`).

### 6.3 V2 post-graduation swaps on tax variants

Tax tokens deployed on V2 (`LivoTaxableTokenUniV2`, `LivoTaxableTokenUniV2SniperProtected`) take taxes intrinsically inside `_update`. There is no V2 hook; the token contract diverts a portion of every pair-touching transfer into its own balance, then auto-swaps the accumulated tokens to ETH on a sell once the contract balance crosses `SWAP_THRESHOLD = TOTAL_SUPPLY / 2000` (= 500_000e18).

Indexer-relevant points:

- **Buy (ETH → token)** within the tax window emits an extra `Transfer(pair, address(token), buyTaxAmount)` for the tax slice in addition to `Transfer(pair, buyer, netAmount)`. No Livo event is emitted at this point — the tax accrual is reported later, at swap-back time.
- **Sell (token → ETH)** within the tax window emits an extra `Transfer(seller, address(token), sellTaxAmount)` for the tax slice in addition to `Transfer(seller, pair, netAmount)`. The auto-swap-back, if triggered, fires *before* the tax slice transfers, while `inSwap` is true. No Livo event is emitted at this point either; the accrual is reported by `CreatorTaxSwapback` from the auto-swap-back below.
- **Auto- or manual-triggered swap-back** runs `IUniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens` against the pair and then routes proceeds to the master fee handler. Livo event order:
  1. ERC20 transfer from `address(token)` to `pair` for the swap input.
  2. External Uniswap V2 `Sync` / `Swap` events on the pair, plus `Withdrawal` on WETH.
  3. **`LivoTaxableTokenUniV2.CreatorTaxSwapback`** (`tokenAmountIn, ethAmount`) — emitted before fees are deposited. `ethAmount` is the ETH that will be routed through `feeHandler.depositFees`, i.e. the tax accrued to the creator (and any direct receivers) for the swap window covered by this back-swap.
  4. **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=ethAmount`) emitted by `depositFees`.
  5. Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) for each successful direct forward.
- The token's `swapBack(uint256 amountOutMinWei)` external function is owner-only and produces the same event sequence as the auto-trigger only if the token has a non-zero owner. Factory-deployed V2 tokens are ownerless, so this manual path is inaccessible there.
- Past the tax window (`block.timestamp > graduationTimestamp + taxDurationSeconds`), no tax transfer is taken and the `CreatorTaxSwapback` path is not entered.

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
