import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";

const host = "0.0.0.0";
const port = Number(process.env.PORT || 18084);
const clientId = process.env.TEST_GITHUB_CLIENT_ID || "compose-oauth-client";
const clientSecret = process.env.TEST_GITHUB_CLIENT_SECRET || "compose-oauth-client-secret";
const publicOrigin = process.env.TEST_PUBLIC_ORIGIN || "https://accounts.test";
const people = new Map([
  ["elric1", { id: 1001, login: "elric1", name: "Elric One" }],
  ["friend1", { id: 1002, login: "friend1", name: "Friendly User" }],
  ["observer1", { id: 1003, login: "observer1", name: "Outside Observer" }],
  ["expired1", { id: 1004, login: "expired1", name: "Expired Invitation" }],
]);
const aliases = new Map([...people.keys()].map((login) => [login, login]));
const codes = new Map();
const accessTokens = new Map();
let currentIdentity = "elric1";

function json(response, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": body.length,
    "cache-control": "no-store",
  });
  response.end(body);
}

async function bodyJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function currentPerson() {
  return people.get(currentIdentity);
}

const server = createServer((request, response) => {
  void (async () => {
    const url = new URL(request.url || "/", `http://${request.headers.host || "github"}`);

    if (request.method === "GET" && url.pathname === "/healthz") {
      json(response, 200, { ok: true });
      return;
    }

    if (request.method === "POST" && url.pathname === "/__test/identity") {
      const login = String(url.searchParams.get("login") || "").toLowerCase();
      const canonical = aliases.get(login);
      if (!canonical || !people.has(canonical)) {
        json(response, 404, { error: "unknown test identity" });
        return;
      }
      currentIdentity = canonical;
      json(response, 200, currentPerson());
      return;
    }

    if (request.method === "POST" && url.pathname === "/__test/rename") {
      const login = String(url.searchParams.get("login") || "").toLowerCase();
      if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(login)) {
        json(response, 400, { error: "invalid test login" });
        return;
      }
      const person = currentPerson();
      aliases.set(login, currentIdentity);
      person.login = login;
      json(response, 200, person);
      return;
    }

    if (request.method === "GET" && url.pathname === "/authorize") {
      if (url.searchParams.get("client_id") !== clientId
          || url.searchParams.get("redirect_uri") !== `${publicOrigin}/auth/callback`
          || url.searchParams.get("code_challenge_method") !== "S256"
          || url.searchParams.get("allow_signup") !== "false") {
        json(response, 400, { error: "invalid authorization request" });
        return;
      }
      const state = url.searchParams.get("state");
      const challenge = url.searchParams.get("code_challenge");
      if (!state || !challenge) {
        json(response, 400, { error: "missing OAuth state or PKCE challenge" });
        return;
      }
      const code = randomBytes(18).toString("base64url");
      codes.set(code, { challenge, identity: currentIdentity });
      const callback = new URL("/auth/callback", publicOrigin);
      callback.searchParams.set("code", code);
      callback.searchParams.set("state", state);
      response.writeHead(302, { location: callback.href, "cache-control": "no-store" });
      response.end();
      return;
    }

    if (request.method === "POST" && url.pathname === "/token") {
      const payload = await bodyJson(request);
      const authorization = codes.get(payload.code);
      const verifierChallenge = typeof payload.code_verifier === "string"
        ? createHash("sha256").update(payload.code_verifier).digest("base64url")
        : "";
      if (payload.client_id !== clientId
          || payload.client_secret !== clientSecret
          || payload.redirect_uri !== `${publicOrigin}/auth/callback`
          || !authorization
          || authorization.challenge !== verifierChallenge) {
        json(response, 400, { error: "invalid_grant" });
        return;
      }
      codes.delete(payload.code);
      const token = randomBytes(24).toString("base64url");
      accessTokens.set(token, authorization.identity);
      json(response, 200, { access_token: token, token_type: "bearer" });
      return;
    }

    if (request.method === "GET" && url.pathname === "/user") {
      const token = String(request.headers.authorization || "").replace(/^Bearer /, "");
      const identity = accessTokens.get(token);
      if (!identity) {
        json(response, 401, { message: "Bad credentials" });
        return;
      }
      json(response, 200, people.get(identity));
      return;
    }

    const userMatch = request.method === "GET" && url.pathname.match(/^\/users\/([^/]+)$/);
    if (userMatch) {
      const requested = decodeURIComponent(userMatch[1]).toLowerCase();
      const identity = aliases.get(requested);
      if (!identity) {
        json(response, 404, { message: "Not Found" });
        return;
      }
      json(response, 200, people.get(identity));
      return;
    }

    json(response, 404, { message: "Not Found" });
  })().catch((error) => json(response, 500, { error: error.message }));
});

server.listen(port, host, () => {
  process.stdout.write(`Fake GitHub listening on http://${host}:${port}\n`);
});
