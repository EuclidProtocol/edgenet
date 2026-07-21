import { useState } from "react";

const CHAINS = [
  { id: "lumen", label: "Lumen (euclid...)" },
  { id: "base", label: "Base (anvil fork)" },
  { id: "somnia", label: "Somnia (anvil fork)" },
  { id: "polygon", label: "Polygon (anvil fork)" },
];

type Result = { ok: boolean; text: string };

type SyncResult = {
  chain: string;
  lag?: number;
  synced?: boolean;
  error?: string;
};

export default function App() {
  const [chain, setChain] = useState("lumen");
  const [address, setAddress] = useState("");
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<Result | null>(null);
  const [syncing, setSyncing] = useState(false);
  const [syncResult, setSyncResult] = useState<Result | null>(null);

  async function syncTime() {
    setSyncing(true);
    setSyncResult(null);
    try {
      const res = await fetch("/api/sync-time", { method: "POST" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Request failed");
      const text = (data.results as SyncResult[])
        .map((r) =>
          r.error
            ? `${r.chain}: failed (${r.error})`
            : r.synced
              ? `${r.chain}: synced (was ${r.lag}s behind)`
              : `${r.chain}: already in sync (${r.lag}s)`
        )
        .join(" · ");
      const ok = (data.results as SyncResult[]).every((r) => !r.error);
      setSyncResult({ ok, text });
    } catch (err) {
      setSyncResult({ ok: false, text: String(err) });
    } finally {
      setSyncing(false);
    }
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setResult(null);
    try {
      const res = await fetch("/api/faucet", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ chain, address: address.trim() }),
      });
      const data = await res.json();
      if (res.ok && data.txHash) {
        setResult({ ok: true, text: `Sent. tx: ${data.txHash}` });
      } else {
        setResult({ ok: false, text: data.error || "Request failed" });
      }
    } catch (err) {
      setResult({ ok: false, text: String(err) });
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="card">
      <h1>Edgenet Faucet</h1>
      <p className="sub">Drip test funds to an address on a forked chain.</p>
      <form onSubmit={submit}>
        <label htmlFor="chain">Chain</label>
        <select id="chain" value={chain} onChange={(e) => setChain(e.target.value)}>
          {CHAINS.map((c) => (
            <option key={c.id} value={c.id}>
              {c.label}
            </option>
          ))}
        </select>

        <label htmlFor="address">Address</label>
        <input
          id="address"
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          placeholder={chain === "lumen" ? "euclid1..." : "0x..."}
          autoComplete="off"
        />

        <button type="submit" disabled={loading || !address.trim()}>
          {loading ? "Sending..." : "Request funds"}
        </button>
      </form>

      {result && (
        <div className={`result ${result.ok ? "ok" : "err"}`}>{result.text}</div>
      )}

      <div className="sync">
        <button type="button" className="secondary" onClick={syncTime} disabled={syncing}>
          {syncing ? "Syncing..." : "Sync fork clocks"}
        </button>
        <p className="sub">
          Set the EVM forks' chain time to the current wall-clock time.
        </p>
      </div>

      {syncResult && (
        <div className={`result ${syncResult.ok ? "ok" : "err"}`}>
          {syncResult.text}
        </div>
      )}
    </div>
  );
}
