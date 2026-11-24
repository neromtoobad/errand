import "./style.css";
import { BaseError, ContractFunctionRevertedError, createWalletClient, custom, formatUnits, parseUnits, type Address, type Hash, type WalletClient } from "viem";
import { D, EXPLORER, LIDO, baseSepolia } from "./config";
import { base, demoDepositAbi, followRound, onchainSeconds, readLido, readRounds, readSnapshot, type Round, type Snapshot } from "./chain";

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const tusd = (v: bigint, dp = 2) =>
  Number(formatUnits(v, 18)).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
const link = (href: string, text: string, cls = "mono") => `<a class="${cls}" href="${href}" target="_blank" rel="noopener">${text}</a>`;
const baseTx = (h: string) => link(`${EXPLORER.base}/tx/${h}`, short(h));
const lasnaTx = (h: string) => link(`${EXPLORER.lasna}/tx/${h}`, short(h));

function toast(msg: string, ms = 5000) {
  const t = $("toast");
  t.textContent = msg;
  t.hidden = false;
  clearTimeout((toast as unknown as { h?: number }).h);
  (toast as unknown as { h?: number }).h = window.setTimeout(() => (t.hidden = true), ms);
}

/* ---------------- lender + Errand state ---------------- */

let snap: Snapshot | undefined;

async function refreshSnapshot() {
  try {
    snap = await readSnapshot();
  } catch {
    return;
  }
  const total = snap.lenderStuck + snap.lenderOut;
  $("stuck").textContent = tusd(snap.lenderStuck);
  $("out").textContent = tusd(snap.lenderOut);
  $("bar-out").style.width = total > 0n ? `${Number((snap.lenderOut * 10000n) / total) / 100}%` : "0%";
  $("util").textContent = snap.supplied > 0n ? `${(Number((snap.borrowed * 10000n) / snap.supplied) / 100).toFixed(1)}%` : "—";
  $("errands").textContent = snap.errandsSent.toString();
  $("react").textContent = `${Number(formatUnits(snap.errandReact, 18)).toFixed(3)} lREACT`;
  const st = $("errand-status");
  if (snap.armed) {
    st.innerHTML = `<span class="dot live"></span>Errand is watching`;
    st.className = "pill on";
  } else {
    st.innerHTML = snap.lenderStuck === 0n ? "Lender is fully out · Errand off" : "Errand is off";
    st.className = "pill";
  }
  updateGo();
}

/* ---------------- rounds table ---------------- */

const rendered = new Map<string, Round>();

function whatFreed(r: Round) {
  const w = r.trigger.what;
  if (w.kind === "exit request") return `<span class="tag ink">Exit request</span>`;
  const who = w.by ? (w.by.toLowerCase() === account?.toLowerCase() ? "you" : short(w.by)) : "";
  const amt = w.amount !== undefined ? `${tusd(w.amount, 0)} tUSD` : "";
  if (w.kind === "deposit") return `<span class="tag lime">Deposit</span> ${amt} <span class="who">by ${who}</span>`;
  if (w.kind === "repay") return `<span class="tag">Repay</span> ${amt}`;
  return `<span class="tag">Other</span>`;
}

function renderRounds(rounds: Round[]) {
  const body = $("rounds-body");
  if (!rounds.length) {
    body.innerHTML = `<tr><td colspan="7" class="empty">No rounds yet.</td></tr>`;
    return;
  }
  body.innerHTML = rounds.map((r) => {
    const secs = onchainSeconds(r);
    const blocks = r.callback ? Number(r.callback.block - r.trigger.block) : undefined;
    const isNew = !rendered.has(r.reactive.tx);
    return `<tr class="${isNew && rendered.size ? "flash" : ""}">
      <td class="mono dim">${r.n}</td>
      <td>${whatFreed(r)}</td>
      <td>${baseTx(r.trigger.tx)}</td>
      <td>${lasnaTx(r.reactive.tx)}</td>
      <td>${r.callback ? baseTx(r.callback.tx) : `<span class="dim">waiting…</span>`}</td>
      <td class="r mono">${r.callback ? tusd(r.callback.withdrawn) : "—"}</td>
      <td class="r mono strong">${secs !== undefined ? `${secs.toFixed(1)} s <span class="dim">· ${blocks} blk</span>` : "—"}</td>
    </tr>`;
  }).join("");
  for (const r of rounds) rendered.set(r.reactive.tx, r);

  const timed = rounds.filter((r) => r.callback && r.callback.withdrawn > 0n).map((r) => onchainSeconds(r)!).sort((a, b) => a - b);
  if (timed.length) {
    const med = timed[Math.floor(timed.length / 2)];
    $("rounds-sum").innerHTML = `Median <strong>${med.toFixed(1)} s</strong> from the trigger to the withdrawal, over the last ${timed.length} withdrawals (fastest ${timed[0].toFixed(1)} s).`;
  }
}

let roundsBusy = false;
async function refreshRounds() {
  if (roundsBusy) return;
  roundsBusy = true;
  try {
    renderRounds(await readRounds(12));
  } catch {
    $("rounds-sum").textContent = "Couldn't read the chains just now; retrying.";
  } finally {
    roundsBusy = false;
  }
}

/* ---------------- wallet ---------------- */

type Eip1193 = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown>; on?: (e: string, f: (x: unknown) => void) => void };
const injected = (window as unknown as { ethereum?: Eip1193 }).ethereum;
let wallet: WalletClient | undefined;
let account: Address | undefined;
let visitorEth = 0n;
let amount = 10;
let running = false;

async function ensureBaseSepolia() {
  if (!wallet) return;
  if ((await wallet.getChainId()) === baseSepolia.id) return;
  try {
    await wallet.switchChain({ id: baseSepolia.id });
  } catch {
    await wallet.addChain({ chain: baseSepolia });
  }
}

async function connect() {
  if (!injected) {
    toast("No browser wallet found. Install one (MetaMask, Rabby, Coinbase Wallet) to deposit; everything else on this page works without it.", 8000);
    return;
  }
  wallet = createWalletClient({ chain: baseSepolia, transport: custom(injected) });
  try {
    [account] = await wallet.requestAddresses();
    await ensureBaseSepolia();
  } catch {
    toast("The wallet didn't connect.");
    return;
  }
  injected.on?.("accountsChanged", (a) => { account = (a as Address[])[0]; refreshVisitor(); });
  injected.on?.("chainChanged", () => refreshVisitor());
  await refreshVisitor();
}

async function refreshVisitor() {
  const c = $("connect");
  if (!account) {
    c.textContent = "Connect wallet";
    updateGo();
    return;
  }
  c.textContent = short(account);
  c.classList.add("connected");
  visitorEth = await base.getBalance({ address: account }).catch(() => 0n);
  updateGo();
}

function updateGo() {
  const go = $<HTMLButtonElement>("go");
  const note = $("go-note");
  if (running) return;
  go.disabled = false;
  if (snap && !snap.armed) {
    go.textContent = "Errand is off";
    go.disabled = true;
    note.textContent = snap.lenderStuck === 0n ? "The lender is fully out, so Errand switched itself off." : "The lender hasn't asked to exit.";
    return;
  }
  if (snap && snap.lenderStuck === 0n) {
    go.textContent = "Nothing left to free";
    go.disabled = true;
    return;
  }
  if (!account) {
    go.textContent = "Connect wallet to deposit";
    note.textContent = "One transaction on Base Sepolia. The tUSD is minted for you and has no value.";
    return;
  }
  go.textContent = `Deposit ${amount} tUSD`;
  if (visitorEth === 0n) {
    note.innerHTML = `You need a little Base Sepolia ETH for gas. Free from the ${link("https://portal.cdp.coinbase.com/products/faucet", "Coinbase", "")}, ${link("https://www.alchemy.com/faucets/base-sepolia", "Alchemy", "")} or ${link("https://console.optimism.io/faucet", "Superchain", "")} faucets.`;
  } else {
    note.textContent = `One transaction on Base Sepolia from ${short(account)}. The tUSD is minted for you and has no value.`;
  }
}

/* ---------------- the live round ---------------- */

let raf = 0;
function startClock(t0: number) {
  const el = $("clock");
  const tick = () => {
    el.innerHTML = `${((performance.now() - t0) / 1000).toFixed(2)}<span>s</span>`;
    raf = requestAnimationFrame(tick);
  };
  cancelAnimationFrame(raf);
  tick();
}
const stopClock = () => cancelAnimationFrame(raf);

function setSplit(i: number, state: "" | "wait" | "done", right = "") {
  const li = $(`s${i}`);
  li.className = state;
  li.querySelector(".s-r")!.innerHTML = right;
}

function resetBoard() {
  for (const i of [1, 2, 3]) setSplit(i, "");
  $("clock").innerHTML = `0.00<span>s</span>`;
  $("clock-label").textContent = "from your deposit landing to the lender's withdrawal";
  $("result").hidden = true;
  $("board").classList.remove("finished");
}

async function deposit() {
  if (!account || !wallet) return connect();
  if (running) return;
  const go = $<HTMLButtonElement>("go");
  running = true;
  go.disabled = true;
  resetBoard();
  let hash: Hash;
  try {
    await ensureBaseSepolia();
    go.textContent = "Confirm in your wallet…";
    setSplit(1, "wait", "signing");
    hash = await wallet.writeContract({
      address: D.demoDeposit, abi: demoDepositAbi, functionName: "deposit",
      args: [parseUnits(String(amount), 18)], account, chain: baseSepolia,
    });
  } catch (e) {
    running = false;
    resetBoard();
    updateGo();
    const reason = e instanceof BaseError ? e.walk((x) => x instanceof ContractFunctionRevertedError) : undefined;
    toast(reason ? "The deposit would revert." : (e as { shortMessage?: string }).shortMessage ?? "Cancelled.");
    return;
  }

  go.textContent = "Watching the chains…";
  setSplit(1, "wait", `${baseTx(hash)}`);
  let t0 = 0;
  const signal = { stopped: false };
  const timeout = window.setTimeout(() => (signal.stopped = true), 120_000);
  try {
    await followRound(hash, (ev) => {
      if (ev.stage === "landed") {
        t0 = ev.at;
        startClock(t0);
        setSplit(1, "done", `${baseTx(ev.tx)} <span class="dim">block ${ev.block}</span>`);
        setSplit(2, "wait", "waiting");
      } else if (ev.stage === "reacted") {
        setSplit(2, "done", `${ev.tx === "0x" ? "" : lasnaTx(ev.tx)} <span class="dim">+${((ev.at - t0) / 1000).toFixed(2)} s</span>`);
        setSplit(3, "wait", "waiting");
      } else if (ev.stage === "withdrawn") {
        stopClock();
        const secs = Number(ev.blocks) * 0.2;
        setSplit(3, "done", `${baseTx(ev.tx)} <span class="dim">block ${ev.block}</span>`);
        $("clock").innerHTML = `${secs.toFixed(1)}<span>s</span>`;
        $("clock-label").textContent = `onchain: ${ev.blocks} Base blocks after your deposit · your browser saw it after ${((ev.at - t0) / 1000).toFixed(2)} s`;
        const r = $("result");
        r.innerHTML = `The lender's wallet took back <strong>${tusd(ev.withdrawn)} tUSD</strong>, ${ev.blocks} blocks after your deposit landed.`;
        r.hidden = false;
        $("board").classList.add("finished");
      }
    }, signal);
    if (signal.stopped) toast("No withdrawal seen within 2 minutes. Reactive may be busy; check the rounds table later.", 8000);
  } catch (e) {
    toast((e as Error).message);
  } finally {
    clearTimeout(timeout);
    stopClock();
    running = false;
    updateGo();
    refreshSnapshot();
    refreshVisitor();
    refreshRounds();
  }
}

/* ---------------- Lido panel ---------------- */

async function refreshLido() {
  $<HTMLAnchorElement>("lido-r").href = `${EXPLORER.reactive}/address/${LIDO.errandLido}`;
  $("lido-dot1").className = "dot on";
  const l = await readLido();
  if (l.delegated) {
    $("lido-eth").innerHTML = `<strong>Wallet switched on</strong> on Ethereum (EIP-7702 delegation)`;
    $("lido-dot2").className = "dot on";
  } else {
    $("lido-eth").innerHTML = `<strong>Ethereum side waiting for cheap gas.</strong> The wallet has 0.0005 ETH, so it deploys when the base fee drops.`;
    $("lido-dot2").className = "dot wait";
  }
  const n = l.tracked?.length ?? 0;
  $("lido-claim").innerHTML = n
    ? `<strong>${n} Lido request${n > 1 ? "s" : ""} tracked,</strong> claimed as soon as Lido finalizes`
    : `<strong>First real claim:</strong> after the wallet requests a withdrawal and Lido finalizes it`;
  $("lido-dot3").className = n ? "dot on" : "dot wait";
}

/* ---------------- wire up ---------------- */

function init() {
  const la = $<HTMLAnchorElement>("lender-addr");
  la.textContent = short(D.wallet);
  la.href = `${EXPLORER.base}/address/${D.wallet}`;
  $("foot-links").innerHTML = [
    link(`${EXPLORER.lasna}/address/${D.errand}`, "ErrandMorpho · Lasna", ""),
    link(`${EXPLORER.base}/address/${D.walletCode}`, "Wallet code · Base Sepolia", ""),
    link(`${EXPLORER.base}/address/${D.morpho}`, "Morpho Blue · Base Sepolia", ""),
    link(`${EXPLORER.base}/address/${D.demoDeposit}`, "DemoDeposit (testnet helper)", ""),
    link("https://github.com/neromtoobad/errand", "Source on GitHub", ""),
  ].join("");

  $("connect").addEventListener("click", connect);
  $("go").addEventListener("click", deposit);
  document.querySelectorAll<HTMLButtonElement>(".chip").forEach((c) =>
    c.addEventListener("click", () => {
      if (running) return;
      document.querySelectorAll(".chip").forEach((x) => x.classList.remove("on"));
      c.classList.add("on");
      amount = Number(c.dataset.amt);
      updateGo();
    }),
  );

  refreshSnapshot();
  refreshRounds();
  refreshLido().catch(() => undefined);
  setInterval(refreshSnapshot, 5000);
  setInterval(() => !running && refreshRounds(), 15000);

  // Reconnect silently if the site was already allowed.
  injected?.request({ method: "eth_accounts" }).then((a) => {
    if ((a as string[]).length) connect();
  }).catch(() => undefined);
}

init();
