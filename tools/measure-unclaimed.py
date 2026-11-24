#!/usr/bin/env python3
"""How much Lido withdrawal ETH sits finalized but unclaimed, and for how long.

Reads only public state of Lido's WithdrawalQueueERC721 on Ethereum mainnet through `cast`:
  - getLockedEtherAmount(): ETH Lido has set aside for finalized requests nobody has claimed yet
  - getWithdrawalStatus(ids) for the last N finalized requests: which are still unclaimed, and since when
Usage: python3 tools/measure-unclaimed.py [N=2000]   (ETHEREUM_RPC_URL overrides the public RPC)
"""
import json, os, statistics, subprocess, sys, time

RPC = os.environ.get("ETHEREUM_RPC_URL", "https://ethereum-rpc.publicnode.com")
QUEUE = "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
STATUS = "getWithdrawalStatus(uint256[])((uint256,uint256,address,uint256,bool,bool)[])"

def call(sig, *args):
    out = subprocess.run(["cast", "call", QUEUE, sig, *args, "-r", RPC, "--json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)

def num(x):
    return int(str(x).split()[0])

locked = num(call("getLockedEtherAmount()(uint256)")[0])
last = num(call("getLastFinalizedRequestId()(uint256)")[0])
block = json.loads(subprocess.run(["cast", "block", "latest", "--json", "-r", RPC],
                                  capture_output=True, text=True, check=True).stdout)
block = block.get("data", block)  # newer cast wraps the block in {"data": ...}
now = int(str(block["timestamp"]), 0)

unclaimed = []
for start in range(last - N + 1, last + 1, 200):
    ids = list(range(start, min(start + 200, last + 1)))
    rows = call(STATUS, "[" + ",".join(map(str, ids)) + "]")[0]
    for rid, row in zip(ids, rows):
        steth, _, owner, ts, finalized, claimed = row
        if finalized and not claimed:
            unclaimed.append((rid, num(steth), num(ts)))

ages = [(now - ts) / 86400 for _, _, ts in unclaimed]
result = {
    "measuredAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
    "block": int(str(block["number"]), 0),
    "lockedEtherForUnclaimedRequests": locked / 1e18,
    "lastFinalizedRequestId": last,
    "window": [last - N + 1, last],
    "unclaimedInWindow": len(unclaimed),
    "unclaimedStEthInWindow": sum(s for _, s, _ in unclaimed) / 1e18,
    "medianDaysSinceRequest": round(statistics.median(ages), 1) if ages else None,
    "oldestDaysSinceRequest": round(max(ages), 1) if ages else None,
}
print(json.dumps(result, indent=2))
