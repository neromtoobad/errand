#!/usr/bin/env bash
# Step 2 of 2, on Ethereum:
#   a. deploy the wallet's ErrandWallet code, trusting the ErrandLido from step 1
#   b. the wallet signs an EIP-7702 authorization pointing at that code
#   c. optional: prepay callback fees to the proxy (FEE_RESERVE). With no reserve the proxy
#      charges the wallet's own balance through pay(), in the same transaction as the claim.
source "$(dirname "$0")/lib.sh"
MAX_FEE=${MAX_FEE:-1000000000000000}   # 0.001 ETH: most the proxy may collect per pay()
FEE_RESERVE=${FEE_RESERVE:-0}
FEES=$(eth_fee_flags)
ERRAND=$(read_record reactive.ErrandLido)

echo "Deploying ErrandWallet (trusts $ERRAND)…"
OUT=$(forge create src/ErrandWallet.sol:ErrandWallet --broadcast --json $FEES \
  --rpc-url "$ETH_RPC" --private-key "$KEY" \
  --constructor-args "$PROXY" "$ERRAND" "$QUEUE" "$MAX_FEE")
IMPL=$(echo "$OUT" | addr_of); IMPL_TX=$(echo "$OUT" | tx_of)
echo "   ErrandWallet $IMPL ($IMPL_TX)"
record ethereum.chainId 1
record ethereum.ErrandWallet "$IMPL"
record ethereum.deployTx "$IMPL_TX"
record ethereum.lidoQueue "$QUEUE"
record ethereum.callbackProxy "$PROXY"

echo "Delegating the wallet to it (EIP-7702)…"
AUTH_TX=$(cast send "$WALLET" --auth "$IMPL" --force $FEES --rpc-url "$ETH_RPC" --private-key "$KEY" --json | tx_of)
echo "   wallet code now $(cast code "$WALLET" -r "$ETH_RPC") ($AUTH_TX)"
record ethereum.delegationTx "$AUTH_TX"

if [ "$FEE_RESERVE" != "0" ]; then
  RESERVE_TX=$(cast send "$PROXY" "depositTo(address)" "$WALLET" --value "$FEE_RESERVE" $FEES \
    --rpc-url "$ETH_RPC" --private-key "$KEY" --json | tx_of)
  echo "   reserve tx $RESERVE_TX"
  record ethereum.feeReserveTx "$RESERVE_TX"
fi
echo "Saved $RECORD"
