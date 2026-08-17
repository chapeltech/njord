import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { spawn } from "node:child_process";

const repository = new URL("../", import.meta.url).pathname;
const temporary = await mkdtemp(join(tmpdir(), "njord-oauth-test."));
const psqlLog = join(temporary, "psql.jsonl");
const sessionSecret = "session-secret-for-local-oauth-tests-0001";
const jwtSecret = "postgrest-jwt-secret-for-local-tests-001";
const clientId = "local-client";
const clientSecret = "local-client-secret";
const expectedIdentity = { id: 424242, login: "Elric", name: "Elric Example" };
let gateway;
let provider;
let upstream;
let authorizeParameters;
let tokenRequests = 0;
let userRequests = 0;
const upstreamRequests = [];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function safeEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
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

function request(url, options = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const outgoing = httpRequest(target, options, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    outgoing.on("error", reject);
    if (options.body) outgoing.write(options.body);
    outgoing.end();
  });
}

function cookiePair(setCookie, name) {
  const headers = Array.isArray(setCookie) ? setCookie : [setCookie];
  const field = headers.find((value) => String(value).startsWith(`${name}=`));
  return field ? field.split(";", 1)[0] : null;
}

function cookieValue(pair) {
  return pair.slice(pair.indexOf("=") + 1);
}

function decodeJsonPart(value) {
  return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
}

async function waitForGateway(url) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (gateway.exitCode !== null) throw new Error("OAuth gateway exited during startup");
    try {
      const response = await request(`${url}/auth/login`);
      if (response.status) return;
    } catch {
      // The socket is expected to refuse connections briefly during startup.
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("OAuth gateway did not start");
}

const fakePsql = join(temporary, "fake-psql.mjs");
await writeFile(fakePsql, `#!/usr/bin/env node
import { appendFile } from "node:fs/promises";
import { basename } from "node:path";
const variables = {};
for (let index = 2; index < process.argv.length; index += 1) {
  if (process.argv[index] === "-v" && index + 1 < process.argv.length) {
    const field = process.argv[index + 1];
    const separator = field.indexOf("=");
    if (separator >= 0) variables[field.slice(0, separator)] = field.slice(separator + 1);
    index += 1;
  }
}
const script = basename(process.argv.at(-1));
await appendFile(process.env.NJORD_FAKE_PSQL_LOG, JSON.stringify({ script, variables }) + "\\n");
const responses = {
  "authenticate-github-identity.sql": { principal_id: "11111111-1111-4111-8111-111111111111", database_role: "elric", identity_created: false },
  "create-web-session.sql": { created: true }
};
if (!(script in responses)) process.exit(2);
process.stdout.write(JSON.stringify(responses[script]) + "\\n");
`);
await chmod(fakePsql, 0o700);

try {
  provider = createServer(async (incoming, response) => {
    const url = new URL(incoming.url, "http://provider.invalid");
    if (url.pathname === "/authorize") {
      authorizeParameters = url.searchParams;
      response.writeHead(204).end();
      return;
    }
    if (url.pathname === "/token") {
      tokenRequests += 1;
      const chunks = [];
      for await (const chunk of incoming) chunks.push(chunk);
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      assert(payload.client_id === clientId, "token exchange used the wrong client id");
      assert(payload.client_secret === clientSecret, "token exchange used the wrong client secret");
      assert(payload.code === "one-use-code", "token exchange used the wrong authorization code");
      assert(payload.redirect_uri.endsWith("/auth/callback"), "token exchange used the wrong callback URI");
      const challenge = createHash("sha256").update(payload.code_verifier).digest("base64url");
      assert(challenge === authorizeParameters.get("code_challenge"), "PKCE verifier did not match its challenge");
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ access_token: "provider-access-token", token_type: "bearer" }));
      return;
    }
    if (url.pathname === "/user") {
      userRequests += 1;
      assert(incoming.headers.authorization === "Bearer provider-access-token", "GitHub user request omitted its bearer token");
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(expectedIdentity));
      return;
    }
    response.writeHead(404).end();
  });
  const providerPort = await listen(provider);

  upstream = createServer(async (incoming, response) => {
    const chunks = [];
    for await (const chunk of incoming) chunks.push(chunk);
    upstreamRequests.push({
      url: incoming.url,
      authorization: incoming.headers.authorization,
      cookie: incoming.headers.cookie,
      body: Buffer.concat(chunks).toString("utf8"),
    });
    let result = [];
    if (incoming.url === "/rpc/authenticate_gateway_identity") {
      result = [{
        principal_id: "11111111-1111-4111-8111-111111111111",
        database_role: "elric",
        identity_created: false,
      }];
    } else if (incoming.url === "/rpc/create_gateway_session") {
      result = [{
        session_id: "22222222-2222-4222-8222-222222222222",
        database_role: "elric",
        expires_at: "2999-01-01T00:00:00.000Z",
      }];
    } else if (incoming.url === "/rpc/resolve_gateway_session") {
      result = [{
        principal_id: "11111111-1111-4111-8111-111111111111",
        database_role: "elric",
        provider_login: "elric",
        expires_at: "2999-01-01T00:00:00.000Z",
      }];
    } else if (incoming.url === "/rpc/revoke_gateway_session") {
      result = true;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(result));
  });
  const upstreamPort = await listen(upstream);

  const probe = createServer();
  const gatewayPort = await listen(probe);
  await close(probe);
  const gatewayOrigin = `http://127.0.0.1:${gatewayPort}`;
  gateway = spawn(process.execPath, ["scripts/static-server.mjs"], {
    cwd: repository,
    env: {
      ...process.env,
      NJORD_UI_PORT: String(gatewayPort),
      NJORD_POSTGREST_URL: `http://127.0.0.1:${upstreamPort}`,
      NJORD_CONTROL_POSTGREST_URL: `http://127.0.0.1:${upstreamPort}`,
      NJORD_GITHUB_CLIENT_ID: clientId,
      NJORD_GITHUB_CLIENT_SECRET: clientSecret,
      NJORD_PUBLIC_URL: gatewayOrigin,
      NJORD_SESSION_SECRET: sessionSecret,
      NJORD_POSTGREST_JWT_SECRET: jwtSecret,
      NJORD_GITHUB_AUTHORIZE_URL: `http://127.0.0.1:${providerPort}/authorize`,
      NJORD_GITHUB_TOKEN_URL: `http://127.0.0.1:${providerPort}/token`,
      NJORD_GITHUB_API_URL: `http://127.0.0.1:${providerPort}`,
      NJORD_CONTROL_DATABASE: "fake-control",
      NJORD_FAKE_PSQL_LOG: psqlLog,
      PSQL: fakePsql,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let gatewayErrors = "";
  gateway.stderr.on("data", (chunk) => { gatewayErrors += chunk; });
  await waitForGateway(gatewayOrigin);

  const anonymousRpc = await request(`${gatewayOrigin}/api/control/rpc/shell_page`, {
    method: "POST",
    headers: { "content-type": "application/json", "content-length": "2" },
    body: "{}",
  });
  assert(anonymousRpc.status === 403, `anonymous RPC returned ${anonymousRpc.status}, not 403`);
  assert(upstreamRequests.length === 0, "anonymous RPC reached PostgREST");

  const anonymousPage = await request(`${gatewayOrigin}/?page=accounts&book=private`);
  assert(anonymousPage.status === 302, `anonymous page returned ${anonymousPage.status}, not a login redirect`);
  assert(
    anonymousPage.headers.location === "/auth/login?return_to=%2F%3Fpage%3Daccounts%26book%3Dprivate",
    "anonymous page did not retain its internal destination",
  );

  const login = await request(`${gatewayOrigin}/auth/login?return_to=${encodeURIComponent("//evil.example/steal")}`);
  assert(login.status === 302, `login returned ${login.status}, not a provider redirect`);
  const oauthCookie = cookiePair(login.headers["set-cookie"], "njord_oauth");
  assert(oauthCookie, "login did not set the OAuth state cookie");
  const oauthSetCookie = login.headers["set-cookie"].join(";");
  assert(oauthSetCookie.includes("HttpOnly"), "OAuth cookie is not HttpOnly");
  assert(oauthSetCookie.includes("SameSite=Lax"), "OAuth cookie is not SameSite=Lax");
  const authorizationUrl = new URL(login.headers.location);
  await request(authorizationUrl);
  assert(authorizationUrl.searchParams.get("client_id") === clientId, "authorization redirect used the wrong client id");
  assert(authorizationUrl.searchParams.get("code_challenge_method") === "S256", "authorization redirect omitted PKCE S256");
  assert(authorizationUrl.searchParams.get("allow_signup") === "false", "authorization redirect allowed uninvited signup");

  const badState = await request(`${gatewayOrigin}/auth/callback?code=one-use-code&state=tampered`, {
    headers: { cookie: oauthCookie },
  });
  assert(badState.status === 400, `tampered state returned ${badState.status}, not 400`);
  assert(tokenRequests === 0, "tampered state reached the provider token endpoint");
  assert(
    badState.headers["set-cookie"].some((value) => value.startsWith("njord_oauth=") && value.includes("Max-Age=0")),
    "tampered state did not clear the OAuth cookie",
  );

  const callback = await request(
    `${gatewayOrigin}/auth/callback?code=one-use-code&state=${encodeURIComponent(authorizationUrl.searchParams.get("state"))}`,
    { headers: { cookie: oauthCookie, "user-agent": "njord-oauth-test" } },
  );
  assert(callback.status === 302, `valid callback returned ${callback.status}: ${callback.body || gatewayErrors}`);
  assert(callback.headers.location === "/", "external return_to was not reduced to the site root");
  assert(tokenRequests === 1 && userRequests === 1, "valid callback did not perform exactly one identity exchange");
  const sessionCookie = cookiePair(callback.headers["set-cookie"], "njord_session");
  assert(sessionCookie, "valid callback did not issue a session cookie");
  const sessionSetCookie = callback.headers["set-cookie"].find((value) => value.startsWith("njord_session="));
  assert(sessionSetCookie.includes("HttpOnly") && sessionSetCookie.includes("SameSite=Strict"), "session cookie lacks browser protections");

  for (const origin of [undefined, "https://wrong.example"]) {
    const before = upstreamRequests.length;
    const headers = {
      "content-type": "application/json",
      "content-length": "2",
      cookie: sessionCookie,
    };
    if (origin) headers.origin = origin;
    const deniedMutation = await request(`${gatewayOrigin}/api/control/rpc/shell_page`, {
      method: "POST", headers, body: "{}",
    });
    assert(deniedMutation.status === 403, `RPC with origin ${origin || "missing"} returned ${deniedMutation.status}`);
    assert(upstreamRequests.length === before, "origin-rejected RPC reached PostgREST");

    const deniedLogout = await request(`${gatewayOrigin}/auth/logout`, {
      method: "POST", headers: { cookie: sessionCookie, ...(origin ? { origin } : {}) },
    });
    assert(deniedLogout.status === 403, `logout with origin ${origin || "missing"} returned ${deniedLogout.status}`);
    assert(upstreamRequests.length === before, "origin-rejected logout reached the session store");
  }

  const authenticatedRpc = await request(`${gatewayOrigin}/api/control/rpc/shell_page`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "content-length": "2",
      cookie: sessionCookie,
      origin: gatewayOrigin,
      authorization: "Bearer attacker-supplied-token",
    },
    body: "{}",
  });
  assert(authenticatedRpc.status === 200, `authenticated RPC returned ${authenticatedRpc.status}: ${authenticatedRpc.body || gatewayErrors}`);
  const forwardedJwt = upstreamRequests.at(-1).authorization;
  assert(!upstreamRequests.at(-1).cookie, "gateway exposed the raw browser session cookie to PostgREST");
  assert(forwardedJwt?.startsWith("Bearer "), "authenticated RPC did not receive a gateway JWT");
  assert(forwardedJwt !== "Bearer attacker-supplied-token", "gateway forwarded a caller-supplied bearer token");
  const jwt = forwardedJwt.slice("Bearer ".length).split(".");
  assert(jwt.length === 3, "gateway bearer token is not a JWT");
  const claims = decodeJsonPart(jwt[1]);
  assert(claims.role === "elric", "gateway JWT used the wrong PostgreSQL role");
  assert(claims.sub === "11111111-1111-4111-8111-111111111111", "gateway JWT used the wrong principal");
  assert(claims.exp - claims.iat === 60, "gateway JWT has an unexpectedly long lifetime");
  const expectedSignature = createHmac("sha256", jwtSecret).update(`${jwt[0]}.${jwt[1]}`).digest("base64url");
  assert(safeEqual(jwt[2], expectedSignature), "gateway JWT signature is invalid");

  const authenticationCall = upstreamRequests.find((entry) => entry.url === "/rpc/authenticate_gateway_identity");
  const authenticationBody = JSON.parse(authenticationCall.body);
  assert(authenticationBody.p_provider_subject === expectedIdentity.id, "gateway did not use GitHub's immutable numeric id");
  assert(authenticationBody.p_github_login === "elric", "gateway did not normalize the GitHub login");
  const sessionCall = upstreamRequests.find((entry) => entry.url === "/rpc/create_gateway_session");
  const sessionBody = JSON.parse(sessionCall.body);
  assert(/^[0-9a-f]{64}$/.test(sessionBody.p_token_hash), "gateway did not persist a SHA-256 session-token hash");
  assert(!JSON.stringify(upstreamRequests).includes(cookieValue(sessionCookie)), "raw session token escaped into the control API");
  const serviceClaims = decodeJsonPart(authenticationCall.authorization.slice("Bearer ".length).split(".")[1]);
  assert(serviceClaims.role === "njord_gateway", "control wrapper did not use the service role");
  let psqlCalls = [];
  try {
    psqlCalls = (await readFile(psqlLog, "utf8")).trim().split("\n").filter(Boolean).map(JSON.parse);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  assert(psqlCalls.length === 0, "public gateway spawned psql");

  const logout = await request(`${gatewayOrigin}/auth/logout`, {
    method: "POST",
    headers: { cookie: sessionCookie, origin: gatewayOrigin },
  });
  assert(logout.status === 302, `logout returned ${logout.status}`);
  assert(cookiePair(logout.headers["set-cookie"], "njord_session") === "njord_session=", "logout did not clear the session cookie");
  let callsAfterLogout = [];
  try {
    callsAfterLogout = (await readFile(psqlLog, "utf8")).trim().split("\n").filter(Boolean).map(JSON.parse);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  assert(callsAfterLogout.length === 0, "logout spawned psql");
  assert(upstreamRequests.some((entry) => entry.url === "/rpc/revoke_gateway_session"), "logout did not revoke the database session");

  const style = await request(`${gatewayOrigin}/style.css`);
  assert(style.headers["content-security-policy"].includes("style-src 'self' 'unsafe-inline'"), "CSP blocks Elm inline styles");
  assert(style.headers["cache-control"] === "no-cache", "unhashed static asset was not revalidated");

  let limited;
  for (let attempt = 0; attempt < 21; attempt += 1) {
    limited = await request(`${gatewayOrigin}/auth/login`);
  }
  assert(limited.status === 429, `authentication rate limit returned ${limited.status}, not 429`);

  process.stdout.write("ok - local fake-GitHub OAuth flow passed\n");
} finally {
  if (gateway && gateway.exitCode === null) {
    gateway.kill("SIGTERM");
    await new Promise((resolve) => gateway.once("exit", resolve));
  }
  if (provider?.listening) await close(provider);
  if (upstream?.listening) await close(upstream);
  await rm(temporary, { recursive: true, force: true });
}
