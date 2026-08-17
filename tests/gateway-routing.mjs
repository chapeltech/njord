import { spawn } from "node:child_process";
import { createServer, request as httpRequest } from "node:http";

const repository = new URL("../", import.meta.url).pathname;
const events = [];
let gateway;
let control;
let book;

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

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
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

try {
  control = createServer(async (incoming, response) => {
    const body = await readBody(incoming);
    events.push({ adapter: "control", url: incoming.url, body });
    if (incoming.url === "/rpc/slow_control") await new Promise((done) => setTimeout(done, 300));
    if (incoming.url === "/rpc/huge_control") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify([{ payload: "x".repeat(2048) }]));
      return;
    }
    const payload = body ? JSON.parse(body) : {};
    const visible = payload.p_book_id === "trusted-book" || payload.p_book_id === "wrong-book";
    const result = incoming.url.startsWith("/rpc/shell_page") && payload.p_book_id
      ? (visible ? [{ component: "book_option", payload: { id: payload.p_book_id } }] : [])
      : [{ component: "control_result", payload }];
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(result));
  });
  const controlPort = await listen(control);

  book = createServer(async (incoming, response) => {
    const body = await readBody(incoming);
    events.push({ adapter: "book", url: incoming.url, body });
    const result = incoming.url === "/rpc/adapter_status"
      ? [{ database: "trusted-book", schema_version: 1 }]
      : [{ component: "book_result", payload: JSON.parse(body) }];
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(result));
  });
  const bookPort = await listen(book);

  const probe = createServer();
  const gatewayPort = await listen(probe);
  await close(probe);
  const origin = `http://127.0.0.1:${gatewayPort}`;
  const endpoint = `http://127.0.0.1:${bookPort}`;
  gateway = spawn(process.execPath, ["scripts/static-server.mjs"], {
    cwd: repository,
    env: {
      ...process.env,
      NJORD_UI_PORT: String(gatewayPort),
      NJORD_CONTROL_POSTGREST_URL: `http://127.0.0.1:${controlPort}`,
      NJORD_BOOK_POSTGREST_URLS: JSON.stringify({
        "trusted-book": endpoint,
        "wrong-book": endpoint,
      }),
      NJORD_MAX_CONCURRENT_REQUESTS: "2",
      NJORD_REQUEST_BODY_LIMIT: "1024",
      NJORD_UPSTREAM_BODY_LIMIT: "1024",
      NJORD_POSTGREST_JWT_SECRET: "gateway-routing-postgrest-jwt-secret-00000001",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let gatewayErrors = "";
  gateway.stderr.on("data", (chunk) => { gatewayErrors += chunk; });
  await waitForGateway(origin);
  events.length = 0;

  const queryRejected = await request(`${origin}/api/control/rpc/shell_page?language=en-GB`);
  assert(queryRejected.status === 400, `RPC query string returned ${queryRejected.status}, not 400`);
  assert(events.length === 0, "RPC query string reached an adapter");

  const controlResult = await request(`${origin}/api/control/rpc/shell_page`);
  assert(controlResult.status === 200, `explicit control route returned ${controlResult.status}`);
  assert(events.length === 1 && events[0].adapter === "control", "control route left the control adapter");
  assert(events[0].url === "/rpc/shell_page", "control route did not strip its gateway prefix");

  events.length = 0;
  const bookResult = await request(`${origin}/api/books/trusted-book/rpc/accounts_page`);
  assert(bookResult.status === 200, `explicit Book route returned ${bookResult.status}: ${bookResult.body}`);
  assert(events.map((event) => `${event.adapter}:${event.url}`).join(",")
    === "control:/rpc/shell_page,book:/rpc/adapter_status,book:/rpc/accounts_page",
  "Book route did not authorize, identify, then invoke its adapter");
  assert(JSON.parse(events.at(-1).body).p_book_id === "trusted-book", "Book route did not inject its trusted handle");

  events.length = 0;
  const unscoped = await request(`${origin}/rpc/accounts_page`, '{"p_book_id":"trusted-book"}');
  assert(unscoped.status === 404, `unscoped RPC route returned ${unscoped.status}, not 404`);
  assert(events.length === 0, "unscoped RPC route reached an adapter");

  events.length = 0;
  const mismatch = await request(
    `${origin}/api/books/trusted-book/rpc/accounts_page`,
    '{"p_book_id":"another-book"}',
  );
  assert(mismatch.status === 400 && mismatch.body.includes("BOOK_ROUTE_MISMATCH"), "route/body mismatch did not fail closed");
  assert(events.length === 0, "route/body mismatch reached an adapter");

  const denied = await request(`${origin}/api/books/denied-book/rpc/accounts_page`);
  assert(denied.status === 403 && denied.body.includes("BOOK_ACCESS_DENIED"), "catalogue denial was not a 403");
  assert(!events.some((event) => event.adapter === "book"), "denied Book route reached a Book adapter");

  events.length = 0;
  const wrongDatabase = await request(`${origin}/api/books/wrong-book/rpc/accounts_page`);
  assert(
    wrongDatabase.status === 502 && wrongDatabase.body.includes("BOOK_ADAPTER_DATABASE_MISMATCH"),
    "misconfigured Book adapter did not fail its database identity check",
  );
  assert(!events.some((event) => event.url === "/rpc/accounts_page"), "identity mismatch reached the requested Book RPC");

  events.length = 0;
  const forcedControl = await request(
    `${origin}/api/control/rpc/accounts_page`,
    '{"p_book_id":"trusted-book"}',
  );
  assert(forcedControl.status === 200, `forced control route returned ${forcedControl.status}`);
  assert(events.length === 1 && events[0].adapter === "control", "explicit control route used a body-selected Book");

  const unknown = await request(`${origin}/api/books/trusted-book/accounts_page`);
  assert(unknown.status === 404, `malformed API route returned ${unknown.status}, not 404`);

  const slowOne = request(`${origin}/api/control/rpc/slow_control`);
  const slowTwo = request(`${origin}/api/control/rpc/slow_control`);
  await new Promise((resolve) => setTimeout(resolve, 50));
  const overloaded = await request(`${origin}/api/control/rpc/shell_page`);
  assert(overloaded.status === 503, `global concurrency limit returned ${overloaded.status}, not 503`);
  assert((await slowOne).status === 200 && (await slowTwo).status === 200, "admitted requests did not complete");

  const oversizedRequest = await request(`${origin}/api/control/rpc/shell_page`, `{"p":"${"x".repeat(1100)}"}`);
  assert(oversizedRequest.status === 413, `oversized request returned ${oversizedRequest.status}, not 413`);
  const oversizedResponse = await request(`${origin}/api/control/rpc/huge_control`);
  assert(oversizedResponse.status === 502 && oversizedResponse.body.includes("UPSTREAM_RESPONSE_TOO_LARGE"), "oversized upstream response was not rejected");

  process.stdout.write("ok - explicit-only gateway routing and adapter identity passed\n");
} catch (error) {
  process.stderr.write(`${error.stack}\n`);
  throw error;
} finally {
  if (gateway && gateway.exitCode === null) {
    gateway.kill("SIGTERM");
    await new Promise((resolve) => gateway.once("exit", resolve));
  }
  if (control?.listening) await close(control);
  if (book?.listening) await close(book);
}
