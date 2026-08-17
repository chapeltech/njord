#!/usr/bin/env node

import { chmod, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { createServer } from "node:net";
import { resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const repository = resolve(import.meta.dirname, "..");
const socketPath = process.env.NJORD_LIFECYCLE_BROKER_SOCKET || "/run/njord/lifecycle.sock";
const controlDatabase = process.env.NJORD_CONTROL_DATABASE || "njord";
const authenticatorRole = process.env.NJORD_POSTGREST_AUTHENTICATOR_ROLE || "njord_authenticator";
const timeout = Number(process.env.NJORD_LIFECYCLE_TIMEOUT_MS || 120_000);
const bookPattern = /^[a-z][a-z0-9_-]{0,62}$/;
const rolePattern = /^[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?$/;
let operations = Promise.resolve();
let pendingOperations = 0;
const maximumPendingOperations = Number(process.env.NJORD_MAX_LIFECYCLE_QUEUE || 32);
const loggedOperations = new Set(["create_book", "delete_book", "unregister_book", "grant_role"]);
if (!Number.isSafeInteger(maximumPendingOperations)
    || maximumPendingOperations < 1 || maximumPendingOperations > 256) {
  throw new Error("NJORD_MAX_LIFECYCLE_QUEUE must be an integer from 1 through 256");
}

function environment(extra = {}) {
  const result = {
    PATH: process.env.PATH,
    HOME: process.env.HOME || "/var/lib/postgresql",
    PGHOST: process.env.PGHOST || "/var/run/postgresql",
    PGPORT: process.env.PGPORT || "5432",
    PGUSER: process.env.PGUSER || "postgres",
    NJORD_CONTROL_DATABASE: controlDatabase,
    NJORD_POSTGREST_AUTHENTICATOR_ROLE: authenticatorRole,
    NJORD_LOCK_DIR: process.env.NJORD_LOCK_DIR || "/run/njord/locks",
    ...extra,
  };
  return Object.fromEntries(Object.entries(result).filter(([, value]) => value !== undefined));
}

async function execute(program, args, extra = {}) {
  return execFileAsync(program, args, {
    cwd: repository,
    env: environment(extra),
    maxBuffer: 2 * 1024 * 1024,
    timeout,
    killSignal: "SIGKILL",
  });
}

async function psql(database, script, variables = {}) {
  const args = ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", database];
  for (const [name, value] of Object.entries(variables)) args.push("-v", `${name}=${value}`);
  args.push("-f", resolve(repository, "sql", script));
  return execute(process.env.PSQL || "psql", args);
}

async function catalogueScalar(query) {
  const { stdout } = await execute(process.env.PSQL || "psql", [
    "-X", "-qAt", "-d", controlDatabase, "-c", query,
  ]);
  return stdout.trim();
}

async function handle(message) {
  if (!message || typeof message !== "object" || Array.isArray(message)) throw new Error("invalid request");
  const { operation } = message;
  if (operation === "create_book") {
    const { book, name, reportingAsset, entityType, standardAccounts } = message;
    if (!bookPattern.test(book) || typeof name !== "string" || name.length > 200
        || !/^[A-Z][A-Z0-9]{0,15}$/.test(reportingAsset)
        || !/^[a-z][a-z0-9_-]{0,62}$/.test(entityType)
        || typeof standardAccounts !== "boolean") throw new Error("invalid create_book request");
    if (await catalogueScalar(`SELECT count(*) FROM njord_control.books WHERE id = '${book}' AND provisioning_state = 'provisioning'`) !== "1") {
      throw new Error("Book is not awaiting provisioning");
    }
    await execute(resolve(repository, "scripts/create-book-database"), [
      book, name, reportingAsset, entityType, standardAccounts ? "true" : "false",
    ], { NJORD_BOOK_ALREADY_REGISTERED: "1" });
    await psql(book, "grant-book-gateway.sql", { book_id: book, authenticator_role: authenticatorRole });
    return;
  }
  if (operation === "delete_book") {
    const { book, confirmName } = message;
    if (!bookPattern.test(book) || typeof confirmName !== "string" || confirmName.length > 200) {
      throw new Error("invalid delete_book request");
    }
    if (await catalogueScalar(`SELECT count(*) FROM njord_control.books WHERE id = '${book}'`) !== "1") {
      throw new Error("Book is not registered");
    }
    await execute(resolve(repository, "scripts/delete-book-database"), [book, confirmName]);
    return;
  }
  if (operation === "unregister_book") {
    const { book } = message;
    if (!bookPattern.test(book)) throw new Error("invalid unregister_book request");
    await psql(controlDatabase, "unregister-book.sql", { book_id: book });
    return;
  }
  if (operation === "grant_role") {
    const { databaseRole } = message;
    if (!rolePattern.test(databaseRole)) throw new Error("invalid grant_role request");
    if (await catalogueScalar(`SELECT count(*) FROM njord_control.principals WHERE database_role = '${databaseRole}' AND disabled_at IS NULL`) !== "1") {
      throw new Error("principal is not enabled");
    }
    await psql("postgres", "create-user-role.sql", { database_role: databaseRole });
    await psql("postgres", "grant-role-to-authenticator.sql", {
      database_role: databaseRole, authenticator_role: authenticatorRole,
    });
    await psql(controlDatabase, "grant-control-user.sql", {
      control_database: controlDatabase, database_role: databaseRole,
    });
    return;
  }
  throw new Error("unsupported operation");
}

await rm(socketPath, { force: true });
process.umask(0o007);
const server = createServer({ allowHalfOpen: true }, (connection) => {
  let input = "";
  connection.setTimeout(5_000, () => connection.destroy());
  connection.setEncoding("utf8");
  connection.on("data", (chunk) => {
    input += chunk;
    if (Buffer.byteLength(input) > 64 * 1024) connection.destroy();
  });
  connection.on("end", () => {
    if (pendingOperations >= maximumPendingOperations) {
      connection.end('{"ok":false}\n');
      return;
    }
    pendingOperations += 1;
    operations = operations.then(async () => {
      let operation = "request";
      try {
        const message = JSON.parse(input);
        if (loggedOperations.has(message?.operation)) operation = message.operation;
        await handle(message);
        connection.end('{"ok":true}\n');
      } catch (error) {
        const rawClassification = String(error.code ?? "rejected");
        const classification = /^[A-Za-z0-9_-]{1,32}$/.test(rawClassification)
          ? rawClassification : "rejected";
        process.stderr.write(`Lifecycle ${operation} failed (${classification})\n`);
        connection.end('{"ok":false}\n');
      }
    }).finally(() => { pendingOperations -= 1; });
  });
});
server.maxConnections = maximumPendingOperations + 4;
server.listen(socketPath, async () => {
  await chmod(socketPath, 0o660);
  process.stdout.write(`Lifecycle broker listening on ${socketPath}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
