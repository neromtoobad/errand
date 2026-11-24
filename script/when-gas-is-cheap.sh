#!/usr/bin/env bash
# Waits until Ethereum's base fee is at or below MAX_BASE_GWEI, then does the Ethereum side in one go:
# deploys and delegates the wallet code (deploy-ethereum.sh), then stakes whatever ETH is left
# after a gas allowance and requests the withdrawal (request-withdrawal.sh).
# Built for a wallet with very little ETH: every transaction's max fee is capped at 2x the base fee seen.
source "$(dirname "$0")/lib.sh"
MAX_BASE_GWEI=${MAX_BASE_GWEI:-0.12}
POLL=${POLL:-60}
MARGIN=${MARGIN:-0.00005ether}   # kept back in the wallet toward the claim's callback fee

while :; do
  # A failed RPC read is not a reason to stop waiting: log it and try again next poll.
  BASE=$(cast base-fee -r "$ETH_RPC" 2>/dev/null) || { echo "$(date -u +%FT%TZ) RPC read failed, retrying"; sleep "$POLL"; continue; }
  GWEI=$(python3 -c "print(f'{$BASE/1e9:.3f}')")
  python3 -c "import sys; sys.exit(0 if $BASE <= $MAX_BASE_GWEI*1e9 else 1)" && break
  echo "$(date -u +%FT%TZ) base fee $GWEI gwei > $MAX_BASE_GWEI, waiting"
  sleep "$POLL"
done
export GAS_MAX_GWEI=$(python3 -c "print(f'{2*$BASE/1e9:.4f}')")
echo "$(date -u +%FT%TZ) base fee $GWEI gwei: going (max fee $GAS_MAX_GWEI gwei)"

if python3 -c "import json,sys; sys.exit(0 if 'delegationTx' in json.load(open('$RECORD')).get('ethereum',{}) else 1)"; then
  echo "Wallet code already deployed and delegated; skipping."
else
  ./script/deploy-ethereum.sh
fi

BAL=$(cast balance "$WALLET" -r "$ETH_RPC")
# stake + approve + request use ~380k gas; budget 500k at the max fee, plus the margin.
STAKE=$(python3 -c "print(int($BAL - 500_000*$GAS_MAX_GWEI*1e9 - $(cast to-wei ${MARGIN%ether})))")
echo "Wallet holds $BAL wei; staking $STAKE wei"
python3 -c "import sys; sys.exit(0 if $STAKE > 10**13 else 1)" || { echo "Too little left to stake."; exit 1; }
./script/request-withdrawal.sh "$(cast from-wei $STAKE)ether"
