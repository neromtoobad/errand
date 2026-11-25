# Submission text (DoraHacks, Reactive Omni Buildathon)

Plan: one repo, entered as **two BUIDLs**, one per track, each with its own loop and proof. The rules
don't say whether one project may enter two tracks, so ask the organizer before submitting. If the
answer is "one track only", submit the Every Second Counts entry and keep the Lido errand as a second
section of its description.

Shared fields:
- **Name:** Errand
- **Tagline:** Your wallet runs its own errands.
- **GitHub:** https://github.com/neromtoobad/errand
- **Live demo:** https://errand.nerom.site
- **Video:** (link once recorded, under 3 minutes)
- **Check it in 2 minutes:** https://github.com/neromtoobad/errand/blob/main/JUDGES.md

---

## Entry 1: Every Second Counts (Morpho exit, Base Sepolia + Lasna)

**One line:** A lender stuck in a fully borrowed Morpho market gets their money back the second
someone repays: their own wallet withdraws it about 1 s later, triggered by Reactive Network.

**Description**

When every coin in a lending market is borrowed, lenders can't withdraw. Each repayment frees a
little, and the first lender to send a withdrawal gets it. Today that means watching the market or
running a bot that holds your key.

With Errand, the lender signs one EIP-7702 authorization and asks to exit once. From then on:
1. Someone repays or deposits in the market on Base Sepolia.
2. ErrandMorpho on Reactive Lasna sees the event and requests a callback.
3. The lender's own wallet withdraws exactly what was freed.

It repeats on every repay or deposit until the lender is fully out, then stands down by itself.

**Measured latency (full loop, onchain):** across 9 rounds, the callback landed 3–8 Base blocks
after the trigger (0.6–1.6 s, median 1.0 s). In the 7 scripted rounds
([evidence/race-2026-11-24.json](https://github.com/neromtoobad/errand/blob/main/evidence/race-2026-11-24.json))
the block timestamp moved by 1 s every time. We ran 2 more after re-arming the demo for the live page: an
exit request, and a deposit the page followed live. All 9 were sent by us; the page shows any round a
visitor runs. Each round links its trigger, reactive and callback txs.

**Try it:** at errand.nerom.site, deposit 5–50 test tUSD (one transaction on Base Sepolia) and time how
fast the lender's wallet takes it back.

**Why Reactive:** the withdrawal has to come from the lender's own address within seconds of an event
on Base. Reactive turns Morpho's own `Repay`/`Supply` events into the trigger, and its callback proxy
tells the wallet which reactive contract sent the call, so the wallet obeys only its own Errand. No
keeper holds the key, and no server polls.

**Contracts**
| Contract | Chain | Address |
|---|---|---|
| ErrandMorpho (reactive) | Lasna 5318007 | [0x6fBf9C16ed3e75eDA1b5A8Cc600cbA25B1226651](https://lasna.reactscan.net/address/0x6fBf9C16ed3e75eDA1b5A8Cc600cbA25B1226651) (Sourcify verified) |
| ErrandMorphoWallet (7702 code) | Base Sepolia | [0x0D671866021CE29099F9aEc9bfF2d93D6C155CBe](https://base-sepolia.blockscout.com/address/0x0D671866021CE29099F9aEc9bfF2d93D6C155CBe) (Sourcify verified) |
| DemoDeposit (the page's deposit button) | Base Sepolia | [0x6D05eac4aDEA141AC9fa39fED6C1Bc896873F648](https://base-sepolia.blockscout.com/address/0x6D05eac4aDEA141AC9fa39fED6C1Bc896873F648) (Sourcify verified) |
| Lender wallet (delegated) | Base Sepolia | [0x529d216723506E3390c9c6832b86fd78A805d4EC](https://base-sepolia.blockscout.com/address/0x529d216723506E3390c9c6832b86fd78A805d4EC) |
| Morpho Blue (real) | Base Sepolia | 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb |

**Full loop tx hashes (origin → reactive → callback)**
- repay 10: [0x02df3310…](https://base-sepolia.blockscout.com/tx/0x02df331060a1e727429d94a3ac4c545f2ce6865f6ad5c13f41afafdf6e73c69b) → [0x22c12746…](https://lasna.reactscan.net/tx/0x22c127463641ef5c660c25912e2a99748c133bc0ce8c2cd5ba58472773712811) → [0xa71e9fd0…](https://base-sepolia.blockscout.com/tx/0xa71e9fd069d2554ee539e42ddb01800c8e056c81a4ccf9b147349abbfeeefcf5) (3 blocks)
- repay rest, wallet fully out: [0x7e760c45…](https://base-sepolia.blockscout.com/tx/0x7e760c453b31325e430f5e938bb462b691a4906f030c00c55bbf9abbd8997262) → [0x7fe2c770…](https://lasna.reactscan.net/tx/0x7fe2c770033386be8ade5c1ba8ce3b558157e31f1700e82a43473821aa5c00cb) → [0xdcb45497…](https://base-sepolia.blockscout.com/tx/0xdcb454971c5215e04d576be777ae40cff19db41da2080b618707ab64d1b9ed89) (5 blocks)
- deposit followed by the live page (round #9, sent by us): [0x0c6507b5…](https://base-sepolia.blockscout.com/tx/0x0c6507b5c512c57f6b56ca7504b331bda43c2be03a9ae0aed9f616165873e6c2) → [0xdcecb908…](https://lasna.reactscan.net/tx/0xdcecb9089f651a65cd861b03894a9a2c0900215566379304e64b510f57c2a834) → [0x94cd802a…](https://base-sepolia.blockscout.com/tx/0x94cd802ae8c8b9425a76fe523b2b3c0ca34ece8576494dd3a193a21a212cbdd1) (8 blocks)
- All rounds: the [latency table in the README](https://github.com/neromtoobad/errand#latency-measured-on-base-sepolia) and the live page.

**What's test-only:** tUSD, tETH and the 1:1 price oracle are stand-ins we deployed. The market built
on them is a real Morpho Blue market, and Reactive Lasna is the real testnet.

---

## Entry 2: Set It and Forget It (Lido claim, Ethereum + Reactive mainnet)

**One line:** Your wallet claims its own Lido withdrawals the moment Lido finalizes them, with your
laptop off, no bot, and no key handed over.

**Description**

Lido withdrawals take two transactions: request, then claim once Lido finalizes. Nothing claims for
you. On Nov 24 we measured **37,306 ETH** sitting finalized but unclaimed in Lido's queue, and 27% of
the last 2,000 finalized requests still unclaimed, a median of 7.6 days after they were made
([tools/measure-unclaimed.py](https://github.com/neromtoobad/errand/blob/main/tools/measure-unclaimed.py)).

Errand turns it on once:
1. The wallet signs one EIP-7702 authorization pointing at ErrandWallet. Address, key and balance stay the same.
2. ErrandLido on Reactive mainnet tracks every Lido request NFT the wallet holds.
3. On `WithdrawalsFinalized`, it sends one callback with the requests that are now claimable.
4. The wallet calls `claimWithdrawals` on itself, and the ETH lands in the wallet.

The wallet accepts the call only through Reactive's callback proxy, and only from its own ErrandLido.
The delegated code can only claim to the wallet and pay capped fees.

**Live on mainnet:** ErrandLido on Reactive mainnet (Sourcify verified), the wallet delegated on
Ethereum, and a real Lido request (#142667) that ErrandLido is tracking. The claim fires when Lido
finalizes the request. (Update this line with the claim tx once it lands.)

**Contracts**
| Contract | Chain | Address |
|---|---|---|
| ErrandLido (reactive) | Reactive mainnet 1597 | [0x6fBf9C16ed3e75eDA1b5A8Cc600cbA25B1226651](https://reactscan.net/address/0x6fBf9C16ed3e75eDA1b5A8Cc600cbA25B1226651) (Sourcify verified) |
| ErrandWallet (7702 code) | Ethereum | [0x08e2A31B676214E306F78aF5Ad1Aa3883eDe9f05](https://etherscan.io/address/0x08e2A31B676214E306F78aF5Ad1Aa3883eDe9f05) (Sourcify verified) |
| Wallet (delegated) | Ethereum | [0x529d216723506E3390c9c6832b86fd78A805d4EC](https://etherscan.io/address/0x529d216723506E3390c9c6832b86fd78A805d4EC) |

**Loop tx hashes (origin → reactive → callback)**
- Lido request: [0xf2687d9f…](https://etherscan.io/tx/0xf2687d9ff17d8e2c465539feb09f233fc094416bef4a1ee0a62c1efd848cb237) → ErrandLido tracks it: [0x07116c76…](https://reactscan.net/tx/0x07116c760fe004f14a6c50defcc2effc6179aff81666b26372910e9f72ca0415)
- Lido finalization → claim callback: (add once it lands)
- 7702 delegation: [0x4c2d10d3…](https://etherscan.io/tx/0x4c2d10d363da3b30f678e126e20b7b02ba2549856e457991c1d3cc37124a4910)

---

## AI usage / prior work (both entries)

Built with Claude Code. Under our direction it wrote the contracts, tests, scripts, the live page and
the docs, and it ran the deployments. We chose the idea, the design and the tradeoffs, funded the
wallets and reviewed the results. No AI runs inside Errand. All code was written during the event (first
commit Nov 23). The only outside code is forge-std and reactive-lib-omni, as dependencies.
