import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";

const temporary = await mkdtemp(join(tmpdir(), "njord-broker-test."));
const socketPath = join(temporary, "lifecycle.sock");
const broker = spawn(process.execPath, ["scripts/lifecycle-broker.mjs"], {
  env: { ...process.env, NJORD_LIFECYCLE_BROKER_SOCKET: socketPath },
  stdio: ["ignore", "ignore", "ignore"],
});

function request(payload) {
  return new Promise((resolve, reject) => {
    const connection = createConnection(socketPath);
    let response = "";
    connection.setEncoding("utf8");
    connection.on("connect", () => connection.end(payload));
    connection.on("data", (chunk) => { response += chunk; });
    connection.on("end", () => resolve(response));
    connection.on("error", reject);
  });
}

try {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const response = await request("not-json");
      assert.equal(response, '{"ok":false}\n');
      break;
    } catch (error) {
      if (attempt === 99) throw error;
      await new Promise((done) => setTimeout(done, 20));
    }
  }
  assert.equal(await request('{"operation":"unknown"}'), '{"ok":false}\n');
  assert.equal(broker.exitCode, null, "a rejected request stopped the lifecycle broker");
  process.stdout.write("ok - lifecycle broker rejects invalid requests without stopping\n");
} finally {
  broker.kill("SIGTERM");
  await new Promise((done) => broker.once("exit", done));
  await rm(temporary, { recursive: true, force: true });
}
