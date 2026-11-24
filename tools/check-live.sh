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

# Every Second Counts (testnets): Base Sepolia + Reactive Lasna
T=deployments/testnet.json
BASE=${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org}
LASNA=${LASNA_RPC_URL:-https://lasna-rpc.rnk.dev/}
TW=$(J=$T; get wallet); TE=$(J=$T; get reactive.ErrandMorpho); TI=$(J=$T; get base.ErrandMorphoWallet); MID=$(J=$T; get base.marketId)
J=$T
check "ErrandMorpho has code on Lasna" "$([ "$(cast code "$TE" -r "$LASNA" | wc -c)" -gt 10 ] && echo yes)" yes
check "ErrandMorpho watches the recorded market on Base Sepolia (84532)" "$(cast call "$TE" 'MARKET_ID()(bytes32)' -r "$LASNA")/$(cast call "$TE" 'CHAIN_ID()(uint256)' -r "$LASNA" | awk '{print $1}')" "$MID/84532"
check "Wallet is delegated to ErrandMorphoWallet on Base Sepolia (EIP-7702)" "$(cast code "$TW" -r "$BASE" | lc)" "$(echo "0xef0100${TI:2}" | lc)"
check "ErrandMorphoWallet trusts only our ErrandMorpho" "$(cast call "$TI" 'ERRAND()(address)' -r "$BASE" | lc)" "$(echo "$TE" | lc)"
check "The market is real Morpho Blue state (created, lltv 0.86)" "$(cast call 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb 'idToMarketParams(bytes32)(address,address,address,address,uint256)' "$MID" -r "$BASE" | tail -1 | awk '{print $1}')" 860000000000000000
RACE=$(ls evidence/race-*.json 2>/dev/null | tail -1)
if [ -n "$RACE" ]; then
  SHARES=$(cast call 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb 'position(bytes32,address)(uint256,uint128,uint128)' "$MID" "$TW" -r "$BASE" | head -1 | awk '{print $1}')
  check "After the race ($RACE) the wallet is fully out of the market" "$SHARES" 0
  check "Errand stood down once the wallet was out (armed = false)" "$(cast call "$TE" 'armed()(bool)' -r "$LASNA")" false
  for TX in $(python3 -c "import json;[print(r['callback']['tx']) for r in json.load(open('$RACE'))['rounds']]"); do
    S=$(cast receipt "$TX" status -r "$BASE" 2>/dev/null | awk '{print $1}'); [ "$S" = 1 ] && S=true
    check "Callback $TX succeeded on Base Sepolia" "$S" true
  done
fi

echo "---"; echo "$pass passed, $fail failed, $pending waiting"
[ "$fail" -eq 0 ]
