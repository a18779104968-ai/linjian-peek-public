import http from "http";
import { spawn } from "child_process";

const PUBLIC_PORT = Number(process.env.PORT || 8787);
const INTERNAL_PORT = Number(process.env.MCP_INTERNAL_PORT || 8788);

const ACCESS_TOKEN = String(
  process.env.MCP_ACCESS_TOKEN ||
  process.env.LINJIAN_TOKEN ||
  ""
).trim();

const PATH_SECRET = String(process.env.MCP_PATH_SECRET || "").trim();

if (!ACCESS_TOKEN) {
  console.error("Missing MCP_ACCESS_TOKEN (or LINJIAN_TOKEN fallback). Refusing to start insecure MCP proxy.");
  process.exit(1);
}
if (!PATH_SECRET) {
  console.error("Missing MCP_PATH_SECRET. Refusing to expose unauthenticated MCP path.");
  process.exit(1);
}

const child = spawn(
  process.execPath,
  ["server.js"],
  {
    stdio: "inherit",
    env: {
      ...process.env,
      PORT: String(INTERNAL_PORT),
    },
  }
);

child.on("exit", (code, signal) => {
  console.error(`Inner MCP server exited: code=${code} signal=${signal}`);
  process.exit(code ?? 1);
});

function unauthorized(res) {
  res.writeHead(401, {
    "Content-Type": "application/json; charset=utf-8",
    "WWW-Authenticate": 'Bearer realm="zhangxinchuang-mcp"',
  });
  res.end(JSON.stringify({ ok: false, error: "unauthorized" }));
}

function splitUrl(raw = "") {
  const i = raw.indexOf("?");
  return i >= 0
    ? { path: raw.slice(0, i), query: raw.slice(i) }
    : { path: raw, query: "" };
}

function publicPath(url = "") {
  const { path } = splitUrl(String(url));
  return path === "/" || path === "/health";
}

function secretMcpPath(url = "") {
  const { path, query } = splitUrl(String(url));
  const expected = `/mcp/${encodeURIComponent(PATH_SECRET)}`;
  if (path === expected) {
    return `/mcp${query}`;
  }
  return "";
}

const proxy = http.createServer((req, res) => {
  const rewrittenSecretPath = secretMcpPath(req.url);

  // Public health/root remain open.
  // Secret URL authenticates by possession of MCP_PATH_SECRET.
  // All other MCP/SSE/message paths still require Bearer authentication.
  if (!publicPath(req.url) && !rewrittenSecretPath) {
    const expected = `Bearer ${ACCESS_TOKEN}`;
    const actual = String(req.headers.authorization || "");
    if (actual !== expected) {
      unauthorized(res);
      return;
    }
  }

  const headers = { ...req.headers };
  headers.host = `127.0.0.1:${INTERNAL_PORT}`;

  const upstream = http.request(
    {
      hostname: "127.0.0.1",
      port: INTERNAL_PORT,
      path: rewrittenSecretPath || req.url,
      method: req.method,
      headers,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
      upstreamRes.pipe(res);
    }
  );

  upstream.on("error", (err) => {
    console.error("MCP proxy upstream error:", err);
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "application/json; charset=utf-8" });
    }
    res.end(JSON.stringify({ ok: false, error: "bad_gateway" }));
  });

  req.pipe(upstream);
});

proxy.listen(PUBLIC_PORT, "0.0.0.0", () => {
  console.log(`Secure MCP proxy listening on 0.0.0.0:${PUBLIC_PORT}`);
  console.log(`Inner MCP listening on 127.0.0.1:${INTERNAL_PORT}`);
  console.log("Bearer auth remains enabled for /mcp, /sse, /messages.");
  console.log("Secret-path auth enabled at /mcp/<MCP_PATH_SECRET>.");
});
