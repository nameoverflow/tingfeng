#!/usr/bin/env node
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import crypto from "node:crypto";

const CLIENT_DIR = path.resolve(import.meta.dirname, "..");
const REPO_ROOT = path.resolve(CLIENT_DIR, "..");
const PUBLIC_DIR = fs.existsSync(path.join(CLIENT_DIR, "dist/wasm/tingfeng.wasm"))
  ? path.join(CLIENT_DIR, "dist")
  : path.join(CLIENT_DIR, "public");

// Parse --port flag (used by Playwright webServer) or $PORT env
let portArg = parseInt(process.env.PORT || "8080", 10);
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === "--port" && process.argv[i + 1]) {
    portArg = parseInt(process.argv[i + 1], 10);
  }
}
const GAME_WS_PORT = parseInt(process.env.GAME_WS_PORT || "9160", 10);

const DATA_FILES = {
  "/data/svg-poses.json": path.join(REPO_ROOT, "resources/scripts/combat_presentation/svg-poses.json"),
  "/data/staging.json": path.join(REPO_ROOT, "resources/scripts/combat_presentation/staging.json"),
  "/data/fist.json": path.join(REPO_ROOT, "resources/scripts/combat_actions/fist.json"),
  "/data/sword.json": path.join(REPO_ROOT, "resources/scripts/combat_actions/sword.json"),
  "/data/effects.json": path.join(REPO_ROOT, "resources/scripts/combat_actions/effects.json"),
};

const FIXTURES_SHIM = `
if (globalThis.__tfHsReady) await globalThis.__tfHsReady;
export function seedBattle(playerProfile = "female", enemyProfile = "male") {
  globalThis.__tfHsFixtures?.seed(playerProfile, enemyProfile);
}
export function submitBattleAction(actionId, result = "hit", actorSide = "player", damage = 18) {
  globalThis.__tfHsFixtures?.submit(actionId, result, actorSide, damage);
}
export function playBattleDemo() {
  globalThis.__tfHsFixtures?.demo();
}
`;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".ts": "application/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".webp": "image/webp",
};

// Event-driven low-latency HTTP <-> WebSocket bridge (piggybacked send + instant-wake long-poll)
const sessions = new Map();

function wakeWaiters(sess) {
  while (sess.waiters.length > 0 && (sess.queue.length > 0 || sess.closed)) {
    const resolve = sess.waiters.shift();
    resolve();
  }
}

setInterval(() => {
  const now = Date.now();
  for (const [sid, s] of sessions.entries()) {
    if (now - s.lastSeen > 180_000) {
      s.closed = true;
      wakeWaiters(s);
      try { s.ws.close(); } catch (_) {}
      sessions.delete(sid);
    }
  }
}, 30_000).unref();

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
    req.on("error", reject);
  });
}

function sendJson(res, status, obj) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(obj));
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);

    if (url.pathname === "/favicon.ico") {
      res.writeHead(204);
      return res.end();
    }

    if (url.pathname === "/src/battle/battleFixtures.ts") {
      res.writeHead(200, { "Content-Type": "application/javascript; charset=utf-8", "Cache-Control": "no-store" });
      return res.end(FIXTURES_SHIM);
    }

    if (req.method === "POST" && url.pathname === "/api/bridge/open") {
      await readBody(req);
      const sessionId = crypto.randomUUID();
      const ws = new WebSocket(`ws://127.0.0.1:${GAME_WS_PORT}`);
      const sess = { ws, queue: [], outbox: [], waiters: [], open: false, closed: false, lastSeen: Date.now() };
      sessions.set(sessionId, sess);
      ws.addEventListener("open", () => {
        sess.open = true;
        for (const msg of sess.outbox.splice(0)) ws.send(msg);
      });
      ws.addEventListener("message", (ev) => {
        if (typeof ev.data === "string") {
          sess.queue.push(ev.data);
          wakeWaiters(sess);
        }
      });
      ws.addEventListener("close", () => { sess.closed = true; wakeWaiters(sess); });
      ws.addEventListener("error", () => { sess.closed = true; wakeWaiters(sess); });
      return sendJson(res, 200, { sessionId });
    }

    if (req.method === "POST" && url.pathname === "/api/bridge/send") {
      const { sessionId, payload } = JSON.parse((await readBody(req)) || "{}");
      const sess = sessions.get(sessionId);
      if (!sess) return sendJson(res, 404, { error: "session_not_found" });
      sess.lastSeen = Date.now();
      if (sess.open && sess.ws.readyState === WebSocket.OPEN) sess.ws.send(payload);
      else if (!sess.closed) sess.outbox.push(payload);

      // Piggyback immediate server reply (e.g. MoveMsg + ViewMsg) within 35ms!
      if (sess.queue.length === 0 && !sess.closed) {
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 35);
          sess.waiters.push(() => { clearTimeout(timer); setTimeout(resolve, 6); });
        });
      }
      const messages = sess.queue.splice(0, 64);
      return sendJson(res, 200, { ok: true, messages });
    }

    if (req.method === "POST" && url.pathname === "/api/bridge/poll") {
      const { sessionId } = JSON.parse((await readBody(req)) || "{}");
      const sess = sessions.get(sessionId);
      if (!sess) return sendJson(res, 200, { messages: [], closed: true });
      sess.lastSeen = Date.now();
      if (sess.queue.length === 0 && !sess.closed) {
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 2200);
          sess.waiters.push(() => { clearTimeout(timer); resolve(); });
        });
      }
      const messages = sess.queue.splice(0, 64);
      return sendJson(res, 200, { messages, closed: sess.closed });
    }

    if (url.pathname in DATA_FILES) {
      const raw = fs.readFileSync(DATA_FILES[url.pathname]);
      res.writeHead(200, { "Content-Type": MIME[".json"], "Cache-Control": "no-cache" });
      return res.end(raw);
    }

    if (url.pathname.startsWith("/portraits/")) {
      const pName = path.basename(url.pathname);
      const pFile = fs.existsSync(path.join(PUBLIC_DIR, "portraits", pName))
        ? path.join(PUBLIC_DIR, "portraits", pName)
        : path.join(CLIENT_DIR, "src/assets/portraits", pName);
      if (fs.existsSync(pFile)) {
        res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "max-age=3600" });
        return res.end(fs.readFileSync(pFile));
      }
    }

    const rel = url.pathname === "/" ? "index.html" : url.pathname.replace(/^\/+/, "");
    const filePath = path.resolve(PUBLIC_DIR, rel);
    if (!filePath.startsWith(PUBLIC_DIR) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      res.writeHead(404);
      return res.end("Not found");
    }

    const ext = path.extname(filePath);
    const mime = MIME[ext] || "application/octet-stream";
    const raw = fs.readFileSync(filePath);
    if ((req.headers["accept-encoding"] || "").includes("gzip") && raw.length > 2048) {
      res.writeHead(200, { "Content-Type": mime, "Content-Encoding": "gzip", "Cache-Control": "no-cache" });
      return res.end(zlib.gzipSync(raw, { level: 6 }));
    }
    res.writeHead(200, { "Content-Type": mime, "Cache-Control": "no-cache" });
    res.end(raw);
  } catch (err) {
    res.writeHead(500);
    res.end(String(err));
  }
});

server.on("upgrade", (req, clientSocket, head) => {
  const upstream = net.connect(GAME_WS_PORT, "127.0.0.1", () => {
    const headers = ["GET / HTTP/1.1"];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      headers.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    }
    upstream.write(headers.join("\r\n") + "\r\n\r\n");
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  upstream.on("error", () => clientSocket.destroy());
  clientSocket.on("error", () => upstream.destroy());
});

server.listen(portArg, "127.0.0.1", () => {
  console.log(`Tingfeng Pure-Geisha Wasm client listening on http://127.0.0.1:${portArg}`);
});
