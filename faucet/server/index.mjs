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

app.use(express.static(join(__dirname, "..", "dist")));

app.listen(PORT, () => console.log(`faucet listening on :${PORT}`));
