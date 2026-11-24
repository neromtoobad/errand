#!/usr/bin/env bash
# Every Second Counts setup, on testnets: Base Sepolia (Morpho Blue) + Reactive Lasna.
#   1. two test tokens + a fixed-price oracle, and a new Morpho Blue market for them   (Base Sepolia)
#   2. ErrandMorpho, watching that market and the wallet                               (Lasna)
#   3. ErrandMorphoWallet code, trusting that ErrandMorpho; the wallet delegates to it  (Base Sepolia, EIP-7702)
#   4. the wallet lends 100 tUSD; the borrower posts collateral and borrows all of it, so the market is 100% borrowed
# Every step is recorded in deployments/testnet.json and skipped if it is already there.
# The test tokens and the oracle are testnet stand-ins and say so in their source; Morpho Blue is the real deployment.
export RECORD=deployments/testnet.json
source "$(dirname "$0")/../lib.sh"
BASE=${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org}
LASNA=${LASNA_RPC_URL:-https://lasna-rpc.rnk.dev/}
MORPHO=0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb      # Morpho Blue, Base Sepolia
BASE_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585  # Reactive callback proxy, Base Sepolia
LLTV=860000000000000000
LEND=${LEND:-100ether}
REACT_FUNDING=${REACT_FUNDING:-0.8ether}
MAX_FEE=${MAX_FEE:-1000000000000000}   # 0.001 ETH: most the proxy may collect per pay()
[ -f "$RECORD" ] || echo '{}' > "$RECORD"
has() { python3 -c "import json,sys;d=json.load(open('$RECORD'))
for k in sys.argv[1].split('.'): d=d[k]" "$1" 2>/dev/null; }
send() { cast send "$@" -r "$BASE" --json | tx_of; }

record wallet "$WALLET"
record borrower "$BORROWER_ADDRESS"
record base.chainId 84532
record base.morpho "$MORPHO"
record base.callbackProxy "$BASE_PROXY"

# 1. tokens, oracle, market
for T in loanToken:"Test USD":tUSD collateralToken:"Test ETH":tETH; do
  IFS=: read -r KEYNAME NAME SYM <<<"$T"
  if ! has "base.$KEYNAME"; then
    A=$(forge create src/testnet/TestToken.sol:TestToken --broadcast --json -r "$BASE" --private-key "$KEY" \
      --constructor-args "$NAME" "$SYM" | addr_of)
    record "base.$KEYNAME" "$A"; echo "$SYM $A"
  fi
done
if ! has base.oracle; then
  A=$(forge create src/testnet/FixedPriceOracle.sol:FixedPriceOracle --broadcast --json -r "$BASE" --private-key "$KEY" | addr_of)
  record base.oracle "$A"; echo "oracle $A"
fi
PARAMS="($(read_record base.loanToken),$(read_record base.collateralToken),$(read_record base.oracle),0x0000000000000000000000000000000000000000,$LLTV)"
MARKET_ID=$(cast keccak "$(cast abi-encode 'f((address,address,address,address,uint256))' "$PARAMS")")
if ! has base.createMarketTx; then
  TX=$(send $MORPHO "createMarket((address,address,address,address,uint256))" "$PARAMS" --private-key "$KEY")
  record base.marketId "$MARKET_ID"; record base.createMarketTx "$TX"; echo "market $MARKET_ID ($TX)"
fi

# 2. ErrandMorpho on Lasna
if ! has reactive.ErrandMorpho; then
  OUT=$(forge create src/ErrandMorpho.sol:ErrandMorpho --broadcast --json --legacy -r "$LASNA" --private-key "$KEY" \
    --value "$REACT_FUNDING" --constructor-args "$WALLET" 84532 "$MORPHO" "$MARKET_ID")
  record reactive.chainId 5318007
  record reactive.ErrandMorpho "$(echo "$OUT" | addr_of)"
  record reactive.deployTx "$(echo "$OUT" | tx_of)"
  echo "ErrandMorpho $(read_record reactive.ErrandMorpho)"
  forge verify-contract --verifier sourcify --chain-id 5318007 "$(read_record reactive.ErrandMorpho)" \
    src/ErrandMorpho.sol:ErrandMorpho || echo "Sourcify verification failed; retry later."
fi
ERRAND=$(read_record reactive.ErrandMorpho)

# 3. wallet code + EIP-7702 delegation on Base Sepolia
if ! has base.delegationTx; then
  OUT=$(forge create src/ErrandMorphoWallet.sol:ErrandMorphoWallet --broadcast --json -r "$BASE" --private-key "$KEY" \
    --constructor-args "$BASE_PROXY" "$ERRAND" "$MORPHO" "$PARAMS" "$MAX_FEE")
  IMPL=$(echo "$OUT" | addr_of)
  record base.ErrandMorphoWallet "$IMPL"; record base.walletCodeTx "$(echo "$OUT" | tx_of)"
  record base.delegationTx "$(cast send "$WALLET" --auth "$IMPL" --force -r "$BASE" --private-key "$KEY" --json | tx_of)"
  echo "wallet code $(cast code "$WALLET" -r "$BASE")"
fi

# 4. lend, then borrow everything
LOAN=$(read_record base.loanToken); COLL=$(read_record base.collateralToken)
if ! has base.supplyTx; then
  send $LOAN "mint(address,uint256)" "$WALLET" "$LEND" --private-key "$KEY" >/dev/null
  send $LOAN "approve(address,uint256)" $MORPHO "$(cast max-uint)" --private-key "$KEY" >/dev/null
  record base.supplyTx "$(send $MORPHO "supply((address,address,address,address,uint256),uint256,uint256,address,bytes)" \
    "$PARAMS" "$LEND" 0 "$WALLET" 0x --private-key "$KEY")"
  echo "wallet lent $LEND"
fi
if ! has base.borrowTx; then
  [ "$(cast balance "$BORROWER_ADDRESS" -r "$BASE")" != "0" ] || \
    send "$BORROWER_ADDRESS" --value 0.001ether --private-key "$KEY" >/dev/null   # borrower's gas
  BK=$BORROWER_PRIVATE_KEY
  send $COLL "mint(address,uint256)" "$BORROWER_ADDRESS" 1000ether --private-key "$KEY" >/dev/null
  send $LOAN "mint(address,uint256)" "$BORROWER_ADDRESS" 1000ether --private-key "$KEY" >/dev/null   # to repay with
  send $COLL "approve(address,uint256)" $MORPHO "$(cast max-uint)" --private-key "$BK" >/dev/null
  send $LOAN "approve(address,uint256)" $MORPHO "$(cast max-uint)" --private-key "$BK" >/dev/null
  send $MORPHO "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)" \
    "$PARAMS" 1000ether "$BORROWER_ADDRESS" 0x --private-key "$BK" >/dev/null
  record base.borrowTx "$(send $MORPHO "borrow((address,address,address,address,uint256),uint256,uint256,address,address)" \
    "$PARAMS" "$LEND" 0 "$BORROWER_ADDRESS" "$BORROWER_ADDRESS" --private-key "$BK")"
  echo "borrower took $LEND: market is 100% borrowed"
fi
cast call $MORPHO "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)" "$MARKET_ID" -r "$BASE" \
  | awk 'NR==1{s=$1} NR==3{print "market: supplied", s, "| borrowed", $1}'
echo "Saved $RECORD"
