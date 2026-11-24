#!/usr/bin/env bash
# Checks the README's onchain claims against the live chains. Needs only `cast` and python3; no keys, no .env.
#   ./tools/check-live.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
ETH=${ETHEREUM_RPC_URL:-https://ethereum-rpc.publicnode.com}
RNK=${REACTIVE_RPC_URL:-https://mainnet-rpc.rnk.dev/}
J=deployments/mainnet.json
get() { python3 -c "import json,sys;d=json.load(open('$J'))
try:
  for k in sys.argv[1].split('.'): d=d[k]
  print(d)
except KeyError: print('')" "$1"; }
pass=0; fail=0; pending=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $3, got $2)"; fail=$((fail+1)); fi; }
wait_() { echo "WAIT  $1"; pending=$((pending+1)); }
lc() { tr 'A-Z' 'a-z'; }

WALLET=$(get wallet); ERRAND=$(get reactive.ErrandLido); IMPL=$(get ethereum.ErrandWallet)

# Reactive Network side
check "ErrandLido has code on Reactive mainnet" "$([ "$(cast code "$ERRAND" -r "$RNK" | wc -c)" -gt 10 ] && echo yes)" yes
check "ErrandLido works for the recorded wallet" "$(cast call "$ERRAND" 'WALLET()(address)' -r "$RNK" | lc)" "$(echo "$WALLET" | lc)"
check "ErrandLido watches Lido's queue on Ethereum (chain 1)" "$(cast call "$ERRAND" 'CHAIN_ID()(uint256)' -r "$RNK")" 1
check "ErrandLido owes Reactive nothing (debt 0)" "$(cast call 0x8888888888888888888888888888888888888888 'debts(address)(uint256)' "$ERRAND" -r "$RNK")" 0
MATCH=$(curl -s "https://sourcify.dev/server/v2/contract/1597/$ERRAND" | python3 -c "import json,sys;print(json.load(sys.stdin).get('match',''))" 2>/dev/null)
check "ErrandLido source verified on Sourcify" "$MATCH" exact_match

# Ethereum side
if [ -z "$IMPL" ]; then
  wait_ "ErrandWallet not deployed yet (script/when-gas-is-cheap.sh waits for cheap gas)"
else
  check "Wallet is delegated to ErrandWallet (EIP-7702)" "$(cast code "$WALLET" -r "$ETH" | lc)" "$(echo "0xef0100${IMPL:2}" | lc)"
  check "ErrandWallet trusts only our ErrandLido" "$(cast call "$IMPL" 'ERRAND()(address)' -r "$ETH" | lc)" "$(echo "$ERRAND" | lc)"
  check "ErrandWallet accepts calls only from Reactive's callback proxy" "$(cast call "$IMPL" 'CALLBACK_PROXY()(address)' -r "$ETH" | lc)" "0xfce1f192f489c988392abc16e91e359d540d94fe"
fi
RID=$(get lido.requestId)
if [ -z "$RID" ]; then
  wait_ "No Lido withdrawal requested yet"
else
  S=$(cast call 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1 "getWithdrawalStatus(uint256[])((uint256,uint256,address,uint256,bool,bool)[])" "[$RID]" -r "$ETH" --json)
  read -r OWNER FIN CLAIMED < <(echo "$S" | python3 -c "import json,sys;r=json.load(sys.stdin)[0][0];print(r[2].lower(),r[4],r[5])")
  check "Lido request $RID belongs to the wallet" "$OWNER" "$(echo "$WALLET" | lc)"
  if [ "$CLAIMED" = "true" ]; then check "Lido request $RID claimed" yes yes
  elif [ "$FIN" = "true" ]; then echo "FAIL  Lido request $RID is finalized but not claimed"; fail=$((fail+1))
  else wait_ "Lido request $RID not finalized by Lido yet (Lido finalizes about daily)"; fi
fi
echo "---"; echo "$pass passed, $fail failed, $pending waiting"
[ "$fail" -eq 0 ]
