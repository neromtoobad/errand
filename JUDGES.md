# Errand: check it in 2 minutes

**What it does:** your own wallet sends a follow-up transaction the moment it can succeed:
claiming a Lido withdrawal once Lido finalizes it, or withdrawing from a lending market once someone
repays. Reactive Network sees the event and calls back into the wallet, which has Errand's code
through one EIP-7702 signature. No bot, no server, no key handed over.

You don't need a wallet, a key or an `.env` for anything below.

## 1. Look (30 seconds)

| Open this | You see |
|---|---|
| [errand.nerom.site](https://errand.nerom.site) | A lender's money stuck in a fully borrowed Morpho market on Base Sepolia, Errand's status on Lasna, and every round so far with its three transactions. Everything on the page is read from the chains in your browser. "Replay" replays the last real round from its block numbers and says so |
| [Round #9 trigger](https://base-sepolia.blockscout.com/tx/0x0c6507b5c512c57f6b56ca7504b331bda43c2be03a9ae0aed9f616165873e6c2) → [reactive tx on Lasna](https://lasna.reactscan.net/tx/0xdcecb9089f651a65cd861b03894a9a2c0900215566379304e64b510f57c2a834) → [callback on Base](https://base-sepolia.blockscout.com/tx/0x94cd802ae8c8b9425a76fe523b2b3c0ca34ece8576494dd3a193a21a212cbdd1) | One full loop started from the live page: a 10 tUSD deposit freed liquidity, and the lender's own address withdrew it 8 Base blocks (1.6 s) later |
| [Lido request on Ethereum](https://etherscan.io/tx/0xf2687d9ff17d8e2c465539feb09f233fc094416bef4a1ee0a62c1efd848cb237) → [ErrandLido tracking it on Reactive mainnet](https://reactscan.net/tx/0x07116c760fe004f14a6c50defcc2effc6179aff81666b26372910e9f72ca0415) | The mainnet errand: a real Lido withdrawal request (#142667) from the delegated wallet, picked up by ErrandLido. The claim callback fires when Lido finalizes it. If it has landed, its tx is in [deployments/mainnet.json](deployments/mainnet.json) under `lido.claimTx` and on the live page |

## 2. Run (90 seconds, needs [Foundry](https://getfoundry.sh) and python3)

```bash
git clone --recursive https://github.com/neromtoobad/errand && cd errand
./tools/check-live.sh
```

It prints PASS / FAIL / WAIT for every onchain claim in the README, read live from Reactive mainnet,
Lasna, Ethereum, Base Sepolia and Sourcify. On Nov 25: **23 pass, 0 fail, 1 waiting** (Lido hasn't
finalized our request yet).

```bash
ETHEREUM_RPC_URL=https://ethereum-rpc.publicnode.com BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test
```

41 tests. 10 run on an Ethereum mainnet fork against Lido's real queue, and 8 on a Base Sepolia fork
against real Morpho Blue, with real EIP-7702 delegations. CI runs the same command on every push.

## 3. Read (the 4 files that matter, about 590 lines in all)

| File | What to look at |
|---|---|
| [src/ErrandLido.sol](src/ErrandLido.sol) (Reactive mainnet) | `react()` at [:72](src/ErrandLido.sol#L72-L94): tracks the wallet's request NFTs, and on `WithdrawalsFinalized` sends one callback with the ids that are now claimable |
| [src/ErrandWallet.sol](src/ErrandWallet.sol) (the wallet's 7702 code on Ethereum) | `claimLido()` at [:61](src/ErrandWallet.sol#L61-L86): only the callback proxy may call, and only when Reactive says our ErrandLido sent it |
| [src/ErrandMorpho.sol](src/ErrandMorpho.sol) (Lasna) | `react()` at [:75](src/ErrandMorpho.sol#L75-L95): arms on the wallet's exit request, fires on every repay or deposit in the market, stands down when the wallet is out |
| [src/ErrandMorphoWallet.sol](src/ErrandMorphoWallet.sol) (the wallet's 7702 code on Base Sepolia) | `exitMorpho()` at [:106](src/ErrandMorphoWallet.sol#L106-L131): withdraws exactly what is free, or 0 instead of reverting |

## Questions you might ask

**How does the wallet know a callback really comes from its own Errand?**
Reactive's callback proxy overwrites the first argument of every callback with the reactive contract
that requested it. The wallet's code accepts these calls only from the proxy, and rejects any
requester but its own ErrandLido or ErrandMorpho
([`src/ErrandWallet.sol:62`](src/ErrandWallet.sol#L62), [`src/ErrandMorphoWallet.sol:107`](src/ErrandMorphoWallet.sol#L107)).
Tested in `test_rejectsErrandsFromOtherReactiveContracts` and `test_onlyTheProxyAndOnlyOurErrand`.

**What is the worst a forged callback could do?**
Claim the wallet's own finalized Lido requests to the wallet, or withdraw the wallet's own Morpho
position to the wallet, which is what the owner asked for anyway. Fees are capped per payment. The
delegated code has no path that sends funds anywhere else. See [Trust model](README.md#trust-model--limitations).

**How was the latency measured?**
For each round, the Base block of the trigger and the Base block of the callback, both read from the
chain. Base Sepolia makes a block every 0.2 s, and its timestamps only have whole seconds, so the
README gives both: timestamp Δ of 1 s every time, and 3–8 blocks (0.6–1.6 s). The 7 scripted rounds
are in [evidence/race-2026-11-24.json](evidence/race-2026-11-24.json); the live page reads every round,
including the ones visitors started.

**Why EIP-7702 and not a vault?**
A vault means moving your funds into someone else's contract. With 7702 the address, key and balance
stay yours, and Lido or Morpho see the withdrawal come from you. Signing a new authorization undoes it.

**Has a Lido claim happened on mainnet yet?**
Not yet, as of Nov 25. Everything up to the claim is live: ErrandLido on Reactive mainnet, the
delegated wallet, and request #142667 that ErrandLido is tracking. The claim fires when Lido finalizes
the request (Lido finalizes about daily). `./tools/check-live.sh` reports WAIT until then and PASS after.
The full loop with real Lido state already runs on a mainnet fork in CI.

**What's not real?**
The test tokens (tUSD, tETH) and the 1:1 price oracle on Base Sepolia are stand-ins we deployed
([src/testnet/](src/testnet/)); the market built on them is a real Morpho Blue market. Unit tests use a
mock of Reactive's system contract. The full list is in [What's real](README.md#whats-real).

**Two tracks?**
One engine, two errands, each with its own loop and proof: the Lido claim for **Set It and Forget It**
(Ethereum + Reactive mainnet) and the Morpho exit for **Every Second Counts** (Base Sepolia + Lasna,
with measured latency).
