# Demo video script (target 2:30, hard limit 3:00)

Rule: every shot is the real page or a real explorer page. No mock-ups, and nothing sped up without
saying so on screen. Record a fresh live round on the day so the newest row is the one in the video.

| Time | Screen | Voice |
|---|---|---|
| 0:00–0:12 | errand.nerom.site hero, the lender card showing 990 tUSD stuck | "This lender wants their money back, but every coin in this market is borrowed, so they can't withdraw." |
| 0:12–0:25 | Scroll slowly over the "No bot / No server / No key handed over" ticks and the timing board | "They asked once. Now, whenever someone repays or deposits, Errand has their own wallet take back what was freed. Let's free some." |
| 0:25–0:40 | Pick 10 tUSD, press Deposit, confirm in the wallet | "I deposit 10 test tUSD into the market. That's one transaction on Base Sepolia." |
| 0:40–0:55 | The arc: courier leaves Base Sepolia, lights Reactive Lasna, lands back on Base Sepolia; the clock stops | "My deposit lands. Errand sees it on Reactive Network and calls back into the lender's wallet, which withdraws the 10. About a second and a half, onchain." |
| 0:55–1:10 | Click the three links in the result: Base trigger, Lasna reactive tx, Base callback (Blockscout and Reactscan) | "Three transactions, all public: my deposit, Errand's reaction on Lasna, and the withdrawal from the lender's own address." |
| 1:10–1:25 | Scroll to the speed chart and rounds table | "Every round so far, read straight from the chains. Median: one second from trigger to withdrawal." |
| 1:25–1:45 | "How it works" steps, then the bot-vs-Errand table | "How: the wallet signs one EIP-7702 authorization, so it can take calls from Reactive's callback proxy, and only from its own Errand. A keeper bot would need your key. Errand never does." |
| 1:45–2:10 | Scroll to "Lido claims on mainnet", then Etherscan: the delegation tx and Lido request #142667; Reactscan: ErrandLido's Tracking event (or the claim tx, if it has landed) | "The same idea on Ethereum mainnet. Thirty-seven thousand ETH sits finalized and unclaimed in Lido's queue. This wallet's Lido withdrawal gets claimed the moment Lido finalizes it, by the wallet itself." |
| 2:10–2:25 | Terminal: `./tools/check-live.sh` scrolling to "23 passed, 0 failed" | "Every claim in the README is checked live against the chains. One command." |
| 2:25–2:30 | Back to the hero, logo | "Errand. Your wallet runs its own errands." |

Before recording:
- Update the Lido shot and line if the claim has landed (it shows on the page and in `deployments/mainnet.json`).
- Make sure ErrandMorpho has lREACT for fees (about 0.026 per round) and the lender still has tUSD lent (`script/testnet/rearm-demo.sh`).
- Run `./tools/check-live.sh` on the day and use that day's numbers in the voice line.
- Build the video with the `video-creative-draft` house rules (voice, music, captions).
