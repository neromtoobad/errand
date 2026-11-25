#!/usr/bin/env python3
"""Every Second Counts: more rounds against the live demo, then latency stats over every round so far.

The demo (script/testnet/rearm-demo.sh) leaves the lender's wallet armed in a 100%-borrowed market. Each round
frees 10 tUSD, and Errand's callback withdraws it for the wallet. Rounds alternate between the two ways money
gets freed:
  odd rounds   a deposit through DemoDeposit, the same contract the live page's button calls
  even rounds  the borrower repays 10 tUSD
Both are sent from our test borrower key. Each round is timed from the chains (see tools/race.py).

It then rebuilds the full list of rounds: the scripted race (evidence/race-2026-11-24.json), the rounds run
after the demo was re-armed (found onchain from their trigger txs), and the new ones, and reports min, median,
p95 and max in Base blocks and in block-timestamp seconds.
Writes evidence/rounds-<UTC date>.json.   Usage: python3 tools/rounds.py [N=20] [GAP seconds=8]
"""
import json, sys, time
from datetime import datetime, timezone

import race
from race import B, BASE, D, ENV, LASNA, MORPHO, MP, PARAMS, WALLET, block, cast, iso, rpc, run_round


# Lasna's RPC caches eth_getLogs by request body, so an open-ended query can keep returning a stale answer.
# Always name the current head as toBlock.
def logs(url, address, topic0, from_block, to_block=None):
    head, _ = block(url)
    to = head if to_block is None else min(head, to_block)
    return rpc(url, "eth_getLogs", {"address": address, "topics": [topic0], "fromBlock": hex(from_block),
                                    "toBlock": hex(to)})


race.logs = logs

# Rounds run after the race, while the demo served the live page (trigger txs; the rest is read from the chain).
EARLIER = [
    ("exit request (demo re-armed)", D["demo"]["requestExitTx"]),
    ("deposit 10 (page followed it)", "0x0c6507b5c512c57f6b56ca7504b331bda43c2be03a9ae0aed9f616165873e6c2"),
    ("deposit 10 (demo video, from the page)", "0x21355fc5b20643b691bbc830ab67221f7e1b52c3cd6aedcd65778aa5c0685563"),
]


def measure_existing(label, tx):
    """Times a past round: the trigger's block, then the wallet's first ExitProgress at or after it."""
    rc = rpc(BASE, "eth_getTransactionReceipt", tx)
    b0 = int(rc["blockNumber"], 16)
    _, ts0 = block(BASE, rc["blockNumber"])
    # the callback lands within seconds; a bounded range keeps public RPCs happy
    prog = [l for l in logs(BASE, WALLET, race.T_PROGRESS, b0, b0 + 150) if l["topics"][1] == B["marketId"]]
    p = prog[0]
    b1 = int(p["blockNumber"], 16)
    _, ts1 = block(BASE, p["blockNumber"])
    return {"round": label, "trigger": {"tx": tx, "block": b0, "timestamp": ts0},
            "callback": {"tx": p["transactionHash"], "block": b1, "timestamp": ts1,
                         "withdrawnWei": int(p["data"][2:66], 16)},
            "baseBlocks": b1 - b0, "chainSeconds": ts1 - ts0}


def pct(xs, q):
    """Nearest-rank percentile."""
    xs = sorted(xs)
    return xs[max(0, min(len(xs) - 1, -(-len(xs) * q // 100) - 1))]


def stats(xs):
    xs = sorted(xs)
    return {"n": len(xs), "min": xs[0], "median": pct(xs, 50), "p95": pct(xs, 95), "max": xs[-1]}


def chunked_logs(url, flt, b_from, b_to, step=190):  # sepolia.base.org caps eth_getLogs at 200 blocks
    out = []
    for a in range(b_from, b_to + 1, step):
        out += rpc(url, "eth_getLogs", flt | {"fromBlock": hex(a), "toBlock": hex(min(b_to, a + step - 1))})
    return out


def rebuild(b_from, b_to, wall_log=None):
    """Rebuilds rounds from the chain alone: every Supply/Repay in our market between two Base blocks, Errand's
    ErrandSent on Lasna that names it, and the wallet's next ExitProgress. Used when a run's file wasn't saved."""
    sup, rep = cast("keccak", f"Supply(bytes32,address,address,uint256,uint256)"), cast("keccak", "Repay(bytes32,address,address,uint256,uint256)")
    trig = chunked_logs(BASE, {"address": MORPHO, "topics": [[sup, rep], B["marketId"]]}, b_from, b_to)
    trig = [l for l in trig if int(l["topics"][2 if l["topics"][0] == sup else 3][-40:], 16) != int(WALLET, 16)]
    lhead, _ = block(LASNA)
    sent = rpc(LASNA, "eth_getLogs", {"address": race.ERRAND, "topics": [race.T_SENT],
                                      "fromBlock": hex(lhead - 29000), "toBlock": hex(lhead)})
    by_trigger = {int(l["data"][:66], 16): l for l in sent}
    prog = chunked_logs(BASE, {"address": WALLET, "topics": [race.T_PROGRESS, B["marketId"]]}, b_from, b_to + 150)
    wall = {}
    if wall_log:
        import re
        for line in open(wall_log):
            m = re.search(r"trigger blk (\d+) .* ([\d.]+)s wall", line)
            if m: wall[int(m.group(1))] = float(m.group(2))
    rounds = []
    for i, t in enumerate(trig, 1):
        tx, b0 = t["transactionHash"], int(t["blockNumber"], 16)
        _, ts0 = block(BASE, t["blockNumber"])
        s_ = by_trigger[int(tx, 16)]
        _, rts = block(LASNA, s_["blockNumber"])
        p = next(l for l in prog if int(l["blockNumber"], 16) >= b0)
        b1 = int(p["blockNumber"], 16)
        _, ts1 = block(BASE, p["blockNumber"])
        cb = rpc(BASE, "eth_getTransactionReceipt", p["transactionHash"])
        fee = sum(int(l["data"], 16) for l in cb["logs"] if l["address"].lower() == WALLET.lower() and l["topics"][0] == race.T_FEE)
        kind = "deposit 10 (DemoDeposit)" if t["topics"][0] == sup else "repay 10"
        r = {"round": f"{i} {kind}", "trigger": {"tx": tx, "block": b0, "timestamp": ts0},
             "reactive": {"tx": s_["transactionHash"], "block": int(s_["blockNumber"], 16), "timestamp": rts},
             "callback": {"tx": p["transactionHash"], "block": b1, "timestamp": ts1,
                          "withdrawnWei": int(p["data"][2:66], 16), "remainingShares": int(p["data"][66:130], 16),
                          "feePaidWei": fee, "gasUsed": int(cb["gasUsed"], 16)},
             "baseBlocks": b1 - b0, "chainSeconds": ts1 - ts0}
        if b0 in wall:
            r["wallClock"] = {"triggerSeenToCallbackSeenSec": wall[b0], "source": "the run's console log"}
        rounds.append(r)
        print(f"{r['round']:<26} {tx[:10]}… blk {b0} → {b1} ({b1 - b0} blocks, {ts1 - ts0}s)  Lasna {s_['transactionHash'][:10]}…")
    return rounds


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--rebuild":
        new = rebuild(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None)
        return finish(new)
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    gap = float(sys.argv[2]) if len(sys.argv) > 2 else 8
    key = ENV["BORROWER_PRIVATE_KEY"]
    ten = cast("to-wei", "10")
    demo = D["demo"]["DemoDeposit"]
    print(f"{n} rounds against the live demo (wallet {WALLET}), {gap:g} s apart")
    new = []
    for i in range(1, n + 1):
        if i % 2:
            r = run_round(f"{i} deposit 10 (DemoDeposit)", demo, "deposit(uint256)", ten, key=key)
        else:
            r = run_round(f"{i} repay 10", MORPHO, f"repay({MP},uint256,uint256,address,bytes)",
                          PARAMS, ten, "0", D["borrower"], "0x", key=key)
        new.append(r)
        if i < n:
            time.sleep(gap)
    finish(new)


def finish(new):
    old = json.load(open("evidence/race-2026-11-24.json"))["rounds"]
    earlier = [measure_existing(l, tx) for l, tx in EARLIER]
    every = old + earlier + new
    withdrew = [r for r in every if r["callback"]["withdrawnWei"] > 0]
    blocks = [r["baseBlocks"] for r in every]
    summary = {
        "newRounds": stats([r["baseBlocks"] for r in new]) | {"chainSeconds": stats([r["chainSeconds"] for r in new])},
        "allRounds": {"baseBlocks": stats(blocks), "baseSecondsAt0_2sPerBlock": {k: round(v * 0.2, 1) for k, v in stats(blocks).items() if k != "n"},
                      "chainSeconds": stats([r["chainSeconds"] for r in every])},
        "withdrawalsOnly": {"baseBlocks": stats([r["baseBlocks"] for r in withdrew])},
        "withdrawnThisRunWei": sum(r["callback"]["withdrawnWei"] for r in new),
        "walletSharesLeft": int(cast("call", MORPHO, "position(bytes32,address)(uint256,uint128,uint128)",
                                     B["marketId"], WALLET, "-r", BASE).split("\n")[0].split()[0]),
        "errandArmedAfter": cast("call", race.ERRAND, "armed()(bool)", "-r", LASNA) == "true",
    }
    print(json.dumps(summary, indent=2))
    out = {"measuredAt": iso(time.time()), "deployment": "deployments/testnet.json", "pollSeconds": race.POLL,
           "sentBy": "our test borrower key (" + D["borrower"] + ")", "rounds": new,
           "earlierRounds": earlier, "earlierEvidence": "evidence/race-2026-11-24.json", "summary": summary}
    path = f"evidence/rounds-{datetime.now(timezone.utc):%Y-%m-%d}.json"
    json.dump(out, open(path, "w"), indent=2)
    print("Saved", path)


if __name__ == "__main__":
    main()
