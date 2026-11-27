// Tingfeng (《听风录》) Crema Bootstrapper (`client/public/app.js`).
// Generic UI layout, binary DrawList rendering, and IME are handled by `geisha-lang/crema` (`/wasm/crema.js`).
// Tingfeng-specific Xuan-paper background overlay, martial WebAudio SFX, localStorage, and WS/HTTP bridge
// live here and are injected cleanly via `mountCremaApp` hooks (`onClearBg`, `fonts`, `extraImports`).

import { mountCremaApp } from "/wasm/crema.js";

const pageKind = document.body.dataset.page || "game";
const canvas = document.getElementById("c2d-stage");
const imeInput = document.getElementById("ime-proxy");
const stageProbe = document.getElementById("stage-probe");
const reducedMotionQuery = matchMedia("(prefers-reduced-motion: reduce)");

let resolveWasmReady = null;
globalThis.__tfHsReady = new Promise((r) => { resolveWasmReady = r; });

let cremaApp = null;
let wasmReady = false;
let latestLabStateObj = {
  stageEventId: "idle",
  playerDashX: 0,
  playerDashY: 0,
  soundOn: false,
  logCount: 0,
  game: { battle: { active: false, player: null, enemy: null, presentation: null, animation: { activeTimeline: null, queueDepth: 0 } } },
  playback: { paused: false, speed: 1, elapsedMs: 0, durationMs: 0 },
};

// ============================================================================
// 1. Song-Dynasty Xuan-Paper Grain & Vignette Overlay
// ============================================================================

let paperPattern = null;
function ensurePaperPattern(ctx) {
  if (paperPattern !== null) return paperPattern;
  const tile = document.createElement("canvas");
  tile.width = 192;
  tile.height = 192;
  const tctx = tile.getContext("2d");
  if (!tctx) {
    paperPattern = false;
    return false;
  }
  let seed = 1337;
  const rand = () => { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };
  for (let i = 0; i < 600; i++) {
    const x = rand() * 192, y = rand() * 192;
    tctx.fillStyle = rand() > 0.45 ? "rgba(62,50,36,0.026)" : "rgba(255,252,244,0.048)";
    tctx.fillRect(x, y, 1 + rand() * 2, 1);
  }
  tctx.strokeStyle = "rgba(88,72,52,0.02)";
  tctx.lineWidth = 0.7;
  for (let i = 0; i < 38; i++) {
    const x = rand() * 192, y = rand() * 192, len = 10 + rand() * 22;
    tctx.beginPath();
    tctx.moveTo(x, y);
    tctx.lineTo(x + len, y + (rand() - 0.5) * 3);
    tctx.stroke();
  }
  paperPattern = ctx.createPattern(tile, "repeat") || false;
  return paperPattern;
}

function drawXuanPaperOverlay(ctx, w, h) {
  const pat = ensurePaperPattern(ctx);
  if (pat) {
    ctx.fillStyle = pat;
    ctx.fillRect(0, 0, w, h);
  }
  const vig = ctx.createRadialGradient(
    w * 0.5, h * 0.45, Math.min(w, h) * 0.25,
    w * 0.5, h * 0.5, Math.max(w, h) * 0.78
  );
  vig.addColorStop(0, "rgba(255,252,244,0.08)");
  vig.addColorStop(1, "rgba(20,16,12,0.08)");
  ctx.fillStyle = vig;
  ctx.fillRect(0, 0, w, h);
}

// ============================================================================
// 2. Tingfeng Martial WebAudio SFX
// ============================================================================

let audioCtx = null;
function playTingfengSfx(kind) {
  try {
    const Ctor = window.AudioContext || window.webkitAudioContext;
    if (!Ctor) return;
    if (!audioCtx) audioCtx = new Ctor();
    if (audioCtx.state === "suspended") audioCtx.resume();
    const now = audioCtx.currentTime;
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    if (kind === "parry") {
      osc.type = "triangle";
      osc.frequency.setValueAtTime(960, now);
      osc.frequency.exponentialRampToValueAtTime(420, now + 0.14);
      gain.gain.setValueAtTime(0.15, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.15);
      osc.start(now); osc.stop(now + 0.15);
    } else if (kind === "impact") {
      osc.type = "sine";
      osc.frequency.setValueAtTime(175, now);
      osc.frequency.exponentialRampToValueAtTime(46, now + 0.13);
      gain.gain.setValueAtTime(0.20, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.14);
      osc.start(now); osc.stop(now + 0.14);
    } else {
      osc.type = "sine";
      osc.frequency.setValueAtTime(420, now);
      osc.frequency.exponentialRampToValueAtTime(220, now + 0.06);
      gain.gain.setValueAtTime(0.06, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.06);
      osc.start(now); osc.stop(now + 0.06);
    }
  } catch (_) {}
}

// ============================================================================
// 3. Tingfeng WebSocket + `/api/bridge` HTTP Long-Poll Transport
// ============================================================================

function createTingfengNet({ writeStr, invokeWasm, getExports }) {
  const bridgePrefix = "/api/bridge";
  let ws = null;
  let bridgeSession = null;
  let bridgeAborter = null;

  async function startHttpBridgeLoop(sessionId) {
    while (bridgeSession === sessionId) {
      try {
        bridgeAborter = new AbortController();
        const res = await fetch(`${bridgePrefix}/poll`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId }),
          signal: bridgeAborter.signal,
        });
        if (!res.ok) break;
        const { messages, closed } = await res.json();
        const exports = getExports();
        for (const m of messages || []) {
          if (exports?.tf_on_net_message) {
            invokeWasm(() => exports.tf_on_net_message(writeStr(m)));
          }
        }
        if (closed) {
          bridgeSession = null;
          if (exports?.tf_on_net_close) invokeWasm(() => exports.tf_on_net_close());
          break;
        }
      } catch (e) {
        if (e.name === "AbortError") break;
        await new Promise((r) => setTimeout(r, 250));
      }
    }
  }

  async function openHttpBridge(mode, user, token) {
    const exports = getExports();
    try {
      const res = await fetch(`${bridgePrefix}/open`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const { sessionId } = await res.json();
      bridgeSession = sessionId;
      if (exports?.tf_on_net_open) {
        invokeWasm(() => exports.tf_on_net_open(writeStr(mode), writeStr(user), writeStr(token)));
      }
      startHttpBridgeLoop(sessionId);
    } catch (_) {
      if (exports?.tf_on_net_close) invokeWasm(() => exports.tf_on_net_close());
    }
  }

  function connectNet(mode, user, token) {
    if (ws) { try { ws.close(); } catch (_) {} ws = null; }
    if (bridgeAborter) { try { bridgeAborter.abort(); } catch (_) {} }
    bridgeSession = null;

    const targetUrl = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`;
    let settled = false;
    const fallbackTimer = setTimeout(() => {
      if (!settled) {
        settled = true;
        if (ws) { try { ws.close(); } catch (_) {} ws = null; }
        openHttpBridge(mode, user, token);
      }
    }, 950);

    try {
      const sock = new WebSocket(targetUrl);
      ws = sock;
      sock.addEventListener("open", () => {
        if (settled) return;
        settled = true;
        clearTimeout(fallbackTimer);
        const exports = getExports();
        if (exports?.tf_on_net_open) {
          invokeWasm(() => exports.tf_on_net_open(writeStr(mode), writeStr(user), writeStr(token)));
        }
      });
      sock.addEventListener("message", (ev) => {
        const exports = getExports();
        if (typeof ev.data === "string" && exports?.tf_on_net_message) {
          invokeWasm(() => exports.tf_on_net_message(writeStr(ev.data)));
        }
      });
      sock.addEventListener("error", () => {
        if (!settled) {
          settled = true;
          clearTimeout(fallbackTimer);
          ws = null;
          openHttpBridge(mode, user, token);
        }
      });
      sock.addEventListener("close", () => {
        const exports = getExports();
        if (settled && ws === sock && exports?.tf_on_net_close) {
          ws = null;
          invokeWasm(() => exports.tf_on_net_close());
        }
      });
    } catch (_) {
      clearTimeout(fallbackTimer);
      openHttpBridge(mode, user, token);
    }
  }

  function sendNet(payload) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(payload);
    } else if (bridgeSession) {
      const sid = bridgeSession;
      fetch(`${bridgePrefix}/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId: sid, payload }),
      })
        .then((r) => (r.ok ? r.json() : null))
        .then((data) => {
          const exports = getExports();
          if (data?.messages?.length && exports?.tf_on_net_message) {
            for (const m of data.messages) {
              invokeWasm(() => exports.tf_on_net_message(writeStr(m)));
            }
          }
        })
        .catch(() => {});
    }
  }

  return { connectNet, sendNet };
}

// ============================================================================
// 4. Lab / Fixture Probe & App Boot
// ============================================================================

function pullLabState() {
  if (!cremaApp) return latestLabStateObj;
  const { exports, readStr, invokeWasm } = cremaApp;
  const raw = invokeWasm(() => readStr(exports.tf_lab_state_json()));
  if (raw) {
    latestLabStateObj = JSON.parse(raw);
    if (stageProbe) {
      stageProbe.setAttribute("data-event-id", latestLabStateObj.stageEventId || "idle");
      const pNode = stageProbe.querySelector('[data-side="player"]');
      if (pNode) {
        const dx = +(latestLabStateObj.playerDashX || 0).toFixed(2);
        const dy = +(latestLabStateObj.playerDashY || 0).toFixed(2);
        pNode.style.transform = `matrix(1, 0, 0, 1, ${dx}, ${dy})`;
      }
    }
  }
  return latestLabStateObj;
}

function callUi(kind, a1 = "", a2 = "") {
  if (!cremaApp) return;
  const { exports, writeStr, invokeWasm } = cremaApp;
  invokeWasm(() => exports.tf_ui_action(writeStr(kind), writeStr(a1), writeStr(a2)));
}

function callLab(cmd, a1 = "", a2 = "", a3 = "", numArg = 0) {
  if (!cremaApp) return;
  const { exports, writeStr, invokeWasm } = cremaApp;
  invokeWasm(() => exports.tf_lab_cmd(writeStr(cmd), writeStr(a1), writeStr(a2), writeStr(a3), numArg));
}

const fixturesApi = {
  ready: () => wasmReady,
  seed: (p = "female", e = "male") => {
    callUi("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
    callLab("seed", p, e, "", 0);
    pullLabState();
  },
  submit: (actionId = "rig.fist.punch_a", result = "hit", side = "player", damage = 18) => {
    callUi("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
    callLab("submit", actionId, result, side, damage);
    pullLabState();
  },
  demo: () => {
    callUi("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
    callLab("demo", "", "", "", 0);
    pullLabState();
  },
  pause: (paused = true) => {
    callLab("pause", paused ? "true" : "false", "", "", 0);
    pullLabState();
  },
  seek: (ms) => {
    callUi("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
    callLab("seek", "", "", "", Number(ms) || 0);
    pullLabState();
  },
  speed: (val) => {
    callLab("speed", "", "", "", Number(val) || 1);
    pullLabState();
  },
  weapon: (side = "player", visual = "jian") => {
    callLab("weapon", side, visual, "", 0);
    pullLabState();
  },
  ui: (kind, a1 = "", a2 = "") => {
    callUi(kind, a1, a2);
    pullLabState();
  },
  state: () => pullLabState(),
};
window.__battleLab = fixturesApi;
globalThis.__tfHsFixtures = fixturesApi;

async function boot() {
  const [poseTxt, stgTxt, fistTxt, swordTxt, weaponsTxt, effTxt] = await Promise.all([
    fetch("/data/svg-poses.json").then((r) => r.text()),
    fetch("/data/staging.json").then((r) => r.text()),
    fetch("/data/fist.json").then((r) => r.text()),
    fetch("/data/sword.json").then((r) => r.text()),
    fetch("/data/weapons.json").then((r) => r.text()),
    fetch("/data/effects.json").then((r) => r.text()),
  ]);

  if (pageKind === "poses") {
    canvas.style.minHeight = "1420px";
  }

  cremaApp = await mountCremaApp({
    canvas,
    imeInput,
    wasmUrl: "/wasm/tingfeng.wasm",
    fitVisualViewport: pageKind !== "poses",
    captureWheel: pageKind !== "poses",
    fonts: {
      sans: '"PingFang SC", "Hiragino Sans GB", "Noto Sans SC", -apple-system, sans-serif',
      serif: '"Songti SC", "STSong", "Noto Serif CJK SC", "Source Han Serif SC", Georgia, serif',
      mono: '"SF Mono", "JetBrains Mono", Menlo, Consolas, monospace',
    },
    onClearBg: drawXuanPaperOverlay,
    extraImports: ({ readStr, writeStr, invokeWasm, getExports }) => {
      const net = createTingfengNet({ writeStr, invokeWasm, getExports });
      return {
        tf_host_play_sfx: (sfxPtr) => playTingfengSfx(readStr(sfxPtr)),
        tf_host_save_local: (kPtr, vPtr) => {
          try { localStorage.setItem(readStr(kPtr), readStr(vPtr)); } catch (_) {}
        },
        tf_host_send_net: (payloadPtr) => net.sendNet(readStr(payloadPtr)),
        tf_host_connect_net: (mPtr, uPtr, tPtr) => net.connectNet(readStr(mPtr), readStr(uPtr), readStr(tPtr)),
      };
    },
    beforeInit: ({ exports, writeStr, invokeWasm }) => {
      invokeWasm(() =>
        exports.tf_seed_assets(
          writeStr(pageKind),
          writeStr(poseTxt),
          writeStr(stgTxt),
          writeStr(fistTxt),
          writeStr(swordTxt),
          writeStr(weaponsTxt),
          writeStr(effTxt),
          reducedMotionQuery.matches ? 1 : 0
        )
      );
    },
    onAfterFrame: () => {
      if (stageProbe) pullLabState();
    },
  });

  wasmReady = true;
  pullLabState();
  if (resolveWasmReady) resolveWasmReady();

  reducedMotionQuery.addEventListener("change", () => {
    callUi("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
  });

  document.addEventListener("visibilitychange", () => {
    if (!cremaApp) return;
    const { exports, invokeWasm } = cremaApp;
    invokeWasm(() => exports.tf_set_hidden(document.hidden ? 1 : 0));
    if (stageProbe) pullLabState();
  });

  if (pageKind === "game") {
    let savedName = "";
    try { savedName = localStorage.getItem("tingfeng.lastUsername") || ""; } catch (_) {}
    const params = new URLSearchParams(location.search);
    const isTest = params.get("test") === "1";
    const urlUser = params.get("user");
    const initName = urlUser || savedName;
    if (initName) callUi("set_username", initName, "");
    if (isTest || urlUser) {
      const targetUser = urlUser || "tester";
      const wantReset = isTest ? params.get("reset") !== "0" : params.get("reset") === "1";
      callUi("login_submit", targetUser, wantReset ? "reset" : "");
    } else {
      callUi("request_creation_cfg", "", "");
    }
  }
}

boot().catch((e) => console.error("[tingfeng-crema] Boot failed:", e));
