#!/usr/bin/env bash
# Sweep an RPC for Uniswap factory / PoolManager deployments.
#
# Scans for pool-creation events instead of Swap(): their emitter IS the contract
# we want (V2 factory, V3 factory, V4 PoolManager), so no extra hop is needed.
#
#   ./find-uniswap.sh <rpc-url> [fromBlock]
#
set -euo pipefail

STEP=10000 # ponytail: Arc RPCs cap eth_getLogs at a 10k block range
JOBS=8
TOPICS='["0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9","0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118","0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"]'

rpc() { curl -s --max-time 30 -X POST -H 'content-type: application/json' --data "$1" "$RPC"; }

# worker: re-entry point for one 10k chunk
if [[ ${1:-} == --chunk ]]; then
    RPC=$2
    from=$3
    to=$((from + STEP - 1 < $4 ? from + STEP - 1 : $4))
    rpc "$(printf '{"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{"fromBlock":"0x%x","toBlock":"0x%x","topics":[%s]}]}' "$from" "$to" "$TOPICS")" |
        jq -r '.result[]? |
      {a:.address, b:(.blockNumber|ltrimstr("0x")),
       v:(if   .topics[0]=="0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9" then "V2Factory"
          elif .topics[0]=="0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118" then "V3Factory"
          else "V4PoolManager" end)}
      | "\(.v)\t\(.a)\t\(.b)"'
    exit 0
fi

RPC=${1:?usage: find-uniswap.sh <rpc-url> [fromBlock]}
FROM=${2:-0}
latest=$((16#$(rpc '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' | jq -r .result | sed 's/^0x//')))
echo "scanning $FROM..$latest ($RPC)" >&2

seq "$FROM" "$STEP" "$latest" |
    xargs -P "$JOBS" -I{} bash "$0" --chunk "$RPC" {} "$latest" |
    sort -t$'\t' -k3,3n | awk -F'\t' '!seen[$1$2]++'
