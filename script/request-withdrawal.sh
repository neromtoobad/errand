#!/usr/bin/env bash
# Stakes a little ETH with Lido and asks to withdraw it, so the wallet has a request in the queue.
# This is the normal Lido flow; Errand is not involved until Lido finalizes the request.
#   ./script/request-withdrawal.sh 0.002ether
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
export PATH="$HOME/.foundry/bin:$PATH"

AMOUNT=${1:-0.002ether}
STETH=0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
QUEUE=0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
RPC=$ETHEREUM_RPC_URL
WEI=$(cast to-wei "${AMOUNT%ether}")

cast send $STETH "submit(address)" 0x0000000000000000000000000000000000000000 --value "$AMOUNT" \
  --rpc-url "$RPC" --private-key "$OWNER_PRIVATE_KEY" > /dev/null
BAL=$(cast call $STETH "balanceOf(address)(uint256)" "$OWNER_ADDRESS" -r "$RPC" | awk '{print $1}')
# stETH rounds down by a wei or two, so withdraw what the wallet actually holds (at most the amount staked).
REQ=$(( BAL < WEI ? BAL : WEI ))
cast send $STETH "approve(address,uint256)" $QUEUE "$REQ" --rpc-url "$RPC" --private-key "$OWNER_PRIVATE_KEY" > /dev/null
TX=$(cast send $QUEUE "requestWithdrawals(uint256[],address)" "[$REQ]" "$OWNER_ADDRESS" \
  --rpc-url "$RPC" --private-key "$OWNER_PRIVATE_KEY" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
ID=$(cast call $QUEUE "getLastRequestId()(uint256)" -r "$RPC" | awk '{print $1}')
echo "Requested withdrawal of $REQ wei stETH: tx $TX (latest request id $ID)"
