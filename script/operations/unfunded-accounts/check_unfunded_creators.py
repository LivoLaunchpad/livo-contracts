# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "python-dotenv", "rich"]
# ///
"""Daily alert: fail if any Livo reward creator has pending ETH claims but a 0 ETH wallet.

Runs in CI via .github/workflows/check-unfunded-creators.yml. On match, exits 1 so
GitHub fires the standard workflow-failed email. Locally, runnable with
`uv run check_unfunded_creators.py` after exporting MAINNET_RPC_URL (or putting it
in a sibling .env file).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv
from rich.console import Console
from rich.table import Table

GRAPHQL_URL = "https://indexer.livo.trade/v1/graphql"
JSONRPC_BATCH_SIZE = 100
HTTP_TIMEOUT = 30

QUERY = """
query MyQuery {
  RewardsTokenCreator(
    where: {
      chainId: {_eq: "1"},
      accountedEth: {_gt: "0"},
      claimedEth: {_eq: "0"}
    }
  ) {
    accruedEth
    creator
  }
}
"""

console = Console(highlight=False)


def fetch_creators() -> list[dict]:
    resp = requests.post(GRAPHQL_URL, json={"query": QUERY}, timeout=HTTP_TIMEOUT)
    if resp.status_code != 200:
        raise RuntimeError(f"GraphQL HTTP {resp.status_code}: {resp.text}")
    payload = resp.json()
    if "errors" in payload:
        raise RuntimeError(f"GraphQL errors: {payload['errors']}")
    return payload["data"]["RewardsTokenCreator"]


def unique_creators(rows: list[dict]) -> dict[str, int]:
    """Return {lowercased address: total accruedEth in wei}."""
    totals: dict[str, int] = {}
    for row in rows:
        addr = row["creator"].lower()
        totals[addr] = totals.get(addr, 0) + int(row["accruedEth"])
    return totals


def get_balances(addresses: list[str], rpc_url: str) -> dict[str, int]:
    """Batched eth_getBalance. Returns {address: balance_wei}."""
    out: dict[str, int] = {}
    for start in range(0, len(addresses), JSONRPC_BATCH_SIZE):
        chunk = addresses[start : start + JSONRPC_BATCH_SIZE]
        batch = [
            {
                "jsonrpc": "2.0",
                "id": start + i,
                "method": "eth_getBalance",
                "params": [addr, "latest"],
            }
            for i, addr in enumerate(chunk)
        ]
        resp = requests.post(rpc_url, json=batch, timeout=HTTP_TIMEOUT)
        if resp.status_code != 200:
            raise RuntimeError(f"RPC HTTP {resp.status_code}: {resp.text}")
        results = resp.json()
        by_id = {r["id"]: r for r in results}
        for i, addr in enumerate(chunk):
            r = by_id[start + i]
            if "error" in r:
                raise RuntimeError(f"RPC error for {addr}: {r['error']}")
            out[addr] = int(r["result"], 16)
    return out


def main() -> int:
    load_dotenv(Path(__file__).resolve().parent / ".env")
    rpc_url = os.getenv("MAINNET_RPC_URL")
    if not rpc_url:
        console.print("[red]MAINNET_RPC_URL not set[/red]")
        return 2

    console.print("[dim]Querying Livo indexer…[/dim]")
    rows = fetch_creators()
    accrued_by_addr = unique_creators(rows)
    console.print(
        f"[dim]Indexer returned {len(rows)} rows → {len(accrued_by_addr)} unique creators.[/dim]"
    )

    addresses = list(accrued_by_addr.keys())
    console.print(f"[dim]Reading mainnet balances ({len(addresses)} wallets, batched)…[/dim]")
    balances = get_balances(addresses, rpc_url)

    unfunded = [
        (addr, balances[addr], accrued_by_addr[addr])
        for addr in addresses
        if balances[addr] == 0
    ]
    unfunded.sort(key=lambda x: x[2], reverse=True)

    if not unfunded:
        console.print("[green]OK: no unfunded creators with pending claims.[/green]")
        return 0

    table = Table(title=f"Unfunded creators (balance = 0 ETH): {len(unfunded)}")
    table.add_column("creator", style="cyan", no_wrap=True)
    table.add_column("balance (ETH)", justify="right")
    table.add_column("accrued (ETH)", justify="right", style="green")
    for addr, bal_wei, accrued_wei in unfunded:
        table.add_row(addr, f"{bal_wei / 1e18:.6f}", f"{accrued_wei / 1e18:.6f}")
    console.print(table)

    raise RuntimeError(
        f"{len(unfunded)} creator(s) have pending ETH claims but a 0 ETH balance — fund them or investigate."
    )


if __name__ == "__main__":
    sys.exit(main())
