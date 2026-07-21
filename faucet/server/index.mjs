import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import express from "express";
import { fromBech32, fromHex } from "@cosmjs/encoding";
import { DirectSecp256k1Wallet } from "@cosmjs/proto-signing";
import { SigningStargateClient, GasPrice } from "@cosmjs/stargate";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;

// EVM anvil forks: default hostnames match docker-compose service names.
const EVM_CHAINS = {
  base: process.env.BASE_RPC_URL || "http://anvil-base:8545",
  somnia: process.env.SOMNIA_RPC_URL || "http://anvil-somnia:8545",
  polygon: process.env.POLYGON_RPC_URL || "http://anvil-polygon:8545",
};

const LUMEN_RPC_URL = process.env.LUMEN_RPC_URL || "http://edgenet:26657";
const ONE_ETHER = 10n ** 18n; // 1000 ether drip added below

function isEvmAddress(a) {
  return /^0x[0-9a-fA-F]{40}$/.test(a);
}

function isLumenAddress(a) {
  try {
    return fromBech32(a).prefix === "euclid";
  } catch {
    return false;
  }
}

// Minimal JSON-RPC helper for the anvil forks.
async function rpc(url, method, params) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message || "rpc error");
  return data.result;
}

async function fundEvm(url, address) {
  const currentHex = await rpc(url, "eth_getBalance", [address, "latest"]);
  const next = BigInt(currentHex) + 1000n * ONE_ETHER;
  await rpc(url, "anvil_setBalance", [address, "0x" + next.toString(16)]);
  // anvil_setBalance is a state cheat, not a transaction, so there is no
  // real tx hash. Return the mined block hash as an acknowledgement.
  return await rpc(url, "eth_getBlockByNumber", ["latest", false]).then(
    (b) => b.hash
  );
}

// Anvil resumes a persisted state's own clock after a restart, so a fork
// that was down for hours comes back with its chain time lagging wall-clock
// by the same amount. Syncing mines one block stamped "now"; block-time
// mining then derives every later timestamp from it, so a single corrective
// block is enough. Timestamps only ratchet forward, hence the lag threshold:
// evm_setNextBlockTimestamp rejects a timestamp at or below the current tip.
const CLOCK_SYNC_LAG_THRESHOLD = 30; // seconds
const CLOCK_SYNC_INTERVAL =
  Number(process.env.CLOCK_SYNC_INTERVAL_SECONDS ?? 600); // 0 disables

async function syncClock(chain, url) {
  const block = await rpc(url, "eth_getBlockByNumber", ["latest", false]);
  const now = Math.floor(Date.now() / 1000);
  const lag = now - Number(BigInt(block.timestamp));
  if (lag <= CLOCK_SYNC_LAG_THRESHOLD) return { chain, lag, synced: false };
  await rpc(url, "evm_setNextBlockTimestamp", [now]);
  await rpc(url, "evm_mine", []);
  return { chain, lag, synced: true };
}

async function syncAllClocks() {
  return Promise.all(
    Object.entries(EVM_CHAINS).map(([chain, url]) =>
      syncClock(chain, url).catch((err) => ({
        chain,
        error: String(err.message || err),
      }))
    )
  );
}

async function fundLumen(address) {
  const pk = process.env.FAUCET_PRIVATE_KEY;
  if (!pk) throw new Error("FAUCET_PRIVATE_KEY not set");
  const wallet = await DirectSecp256k1Wallet.fromKey(fromHex(pk), "euclid");
  const [account] = await wallet.getAccounts();
  const client = await SigningStargateClient.connectWithSigner(
    LUMEN_RPC_URL,
    wallet,
    { gasPrice: GasPrice.fromString("0.015ualpha") }
  );
  const amount = [
    { denom: "ualpha", amount: "1000000000" },
    { denom: "usync", amount: "1000000000" },
  ];
  const tx = await client.sendTokens(account.address, address, amount, "auto");
  return tx.transactionHash;
}

const app = express();
app.use(express.json());

app.post("/api/faucet", async (req, res) => {
  const { chain, address } = req.body || {};
  try {
    if (chain === "lumen") {
      if (!isLumenAddress(address))
        return res.status(400).json({ error: "invalid euclid address" });
      return res.json({ txHash: await fundLumen(address) });
    }
    const url = EVM_CHAINS[chain];
    if (!url) return res.status(400).json({ error: "unknown chain" });
    if (!isEvmAddress(address))
      return res.status(400).json({ error: "invalid 0x address" });
    return res.json({ txHash: await fundEvm(url, address) });
  } catch (err) {
    return res.status(500).json({ error: String(err.message || err) });
  }
});

app.post("/api/sync-time", async (_req, res) => {
  res.json({ results: await syncAllClocks() });
});

app.use(express.static(join(__dirname, "..", "dist")));

if (CLOCK_SYNC_INTERVAL > 0) {
  setInterval(() => {
    syncAllClocks().then((results) => {
      const synced = results.filter((r) => r.synced);
      if (synced.length)
        console.log(
          `clock sync: ${synced.map((r) => `${r.chain} (+${r.lag}s)`).join(", ")}`
        );
      const failed = results.filter((r) => r.error);
      if (failed.length)
        console.error(
          `clock sync failed: ${failed.map((r) => `${r.chain}: ${r.error}`).join("; ")}`
        );
    });
  }, CLOCK_SYNC_INTERVAL * 1000);
}

app.listen(PORT, () => console.log(`faucet listening on :${PORT}`));
