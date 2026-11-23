#!/usr/bin/env bash
# Sets up Errand for one wallet on mainnet. Run from the repo root with a funded wallet in .env:
#   OWNER_ADDRESS / OWNER_PRIVATE_KEY  (ETH on Ethereum, REACT on Reactive Network)
# Steps:
#   1. Reactive Network: deploy ErrandLido for the wallet (subscribes to Lido's queue on Ethereum)
#   2. Ethereum: deploy the wallet's ErrandWallet code, trusting that ErrandLido
#   3. Ethereum: the wallet signs an EIP-7702 authorization pointing at that code
#   4. Ethereum: prepay callback fees to Reactive's callback proxy (reserves)
# Addresses and tx hashes are written to deployments/mainnet.json.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
export PATH="$HOME/.foundry/bin:$PATH"

QUEUE=0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1     # Lido WithdrawalQueueERC721
PROXY=0xFCE1F192F489c988392aBC16E91e359d540d94Fe     # Reactive Omni callback proxy, Ethereum
REACT_FUNDING=${REACT_FUNDING:-2ether}                # REACT left in ErrandLido for reactive tx fees
FEE_RESERVE=${FEE_RESERVE:-0.001ether}                # ETH prepaid to the proxy for callback fees
MAX_FEE=${MAX_FEE:-1000000000000000}                  # 0.001 ETH: most the proxy may collect per pay()

ETH_RPC=$ETHEREUM_RPC_URL
RNK_RPC=$REACTIVE_RPC_URL
KEY=$OWNER_PRIVATE_KEY
WALLET=$OWNER_ADDRESS
mkdir -p deployments

tx_of() { python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])"; }
addr_of() { python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])"; }

LAST_FINALIZED=$(cast call $QUEUE "getLastFinalizedRequestId()(uint256)" -r "$ETH_RPC" | awk '{print $1}')
echo "Lido last finalized request: $LAST_FINALIZED"

echo "1/4 Deploying ErrandLido on Reactive Network…"
OUT=$(forge create src/ErrandLido.sol:ErrandLido --broadcast --json \
  --rpc-url "$RNK_RPC" --private-key "$KEY" --value "$REACT_FUNDING" \
  --verify --verifier sourcify \
  --constructor-args "$WALLET" 1 "$QUEUE" "$LAST_FINALIZED")
ERRAND=$(echo "$OUT" | addr_of); ERRAND_TX=$(echo "$OUT" | tx_of)
echo "   ErrandLido $ERRAND ($ERRAND_TX)"

echo "2/4 Deploying ErrandWallet code on Ethereum…"
OUT=$(forge create src/ErrandWallet.sol:ErrandWallet --broadcast --json \
  --rpc-url "$ETH_RPC" --private-key "$KEY" \
  --constructor-args "$PROXY" "$ERRAND" "$QUEUE" "$MAX_FEE")
IMPL=$(echo "$OUT" | addr_of); IMPL_TX=$(echo "$OUT" | tx_of)
echo "   ErrandWallet $IMPL ($IMPL_TX)"

echo "3/4 Delegating the wallet to it (EIP-7702)…"
AUTH_TX=$(cast send "$WALLET" --auth "$IMPL" --force --rpc-url "$ETH_RPC" --private-key "$KEY" --json | tx_of)
CODE=$(cast code "$WALLET" -r "$ETH_RPC")
echo "   wallet code now $CODE ($AUTH_TX)"

echo "4/4 Prepaying callback fees…"
RESERVE_TX=$(cast send "$PROXY" "depositTo(address)" "$WALLET" --value "$FEE_RESERVE" \
  --rpc-url "$ETH_RPC" --private-key "$KEY" --json | tx_of)
echo "   reserve tx $RESERVE_TX"

cat > deployments/mainnet.json <<JSON
{
  "wallet": "$WALLET",
  "reactive": { "chainId": 1597, "ErrandLido": "$ERRAND", "deployTx": "$ERRAND_TX" },
  "ethereum": {
    "chainId": 1,
    "ErrandWallet": "$IMPL", "deployTx": "$IMPL_TX",
    "delegationTx": "$AUTH_TX",
    "feeReserveTx": "$RESERVE_TX",
    "lidoQueue": "$QUEUE", "callbackProxy": "$PROXY"
  },
  "lastFinalizedAtSetup": $LAST_FINALIZED
}
JSON
echo "Saved deployments/mainnet.json"
