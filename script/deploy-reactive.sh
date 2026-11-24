#!/usr/bin/env bash
# Step 1 of 2: deploy ErrandLido on Reactive Network for the wallet in .env.
# It subscribes to Lido's withdrawal queue on Ethereum and needs only REACT, no ETH.
source "$(dirname "$0")/lib.sh"
REACT_FUNDING=${REACT_FUNDING:-3ether}   # left in ErrandLido to pay for its reactive transactions

LAST_FINALIZED=$(cast call $QUEUE "getLastFinalizedRequestId()(uint256)" -r "$ETH_RPC" | awk '{print $1}')
echo "Lido last finalized request: $LAST_FINALIZED"
OUT=$(forge create src/ErrandLido.sol:ErrandLido --broadcast --json --legacy \
  --rpc-url "$RNK_RPC" --private-key "$KEY" --value "$REACT_FUNDING" \
  --constructor-args "$WALLET" 1 "$QUEUE" "$LAST_FINALIZED")
ERRAND=$(echo "$OUT" | addr_of); TX=$(echo "$OUT" | tx_of)
echo "ErrandLido $ERRAND ($TX)"
record wallet "$WALLET"
record reactive.chainId 1597
record reactive.ErrandLido "$ERRAND"
record reactive.deployTx "$TX"
record reactive.lastFinalizedAtSetup "$LAST_FINALIZED"
forge verify-contract --verifier sourcify --chain-id 1597 "$ERRAND" src/ErrandLido.sol:ErrandLido \
  || echo "Sourcify verification failed; retry later with the same command."
