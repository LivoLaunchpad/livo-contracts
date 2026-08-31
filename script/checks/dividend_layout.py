#!/usr/bin/env python3
"""Fails if a taxable token and its dividend extension disagree on storage layout.

The extension is `delegatecall`ed with the token's storage, so every slot it writes has to be the
slot the token reads. Both sides derive their layout from a shared venue base and neither adds
state, so they cannot drift by accident - but "cannot" is worth checking, because the failure mode
is a live clone writing round state over its tax config, with no migration from it.
"""

import json
import os
import subprocess
import sys

PAIRS = [
    ("LivoTaxableTokenUniV2", "LivoDividendLogicUniV2"),
    ("LivoTaxableTokenUniV4", "LivoDividendLogicUniV4"),
]


def layout(contract):
    out = subprocess.run(
        ["forge", "inspect", contract, "storage", "--json"],
        capture_output=True, text=True, check=True,
        # The default profile does not emit storage layouts; `layout` does, into its own `out` dir.
        env={**os.environ, "FOUNDRY_PROFILE": "layout"},
    ).stdout
    entries = json.loads(out)["storage"]
    # `contract` and `astId` name where a variable was declared, which legitimately differs.
    return [(e["label"], e["slot"], e["offset"], e["type"]) for e in entries]


def main():
    failed = False
    for token, extension in PAIRS:
        a, b = layout(token), layout(extension)
        if a == b:
            print(f"ok   {token} == {extension}  ({len(a)} slots)")
            continue
        failed = True
        print(f"FAIL {token} != {extension}")
        for i in range(max(len(a), len(b))):
            x = a[i] if i < len(a) else None
            y = b[i] if i < len(b) else None
            if x != y:
                print(f"       {token}: {x}\n       {extension}: {y}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
