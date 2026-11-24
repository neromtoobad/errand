#!/usr/bin/env python3
"""Every Second Counts: measures how fast Errand gets a lender out of a 100%-borrowed Morpho market.

Uses the testnet deployment in deployments/testnet.json (run script/testnet/deploy-morpho.sh first).
  round 0   the wallet calls requestExit() on itself: Errand arms and tries at once (nothing free yet)
  round 1+  the borrower repays part of the loan (or someone deposits): each frees liquidity, and Errand's
            callback withdraws it for the wallet
For every round it records, from the chains themselves:
  - the trigger tx on Base Sepolia (block, timestamp)
  - Errand's reactive tx on Lasna (the ErrandSent event that names the trigger tx)
  - the callback tx on Base Sepolia (the wallet's ExitProgress event), amount withdrawn and fee paid
plus wall-clock times seen by this script, polling every POLL seconds.
Writes evidence/race-<UTC date>.json.   Usage: python3 tools/race.py [repay amounts in tUSD...]
"""
import json, os, subprocess, sys, time, urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
CAST = os.path.expanduser("~/.foundry/bin/cast")
ENV = dict(l.strip().split("=", 1) for l in open(".env") if "=" in l and not l.startswith("#"))
D = json.load(open("deployments/testnet.json"))
B, R = D["base"], D["reactive"]
BASE = ENV.get("BASE_SEPOLIA_RPC_URL", "https://sepolia.base.org")
LASNA = ENV.get("LASNA_RPC_URL", "https://lasna-rpc.rnk.dev/")
POLL = float(os.environ.get("POLL", "0.4"))
TIMEOUT = float(os.environ.get("TIMEOUT", "180"))
WALLET, ERRAND, MORPHO = D["wallet"], R["ErrandMorpho"], B["morpho"]
PARAMS = f"({B['loanToken']},{B['collateralToken']},{B['oracle']},0x0000000000000000000000000000000000000000,860000000000000000)"
MP = "(address,address,address,address,uint256)"


def cast(*args):
    return subprocess.run([CAST, *args], check=True, capture_output=True, text=True).stdout.strip()


def topic(sig):
    return cast("keccak", sig)


T_PROGRESS = topic("ExitProgress(bytes32,uint256,uint256)")
T_FEE = topic("FeePaid(uint256)")
T_SENT = topic("ErrandSent(uint256,uint256)")
T_ARMED = topic("Armed(uint256)")
T_DISARMED = topic("Disarmed(uint256,bool)")


def rpc(url, method, *params):
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                                          "params": list(params)}).encode(),
                                         {"Content-Type": "application/json", "User-Agent": "errand-race"})
            out = json.load(urllib.request.urlopen(req, timeout=10))
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1 + attempt)


def block(url, tag="latest"):
    b = rpc(url, "eth_getBlockByNumber", tag, False)
    return int(b["number"], 16), int(b["timestamp"], 16)


def logs(url, address, topic0, from_block):
    return rpc(url, "eth_getLogs", {"address": address, "topics": [topic0], "fromBlock": hex(from_block)})


def send_async(to, sig, *args, key):
    return cast("send", to, sig, *args, "-r", BASE, "--private-key", key, "--async")


def wait_for(fn, what):
    start = time.time()
    while time.time() - start < TIMEOUT:
        got = fn()
        if got:
            return got, time.time()
        time.sleep(POLL)
    raise TimeoutError(f"no {what} after {TIMEOUT}s")


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="milliseconds")


def run_round(label, to, sig, *args, key):
    base_from, _ = block(BASE)
    lasna_from, _ = block(LASNA)
    t_sent = time.time()
    tx = send_async(to, sig, *args, key=key)
    receipt, t_mined = wait_for(lambda: rpc(BASE, "eth_getTransactionReceipt", tx), "receipt")
    assert receipt["status"] == "0x1", f"{label}: trigger tx reverted"
    b0 = int(receipt["blockNumber"], 16)
    _, ts0 = block(BASE, receipt["blockNumber"])

    def reactive():
        return [l for l in logs(LASNA, ERRAND, T_SENT, lasna_from) if int(l["data"][:66], 16) == int(tx, 16)]
    sent, t_react = wait_for(reactive, "ErrandSent on Lasna")
    rtx = sent[0]["transactionHash"]
    rblock = int(sent[0]["blockNumber"], 16)
    _, rts = block(LASNA, sent[0]["blockNumber"])

    def callback():
        return [l for l in logs(BASE, WALLET, T_PROGRESS, b0) if l["topics"][1] == B["marketId"]]
    prog, t_cb = wait_for(callback, "ExitProgress callback on Base")
    p = prog[-1]
    b1 = int(p["blockNumber"], 16)
    _, ts1 = block(BASE, p["blockNumber"])
    withdrawn = int(p["data"][2:66], 16)
    remaining = int(p["data"][66:130], 16)
    cb_receipt = rpc(BASE, "eth_getTransactionReceipt", p["transactionHash"])
    fee = sum(int(l["data"], 16) for l in cb_receipt["logs"]
              if l["address"].lower() == WALLET.lower() and l["topics"][0] == T_FEE)
    r = {
        "round": label,
        "trigger": {"tx": tx, "block": b0, "timestamp": ts0},
        "reactive": {"tx": rtx, "block": rblock, "timestamp": rts},
        "callback": {"tx": p["transactionHash"], "block": b1, "timestamp": ts1,
                     "withdrawnWei": withdrawn, "remainingShares": remaining,
                     "feePaidWei": fee, "gasUsed": int(cb_receipt["gasUsed"], 16)},
        "baseBlocks": b1 - b0,
        "chainSeconds": ts1 - ts0,
        "wallClock": {"sent": iso(t_sent), "triggerSeen": iso(t_mined), "reactiveSeen": iso(t_react),
                      "callbackSeen": iso(t_cb), "triggerSeenToCallbackSeenSec": round(t_cb - t_mined, 2)},
    }
    print(f"{label:<22} trigger blk {b0}  → callback blk {b1}  ({b1 - b0} blocks, {ts1 - ts0}s onchain, "
          f"{t_cb - t_mined:.1f}s wall)  withdrew {withdrawn / 1e18:g} tUSD, fee {fee / 1e18:.8f} ETH")
    return r


def main():
    amounts = [float(a) for a in sys.argv[1:]] or [10, 15, 20, 25]
    k_wallet, k_borrower = ENV["OWNER_PRIVATE_KEY"], ENV["BORROWER_PRIVATE_KEY"]
    loan = B["loanToken"]
    rounds = []
    print(f"Errand race on Base Sepolia (Morpho market {B['marketId'][:10]}…), Lasna contract {ERRAND}")
    rounds.append(run_round("0 requestExit", WALLET, "requestExit()", key=k_wallet))
    for i, a in enumerate(amounts, 1):
        rounds.append(run_round(f"{i} repay {a:g}", MORPHO, f"repay({MP},uint256,uint256,address,bytes)",
                                PARAMS, cast("to-wei", str(a)), "0", D["borrower"], "0x", key=k_borrower))
    # A new deposit also frees liquidity: someone else lends 10 tUSD into the market.
    rounds.append(run_round(f"{len(amounts) + 1} deposit 10", MORPHO, f"supply({MP},uint256,uint256,address,bytes)",
                            PARAMS, cast("to-wei", "10"), "0", D["borrower"], "0x", key=k_borrower))
    # Then the borrower repays the rest; the wallet is fully out and Errand stands down.
    left = 100 - sum(amounts)
    if left > 0:
        rounds.append(run_round(f"{len(amounts) + 2} repay rest", MORPHO, f"repay({MP},uint256,uint256,address,bytes)",
                                PARAMS, "0", cast("call", MORPHO, "position(bytes32,address)(uint256,uint128,uint128)",
                                                  B["marketId"], D["borrower"], "-r", BASE).split("\n")[1].split()[0],
                                D["borrower"], "0x", key=k_borrower))
    time.sleep(15)  # give Lasna time to react to the final ExitProgress
    armed = cast("call", ERRAND, "armed()(bool)", "-r", LASNA)
    disarms = logs(LASNA, ERRAND, T_DISARMED, rounds[0]["reactive"]["block"])
    shares, _, _ = cast("call", MORPHO, "position(bytes32,address)(uint256,uint128,uint128)", B["marketId"], WALLET,
                        "-r", BASE).split("\n")
    measured = [r for r in rounds[1:] if r["callback"]["withdrawnWei"] > 0]
    blocks = sorted(r["baseBlocks"] for r in measured)
    secs = sorted(r["chainSeconds"] for r in measured)
    summary = {
        "rounds": len(measured),
        "baseBlocksTriggerToCallback": {"min": blocks[0], "median": blocks[len(blocks) // 2], "max": blocks[-1]},
        "chainSecondsTriggerToCallback": {"min": secs[0], "median": secs[len(secs) // 2], "max": secs[-1]},
        "withdrawnTotalWei": sum(r["callback"]["withdrawnWei"] for r in rounds),
        "walletSharesLeft": int(shares.split()[0]),
        "errandArmedAfter": armed == "true",
        "disarmTx": disarms[-1]["transactionHash"] if disarms else None,
    }
    print(json.dumps(summary, indent=2))
    out = {"measuredAt": iso(time.time()), "deployment": "deployments/testnet.json", "pollSeconds": POLL,
           "rounds": rounds, "summary": summary}
    path = f"evidence/race-{datetime.now(timezone.utc):%Y-%m-%d}.json"
    json.dump(out, open(path, "w"), indent=2)
    print("Saved", path)


if __name__ == "__main__":
    main()
