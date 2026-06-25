#!/usr/bin/env python3
"""Derive ConstantProductBondingCurveConfigurable constants (K, T0, E0) for every
(liquidity tier x creator-vault allocation).

A creator-vault token locks `vault_bps` of the 1B supply in vesting vaults, so only
`S = TOTAL_SUPPLY * (10000 - vault_bps) / 10000` tokens are sold on the bonding curve.

Each LIQUIDITY TIER fixes its own graduation invariants (eth into liquidity, graduation
threshold and graduation marketcap), chosen so the marketcap scales 1:2:4 with the LP depth.
Within a tier, locking supply in vaults holds EVERY graduation invariant identical and relaxes
ONLY the starting market cap (it rises as more supply is locked) — same property the original
single-tier solver had.

Closed-form: the curve must pass through two points with a fixed slope at graduation:
  (1) t(0)        = S                              (token reserves at zero eth)
  (2) t(E_g)      = T_GRAD                          (token reserves at graduation)
  (3) dprice@E_g  = (E_g+E0)/(T_GRAD+T0) = P_grad   (spot price at graduation)
Three constraints, three unknowns (K, T0, E0) -> unique real solution per (tier, vault_bps).
We snap to the integer constants near it (deterministic: prefer the lowest T0 on ties) and
report residual errors.

Run:  uv run simulations/script/find_creator_vault_curve_params.py
      uv run simulations/script/find_creator_vault_curve_params.py --solidity   # emit constants
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from decimal import Decimal, getcontext

getcontext().prec = 120

WAD = 10**18
TOTAL_SUPPLY = 1_000_000_000 * WAD


@dataclass(frozen=True)
class Tier:
    """A liquidity tier: LP depth + its own graduation marketcap (proportional to depth)."""

    name: str
    lp_eth: Decimal  # eth deposited into liquidity at graduation
    grad_mcap: Decimal  # graduation marketcap in ETH (scales 1:2:4 with lp_eth)
    fee: Decimal = Decimal("0.25")  # flat graduation fee

    @property
    def E_G(self) -> int:  # eth reserves at graduation = lp + fee (= the graduation threshold)
        return int((self.lp_eth + self.fee) * WAD)

    @property
    def UNI_ETH(self) -> int:  # eth deposited into liquidity
        return int(self.lp_eth * WAD)

    @property
    def GRAD_MCAP_WEI(self) -> int:
        return int(self.grad_mcap * WAD)

    @property
    def T_GRAD(self) -> int:  # tokens left in reserves at graduation == tokens into liquidity
        return TOTAL_SUPPLY * self.UNI_ETH // self.GRAD_MCAP_WEI

    @property
    def P_GRAD(self) -> Decimal:  # graduation spot price (wei eth / wei token)
        return Decimal(self.UNI_ETH) / Decimal(self.T_GRAD)


# Tiers. DEFAULT reproduces the deployed single-tier system (12.25 ETH mcap). THIN/THICK scale
# the graduation marketcap 1:2:4 with the LP depth, which keeps the token split (28.57% into
# liquidity / 71.43% sold) and curve steepness identical across tiers.
TIERS = [
    Tier("THIN", Decimal("1.75"), Decimal("6.125")),
    Tier("DEFAULT", Decimal("3.5"), Decimal("12.25")),
    Tier("THICK", Decimal("7.0"), Decimal("24.5")),
]

BPS = [0, 500, 1000, 1500, 2000, 2500, 3000]

# The deployed base curve (DEFAULT tier, no vault). Used as the sanity anchor.
DEPLOYED_DEFAULT_BASE = (
    3515625000000000000000000000000000000000000000,
    250000000000000000000000000,
    2812500000000000000,
)


def reserves(k: int, t0: int, e0: int, e: int) -> int:
    return k // (e + e0) - t0


def closed_form(s: int, tier: Tier) -> tuple[Decimal, Decimal]:
    """Exact real-valued (E0, T0) for supply-in-curve `s`."""
    d = Decimal(s - tier.T_GRAD)
    pd = tier.P_GRAD * d
    t0 = (Decimal(tier.E_G) * Decimal(s) - pd * Decimal(tier.T_GRAD)) / (pd - Decimal(tier.E_G))
    e0 = tier.P_GRAD * (Decimal(tier.T_GRAD) + t0) - Decimal(tier.E_G)
    return e0, t0


def best_integer_curve(s: int, tier: Tier) -> dict:
    """Snap to integer constants near the closed-form solution; min composite error,
    deterministic lowest-T0 tie-break."""
    e0_star, _ = closed_form(s, tier)
    e0_center = int(e0_star.to_integral_value())

    best = None
    for e0 in range(e0_center - 200, e0_center + 201):
        if e0 <= 0:
            continue
        t0_real = Decimal(e0) * Decimal(s - tier.T_GRAD) / Decimal(tier.E_G) - Decimal(tier.T_GRAD)
        # ascending so ties resolve to the lowest valid T0 (reproducible across runs)
        for t0 in sorted({int(t0_real.to_integral_value()), int(t0_real // 1), int(t0_real // 1) + 1}):
            if t0 < 0:
                continue
            k = (s + t0) * e0
            t_at_zero = reserves(k, t0, e0, 0)
            t_at_grad = reserves(k, t0, e0, tier.E_G)
            if t_at_grad <= 0:
                continue
            zero_err = abs(t_at_zero - s)
            grad_err = abs(t_at_grad - tier.T_GRAD)
            price = Decimal((tier.E_G + e0)) / Decimal(t_at_grad + t0)
            price_dev = abs(price - tier.P_GRAD) / tier.P_GRAD
            score = Decimal(zero_err) / Decimal(s) + Decimal(grad_err) / Decimal(tier.T_GRAD) + price_dev
            cand = dict(
                k=k, t0=t0, e0=e0, t_at_zero=t_at_zero, t_at_grad=t_at_grad,
                zero_err=zero_err, grad_err=grad_err, price_dev=price_dev, score=score,
            )
            if best is None or cand["score"] < best["score"]:
                best = cand
    return best


def report() -> None:
    for tier in TIERS:
        thr = Decimal(tier.E_G) / WAD
        print(f"\n===== TIER {tier.name}  lp={tier.lp_eth} ETH  grad_mcap={tier.grad_mcap} ETH  threshold={thr} ETH =====")
        print(f"  T_GRAD = {tier.T_GRAD}  (tokens into liquidity, identical for every vault bps)")
        for bps in BPS:
            s = TOTAL_SUPPLY * (10_000 - bps) // 10_000
            c = best_integer_curve(s, tier)
            note = ""
            if tier.name == "DEFAULT" and bps == 0:
                note = "  [deployed base curve uses round K/T0/E0; this slot is NOT redeployed]"
            print(
                f"  bps={bps:4d}  K={c['k']} T0={c['t0']} E0={c['e0']}"
                f"  (zero_err={c['zero_err']}, grad_err={c['grad_err']}, dev={c['price_dev']*Decimal(100):.2e}%){note}"
            )


def _sol_name(tier: Tier, bps: int) -> str:
    prefix = "THIN" if tier.name == "THIN" else "THICK"
    return f"{prefix}_{bps // 100}"  # e.g. THIN_0, THIN_5, THICK_30 (bps/100 = percent)


def emit_solidity() -> None:
    """Emit the THIN/THICK constant declarations + dispatchers for CreatorVaultCurveConstants."""
    for tier in TIERS:
        if tier.name == "DEFAULT":
            continue
        print(f"    // ---- {tier.name} tier (lp {tier.lp_eth} ETH, grad mcap {tier.grad_mcap} ETH) ----")
        for bps in BPS:
            s = TOTAL_SUPPLY * (10_000 - bps) // 10_000
            c = best_integer_curve(s, tier)
            n = _sol_name(tier, bps)
            print(f"    uint256 internal constant K_{n} = {c['k']};")
            print(f"    uint256 internal constant T0_{n} = {c['t0']};")
            print(f"    uint256 internal constant E0_{n} = {c['e0']};")
        print()


def main() -> None:
    if "--solidity" in sys.argv:
        emit_solidity()
        return
    report()
    # default-tier sanity: the no-vault closed-form lands within 1 wei of the deployed round base
    c = best_integer_curve(TOTAL_SUPPLY, TIERS[1])
    if c["e0"] != DEPLOYED_DEFAULT_BASE[2]:
        print("\nWARNING: DEFAULT base E0 differs from deployed!", file=sys.stderr)


if __name__ == "__main__":
    main()
