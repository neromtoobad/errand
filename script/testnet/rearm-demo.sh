#!/usr/bin/env bash
# Sets the testnet demo up for the live page: the wallet lends LEND tUSD again, the borrower borrows every
# free coin so the market is 100% borrowed, DemoDeposit is deployed for visitors, and the wallet asks to exit.
# After this, each visitor deposit frees liquidity and ErrandMorpho withdraws it for the wallet.
export RECORD=deployments/testnet.json
source "$(dirname "$0")/../lib.sh"
BASE=${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org}
LEND=${LEND:-1000ether}
MORPHO=$(read_record base.morpho); LOAN=$(read_record base.loanToken); COLL=$(read_record base.collateralToken)
MID=$(read_record base.marketId)
PARAMS="($LOAN,$COLL,$(read_record base.oracle),0x0000000000000000000000000000000000000000,860000000000000000)"
MP="(address,address,address,address,uint256)"
send() { cast send "$@" -r "$BASE" --json | tx_of; }
num() { awk '{print $1}'; }

if ! python3 -c "import json,sys;sys.exit(0 if 'DemoDeposit' in json.load(open('$RECORD')).get('demo',{}) else 1)"; then
  OUT=$(forge create src/testnet/DemoDeposit.sol:DemoDeposit --broadcast --json -r "$BASE" --private-key "$KEY" \
    --constructor-args "$MORPHO" "$PARAMS")
  record demo.DemoDeposit "$(echo "$OUT" | addr_of)"; record demo.deployTx "$(echo "$OUT" | tx_of)"
  echo "DemoDeposit $(read_record demo.DemoDeposit)"
fi

send $LOAN "mint(address,uint256)" "$WALLET" "$LEND" --private-key "$KEY" >/dev/null
record demo.supplyTx "$(send $MORPHO "supply($MP,uint256,uint256,address,bytes)" "$PARAMS" "$LEND" 0 "$WALLET" 0x --private-key "$KEY")"
echo "wallet lent $LEND"

read -r SUPPLIED BORROWED < <(cast call $MORPHO "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)" "$MID" -r "$BASE" \
  | awk 'NR==1{s=$1} NR==3{print s, $1}')
FREE=$(python3 -c "print($SUPPLIED - $BORROWED)")
send $COLL "mint(address,uint256)" "$BORROWER_ADDRESS" 2000ether --private-key "$KEY" >/dev/null
send $MORPHO "supplyCollateral($MP,uint256,address,bytes)" "$PARAMS" 2000ether "$BORROWER_ADDRESS" 0x --private-key "$BORROWER_PRIVATE_KEY" >/dev/null
record demo.borrowTx "$(send $MORPHO "borrow($MP,uint256,uint256,address,address)" "$PARAMS" "$FREE" 0 \
  "$BORROWER_ADDRESS" "$BORROWER_ADDRESS" --private-key "$BORROWER_PRIVATE_KEY")"
echo "borrower took the $FREE wei that was free: market is 100% borrowed"

record demo.requestExitTx "$(send "$WALLET" "requestExit()" --private-key "$KEY")"
echo "wallet asked to exit; ErrandMorpho arms on Lasna"
cast call $MORPHO "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)" "$MID" -r "$BASE" \
  | awk 'NR==1{s=$1} NR==3{print "market: supplied", s, "| borrowed", $1}'
