#!/usr/bin/env node
/**
 * rr — Royalty Router CLI
 *   rr launch <intent.json>        build, simulate, and send a launch (RPC, PK env; FACTORY env or deployments)
 *   rr sweep <router...>           sweep routers whose pending clears MIN_CLAIM (RPC, PK)
 *   rr status <router>             pending / minClaim / route
 *   rr quote <intent.json>         offline: struct, value, approvals, predicted token, seed consumed
 *   rr advise <intent.json>        offline: where the intent departs from the model's recommended defaults
 *   rr venue <token> buy|sell <amount> [secondary] [fee] [spacing]   live: curve vs pool quote + crossover size (RPC)
 */
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, formatEther, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { deployments } from "./addresses.js";
import { buildLaunch, buildLaunchOffline, simulateLaunch, launch, ensureApprovals, type LaunchIntent } from "./launch.js";
import { routerStatus, sweep } from "./router.js";
import { adviseIntent } from "./defaults.js";
import { readVenueState, quoteVenues, crossoverSize } from "./venue.js";
import { poolKeyFor } from "./launch.js";
import { ZERO } from "./addresses.js";

const big = (k: string, v: unknown) => (typeof v === "string" && /^\d+n?$/.test(v) && ["rangeTo", "price", "curveMint", "tokens", "secondary", "minClaim", "buybackShareWad", "compoundShareWad", "minMain", "minSecondary"].includes(k) ? BigInt(v.replace(/n$/, "")) : v);
const loadIntent = (p: string): LaunchIntent => JSON.parse(readFileSync(p, "utf8"), big);
const json = (o: unknown) => JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2);

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const rpc = process.env.RPC;
  const client = rpc ? createPublicClient({ transport: http(rpc) }) : undefined;
  const chainId = client ? await client.getChainId() : 8453;
  const d = { ...deployments[chainId], factory: (process.env.FACTORY as Address | undefined) ?? deployments[chainId]?.factory };
  if (!d.bond) throw new Error(`no deployment for chain ${chainId}`);

  if (cmd === "quote") {
    const b = buildLaunchOffline(d, loadIntent(rest[0]), 0n);
    console.log(json({ ...b, value: `${b.value} (+ creation fee at send time)` }));
    return;
  }
  if (cmd === "advise") {
    const a = adviseIntent(loadIntent(rest[0]));
    console.log(a.length ? a.map(x => `${x.level.toUpperCase()} ${x.code}: ${x.message}`).join("\n") : "matches the recommended defaults");
    return;
  }
  if (!client) throw new Error("RPC env required");
  if (cmd === "venue") {
    const [token, side, amount, secondary, fee, spacing] = rest;
    if (side !== "buy" && side !== "sell") throw new Error("side must be buy or sell");
    const key = poolKeyFor(d, token as Address, (secondary as Address | undefined) ?? ZERO, Number(fee ?? 3000), Number(spacing ?? 60));
    const v = await readVenueState(client, d, token as Address, key);
    const q = quoteVenues(v, side, BigInt(amount));
    const cap = side === "buy" ? BigInt(amount) * 1000n : v.curve.supply;
    const x = crossoverSize(v, side, cap);
    console.log(json({ ...q, crossover: x === null ? "curve always wins" : x === Infinity ? `pool wins up to ${cap}` : x }));
    return;
  }
  if (cmd === "status") {
    console.log(json(await routerStatus(client, rest[0] as Address)));
    return;
  }
  const pk = process.env.PK as `0x${string}` | undefined;
  if (!pk) throw new Error("PK env required");
  const account = privateKeyToAccount(pk);
  const wallet = createWalletClient({ account, transport: http(rpc) });

  if (cmd === "launch") {
    const b = await buildLaunch(client, d, loadIntent(rest[0]));
    console.error(`predicted token ${b.predictedToken}\nseed consumed: ${b.seedConsumed.tokens} tokens, ${formatEther(b.seedConsumed.secondary)} secondary\nvalue ${formatEther(b.value)} ETH`);
    const approved = await ensureApprovals(client, wallet, b);
    if (approved.length) console.error(`approvals sent: ${approved.join(", ")}`);
    const sim = await simulateLaunch(client, d, b, account.address);
    console.error(`simulation ok: token ${sim.token} router ${sim.router}`);
    const res = await launch(client, wallet, d, b);
    console.log(json(res));
    return;
  }
  if (cmd === "sweep") {
    for (const r of rest as Address[]) {
      const s = await routerStatus(client, r);
      if (!s.ready) { console.log(`${r} pending=${s.pending} < min=${s.minClaim}, skipped`); continue; }
      const res = await sweep(client, wallet, r);
      console.log(`${r} swept pending=${s.pending} tx=${res.hash} ${res.status}`);
    }
    return;
  }
  console.error("usage: rr quote|launch <intent.json> | rr status <router> | rr sweep <router...>");
  process.exit(1);
}
main().catch((e) => { console.error(e.message ?? e); process.exit(1); });
