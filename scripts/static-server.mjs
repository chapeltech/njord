import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer, request as proxyRequest } from "node:http";
import { extname, resolve, sep } from "node:path";

const host = process.env.PLUTUS_UI_HOST || "127.0.0.1";
const port = Number(process.env.PLUTUS_UI_PORT || "8080");
const postgrest = new URL(process.env.PLUTUS_POSTGREST_URL || "http://127.0.0.1:3000");
const frontend = resolve(process.cwd(), "frontend");

const contentTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
]);

function proxy(request, response) {
  let target;
  try {
    target = new URL(request.url, postgrest);
  } catch {
    response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
    response.end("Bad request\n");
    return;
  }

  const headers = { ...request.headers, host: postgrest.host };
  const upstream = proxyRequest(
    target,
    { method: request.method, headers },
    (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    },
  );

  upstream.on("error", (error) => {
    if (response.headersSent) {
      response.destroy(error);
      return;
    }
    response.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    response.end(`PostgREST is unavailable: ${error.message}\n`);
  });
  request.pipe(upstream);
}

async function serveStatic(request, response) {
  let filename;
  try {
    const pathname = new URL(request.url, `http://${request.headers.host || host}`).pathname;
    const relative = pathname === "/" ? "index.html" : decodeURIComponent(pathname.slice(1));
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

createServer((request, response) => {
  if ((request.url || "").startsWith("/rpc/")) {
    proxy(request, response);
  } else if (request.method === "GET" || request.method === "HEAD") {
    void serveStatic(request, response);
  } else {
    response.writeHead(405, { allow: "GET, HEAD" }).end();
  }
}).listen(port, host, () => {
  process.stdout.write(`Plutus UI listening on http://${host}:${port}\n`);
});
