#!/usr/bin/env bash
# Stakes a little ETH with Lido and asks to withdraw it, so the wallet has a request in the queue.
# This is the normal Lido flow; Errand is not involved until Lido finalizes the request.
#   ./script/request-withdrawal.sh 0.0002ether
source "$(dirname "$0")/lib.sh"
AMOUNT=${1:-0.0002ether}
FEES=$(eth_fee_flags)
WEI=$(cast to-wei "${AMOUNT%ether}")

STAKE_TX=$(cast send $STETH "submit(address)" 0x0000000000000000000000000000000000000000 --value "$WEI" $FEES \
  --rpc-url "$ETH_RPC" --private-key "$KEY" --json | tx_of)
BAL=$(cast call $STETH "balanceOf(address)(uint256)" "$WALLET" -r "$ETH_RPC" | awk '{print $1}')
# stETH rounds down by a wei or two, so withdraw what the wallet actually holds (at most the amount staked).
REQ=$(python3 -c "print(min($BAL, $WEI))")
cast send $STETH "approve(address,uint256)" $QUEUE "$REQ" $FEES --rpc-url "$ETH_RPC" --private-key "$KEY" > /dev/null
TX=$(cast send $QUEUE "requestWithdrawals(uint256[],address)" "[$REQ]" "$WALLET" $FEES \
  --rpc-url "$ETH_RPC" --private-key "$KEY" --json | tx_of)
# Our request id is the NFT minted to the wallet in this transaction (Transfer from 0x0).
ID=$(cast receipt "$TX" --json -r "$ETH_RPC" | python3 -c "
import json,sys
TRANSFER='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
for l in json.load(sys.stdin)['logs']:
    t=l['topics']
    if l['address'].lower()=='$QUEUE'.lower() and t[0]==TRANSFER and len(t)==4 and int(t[1],16)==0:
        print(int(t[3],16))")
echo "Staked ($STAKE_TX) and requested withdrawal of $REQ wei stETH: tx $TX, request id $ID"
record "lido.requestId" "$ID"
record "lido.stakeTx" "$STAKE_TX"
record "lido.requestTx" "$TX"
record "lido.amountWei" "$REQ"
