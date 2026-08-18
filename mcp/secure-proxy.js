import http from "http";
import { spawn } from "child_process";

const PUBLIC_PORT = Number(process.env.PORT || 8787);
const INTERNAL_PORT = Number(process.env.MCP_INTERNAL_PORT || 8788);
const ACCESS_TOKEN = String(
  process.env.MCP_ACCESS_TOKEN ||
  process.env.LINJIAN_TOKEN ||
  ""
).trim();

if (!ACCESS_TOKEN) {
  console.error("Missing MCP_ACCESS_TOKEN (or LINJIAN_TOKEN fallback). Refusing to start insecure MCP proxy.");
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

function isPublicPath(url = "") {
  const path = String(url).split("?", 1)[0];
  return path === "/" || path === "/health";
}

const proxy = http.createServer((req, res) => {
  if (!isPublicPath(req.url)) {
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
      path: req.url,
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
  console.log("Auth: Authorization: Bearer <MCP_ACCESS_TOKEN>; falling back to LINJIAN_TOKEN when MCP_ACCESS_TOKEN is unset.");
});
