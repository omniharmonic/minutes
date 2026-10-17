// Test-only: actual Prism HTTP app, isolated SQLite and a synthetic in-memory vault.
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const serverRoot = new URL("../../../integrations/prism-current/apps/server/", import.meta.url);
const require = createRequire(new URL("package.json", serverRoot));
const { serve } = await import(require.resolve("@hono/node-server"));
if (process.env.DB_PATH !== ":memory:" || process.env.PARACHUTE_URL !== "http://vault.test") {
  throw new Error("Contract fixture requires .env.test and an in-memory database");
}
const { createApp } = await import(new URL("src/app.ts", serverRoot).href);
const { db } = await import(new URL("src/db.ts", serverRoot).href);
const { issueDeviceToken } = await import(new URL("src/auth/device.ts", serverRoot).href);
const { installFakeVault, resetDb } = await import(new URL("test/helpers.ts", serverRoot).href);
resetDb();
const vault = installFakeVault();
const fakeFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
  if (url.hostname !== "vault.test") throw new Error("Contract fixture blocked external network");
  return fakeFetch(input, init);
};
const issued = issueDeviceToken("owner@test.local", "Swift contract fixture", "minutes-native");
db.prepare("INSERT INTO minutes_grants(device_id,vault_id,created_at) VALUES(?,?,?)")
  .run(issued.id, "primary", Date.now());
const readyPath = process.env.MINUTES_PRISM_CONTRACT_READY;
const tokenPath = process.env.MINUTES_PRISM_CONTRACT_TOKENFILE;
if (!readyPath || !tokenPath) throw new Error("Missing isolated fixture paths");
writeFileSync(tokenPath, issued.token, { mode: 0o600 });
const app = createApp();
const server = serve({ fetch: app.fetch, hostname: "127.0.0.1", port: 0 }, info => {
  writeFileSync(readyPath, JSON.stringify({ origin: `http://127.0.0.1:${info.port}` }), { mode: 0o600 });
  console.log(`Synthetic Prism HTTP fixture ready on 127.0.0.1:${info.port}`);
});
process.on("SIGTERM", () => {
  console.log(`Synthetic vault retained ${vault.notes.size} notes; real vault access was blocked.`);
  server.close(() => { vault.restore(); db.close(); process.exit(0); });
});
