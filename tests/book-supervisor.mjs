import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repository = new URL("../", import.meta.url).pathname;
const temporary = await mkdtemp(join(tmpdir(), "njord-supervisor-test."));
const startsLog = join(temporary, "starts.jsonl");
let control;
let gateway;
let gatewayErrors = "";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function request(url, body = "{}") {
  return new Promise((resolve, reject) => {
    const outgoing = httpRequest(url, {
      method: "POST",
      headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) },
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    outgoing.on("error", reject);
    outgoing.end(body);
  });
}

async function starts() {
  try {
    return (await readFile(startsLog, "utf8")).trim().split("\n").filter(Boolean).map(JSON.parse);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

async function waitForGateway(origin) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (gateway.exitCode !== null) throw new Error("Gateway exited during startup");
    try {
      const response = await request(`${origin}/api/control/rpc/shell_page`);
      if (response.status) return;
    } catch {
      // Startup briefly refuses connections.
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("Gateway did not start");
}

const fakePostgrest = join(temporary, "fake-postgrest.mjs");
await writeFile(fakePostgrest, `#!/usr/bin/env node
import { appendFile } from "node:fs/promises";
import { createServer } from "node:http";
const mainPort = Number(process.env.PGRST_SERVER_PORT);
const adminPort = Number(process.env.PGRST_ADMIN_SERVER_PORT);
const book = decodeURIComponent(new URL(process.env.PGRST_DB_URI).pathname.slice(1));
await appendFile(process.env.NJORD_TEST_POSTGREST_LOG, JSON.stringify({
  book,
  pool: process.env.PGRST_DB_POOL,
  databaseUri: process.env.PGRST_DB_URI,
  leakedParentSecret: process.env.NJORD_TEST_PARENT_SECRET || null,
}) + "\\n");
const main = createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (request.url === "/rpc/slow_page") await new Promise((done) => setTimeout(done, 500));
  const result = request.url === "/rpc/adapter_status"
    ? [{ database: book, schema_version: 2 }]
    : [{ component: "book_result", payload: { book } }];
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify(result));
});
const admin = createServer((request, response) => response.writeHead(200).end("ready"));
await Promise.all([
  new Promise((resolve) => main.listen(mainPort, "127.0.0.1", resolve)),
  new Promise((resolve) => admin.listen(adminPort, "127.0.0.1", resolve)),
]);
let closing = false;
function close() {
  if (closing) return;
  closing = true;
  Promise.all([
    new Promise((resolve) => main.close(resolve)),
    new Promise((resolve) => admin.close(resolve)),
  ]).then(() => process.exit(0));
}
process.on("SIGTERM", close);
process.on("SIGINT", close);
`);
await chmod(fakePostgrest, 0o700);

try {
  control = createServer(async (incoming, response) => {
    const chunks = [];
    for await (const chunk of incoming) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    const result = payload.p_book_id
      ? [{ component: "book_option", payload: { id: payload.p_book_id } }]
      : [];
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(result));
  });
  const controlPort = await listen(control);

  const probe = createServer();
  const gatewayPort = await listen(probe);
  await close(probe);
  const origin = `http://127.0.0.1:${gatewayPort}`;
  gateway = spawn(process.execPath, ["scripts/static-server.mjs"], {
    cwd: repository,
    env: {
      ...process.env,
      NODE_ENV: "test",
      POSTGREST_BIN: fakePostgrest,
      NJORD_TEST_POSTGREST_LOG: startsLog,
      NJORD_TEST_PARENT_SECRET: "must-not-reach-postgrest",
      NJORD_UI_PORT: String(gatewayPort),
      NJORD_CONTROL_POSTGREST_URL: `http://127.0.0.1:${controlPort}`,
      NJORD_MANAGE_BOOK_DATABASES: "1",
      NJORD_BOOK_SHUTDOWN_SECONDS: "2",
      NJORD_BOOK_POSTGREST_POOL_SIZE: "2",
      NJORD_MAX_BOOK_ADAPTERS: "1",
      NJORD_POSTGREST_JWT_SECRET: "book-supervisor-postgrest-jwt-secret-0000001",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  gateway.stderr.on("data", (chunk) => { gatewayErrors += chunk; });
  await waitForGateway(origin);

  const coldRequests = Array.from({ length: 8 }, () => (
    request(`${origin}/api/books/managed-book/rpc/accounts_page`)
  ));
  const coldResults = await Promise.all(coldRequests);
  assert(coldResults.every((result) => result.status === 200), `concurrent cold start failed: ${gatewayErrors}`);
  let processStarts = await starts();
  assert(processStarts.length === 1, `concurrent cold start launched ${processStarts.length} adapters`);
  assert(processStarts[0].pool === "2", "managed Book adapter did not receive the bounded pool size");
  assert(processStarts[0].databaseUri.endsWith("?user=njord_authenticator"), "managed adapter did not use the dedicated authenticator");
  assert(processStarts[0].leakedParentSecret === null, "managed adapter inherited an unrelated parent secret");

  const capped = await request(`${origin}/api/books/second-book/rpc/accounts_page`);
  assert(capped.status === 503 && capped.body.includes("BOOK_ADAPTER_LIMIT"), "resident Book adapter limit did not fail closed");

  await new Promise((resolve) => setTimeout(resolve, 1300));
  const reused = await request(`${origin}/api/books/managed-book/rpc/accounts_page`);
  assert(reused.status === 200, `resident adapter could not be reused: ${reused.body}`);
  processStarts = await starts();
  assert(processStarts.length === 1, `resident adapter unexpectedly restarted ${processStarts.length} times`);

  const slowRequest = request(`${origin}/api/books/managed-book/rpc/slow_page`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  gateway.kill("SIGTERM");
  const slowResult = await slowRequest;
  assert(slowResult.status === 200, "graceful shutdown interrupted an in-flight Book request");
  await Promise.race([
    new Promise((resolve) => gateway.once("exit", resolve)),
    new Promise((_, reject) => setTimeout(() => reject(new Error("Gateway did not finish graceful shutdown")), 3000)),
  ]);

  process.stdout.write("ok - managed Book adapter lifecycle passed\n");
} catch (error) {
  process.stderr.write(`${gatewayErrors || "(no gateway errors)"}\n`);
  throw error;
} finally {
  if (gateway && gateway.exitCode === null) {
    gateway.kill("SIGKILL");
    await new Promise((resolve) => gateway.once("exit", resolve));
  }
  if (control?.listening) await close(control);
  await rm(temporary, { recursive: true, force: true });
}
