import { createPublicClient, decodeEventLog, http, toHex, type Hash, type Hex, type Log } from "viem";
import { mainnet } from "viem/chains";
import {
  BASE_BLOCK_SECONDS, D, LIDO, RPC, baseSepolia, demoDepositAbi, erc20Abi, errandLidoAbi, errandMorphoAbi, lasna,
  morphoAbi, walletAbi,
} from "./config";

export const base = createPublicClient({ chain: baseSepolia, transport: http(RPC.base, { retryCount: 3 }), cacheTime: 0 });
export const reactiveTestnet = createPublicClient({ chain: lasna, transport: http(RPC.lasna, { retryCount: 3 }), cacheTime: 0 });

/**
 * ErrandSent events on Lasna from `from` up to the current head. Lasna's public RPC caches eth_getLogs answers
 * by request body, so an open-ended query keeps returning old results; naming the head block makes each poll new.
 */
async function errandSentLogs(from: bigint) {
  const to = await reactiveTestnet.getBlockNumber();
  return reactiveTestnet.getLogs({ address: D.errand, event: errandMorphoAbi[2], fromBlock: from, toBlock: to, strict: true });
}
const ethereum = createPublicClient({ chain: mainnet, transport: http(RPC.ethereum) });
const reactiveMainnet = createPublicClient({
  chain: { ...lasna, id: 1597, name: "Reactive", rpcUrls: { default: { http: [RPC.reactive] } } },
  transport: http(RPC.reactive),
});

const VIRTUAL_SHARES = 1_000_000n;
const VIRTUAL_ASSETS = 1n;

export type Snapshot = {
  supplied: bigint;
  borrowed: bigint;
  lenderStuck: bigint;   // the lender's position in the market, in tUSD
  lenderOut: bigint;     // tUSD the lender's wallet holds (what it has taken back)
  armed: boolean;
  errandsSent: bigint;
  errandReact: bigint;   // lREACT the reactive contract has left to pay for its work
};

export async function readSnapshot(): Promise<Snapshot> {
  const [market, position, out, armed, sent, react] = await Promise.all([
    base.readContract({ address: D.morpho, abi: morphoAbi, functionName: "market", args: [D.marketId] }),
    base.readContract({ address: D.morpho, abi: morphoAbi, functionName: "position", args: [D.marketId, D.wallet] }),
    base.readContract({ address: D.loanToken, abi: erc20Abi, functionName: "balanceOf", args: [D.wallet] }),
    reactiveTestnet.readContract({ address: D.errand, abi: errandMorphoAbi, functionName: "armed" }),
    reactiveTestnet.readContract({ address: D.errand, abi: errandMorphoAbi, functionName: "errandsSent" }),
    reactiveTestnet.getBalance({ address: D.errand }),
  ]);
  const [supplied, supplyShares, borrowed] = market;
  const shares = position[0];
  const lenderStuck = (shares * (supplied + VIRTUAL_ASSETS)) / (supplyShares + VIRTUAL_SHARES);
  return { supplied, borrowed, lenderStuck, lenderOut: out, armed, errandsSent: sent, errandReact: react };
}

export type Trigger = { kind: "deposit" | "repay" | "exit request" | "other"; by?: string; amount?: bigint };

export type Round = {
  n: bigint;
  trigger: { tx: Hash; block: bigint; timestamp: bigint; what: Trigger };
  reactive: { tx: Hash; block: bigint };
  callback?: { tx: Hash; block: bigint; timestamp: bigint; withdrawn: bigint; remainingShares: bigint };
};

/** What started a round: a Morpho Supply or Repay in our market, or the wallet's own exit request. */
async function describeTrigger(tx: Hash): Promise<{ block: bigint; what: Trigger }> {
  const r = await base.getTransactionReceipt({ hash: tx });
  for (const l of r.logs) {
    try {
      if (l.address.toLowerCase() === D.morpho.toLowerCase()) {
        const e = decodeEventLog({ abi: morphoAbi, data: l.data, topics: l.topics });
        if ((e.eventName === "Supply" || e.eventName === "Repay") && e.args.id === D.marketId) {
          return {
            block: r.blockNumber,
            what: { kind: e.eventName === "Supply" ? "deposit" : "repay", by: e.args.onBehalf, amount: e.args.assets },
          };
        }
      }
      if (l.address.toLowerCase() === D.wallet.toLowerCase()) {
        const e = decodeEventLog({ abi: walletAbi, data: l.data, topics: l.topics });
        if (e.eventName === "ExitRequested") return { block: r.blockNumber, what: { kind: "exit request", by: D.wallet } };
      }
    } catch {
      /* not one of ours */
    }
  }
  return { block: r.blockNumber, what: { kind: "other" } };
}

const blockTimes = new Map<bigint, bigint>();
async function timestampOf(client: typeof base, block: bigint) {
  if (!blockTimes.has(block)) blockTimes.set(block, (await client.getBlock({ blockNumber: block })).timestamp);
  return blockTimes.get(block)!;
}

type ProgressLog = Log<bigint, number, false, (typeof walletAbi)[1], true>;

/** ExitProgress events from the wallet in [from, to] (Base Sepolia's public RPC caps a query at 200 blocks). */
async function progressLogs(from: bigint, to: bigint): Promise<ProgressLog[]> {
  return (await base.getLogs({
    address: D.wallet,
    event: walletAbi[1],
    args: { marketId: D.marketId },
    fromBlock: from,
    toBlock: to,
    strict: true,
  })) as ProgressLog[];
}

/** Every errand ErrandMorpho has sent, newest first, each matched with its trigger and the callback it produced. */
export async function readRounds(limit = 12): Promise<Round[]> {
  const sent = await errandSentLogs(D.errandFromBlock);
  const recent = sent.slice(-limit);
  const rounds: Round[] = await Promise.all(recent.map(async (l) => {
    const tx = toHex(l.args.triggeredByTxHash, { size: 32 }) as Hash;
    const t = await describeTrigger(tx);
    return {
      n: l.args.errandNumber,
      trigger: { tx, block: t.block, timestamp: await timestampOf(base, t.block), what: t.what },
      reactive: { tx: l.transactionHash, block: l.blockNumber },
    };
  }));
  // Each errand produces one ExitProgress. Pair them in order: the first unused callback after each trigger.
  rounds.sort((a, b) => Number(a.trigger.block - b.trigger.block));
  if (rounds.length) {
    const used = new Set<string>();
    const latest = await base.getBlockNumber();
    for (const r of rounds) {
      const to = r.trigger.block + 150n > latest ? latest : r.trigger.block + 150n;
      const logs = await progressLogs(r.trigger.block, to);
      const hit = logs.find((p) => !used.has(p.transactionHash + p.logIndex));
      if (hit) {
        used.add(hit.transactionHash + hit.logIndex);
        r.callback = {
          tx: hit.transactionHash, block: hit.blockNumber, timestamp: await timestampOf(base, hit.blockNumber),
          withdrawn: hit.args.withdrawn, remainingShares: hit.args.remainingShares,
        };
      }
    }
  }
  return rounds.reverse();
}

export const onchainSeconds = (r: Round) =>
  r.callback ? Number(r.callback.block - r.trigger.block) * BASE_BLOCK_SECONDS : undefined;

/* ---------- a live round, started by the visitor ---------- */

export type LiveEvent =
  | { stage: "landed"; tx: Hash; block: bigint; at: number }
  | { stage: "reacted"; tx: Hash; at: number }
  | { stage: "withdrawn"; tx: Hash; block: bigint; withdrawn: bigint; at: number; blocks: bigint; timestampDelta: bigint };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Follows one trigger tx through all three hops, reporting each as soon as this browser sees it. */
export async function followRound(tx: Hash, onEvent: (e: LiveEvent) => void, signal: { stopped: boolean }) {
  const lasnaFrom = await reactiveTestnet.getBlockNumber();
  // 1. the visitor's deposit lands on Base Sepolia
  let receipt;
  while (!signal.stopped) {
    receipt = await base.getTransactionReceipt({ hash: tx }).catch(() => undefined);
    if (receipt) break;
    await sleep(250);
  }
  if (!receipt) return;
  if (receipt.status !== "success") throw new Error("Your deposit reverted on Base Sepolia.");
  const triggerTs = await timestampOf(base, receipt.blockNumber);
  onEvent({ stage: "landed", tx, block: receipt.blockNumber, at: performance.now() });

  // 2. ErrandMorpho reacts on Lasna: the ErrandSent event that names this tx
  let reacted = false;
  const seenCallbacks = new Set<string>();
  for (const p of await progressLogs(receipt.blockNumber - 5n, receipt.blockNumber)) seenCallbacks.add(p.transactionHash);
  while (!signal.stopped) {
    if (!reacted) {
      const sent = await errandSentLogs(lasnaFrom - 2n).catch(() => []);
      const mine = sent.find((l) => l.args.triggeredByTxHash === BigInt(tx));
      if (mine) {
        reacted = true;
        onEvent({ stage: "reacted", tx: mine.transactionHash, at: performance.now() });
      }
    }
    // 3. the lender's wallet withdraws on Base Sepolia (the callback can land before we see the Lasna log)
    const latest = await base.getBlockNumber().catch(() => receipt.blockNumber);
    const logs = await progressLogs(receipt.blockNumber, latest).catch(() => []);
    const cb = logs.find((p) => !seenCallbacks.has(p.transactionHash));
    if (cb) {
      // The callback can show up before our poll of Lasna does; look for the reactive tx a few more times.
      for (let i = 0; !reacted && i < 8; i++) {
        const sent = await errandSentLogs(lasnaFrom - 2n).catch(() => []);
        const mine = sent.find((l) => l.args.triggeredByTxHash === BigInt(tx));
        if (mine) {
          reacted = true;
          onEvent({ stage: "reacted", tx: mine.transactionHash, at: performance.now() });
        } else await sleep(400);
      }
      onEvent({
        stage: "withdrawn", tx: cb.transactionHash, block: cb.blockNumber, withdrawn: cb.args.withdrawn,
        at: performance.now(), blocks: cb.blockNumber - receipt.blockNumber,
        timestampDelta: (await timestampOf(base, cb.blockNumber)) - triggerTs,
      });
      return;
    }
    await sleep(300);
  }
}

/* ---------- Lido errand on mainnet: status only ---------- */

export async function readLido() {
  const [tracked, code] = await Promise.all([
    reactiveMainnet.readContract({ address: LIDO.errandLido, abi: errandLidoAbi, functionName: "tracked" }).catch(() => undefined),
    ethereum.getCode({ address: LIDO.wallet }).catch(() => undefined),
  ]);
  return { tracked, delegated: !!code && code.startsWith("0xef0100") };
}

export { demoDepositAbi };
export type { Hex };
