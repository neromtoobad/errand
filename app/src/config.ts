import { defineChain, parseAbi, type Address, type Hex } from "viem";
import { baseSepolia } from "viem/chains";
import testnet from "../../deployments/testnet.json";
import mainnet from "../../deployments/mainnet.json";

export const lasna = defineChain({
  id: 5318007,
  name: "Reactive Lasna",
  nativeCurrency: { name: "Lasna REACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: { default: { http: ["https://lasna-rpc.rnk.dev/"] } },
  blockExplorers: { default: { name: "Reactscan", url: "https://lasna.reactscan.net" } },
});

export { baseSepolia };

export const RPC = {
  base: "https://sepolia.base.org",
  lasna: "https://lasna-rpc.rnk.dev/",
  // Ethereum RPCs that answer browser (CORS) requests; publicnode refuses them.
  ethereum: ["https://eth.drpc.org", "https://1rpc.io/eth"],
  reactive: "https://mainnet-rpc.rnk.dev/",
};

export const EXPLORER = {
  base: "https://base-sepolia.blockscout.com",
  lasna: "https://lasna.reactscan.net",
  reactive: "https://reactscan.net",
  ethereum: "https://eth.blockscout.com",
};

/** Everything below comes from the repo's deployment records, so the page and the README can't drift. */
export const D = {
  wallet: testnet.wallet as Address,
  morpho: testnet.base.morpho as Address,
  marketId: testnet.base.marketId as Hex,
  loanToken: testnet.base.loanToken as Address,
  collateralToken: testnet.base.collateralToken as Address,
  oracle: testnet.base.oracle as Address,
  walletCode: testnet.base.ErrandMorphoWallet as Address,
  callbackProxy: testnet.base.callbackProxy as Address,
  errand: testnet.reactive.ErrandMorpho as Address,
  demoDeposit: testnet.demo.DemoDeposit as Address,
  /** ErrandMorpho's deploy block on Lasna: history starts here. */
  errandFromBlock: 9149663n,
  lltv: 860000000000000000n,
};

export const LIDO = {
  wallet: mainnet.wallet as Address,
  errandLido: mainnet.reactive.ErrandLido as Address,
  ethereumWalletCode: (mainnet as { ethereum?: { ErrandWallet?: string } }).ethereum?.ErrandWallet as Address | undefined,
  delegationTx: (mainnet as { ethereum?: { delegationTx?: string } }).ethereum?.delegationTx,
  requestTx: (mainnet as { lido?: { requestTx?: string } }).lido?.requestTx,
  claimTx: (mainnet as { lido?: { claimTx?: string } }).lido?.claimTx,
};

/** Base Sepolia makes a block every 0.2 s; block timestamps have 1 s resolution. */
export const BASE_BLOCK_SECONDS = 0.2;

export const morphoAbi = parseAbi([
  "function market(bytes32 id) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)",
  "function position(bytes32 id, address user) view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)",
  "event Supply(bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares)",
  "event Repay(bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares)",
]);

export const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)"]);

export const errandMorphoAbi = parseAbi([
  "function armed() view returns (bool)",
  "function errandsSent() view returns (uint256)",
  "event ErrandSent(uint256 indexed errandNumber, uint256 triggeredByTxHash)",
]);

export const walletAbi = parseAbi([
  "event ExitRequested(bytes32 indexed marketId)",
  "event ExitProgress(bytes32 indexed marketId, uint256 withdrawn, uint256 remainingShares)",
]);

export const demoDepositAbi = parseAbi([
  "function deposit(uint256 assets) returns (uint256 shares)",
  "error AmountOutOfRange(uint256 amount)",
]);

export const errandLidoAbi = parseAbi(["function tracked() view returns (uint256[])"]);
