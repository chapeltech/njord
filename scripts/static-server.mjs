import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { spawn } from "node:child_process";
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { createServer, request as proxyRequest } from "node:http";
import { createConnection, createServer as createNetServer } from "node:net";
import { extname, resolve, sep } from "node:path";

const host = process.env.NJORD_UI_HOST || "127.0.0.1";
const port = Number(process.env.NJORD_UI_PORT || "8080");
const postgrest = new URL(process.env.NJORD_POSTGREST_URL || "http://127.0.0.1:3000");
const controlPostgrest = new URL(process.env.NJORD_CONTROL_POSTGREST_URL || postgrest);
const controlPostgrestAdmin = process.env.NJORD_CONTROL_POSTGREST_ADMIN_URL
  ? new URL(process.env.NJORD_CONTROL_POSTGREST_ADMIN_URL)
  : null;
const frontend = resolve(process.cwd(), "frontend");
const manageBookDatabases = process.env.NJORD_MANAGE_BOOK_DATABASES === "1";
const controlDatabase = process.env.NJORD_CONTROL_DATABASE || "njord";
const databaseRole = process.env.NJORD_DATABASE_ROLE || process.env.USER || "postgres";
const postgrestBin = process.env.POSTGREST_BIN || resolve(process.cwd(), ".tools/postgrest");
const managedBookAdapters = new Map();
const bookStarts = new Map();
const bookValidations = new Map();
const configuredBookPostgrests = new Map();
const drainingBooks = new Set();
const deletingBooks = new Set();
const githubClientId = process.env.NJORD_GITHUB_CLIENT_ID || "";
const githubClientSecret = process.env.NJORD_GITHUB_CLIENT_SECRET || "";
const publicUrlValue = process.env.NJORD_PUBLIC_URL || "";
const sessionSecret = process.env.NJORD_SESSION_SECRET || "";
const postgrestJwtSecret = process.env.NJORD_POSTGREST_JWT_SECRET || "";
const postgrestAuthenticatorRole = process.env.NJORD_POSTGREST_AUTHENTICATOR_ROLE || "njord_authenticator";
const gatewayDatabaseRole = "njord_gateway";
const lifecycleBrokerSocket = process.env.NJORD_LIFECYCLE_BROKER_SOCKET || "";
const githubAuthorizeUrl = process.env.NJORD_GITHUB_AUTHORIZE_URL || "https://github.com/login/oauth/authorize";
const githubTokenUrl = process.env.NJORD_GITHUB_TOKEN_URL || "https://github.com/login/oauth/access_token";
const githubApiUrl = process.env.NJORD_GITHUB_API_URL || "https://api.github.com";
const sessionLifetimeSeconds = Number(process.env.NJORD_SESSION_LIFETIME_SECONDS || 7 * 24 * 60 * 60);
const bookPoolSize = Number(process.env.NJORD_BOOK_POSTGREST_POOL_SIZE || 2);
const bookShutdownSeconds = Number(process.env.NJORD_BOOK_SHUTDOWN_SECONDS || 5);
const bookSchemaVersion = Number(process.env.NJORD_BOOK_SCHEMA_VERSION || 2);
const requestBodyLimit = Number(process.env.NJORD_REQUEST_BODY_LIMIT || 2 * 1024 * 1024);
const upstreamBodyLimit = Number(process.env.NJORD_UPSTREAM_BODY_LIMIT || 16 * 1024 * 1024);
const upstreamTimeoutMilliseconds = Number(process.env.NJORD_UPSTREAM_TIMEOUT_MS || 35_000);
const lifecycleTimeoutMilliseconds = Number(process.env.NJORD_LIFECYCLE_TIMEOUT_MS || 120_000);
const bookStartupMilliseconds = Number(process.env.NJORD_BOOK_STARTUP_MS || 10_000);
const bookRestartBackoffMilliseconds = Number(process.env.NJORD_BOOK_RESTART_BACKOFF_MS || 5_000);
const maximumBookAdapters = Number(process.env.NJORD_MAX_BOOK_ADAPTERS || 32);
const maximumBookStarts = Number(process.env.NJORD_MAX_BOOK_STARTS || 2);
const maximumConcurrentRequests = Number(process.env.NJORD_MAX_CONCURRENT_REQUESTS || 128);
const maximumSessionConcurrency = Number(process.env.NJORD_MAX_SESSION_CONCURRENCY || 8);
const maximumSessionLookups = Number(process.env.NJORD_MAX_SESSION_LOOKUPS || 16);
const allowUnauthenticated = process.env.NJORD_ALLOW_UNAUTHENTICATED === "1";
const testAllInOne = process.env.NODE_ENV === "test" && process.env.NJORD_TEST_ALL_IN_ONE === "1";
const authConfiguration = [ githubClientId, githubClientSecret, publicUrlValue, sessionSecret ];
const githubAuthentication = authConfiguration.every(Boolean);
const postgrestAnonymousRole = process.env.NJORD_POSTGREST_ANON_ROLE || "njord_anonymous";

if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
  throw new Error("NJORD_UI_PORT must be an integer from 1 through 65535");
}
if (authConfiguration.some(Boolean) && !githubAuthentication) {
  throw new Error(
    "GitHub authentication requires NJORD_GITHUB_CLIENT_ID, "
      + "NJORD_GITHUB_CLIENT_SECRET, NJORD_PUBLIC_URL, and NJORD_SESSION_SECRET",
  );
}
if (githubAuthentication && sessionSecret.length < 32) {
  throw new Error("NJORD_SESSION_SECRET must contain at least 32 characters");
}
if (postgrestJwtSecret.length < 32) {
  throw new Error("NJORD_POSTGREST_JWT_SECRET must contain at least 32 characters");
}
if (!Number.isSafeInteger(sessionLifetimeSeconds) || sessionLifetimeSeconds < 300 || sessionLifetimeSeconds > 30 * 24 * 60 * 60) {
  throw new Error("NJORD_SESSION_LIFETIME_SECONDS must be an integer from 300 seconds through 30 days");
}
if (!Number.isSafeInteger(bookPoolSize) || bookPoolSize < 1 || bookPoolSize > 20) {
  throw new Error("NJORD_BOOK_POSTGREST_POOL_SIZE must be an integer from 1 through 20");
}
if (!Number.isSafeInteger(bookShutdownSeconds) || bookShutdownSeconds < 1 || bookShutdownSeconds > 60) {
  throw new Error("NJORD_BOOK_SHUTDOWN_SECONDS must be an integer from 1 through 60");
}
if (!Number.isSafeInteger(bookSchemaVersion) || bookSchemaVersion < 1) {
  throw new Error("NJORD_BOOK_SCHEMA_VERSION must be a positive integer");
}
if (!Number.isSafeInteger(requestBodyLimit) || requestBodyLimit < 1024 || requestBodyLimit > 10 * 1024 * 1024) {
  throw new Error("NJORD_REQUEST_BODY_LIMIT must be an integer from 1024 through 10485760 bytes");
}
if (!Number.isSafeInteger(upstreamBodyLimit) || upstreamBodyLimit < 1024 || upstreamBodyLimit > 64 * 1024 * 1024) {
  throw new Error("NJORD_UPSTREAM_BODY_LIMIT must be an integer from 1024 through 67108864 bytes");
}
if (!Number.isSafeInteger(upstreamTimeoutMilliseconds)
    || upstreamTimeoutMilliseconds < 1000 || upstreamTimeoutMilliseconds > 120_000) {
  throw new Error("NJORD_UPSTREAM_TIMEOUT_MS must be an integer from 1000 through 120000 milliseconds");
}
for (const [name, value, minimum, maximum] of [
  ["NJORD_LIFECYCLE_TIMEOUT_MS", lifecycleTimeoutMilliseconds, 1000, 600_000],
  ["NJORD_BOOK_STARTUP_MS", bookStartupMilliseconds, 250, 120_000],
  ["NJORD_BOOK_RESTART_BACKOFF_MS", bookRestartBackoffMilliseconds, 0, 300_000],
  ["NJORD_MAX_BOOK_ADAPTERS", maximumBookAdapters, 1, 256],
  ["NJORD_MAX_BOOK_STARTS", maximumBookStarts, 1, 32],
  ["NJORD_MAX_CONCURRENT_REQUESTS", maximumConcurrentRequests, 1, 4096],
  ["NJORD_MAX_SESSION_CONCURRENCY", maximumSessionConcurrency, 1, 256],
  ["NJORD_MAX_SESSION_LOOKUPS", maximumSessionLookups, 1, 256],
]) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
}
if (!/^[a-z_][a-z0-9_-]{0,62}$/.test(postgrestAuthenticatorRole)) {
  throw new Error("NJORD_POSTGREST_AUTHENTICATOR_ROLE is not a safe PostgreSQL role name");
}

const publicUrl = githubAuthentication ? new URL(publicUrlValue) : null;
if (publicUrl && (publicUrl.username || publicUrl.password)) {
  throw new Error("NJORD_PUBLIC_URL must not contain credentials");
}
if (publicUrl && (publicUrl.pathname !== "/" || publicUrl.search || publicUrl.hash)) {
  throw new Error("NJORD_PUBLIC_URL must be an origin without a path, query, or fragment");
}
if (publicUrl && publicUrl.protocol !== "https:"
    && !["127.0.0.1", "localhost", "::1", "[::1]"].includes(publicUrl.hostname)) {
  throw new Error("NJORD_PUBLIC_URL must use HTTPS except for loopback development");
}

const secureCookies = publicUrl?.protocol === "https:";
const sessionCookieName = secureCookies ? "__Host-njord_session" : "njord_session";
const oauthCookieName = secureCookies ? "__Host-njord_oauth" : "njord_oauth";

if (process.env.NJORD_BOOK_POSTGREST_URLS) {
  const configured = JSON.parse(process.env.NJORD_BOOK_POSTGREST_URLS);
  for (const [book, endpoint] of Object.entries(configured)) {
    if (!/^[a-z][a-z0-9_-]{0,62}$/.test(book)) throw new Error(`Invalid configured Book handle: ${book}`);
    configuredBookPostgrests.set(book, new URL(endpoint));
  }
}

const multiDatabase =
  manageBookDatabases
  || configuredBookPostgrests.size > 0
  || Boolean(process.env.NJORD_CONTROL_POSTGREST_URL);
if (!multiDatabase && !testAllInOne) {
  throw new Error(
    "A control PostgREST and database-per-Book routing are required; "
      + "the all-in-one adapter is available only to the explicit test fixture",
  );
}
if (!githubAuthentication
    && !allowUnauthenticated
    && !["127.0.0.1", "::1", "localhost"].includes(host)) {
  throw new Error("Refusing a non-loopback listener without GitHub authentication");
}
const accessFunctions = new Set(["invite_book_user", "update_book_access", "remove_book_access"]);
const globalControlFunctions = new Set([
  "shell_page",
  "admin_page",
  "invite_global_user",
  "add_book_page",
  "create_book",
]);

const contentTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
]);
const staticFiles = new Set(["app.js", "bootstrap.js", "index.html", "style.css"]);
const hopByHopHeaders = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailer", "transfer-encoding", "upgrade",
]);
const activeSessions = new Map();
const failedBookStarts = new Map();
const bookIdentityCache = new Map();
const authRateWindows = new Map();
let activeRequests = 0;
let activeSessionLookups = 0;
let activeBookStarts = 0;

function base64Url(value) {
  return Buffer.from(value).toString("base64url");
}

function hashHex(value) {
  return createHash("sha256").update(value).digest("hex");
}

function signValue(value) {
  return createHmac("sha256", sessionSecret).update(value).digest("base64url");
}

function safeEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

async function limitedJson(response, maximumBytes = 64 * 1024) {
  if (!response.body) throw new Error("Remote service returned no response body");
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumBytes) {
      await reader.cancel();
      throw new Error("Remote service response exceeded the size limit");
    }
    chunks.push(value);
  }
  return JSON.parse(Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))).toString("utf8"));
}

function parseCookies(request) {
  const result = new Map();
  for (const part of String(request.headers.cookie || "").split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    if (name) result.set(name, value);
  }
  return result;
}

function cookieHeader(name, value, options = {}) {
  const fields = [
    `${name}=${value}`, "Path=/", "HttpOnly",
    `SameSite=${options.sameSite || "Lax"}`,
  ];
  if (secureCookies) fields.push("Secure");
  if (options.maxAge !== undefined) fields.push(`Max-Age=${options.maxAge}`);
  return fields.join("; ");
}

function clearCookie(name) {
  return cookieHeader(name, "", { maxAge: 0 });
}

function normalizeReturnTo(value) {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) return "/";
  try {
    const parsed = new URL(value, publicUrl);
    return parsed.origin === publicUrl.origin ? `${parsed.pathname}${parsed.search}${parsed.hash}` : "/";
  } catch {
    return "/";
  }
}

function sendText(response, status, message, headers = {}) {
  const body = Buffer.from(`${message}\n`);
  response.writeHead(status, {
    "content-type": "text/plain; charset=utf-8",
    "content-length": body.length,
    ...headers,
  });
  response.end(body);
}

function normalizedRemoteAddress(request) {
  const address = request.socket.remoteAddress || "unknown";
  return address.startsWith("::ffff:") ? address.slice(7) : address;
}

function allowAuthenticationAttempt(request, route) {
  const now = Date.now();
  const key = `${route}:${normalizedRemoteAddress(request)}`;
  const previous = authRateWindows.get(key);
  const window = !previous || now - previous.startedAt >= 60_000
    ? { startedAt: now, count: 0 }
    : previous;
  window.count += 1;
  authRateWindows.set(key, window);
  if (authRateWindows.size > 1024) {
    for (const [candidate, value] of authRateWindows) {
      if (now - value.startedAt >= 60_000) authRateWindows.delete(candidate);
    }
  }
  return window.count <= 20;
}

function acquireSessionPermit(session) {
  const key = String(session.principal_id);
  const count = activeSessions.get(key) || 0;
  if (count >= maximumSessionConcurrency) return null;
  activeSessions.set(key, count + 1);
  let released = false;
  return () => {
    if (released) return;
    released = true;
    const remaining = (activeSessions.get(key) || 1) - 1;
    if (remaining > 0) activeSessions.set(key, remaining);
    else activeSessions.delete(key);
  };
}

function redirect(response, location, headers = {}) {
  response.writeHead(302, { location, "cache-control": "no-store", ...headers });
  response.end();
}

function requestOriginIsPublic(request) {
  return request.headers.origin === publicUrl?.origin;
}

function lifecycleOperation(payload) {
  if (!lifecycleBrokerSocket) {
    throw new GatewayError("The lifecycle broker is unavailable", 503, "LIFECYCLE_BROKER_UNAVAILABLE");
  }
  return new Promise((resolveOperation, reject) => {
    const socket = createConnection(lifecycleBrokerSocket);
    let response = "";
    let settled = false;
    const finish = (operation, value) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      operation(value);
    };
    socket.setEncoding("utf8");
    socket.setTimeout(lifecycleTimeoutMilliseconds, () => finish(
      reject, new GatewayError("Lifecycle operation timed out", 504, "LIFECYCLE_TIMEOUT"),
    ));
    socket.on("connect", () => socket.end(JSON.stringify(payload)));
    socket.on("data", (chunk) => {
      response += chunk;
      if (Buffer.byteLength(response) > 4096) finish(
        reject, new GatewayError("Lifecycle broker returned invalid data", 502, "LIFECYCLE_BROKER_INVALID"),
      );
    });
    socket.on("end", () => {
      try {
        const result = JSON.parse(response);
        if (result?.ok === true) finish(resolveOperation);
        else finish(reject, new GatewayError("Lifecycle operation failed", 502, "LIFECYCLE_OPERATION_FAILED"));
      } catch {
        finish(reject, new GatewayError("Lifecycle broker returned invalid data", 502, "LIFECYCLE_BROKER_INVALID"));
      }
    });
    socket.on("error", () => finish(
      reject, new GatewayError("The lifecycle broker is unavailable", 503, "LIFECYCLE_BROKER_UNAVAILABLE"),
    ));
  });
}

function postgrestRoleJwt(databaseRole, subject) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64Url(JSON.stringify({
    iss: "njord",
    aud: "njord",
    sub: subject,
    role: databaseRole,
    iat: now,
    exp: now + 60,
  }));
  const signature = createHmac("sha256", postgrestJwtSecret)
    .update(`${header}.${payload}`)
    .digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function postgrestJwt(session) {
  return postgrestRoleJwt(session.database_role, session.principal_id);
}

function gatewayJwt() {
  return postgrestRoleJwt(gatewayDatabaseRole, "njord-gateway");
}

async function resolveSession(request) {
  const rawToken = parseCookies(request).get(sessionCookieName);
  if (!rawToken || !/^[A-Za-z0-9_-]{40,128}$/.test(rawToken)) return null;
  if (activeSessionLookups >= maximumSessionLookups) {
    throw new GatewayError("Authentication store is busy", 503, "SESSION_LOOKUP_LIMIT");
  }
  activeSessionLookups += 1;
  try {
    const rows = await controlGatewayRpc("resolve_gateway_session", {
      p_token_hash: hashHex(rawToken),
    });
    return Array.isArray(rows) ? rows[0] || null : null;
  } finally {
    activeSessionLookups -= 1;
  }
}

async function requireSession(request, response, redirectBrowser = false) {
  let session;
  try {
    session = await resolveSession(request);
  } catch {
    sendText(response, 503, "Authentication store unavailable");
    return null;
  }
  if (session) return session;

  const headers = { "set-cookie": clearCookie(sessionCookieName) };
  if (redirectBrowser) {
    const returnTo = normalizeReturnTo(request.url || "/");
    redirect(response, `/auth/login?return_to=${encodeURIComponent(returnTo)}`, headers);
  } else {
    sendText(response, 401, "Authentication required", headers);
  }
  return null;
}

async function handleLogin(request, response) {
  const requestUrl = new URL(request.url, publicUrl);
  const state = randomBytes(24).toString("base64url");
  const verifier = randomBytes(48).toString("base64url");
  const returnTo = normalizeReturnTo(requestUrl.searchParams.get("return_to") || "/");
  const oauthState = base64Url(JSON.stringify({ state, verifier, returnTo, exp: Date.now() + 10 * 60_000 }));
  const signedState = `${oauthState}.${signValue(oauthState)}`;
  const destination = new URL(githubAuthorizeUrl);
  destination.searchParams.set("client_id", githubClientId);
  destination.searchParams.set("redirect_uri", new URL("/auth/callback", publicUrl).href);
  destination.searchParams.set("state", state);
  destination.searchParams.set("code_challenge", createHash("sha256").update(verifier).digest("base64url"));
  destination.searchParams.set("code_challenge_method", "S256");
  destination.searchParams.set("allow_signup", "false");
  redirect(response, destination.href, {
    "set-cookie": cookieHeader(oauthCookieName, signedState, { maxAge: 10 * 60 }),
  });
}

function readOauthState(request, returnedState) {
  const signed = parseCookies(request).get(oauthCookieName) || "";
  const separator = signed.lastIndexOf(".");
  if (separator < 0) return null;
  const encoded = signed.slice(0, separator);
  const signature = signed.slice(separator + 1);
  if (!safeEqual(signature, signValue(encoded))) return null;
  try {
    const state = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
    if (state.exp < Date.now() || !safeEqual(String(state.state), String(returnedState))) return null;
    return state;
  } catch {
    return null;
  }
}

async function githubIdentity(code, verifier) {
  const tokenResponse = await fetch(githubTokenUrl, {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({
      client_id: githubClientId,
      client_secret: githubClientSecret,
      code,
      redirect_uri: new URL("/auth/callback", publicUrl).href,
      code_verifier: verifier,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  const token = await limitedJson(tokenResponse);
  if (!tokenResponse.ok || !token.access_token) throw new Error("GitHub rejected the authorization code");

  const identityResponse = await fetch(new URL("/user", githubApiUrl), {
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token.access_token}`,
      "user-agent": "njord-accounting",
      "x-github-api-version": "2022-11-28",
    },
    signal: AbortSignal.timeout(10_000),
  });
  const identity = await limitedJson(identityResponse);
  if (!identityResponse.ok || !Number.isSafeInteger(identity.id) || typeof identity.login !== "string") {
    throw new Error("GitHub did not return a valid user identity");
  }
  return identity;
}

async function githubPublicIdentity(login) {
  if (!/^[a-z\d](?:[a-z\d-]{0,37}[a-z\d])?$/i.test(login)) {
    throw new Error("Invalid GitHub login");
  }
  const identityResponse = await fetch(
    new URL(`/users/${encodeURIComponent(login)}`, githubApiUrl),
    {
      headers: {
        accept: "application/vnd.github+json",
        "user-agent": "njord-accounting",
        "x-github-api-version": "2022-11-28",
      },
      signal: AbortSignal.timeout(10_000),
    },
  );
  const identity = await limitedJson(identityResponse);
  if (!identityResponse.ok || !Number.isSafeInteger(identity.id) || typeof identity.login !== "string") {
    throw new Error("GitHub user was not found");
  }
  return identity;
}

async function handleCallback(request, response) {
  const requestUrl = new URL(request.url, publicUrl);
  const code = requestUrl.searchParams.get("code");
  const state = readOauthState(request, requestUrl.searchParams.get("state"));
  if (!code || !state) {
    sendText(response, 400, "GitHub sign-in state is invalid or expired", { "set-cookie": clearCookie(oauthCookieName) });
    return;
  }

  try {
    const identity = await githubIdentity(code, state.verifier);
    if (!/^[a-z\d](?:[a-z\d-]{0,37}[a-z\d])?$/i.test(identity.login)) {
      throw new Error("GitHub returned a login that cannot be used as a PostgreSQL role");
    }
    const authenticated = await controlGatewayRpc("authenticate_gateway_identity", {
      p_provider_subject: identity.id,
      p_github_login: identity.login.toLowerCase(),
      p_display_name: typeof identity.name === "string" ? identity.name : identity.login,
    });
    const principal = Array.isArray(authenticated) ? authenticated[0] : null;
    if (!principal) throw new Error("GitHub account is not invited");

    const rawToken = randomBytes(32).toString("base64url");
    const tokenHash = hashHex(rawToken);
    const expiresAt = new Date(Date.now() + sessionLifetimeSeconds * 1000).toISOString();
    await controlGatewayRpc("create_gateway_session", {
      p_principal_id: principal.principal_id,
      p_token_hash: tokenHash,
      p_expires_at: expiresAt,
    });
    response.writeHead(302, {
      location: normalizeReturnTo(state.returnTo),
      "cache-control": "no-store",
      "set-cookie": [
        cookieHeader(sessionCookieName, rawToken, {
          maxAge: sessionLifetimeSeconds,
          sameSite: "Strict",
        }),
        clearCookie(oauthCookieName),
      ],
    });
    response.end();
  } catch (error) {
    console.error("GitHub sign-in failed");
    sendText(response, 403, "GitHub sign-in failed or this account has not been invited", {
      "set-cookie": clearCookie(oauthCookieName),
    });
  }
}

async function handleLogout(request, response) {
  const rawToken = parseCookies(request).get(sessionCookieName);
  if (rawToken && /^[A-Za-z0-9_-]{40,128}$/.test(rawToken)) {
    const tokenHash = hashHex(rawToken);
    try {
      await controlGatewayRpc("revoke_gateway_session", { p_token_hash: tokenHash });
    } catch (error) {
      console.error("Session revocation failed:", error.message);
      sendText(response, 503, "Logout could not be completed; retry before closing the browser");
      return;
    }
  }
  redirect(response, "/auth/login", { "set-cookie": clearCookie(sessionCookieName) });
}

function sendBuffered(response, upstream) {
  const headers = { ...upstream.headers };
  for (const header of hopByHopHeaders) delete headers[header];
  delete headers.server;
  delete headers["x-powered-by"];
  headers["content-length"] = upstream.body.length;
  headers["cache-control"] = "no-store";
  response.writeHead(upstream.statusCode || 502, headers);
  response.end(upstream.body);
}

class GatewayError extends Error {
  constructor(message, status = 502, detail = "BOOK_DATABASE_ROUTING_FAILED") {
    super(message);
    this.status = status;
    this.detail = detail;
  }
}

function sendGatewayError(response, message, detail = "BOOK_DATABASE_ROUTING_FAILED", status = 502) {
  const body = Buffer.from(JSON.stringify({
    code: "NJORD_GATEWAY",
    message,
    details: detail,
    hint: null,
  }));
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length,
  });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolveBody, reject) => {
    const declaredLength = request.headers["content-length"];
    if (declaredLength !== undefined
        && (!/^\d+$/.test(declaredLength) || Number(declaredLength) > requestBodyLimit)) {
      request.resume();
      reject(new GatewayError("RPC request body is too large", 413, "REQUEST_BODY_TOO_LARGE"));
      return;
    }
    const chunks = [];
    let length = 0;
    let settled = false;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      request.removeListener("data", onData);
      request.removeListener("end", onEnd);
      request.removeListener("error", fail);
      request.removeListener("aborted", onAborted);
      request.resume();
      reject(error);
    };
    const onData = (chunk) => {
      if (settled) return;
      length += chunk.length;
      if (length > requestBodyLimit) {
        fail(new GatewayError("RPC request body is too large", 413, "REQUEST_BODY_TOO_LARGE"));
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => {
      if (settled) return;
      settled = true;
      resolveBody(Buffer.concat(chunks));
    };
    const onAborted = () => fail(new GatewayError("Client disconnected", 499, "CLIENT_DISCONNECTED"));
    request.on("data", onData);
    request.on("end", onEnd);
    request.on("error", fail);
    request.on("aborted", onAborted);
  });
}

function requestBuffered(base, request, body, pathname = request.url) {
  return new Promise((resolveRequest, reject) => {
    let settled = false;
    let upstreamResponse;
    const finish = (operation, value) => {
      if (settled) return;
      settled = true;
      request.signal?.removeEventListener("abort", abort);
      operation(value);
    };
    const fail = (error) => finish(reject, error);
    const abort = () => upstream.destroy(new GatewayError(
      "Client disconnected", 499, "CLIENT_DISCONNECTED",
    ));
    let target;
    try {
      target = new URL(pathname, base);
    } catch (error) {
      fail(error);
      return;
    }

    const headers = {
      ...request.headers,
      host: base.host,
      "content-length": body.length,
    };
    for (const header of hopByHopHeaders) delete headers[header];
    const upstream = proxyRequest(
      target,
      { method: request.method, headers },
      (response) => {
        upstreamResponse = response;
        const chunks = [];
        let length = 0;
        response.on("data", (chunk) => {
          length += chunk.length;
          if (length > upstreamBodyLimit) {
            response.destroy(new GatewayError(
              "Upstream response is too large", 502, "UPSTREAM_RESPONSE_TOO_LARGE",
            ));
            return;
          }
          chunks.push(chunk);
        });
        response.on("end", () => {
          finish(resolveRequest, {
            statusCode: response.statusCode || 502,
            headers: response.headers,
            body: Buffer.concat(chunks),
          });
        });
        response.on("error", fail);
      },
    );
    upstream.setTimeout(upstreamTimeoutMilliseconds, () => {
      upstream.destroy(new GatewayError("Upstream request timed out", 504, "UPSTREAM_TIMEOUT"));
    });
    upstream.on("error", fail);
    if (request.signal) {
      if (request.signal.aborted) {
        abort();
        return;
      }
      request.signal.addEventListener("abort", abort, { once: true });
    }
    upstream.end(body);
  });
}

async function controlGatewayRpc(functionName, payload, signal) {
  const body = Buffer.from(JSON.stringify(payload));
  const result = await requestBuffered(controlPostgrest, {
    method: "POST",
    url: `/rpc/${functionName}`,
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${gatewayJwt()}`,
    },
    signal,
  }, body);
  if (result.statusCode < 200 || result.statusCode >= 300) {
    throw new GatewayError("Authentication store unavailable", 503, "SESSION_STORE_UNAVAILABLE");
  }
  try {
    return JSON.parse(result.body.toString("utf8"));
  } catch {
    throw new GatewayError("Authentication store returned invalid data", 503, "SESSION_STORE_INVALID");
  }
}

function freePort() {
  return new Promise((resolvePort, reject) => {
    const probe = createNetServer();
    probe.unref();
    probe.on("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      const selected = typeof address === "object" && address ? address.port : null;
      probe.close((error) => {
        if (error) reject(error);
        else if (selected === null) reject(new Error("Could not allocate a PostgREST port"));
        else resolvePort(selected);
      });
    });
  });
}

async function waitUntilReady(adapter) {
  const { child, adminPort } = adapter;
  const readyUrl = `http://127.0.0.1:${adminPort}/ready`;
  const deadline = Date.now() + bookStartupMilliseconds;
  while (Date.now() < deadline) {
    if (adapter.startError) throw adapter.startError;
    if (child.exitCode !== null) break;
    try {
      const result = await fetch(readyUrl, { signal: AbortSignal.timeout(500) });
      if (result.ok) return;
    } catch {
      // The socket is expected to refuse connections during startup.
    }
    await new Promise((done) => setTimeout(done, 100));
  }
  throw new Error("Book PostgREST did not become ready");
}

function postgrestChildEnvironment(overrides) {
  const environment = {};
  for (const name of ["PATH", "LANG", "LC_ALL", "TZ", "PGHOST", "PGPORT", "GHCRTS"]) {
    if (process.env[name]) environment[name] = process.env[name];
  }
  if (process.env.NODE_ENV === "test" && process.env.NJORD_TEST_POSTGREST_LOG) {
    environment.NJORD_TEST_POSTGREST_LOG = process.env.NJORD_TEST_POSTGREST_LOG;
  }
  return { ...environment, ...overrides };
}

async function terminateChild(child, graceMilliseconds = bookShutdownSeconds * 1000) {
  if (child.exitCode !== null) return;
  child.kill("SIGTERM");
  await Promise.race([
    new Promise((done) => child.once("exit", done)),
    new Promise((done) => setTimeout(done, graceMilliseconds)),
  ]);
  if (child.exitCode === null) {
    child.kill("SIGKILL");
    await Promise.race([
      new Promise((done) => child.once("exit", done)),
      new Promise((done) => setTimeout(done, 500)),
    ]);
  }
}

function forwardBookLogs(book, stream, channel) {
  let pending = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk) => {
    pending += chunk;
    const lines = pending.split("\n");
    pending = lines.pop();
    for (const line of lines) process.stderr.write(`[Book ${book} ${channel}] ${line}\n`);
  });
  stream.on("end", () => {
    if (pending) process.stderr.write(`[Book ${book} ${channel}] ${pending}\n`);
  });
}

async function createManagedBookAdapter(book) {
  if (!/^[a-z][a-z0-9_-]{0,62}$/.test(book)) {
    throw new Error("Invalid book database handle");
  }
  if (!manageBookDatabases) throw new Error(`No PostgREST route is configured for book ${book}`);
  bookIdentityCache.delete(book);

  const serverPort = await freePort();
  const adminPort = await freePort();
  const child = spawn(postgrestBin, [resolve(process.cwd(), "postgrest.conf")], {
    cwd: process.cwd(),
    env: postgrestChildEnvironment({
      PGRST_DB_URI: `postgresql:///${encodeURIComponent(book)}?user=${encodeURIComponent(postgrestAuthenticatorRole)}`,
      PGRST_DB_ANON_ROLE: postgrestAnonymousRole,
      PGRST_JWT_SECRET: postgrestJwtSecret,
      PGRST_JWT_AUD: "njord",
      PGRST_SERVER_PORT: String(serverPort),
      PGRST_ADMIN_SERVER_PORT: String(adminPort),
      PGRST_DB_POOL: String(bookPoolSize),
    }),
    stdio: ["ignore", "pipe", "pipe"],
  });
  const adapter = {
    book,
    child,
    adminPort,
    endpoint: new URL(`http://127.0.0.1:${serverPort}`),
    activeRequests: 0,
    draining: false,
    ready: false,
    startError: null,
  };
  managedBookAdapters.set(book, adapter);
  forwardBookLogs(book, child.stdout, "stdout");
  forwardBookLogs(book, child.stderr, "stderr");
  child.on("error", (error) => { adapter.startError = error; });
  child.on("exit", () => {
    if (managedBookAdapters.get(book) === adapter) {
      managedBookAdapters.delete(book);
      bookValidations.delete(book);
    }
  });

  try {
    await waitUntilReady(adapter);
    adapter.ready = true;
  } catch (error) {
    await terminateChild(child);
    throw error;
  }

  return adapter;
}

async function managedBookAdapter(book) {
  const running = managedBookAdapters.get(book);
  if (running?.ready && !running.draining && running.child.exitCode === null) return running;

  if (bookStarts.has(book)) return bookStarts.get(book);

  const failedAt = failedBookStarts.get(book);
  if (failedAt && Date.now() - failedAt < bookRestartBackoffMilliseconds) {
    throw new GatewayError(`Book ${book} adapter is in restart backoff`, 503, "BOOK_ADAPTER_BACKOFF");
  }
  if (new Set([...managedBookAdapters.keys(), ...bookStarts.keys()]).size >= maximumBookAdapters) {
    throw new GatewayError("The Book adapter resident limit has been reached", 503, "BOOK_ADAPTER_LIMIT");
  }
  if (activeBookStarts >= maximumBookStarts) {
    throw new GatewayError("Too many Book adapters are starting", 503, "BOOK_START_LIMIT");
  }

  activeBookStarts += 1;
  const startup = createManagedBookAdapter(book)
    .then((adapter) => {
      failedBookStarts.delete(book);
      return adapter;
    })
    .catch((error) => {
      failedBookStarts.set(book, Date.now());
      throw error;
    })
    .finally(() => {
      activeBookStarts -= 1;
      bookStarts.delete(book);
    });
  bookStarts.set(book, startup);
  return bookStarts.get(book);
}

async function leaseBookAdapter(book) {
  if (drainingBooks.has(book) || deletingBooks.has(book)) {
    throw new GatewayError(`Book ${book} adapter is draining`, 503, "BOOK_ADAPTER_DRAINING");
  }
  const configured = configuredBookPostgrests.get(book);
  if (configured) return { endpoint: configured, release() {} };

  const adapter = await managedBookAdapter(book);
  if (adapter.draining || drainingBooks.has(book) || deletingBooks.has(book)) {
    throw new GatewayError(`Book ${book} adapter is draining`, 503, "BOOK_ADAPTER_DRAINING");
  }
  adapter.activeRequests += 1;
  let released = false;
  return {
    endpoint: adapter.endpoint,
    release() {
      if (released) return;
      released = true;
      adapter.activeRequests -= 1;
    },
  };
}

async function stopManagedBook(book, reason = "requested") {
  const adapter = managedBookAdapters.get(book);
  bookValidations.delete(book);
  bookIdentityCache.delete(book);
  if (!adapter) return;
  drainingBooks.add(book);
  try {
    adapter.draining = true;
    if (managedBookAdapters.get(book) === adapter) managedBookAdapters.delete(book);

    const deadline = Date.now() + bookShutdownSeconds * 1000;
    while (adapter.activeRequests > 0 && Date.now() < deadline) {
      await new Promise((done) => setTimeout(done, 25));
    }

    const { child } = adapter;
    if (child.exitCode !== null) return;
    console.error(`Stopping Book ${book} PostgREST (${reason})`);
    await terminateChild(child, Math.max(0, deadline - Date.now()));
  } finally {
    drainingBooks.delete(book);
  }
}

async function applyGlobalAccess(databaseRole) {
  await lifecycleOperation({ operation: "grant_role", databaseRole });
}

async function authorizeBookRoute(book, request) {
  const authorizationRequest = {
    url: "/rpc/shell_page",
    method: "POST",
    headers: request.headers,
  };
  const result = await requestBuffered(
    controlPostgrest,
    authorizationRequest,
    Buffer.from(JSON.stringify({ p_book_id: book })),
  );
  if (result.statusCode < 200 || result.statusCode >= 300) {
    const denied = result.statusCode === 401 || result.statusCode === 403;
    throw new GatewayError(
      denied ? "Book access denied" : "The control database could not authorize the Book route",
      denied ? 403 : 502,
      denied ? "BOOK_ACCESS_DENIED" : "BOOK_CATALOGUE_UNAVAILABLE",
    );
  }
  const rows = JSON.parse(result.body.toString("utf8"));
  if (!Array.isArray(rows) || !rows.some((row) => row?.component === "book_option" && row?.payload?.id === book)) {
    throw new GatewayError("Book access denied", 403, "BOOK_ACCESS_DENIED");
  }
}

async function authorizeInvitationLookup(route, request) {
  const isBook = route.kind === "book";
  const result = await requestBuffered(
    controlPostgrest,
    { ...request, url: isBook ? "/rpc/book_acl_page" : "/rpc/admin_page" },
    Buffer.from(JSON.stringify(isBook ? { p_book_id: route.book } : {})),
  );
  if (result.statusCode < 200 || result.statusCode >= 300) {
    const denied = result.statusCode === 401 || result.statusCode === 403 || result.statusCode === 400;
    throw new GatewayError(
      denied ? "Administrator access is required" : "The control database could not authorize the invitation",
      denied ? 403 : 502,
      denied ? "ADMIN_ACCESS_REQUIRED" : "INVITATION_AUTHORIZATION_UNAVAILABLE",
    );
  }
}

async function validateBookAdapter(book, endpoint, routedRequest) {
  const endpointKey = endpoint.href;
  const previous = bookValidations.get(book);
  if (previous?.endpointKey === endpointKey && Date.now() - previous.checkedAt < 60_000) {
    return previous.promise;
  }

  const promise = (async () => {
    const statusRequest = {
      url: "/rpc/adapter_status",
      method: "POST",
      headers: routedRequest.headers,
    };
    const result = await requestBuffered(endpoint, statusRequest, Buffer.from("{}"));
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw new GatewayError(
        `Book ${book} adapter did not expose its authenticated status`,
        502,
        "BOOK_ADAPTER_STATUS_FAILED",
      );
    }
    let rows;
    try {
      rows = JSON.parse(result.body.toString("utf8"));
    } catch {
      throw new GatewayError(`Book ${book} adapter returned invalid status`, 502, "BOOK_ADAPTER_STATUS_INVALID");
    }
    const status = Array.isArray(rows) ? rows[0] : null;
    if (status?.database !== book) {
      throw new GatewayError(
        `Book route ${book} reached database ${status?.database || "unknown"}`,
        502,
        "BOOK_ADAPTER_DATABASE_MISMATCH",
      );
    }
    if (status.schema_version !== bookSchemaVersion) {
      throw new GatewayError(
        `Book ${book} uses schema version ${status.schema_version ?? "unknown"}; expected ${bookSchemaVersion}`,
        503,
        "BOOK_SCHEMA_VERSION_MISMATCH",
      );
    }
  })().catch((error) => {
    if (bookValidations.get(book)?.promise === promise) bookValidations.delete(book);
    throw error;
  });
  bookValidations.set(book, { endpointKey, checkedAt: Date.now(), promise });
  return promise;
}

async function syncBookIdentity(book, upstream) {
  let components;
  try {
    components = JSON.parse(upstream.body.toString("utf8"));
  } catch {
    return;
  }
  if (!Array.isArray(components)) return;
  const identity = components.find((row) => row?.component === "book_identity")?.payload;
  if (!identity) return;
  const canonical = JSON.stringify([
    identity.name, identity.reporting_asset, identity.entity_type, identity.archived_at || "",
  ]);
  const previous = bookIdentityCache.get(book);
  if (previous?.canonical === canonical && Date.now() - previous.syncedAt < 60_000) return;
  const rows = await controlGatewayRpc("sync_gateway_book", {
    p_book_id: book,
    p_name: identity.name,
    p_reporting_asset: identity.reporting_asset,
    p_entity_type: identity.entity_type,
    p_archived_at: identity.archived_at || null,
  });
  if (rows !== true && !(Array.isArray(rows) && rows[0] === true)) {
    throw new GatewayError("Book identity could not be synchronized", 502, "BOOK_SYNC_FAILED");
  }
  bookIdentityCache.set(book, { canonical, syncedAt: Date.now() });
}

async function handleRpc(request, response, session, route) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  const close = () => { if (!response.writableEnded) abort(); };
  const cleanupAbort = () => {
    request.removeListener("aborted", abort);
    response.removeListener("close", close);
  };
  request.once("aborted", abort);
  response.once("close", close);
  let body;
  try {
    body = await readBody(request);
  } catch (error) {
    sendGatewayError(
      response,
      error instanceof GatewayError ? error.message : "The request body could not be read",
      error instanceof GatewayError ? error.detail : "REQUEST_BODY_INVALID",
      error instanceof GatewayError ? error.status : 400,
    );
    cleanupAbort();
    return;
  }
  const routedHeaders = { ...request.headers };
  delete routedHeaders.cookie;
  routedHeaders.authorization = `Bearer ${postgrestJwt(session || {
    principal_id: "unauthenticated-demo",
    database_role: databaseRole,
  })}`;
  const routedRequest = {
    url: route.upstreamPath || request.url,
    method: request.method,
    headers: routedHeaders,
    signal: controller.signal,
  };

  let payload = {};
  let validJson = true;
  try {
    payload = body.length === 0 ? {} : JSON.parse(body.toString("utf8"));
  } catch {
    validJson = false;
    // PostgREST remains authoritative for malformed JSON responses.
  }
  if (route.kind === "book" && validJson) {
    if (payload === null || Array.isArray(payload) || typeof payload !== "object") {
      sendGatewayError(response, "Book RPC bodies must be JSON objects", "BOOK_ROUTE_BODY_INVALID", 400);
      cleanupAbort();
      return;
    }
    if (payload.p_book_id !== undefined && payload.p_book_id !== route.book) {
      sendGatewayError(response, "Book route and p_book_id disagree", "BOOK_ROUTE_MISMATCH", 400);
      cleanupAbort();
      return;
    }
    payload = { ...payload, p_book_id: route.book };
    body = Buffer.from(JSON.stringify(payload));
  }

  const functionName = route.functionName;
  const controlFunction = globalControlFunctions.has(functionName)
    || accessFunctions.has(functionName);
  let bookLease = null;
  let bookAuthorized = false;

  async function authorizeBook(book) {
    if (bookAuthorized) return;
    await authorizeBookRoute(book, routedRequest);
    bookAuthorized = true;
  }

  async function bookTarget(book) {
    await authorizeBook(book);
    if (!bookLease) bookLease = await leaseBookAdapter(book);
    await validateBookAdapter(book, bookLease.endpoint, routedRequest);
    return bookLease.endpoint;
  }

  try {
    if (route.kind === "book") {
      if (globalControlFunctions.has(functionName)) {
        throw new GatewayError(
          `${functionName} belongs on /api/control`,
          400,
          "API_ROUTE_MISMATCH",
        );
      }
      await authorizeBook(route.book);
    }

    if (multiDatabase && functionName === "create_book") {
      const created = await requestBuffered(controlPostgrest, routedRequest, body);
      if (created.statusCode >= 200 && created.statusCode < 300) {
        const rows = JSON.parse(created.body.toString("utf8"));
        const book = rows[0];
        try {
          await lifecycleOperation({
            operation: "create_book",
            book: book.id,
            name: book.name,
            reportingAsset: book.reporting_asset,
            entityType: book.entity_type,
            standardAccounts: payload.p_create_standard_accounts !== false,
          });
        } catch (error) {
          await lifecycleOperation({ operation: "unregister_book", book: book.id }).catch(() => {});
          console.error(`Book ${book.id} provisioning failed:`, error.message);
          sendGatewayError(response, "Book provisioning failed", "BOOK_PROVISIONING_FAILED");
          return;
        }
      }
      sendBuffered(response, created);
      return;
    }

    const book = route.kind === "book" ? route.book : null;

    if (multiDatabase && route.kind === "book" && functionName === "book_settings_page") {
      const target = await bookTarget(book);
      const [settings, access] = await Promise.all([
        requestBuffered(target, routedRequest, body, "/rpc/book_page"),
        requestBuffered(controlPostgrest, routedRequest, body, "/rpc/book_acl_page"),
      ]);
      if (settings.statusCode < 200 || settings.statusCode >= 300) {
        sendBuffered(response, settings);
        return;
      }
      if (access.statusCode < 200 || access.statusCode >= 300) {
        sendBuffered(response, access);
        return;
      }
      const components = [
        ...JSON.parse(settings.body.toString("utf8")),
        ...JSON.parse(access.body.toString("utf8")),
      ];
      const combined = {
        ...settings,
        headers: { ...settings.headers, "content-type": "application/json; charset=utf-8" },
        body: Buffer.from(JSON.stringify(components)),
      };
      await syncBookIdentity(book, settings);
      sendBuffered(response, combined);
      return;
    }

    if (multiDatabase && (functionName === "invite_book_user" || functionName === "invite_global_user")) {
      await authorizeInvitationLookup(route, routedRequest);
      const identity = await githubPublicIdentity(String(payload.p_github_login || ""));
      payload = {
        ...payload,
        p_github_login: identity.login.toLowerCase(),
        p_provider_subject: identity.id,
        p_display_name: typeof identity.name === "string" ? identity.name : identity.login,
      };
      body = Buffer.from(JSON.stringify(payload));
    }

    let target = controlPostgrest;
    let pathname = routedRequest.url;
    const useBookDatabase = multiDatabase && route.kind === "book" && !controlFunction;
    if (useBookDatabase) {
      target = await bookTarget(book);
      if (functionName === "delete_book") {
        pathname = "/rpc/authorize_book_database_deletion";
      }
    } else if (!multiDatabase) {
      target = postgrest;
      if (functionName === "book_settings_page") pathname = "/rpc/book_page";
    }

    const upstream = await requestBuffered(target, routedRequest, body, pathname);

    if (multiDatabase && functionName === "invite_global_user"
        && upstream.statusCode >= 200 && upstream.statusCode < 300) {
      const rows = JSON.parse(upstream.body.toString("utf8"));
      const result = rows.find((row) => row?.component === "global_user_result")?.payload;
      if (!result?.database_role) throw new Error("Global user invitation returned no database role");
      await applyGlobalAccess(result.database_role);
      sendBuffered(response, upstream);
      return;
    }

    if (multiDatabase && functionName === "invite_book_user"
        && upstream.statusCode >= 200 && upstream.statusCode < 300) {
      const rows = JSON.parse(upstream.body.toString("utf8"));
      const result = rows.find((row) => row?.component === "book_access_result")?.payload;
      if (!result?.database_role) throw new Error("Book invitation returned no database role");
      await applyGlobalAccess(result.database_role);
      sendBuffered(response, upstream);
      return;
    }

    if (multiDatabase && book && upstream.statusCode >= 200 && upstream.statusCode < 300) {
      if (functionName === "delete_book") {
        bookLease?.release();
        bookLease = null;
        deletingBooks.add(book);
        try {
          await stopManagedBook(book);
          await lifecycleOperation({
            operation: "delete_book", book, confirmName: payload.p_confirm_name || "",
          });
        } finally {
          deletingBooks.delete(book);
        }
        const shellRequest = {
          url: "/rpc/shell_page",
          method: "POST",
          headers: routedRequest.headers,
        };
        const shell = await requestBuffered(controlPostgrest, shellRequest, Buffer.from("{}"));
        sendBuffered(response, shell);
        return;
      }
      await syncBookIdentity(book, upstream);
    }

    sendBuffered(response, upstream);
  } catch (error) {
    if (controller.signal.aborted || response.destroyed) return;
    if (!(error instanceof GatewayError)) {
      console.error(`RPC ${functionName} failed:`, error.message);
    }
    sendGatewayError(
      response,
      error instanceof GatewayError ? error.message : "The requested operation could not be completed",
      error instanceof GatewayError ? error.detail : "BOOK_DATABASE_ROUTING_FAILED",
      error instanceof GatewayError ? error.status : 502,
    );
  } finally {
    bookLease?.release();
    cleanupAbort();
  }
}

async function serveStatic(request, response) {
  let filename;
  try {
    const pathname = new URL(request.url, "http://localhost").pathname;
    const relative = pathname === "/" ? "index.html" : decodeURIComponent(pathname.slice(1));
    if (!staticFiles.has(relative)) {
      sendText(response, 404, "Not found");
      return;
    }
    filename = resolve(frontend, relative);
  } catch {
    response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
    response.end("Bad request\n");
    return;
  }

  if (filename !== frontend && !filename.startsWith(frontend + sep)) {
    response.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
    response.end("Forbidden\n");
    return;
  }

  try {
    const details = await stat(filename);
    if (!details.isFile()) throw new Error("not a file");
    response.writeHead(200, {
      "content-type": contentTypes.get(extname(filename)) || "application/octet-stream",
      "content-length": details.size,
      "cache-control": "no-cache",
    });
    if (request.method === "HEAD") {
      response.end();
    } else {
      const stream = createReadStream(filename);
      stream.on("error", (error) => response.destroy(error));
      stream.pipe(response);
    }
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found\n");
  }
}

function explicitApiRoute(requestUrl) {
  const parsed = new URL(requestUrl || "/", `http://${host}`);
  let match = parsed.pathname.match(/^\/api\/control\/rpc\/([a-z][a-z0-9_]*)$/);
  if (match) {
    if (parsed.search) return { kind: "query" };
    return {
      kind: "control",
      functionName: match[1],
      upstreamPath: `/rpc/${match[1]}`,
    };
  }

  match = parsed.pathname.match(/^\/api\/books\/([a-z][a-z0-9_-]{0,62})\/rpc\/([a-z][a-z0-9_]*)$/);
  if (match) {
    if (parsed.search) return { kind: "query" };
    return {
      kind: "book",
      book: match[1],
      functionName: match[2],
      upstreamPath: `/rpc/${match[2]}`,
    };
  }
  return parsed.pathname.startsWith("/api/") ? { kind: "invalid" } : null;
}

async function controlIsReady() {
  try {
    if (controlPostgrestAdmin) {
      const response = await fetch(new URL("/ready", controlPostgrestAdmin), {
        signal: AbortSignal.timeout(2_000),
      });
      return response.ok;
    }
    await controlGatewayRpc("resolve_gateway_session", { p_token_hash: "0".repeat(64) });
    return true;
  } catch {
    return false;
  }
}

const server = createServer((request, response) => {
  response.setHeader("content-security-policy", "default-src 'self'; base-uri 'none'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'");
  response.setHeader("permissions-policy", "camera=(), geolocation=(), microphone=(), payment=(), usb=()");
  response.setHeader("referrer-policy", "no-referrer");
  response.setHeader("x-content-type-options", "nosniff");
  response.setHeader("x-frame-options", "DENY");
  const pathname = new URL(request.url || "/", "http://localhost").pathname;
  const admissionExempt = pathname === "/healthz" || pathname === "/readyz";
  if (!admissionExempt && activeRequests >= maximumConcurrentRequests) {
    sendText(response, 503, "Server is busy", { "retry-after": "1" });
    return;
  }
  if (!admissionExempt) activeRequests += 1;
  void (async () => {

    if (pathname === "/healthz" && (request.method === "GET" || request.method === "HEAD")) {
      response.writeHead(200, {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-store",
      });
      response.end(request.method === "HEAD" ? undefined : "ok\n");
      return;
    }

    if (pathname === "/readyz" && (request.method === "GET" || request.method === "HEAD")) {
      const ready = await controlIsReady();
      response.writeHead(ready ? 200 : 503, {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-store",
      });
      response.end(request.method === "HEAD" ? undefined : ready ? "ready\n" : "not ready\n");
      return;
    }

    if (githubAuthentication && pathname === "/auth/login" && request.method === "GET") {
      if (!allowAuthenticationAttempt(request, "login")) {
        sendText(response, 429, "Too many authentication attempts", { "retry-after": "60" });
        return;
      }
      await handleLogin(request, response);
      return;
    }
    if (githubAuthentication && pathname === "/auth/callback" && request.method === "GET") {
      if (!allowAuthenticationAttempt(request, "callback")) {
        sendText(response, 429, "Too many authentication attempts", { "retry-after": "60" });
        return;
      }
      await handleCallback(request, response);
      return;
    }
    if (githubAuthentication && pathname === "/auth/logout" && request.method === "POST") {
      if (!requestOriginIsPublic(request)) {
        sendText(response, 403, "Request origin is not allowed");
        return;
      }
      await handleLogout(request, response);
      return;
    }
    if (githubAuthentication && pathname === "/auth/me" && request.method === "GET") {
      const session = await requireSession(request, response);
      if (!session) return;
      const release = acquireSessionPermit(session);
      if (!release) {
        sendText(response, 429, "Too many concurrent requests", { "retry-after": "1" });
        return;
      }
      try {
        const body = Buffer.from(JSON.stringify({
          principal_id: session.principal_id,
          database_role: session.database_role,
          provider_login: session.provider_login,
        }));
        response.writeHead(200, {
          "content-type": "application/json; charset=utf-8",
          "content-length": body.length,
          "cache-control": "no-store",
        });
        response.end(body);
      } finally {
        release();
      }
      return;
    }
    if (pathname.startsWith("/auth/")) {
      sendText(response, githubAuthentication ? 404 : 503, githubAuthentication
        ? "Authentication route not found"
        : "GitHub authentication is not configured");
      return;
    }

    const apiRoute = explicitApiRoute(request.url);
    if (apiRoute) {
      if (apiRoute.kind === "query") {
        sendText(response, 400, "RPC query strings are not allowed");
        return;
      }
      if (apiRoute.kind === "invalid") {
        sendText(response, 404, "API route not found");
        return;
      }
      if (request.method !== "POST") {
        response.writeHead(405, { allow: "POST" }).end();
        return;
      }
      if (!String(request.headers["content-type"] || "").toLowerCase().startsWith("application/json")) {
        sendText(response, 415, "RPC requests require application/json");
        return;
      }
      if (githubAuthentication && !requestOriginIsPublic(request)) {
        sendText(response, 403, "Request origin is not allowed");
        return;
      }
      const session = githubAuthentication ? await requireSession(request, response) : null;
      if (githubAuthentication && !session) return;
      const release = session ? acquireSessionPermit(session) : () => {};
      if (!release) {
        sendText(response, 429, "Too many concurrent requests", { "retry-after": "1" });
        return;
      }
      try {
        await handleRpc(request, response, session, apiRoute);
      } finally {
        release();
      }
      return;
    }

    if (pathname.startsWith("/rpc/")) {
      sendText(response, 404, "Use an explicit control or Book API route");
      return;
    }
    if (request.method === "GET" || request.method === "HEAD") {
      if (githubAuthentication && (pathname === "/" || pathname === "/index.html")) {
        const session = await requireSession(request, response, true);
        if (!session) return;
      }
      await serveStatic(request, response);
      return;
    }
    response.writeHead(405, { allow: "GET, HEAD" }).end();
  })().catch((error) => {
    console.error("Request failed:", error.message);
    if (!response.headersSent) sendText(response, 500, "Internal server error");
    else response.destroy();
  }).finally(() => {
    if (!admissionExempt) activeRequests -= 1;
  });
});

server.requestTimeout = 40_000;
server.headersTimeout = 15_000;
server.keepAliveTimeout = 5_000;
server.maxHeadersCount = 100;

server.listen(port, host, () => {
  process.stdout.write(`Njord UI listening on http://${host}:${port}\n`);
});

let shuttingDown = false;
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    if (shuttingDown) return;
    shuttingDown = true;
    const serverClosed = new Promise((done) => {
      const forceClose = setTimeout(() => server.closeAllConnections?.(), bookShutdownSeconds * 1000);
      server.close(() => {
        clearTimeout(forceClose);
        done();
      });
    });
    server.closeIdleConnections?.();
    void Promise.all([
      serverClosed,
      ...[...managedBookAdapters.keys()].map((book) => stopManagedBook(book, signal)),
    ]).finally(() => process.exit(0));
  });
}
