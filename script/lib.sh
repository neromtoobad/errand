# Shared helpers for the mainnet scripts. Sourced, not run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source .env
export PATH="$HOME/.foundry/bin:$PATH"

QUEUE=0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1   # Lido WithdrawalQueueERC721, Ethereum
STETH=0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84   # Lido stETH, Ethereum
PROXY=0xFCE1F192F489c988392aBC16E91e359d540d94Fe   # Reactive Omni callback proxy, Ethereum
ETH_RPC=${ETH_RPC:-$ETHEREUM_RPC_URL}
RNK_RPC=${RNK_RPC:-$REACTIVE_RPC_URL}
KEY=$OWNER_PRIVATE_KEY
WALLET=$OWNER_ADDRESS
RECORD=${RECORD:-deployments/mainnet.json}

tx_of() { python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])"; }
addr_of() { python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])"; }

# record <dotted.key> <value>: merges one value into deployments/mainnet.json
record() {
  python3 - "$RECORD" "$1" "$2" <<'PY'
import json, os, sys
path, key, value = sys.argv[1:]
data = json.load(open(path)) if os.path.exists(path) else {}
node = data
*parents, leaf = key.split(".")
for p in parents:
    node = node.setdefault(p, {})
node[leaf] = int(value) if value.isdigit() else value
json.dump(data, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
}

# read_record <dotted.key>
read_record() {
  python3 -c "import json,sys;d=json.load(open('$RECORD'))
for k in sys.argv[1].split('.'): d=d[k]
print(d)" "$1"
}

# Ethereum fee flags: GAS_MAX_GWEI caps the max fee per gas, the tip stays tiny.
eth_fee_flags() {
  echo "--gas-price $(cast to-wei "${GAS_MAX_GWEI:-1}" gwei) --priority-gas-price $(cast to-wei "${GAS_TIP_GWEI:-0.005}" gwei)"
}
