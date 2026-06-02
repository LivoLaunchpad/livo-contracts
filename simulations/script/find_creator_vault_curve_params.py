#!/usr/bin/env python3
"""Derive ConstantProductBondingCurve constants (K, T0, E0) for creator-vault tokens.

A creator-vault token locks `vault_bps` of the 1B supply in vesting vaults, so only
`S = TOTAL_SUPPLY * (10000 - vault_bps) / 10000` tokens are sold on the bonding curve.

We hold EVERY graduation invariant identical to the base curve and relax ONLY the
starting market cap / starting price:
  - eth reserves at graduation      (E_g)        -> identical
  - graduation fee                  (fee)        -> identical
  - tokens deposited into liquidity (T_GRAD)     -> identical
  - eth deposited into liquidity    (E_g - fee)  -> identical
  - graduation price / marketcap    (P_grad)     -> identical

Closed-form: the curve must pass through two points with a fixed slope at graduation:
  (1) t(0)        = S                       (token reserves at zero eth)
  (2) t(E_g)      = T_GRAD                   (token reserves at graduation)
  (3) dprice@E_g  = (E_g+E0)/(T_GRAD+T0) = P_grad   (spot price at graduation)
Three constraints, three unknowns (K, T0, E0) -> unique real solution per vault_bps.
We then snap E0 to the best nearby integer and report residual errors.

Run:  uv run script/find_creator_vault_curve_params.py
"""

from __future__ import annotations

from decimal import Decimal, getcontext

getcontext().prec = 120

WAD = 10**18
TOTAL_SUPPLY = 1_000_000_000 * WAD

# Base graduation invariants (identical to the deployed ConstantProductBondingCurve).
TARGET_ETH = Decimal("3.75")          # E_g : eth reserves at graduation
TARGET_FEE = Decimal("0.25")          # graduation fee
GRAD_MCAP = Decimal("12.25")          # graduation marketcap in ETH (back-solved from deployed curve)

E_G = int(TARGET_ETH * WAD)
UNI_ETH = int((TARGET_ETH - TARGET_FEE) * WAD)        # eth deposited into liquidity = 3.5
GRAD_MCAP_WEI = int(GRAD_MCAP * WAD)

# Tokens left in reserves at graduation == tokens deposited into liquidity.
# Same integer for every curve so "tokens into liquidity" is identical across all variants.
T_GRAD = TOTAL_SUPPLY * UNI_ETH // GRAD_MCAP_WEI       # = 2/7 * 1e27 (floored)

# Target graduation spot price (wei eth / wei token), exact rational.
P_GRAD = Decimal(UNI_ETH) / Decimal(T_GRAD)


def reserves(k: int, t0: int, e0: int, e: int) -> int:
    return k // (e + e0) - t0


def closed_form(s: int) -> tuple[Decimal, Decimal]:
    """Exact real-valued (E0, T0) for supply-in-curve `s`."""
    d = Decimal(s - T_GRAD)
    pd = P_GRAD * d
    t0 = (Decimal(E_G) * Decimal(s) - pd * Decimal(T_GRAD)) / (pd - Decimal(E_G))
    e0 = P_GRAD * (Decimal(T_GRAD) + t0) - Decimal(E_G)
    return e0, t0


def best_integer_curve(s: int) -> dict:
    """Snap to integer constants near the closed-form solution; pick min composite error."""
    e0_star, _ = closed_form(s)
    e0_center = int(e0_star.to_integral_value())

    best = None
    for e0 in range(e0_center - 200, e0_center + 201):
        if e0 <= 0:
            continue
        # T0 forced by requiring t(0)=S and t(E_g)=T_GRAD simultaneously:
        #   T0 = E0*(S - T_GRAD)/E_g - T_GRAD
        t0_real = Decimal(e0) * Decimal(s - T_GRAD) / Decimal(E_G) - Decimal(T_GRAD)
        for t0 in {int(t0_real.to_integral_value()), int(t0_real // 1), int(t0_real // 1) + 1}:
            if t0 < 0:
                continue
            k = (s + t0) * e0
            t_at_zero = reserves(k, t0, e0, 0)
            t_at_grad = reserves(k, t0, e0, E_G)
            if t_at_grad <= 0:
                continue
            zero_err = abs(t_at_zero - s)
            grad_err = abs(t_at_grad - T_GRAD)
            # spot price at graduation, and deviation vs target
            price = Decimal((E_G + e0)) / Decimal(t_at_grad + t0)
            price_dev = abs(price - P_GRAD) / P_GRAD
            score = (
                Decimal(zero_err) / Decimal(s)
                + Decimal(grad_err) / Decimal(T_GRAD)
                + price_dev
            )
            cand = dict(
                k=k, t0=t0, e0=e0, t_at_zero=t_at_zero, t_at_grad=t_at_grad,
                zero_err=zero_err, grad_err=grad_err, price_dev=price_dev, score=score,
            )
            if best is None or cand["score"] < best["score"]:
                best = cand
    return best


def report(vault_bps: int) -> None:
    s = TOTAL_SUPPLY * (10_000 - vault_bps) // 10_000
    c = best_integer_curve(s)
    k, t0, e0 = c["k"], c["t0"], c["e0"]

    start_price = Decimal(e0) / Decimal(s + t0)            # wei/wei at e=0
    start_mcap = start_price * Decimal(TOTAL_SUPPLY) / WAD  # ETH (vs full 1B supply)
    grad_price = Decimal(E_G + e0) / Decimal(c["t_at_grad"] + t0)
    grad_mcap = grad_price * Decimal(TOTAL_SUPPLY) / WAD
    eth_to_lp = Decimal(UNI_ETH) / WAD
    tokens_to_lp = Decimal(c["t_at_grad"]) / WAD
    sold = Decimal(s - c["t_at_grad"]) / WAD
    vault_tokens = Decimal(TOTAL_SUPPLY - s) / WAD

    print(f"\n===== vault = {vault_bps/100:.0f}%  (supply in curve = {Decimal(s)/WAD/1_000_000:.1f}M) =====")
    print(f"K  = {k}")
    print(f"T0 = {t0}")
    print(f"E0 = {e0}")
    print("  -- invariants (must match base curve) --")
    print(f"  eth reserves @ grad      : {TARGET_ETH} ETH")
    print(f"  eth into liquidity       : {eth_to_lp} ETH")
    print(f"  tokens into liquidity    : {tokens_to_lp/1_000_000:.6f}M   (target {Decimal(T_GRAD)/WAD/1_000_000:.6f}M, err {c['grad_err']} wei)")
    print(f"  graduation price (wei/wei): {grad_price:.30f}")
    print(f"  graduation mcap          : {grad_mcap:.6f} ETH")
    print("  -- relaxed (starting point) --")
    print(f"  vault tokens locked      : {vault_tokens/1_000_000:.1f}M")
    print(f"  tokens sold on curve     : {sold/1_000_000:.4f}M")
    print(f"  t(0) error vs S          : {c['zero_err']} wei")
    print(f"  starting price (wei/wei) : {start_price:.30f}")
    print(f"  starting mcap            : {start_mcap:.6f} ETH")
    print(f"  mcap multiplier g/s      : {grad_mcap/start_mcap:.4f}x")
    print(f"  price deviation @ grad   : {c['price_dev']*100:.12f}%")


def main() -> None:
    print("Base invariants held constant across ALL curves:")
    print(f"  E_g (eth @ grad)        = {TARGET_ETH} ETH")
    print(f"  fee                     = {TARGET_FEE} ETH")
    print(f"  eth into liquidity      = {Decimal(UNI_ETH)/WAD} ETH")
    print(f"  tokens into liquidity   = {Decimal(T_GRAD)/WAD/1_000_000:.6f}M  (T_GRAD={T_GRAD})")
    print(f"  graduation mcap         = {GRAD_MCAP} ETH")
    print(f"  graduation price        = {P_GRAD:.30f} wei/wei")
    print("\n(vault=0% is the sanity check: should reproduce deployed K/T0/E0)")
    print("  deployed: K=3515625000000000000000000000000000000000000000")
    print("            T0=250000000000000000000000000  E0=2812500000000000000")

    for bps in (0, 500, 1000, 1500, 2000, 2500, 3000):
        report(bps)


if __name__ == "__main__":
    main()
