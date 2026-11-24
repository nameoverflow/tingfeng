import ghcWasmJsffi from "/wasm/ghc_wasm_jsffi.js";

const pageKind = document.body.dataset.page || "game";
const c2dCanvas = document.getElementById("c2d-stage");
const stageProbe = document.getElementById("stage-probe");
const imeProxy = document.getElementById("ime-proxy");
const ctx = c2dCanvas.getContext("2d", { alpha: false });
const isTouch = matchMedia("(pointer: coarse)").matches || window.innerWidth <= 768;
const reducedMotionQuery = matchMedia("(prefers-reduced-motion: reduce)");

let resolveWasmReady = null;
globalThis.__tfHsReady = new Promise((r) => { resolveWasmReady = r; });

// --- 1. Preload Portrait Images for Canvas2D IMG Command ---
const portraitImages = new Map();
for (const key of ["00", "02", "04", "06", "08", "10"]) {
  const id = `beauty-score-${key}`;
  const img = new Image();
  img.decoding = "async";
  img.src = `/portraits/${id}.png`;
  portraitImages.set(id, img);
}

// --- 2. Self-contained WASI preview1 shim ---
function createWasiShim(getMemory) {
  const dec = new TextDecoder();
  const base = {
    args_sizes_get(argcPtr, argvBufPtr) {
      const dv = new DataView(getMemory().buffer);
      dv.setUint32(argcPtr, 0, true);
      dv.setUint32(argvBufPtr, 0, true);
      return 0;
    },
    args_get() { return 0; },
    environ_sizes_get(cntPtr, szPtr) {
      const dv = new DataView(getMemory().buffer);
      dv.setUint32(cntPtr, 0, true);
      dv.setUint32(szPtr, 0, true);
      return 0;
    },
    environ_get() { return 0; },
    clock_res_get(_id, resPtr) {
      new DataView(getMemory().buffer).setBigUint64(resPtr, 1000n, true);
      return 0;
    },
    clock_time_get(_id, _prec, timePtr) {
      new DataView(getMemory().buffer).setBigUint64(timePtr, BigInt(Math.floor(performance.now() * 1e6)), true);
      return 0;
    },
    fd_fdstat_get(fd, ptr) {
      const dv = new DataView(getMemory().buffer);
      dv.setUint8(ptr, fd <= 2 ? 2 : 4);
      dv.setUint16(ptr + 2, 0, true);
      dv.setBigUint64(ptr + 8, 0n, true);
      dv.setBigUint64(ptr + 16, 0n, true);
      return 0;
    },
    fd_fdstat_set_flags() { return 0; },
    fd_filestat_get() { return 8; },
    fd_filestat_set_size() { return 8; },
    fd_prestat_get() { return 8; },
    fd_prestat_dir_name() { return 8; },
    fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
      const mem = getMemory();
      const dv = new DataView(mem.buffer);
      const u8 = new Uint8Array(mem.buffer);
      let total = 0, out = "";
      for (let i = 0; i < iovsLen; i++) {
        const ptr = dv.getUint32(iovsPtr + i * 8, true);
        const len = dv.getUint32(iovsPtr + i * 8 + 4, true);
        out += dec.decode(u8.subarray(ptr, ptr + len));
        total += len;
      }
      if (out.trim()) (fd === 2 ? console.warn : console.log)("[ghc-wasm]", out.trimEnd());
      dv.setUint32(nwrittenPtr, total, true);
      return 0;
    },
    fd_read(_fd, _iovs, _len, nreadPtr) {
      new DataView(getMemory().buffer).setUint32(nreadPtr, 0, true);
      return 0;
    },
    fd_close() { return 0; },
    fd_seek() { return 70; },
    poll_oneoff(_in, _out, _n, nevPtr) {
      new DataView(getMemory().buffer).setUint32(nevPtr, 0, true);
      return 0;
    },
    proc_exit(code) { throw new Error(`WASI exit ${code}`); },
    random_get(bufPtr, bufLen) {
      crypto.getRandomValues(new Uint8Array(getMemory().buffer, bufPtr, bufLen));
      return 0;
    }
  };
  return new Proxy(base, {
    get(target, prop) { return prop in target ? target[prop] : () => 8; }
  });
}

// --- 3. One-Time Offscreen Xuan-Paper Fiber Texture Pattern (Zero per-frame GPU upload!) ---
function createPaperPattern(targetCtx) {
  const tile = document.createElement("canvas");
  tile.width = 192;
  tile.height = 192;
  const tctx = tile.getContext("2d");
  if (!tctx) return null;
  let seed = 1337;
  const rand = () => { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };
  // Subtle organic Xuan paper grain & horizontal mulberry fibers
  for (let i = 0; i < 650; i++) {
    const x = rand() * 192, y = rand() * 192;
    const dark = rand() > 0.45;
    tctx.fillStyle = dark ? "rgba(62, 50, 36, 0.028)" : "rgba(255, 252, 244, 0.055)";
    tctx.fillRect(x, y, 1 + rand() * 2, 1);
  }
  tctx.strokeStyle = "rgba(88, 72, 52, 0.022)";
  tctx.lineWidth = 0.7;
  for (let i = 0; i < 42; i++) {
    const x = rand() * 192, y = rand() * 192, len = 10 + rand() * 24;
    tctx.beginPath();
    tctx.moveTo(x, y);
    tctx.lineTo(x + len, y + (rand() - 0.5) * 3);
    tctx.stroke();
  }
  return targetCtx.createPattern(tile, "repeat");
}

const paperPattern = createPaperPattern(ctx);

// --- 4. Procedural WebAudio Synthesizer ---
let audioCtx = null;
function playSynthesizedSfx(kind) {
  try {
    const Ctor = window.AudioContext || window.webkitAudioContext;
    if (!Ctor) return;
    if (!audioCtx) audioCtx = new Ctor();
    if (audioCtx.state === "suspended") audioCtx.resume();
    const now = audioCtx.currentTime;
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.connect(gain); gain.connect(audioCtx.destination);
    if (kind === "parry") {
      osc.type = "triangle";
      osc.frequency.setValueAtTime(980, now);
      osc.frequency.exponentialRampToValueAtTime(420, now + 0.14);
      gain.gain.setValueAtTime(0.16, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.15);
      osc.start(now); osc.stop(now + 0.15);
    } else if (kind === "impact") {
      osc.type = "sine";
      osc.frequency.setValueAtTime(165, now);
      osc.frequency.exponentialRampToValueAtTime(48, now + 0.12);
      gain.gain.setValueAtTime(0.22, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.13);
      osc.start(now); osc.stop(now + 0.13);
    } else {
      osc.type = "sine";
      osc.frequency.setValueAtTime(320, now);
      osc.frequency.exponentialRampToValueAtTime(140, now + 0.09);
      gain.gain.setValueAtTime(0.07, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.09);
      osc.start(now); osc.stop(now + 0.09);
    }
  } catch (_) {}
}

// --- 5. Full-Canvas Command Tape Executor (Zero DOM UI!) ---
let cssW = window.innerWidth;
let cssH = pageKind === "poses" ? 1420 : window.innerHeight;
let layoutH = cssH;
let dpr = Math.min(2.0, window.devicePixelRatio || 1);

function syncCanvasSize() {
  // Always match the canvas backing store 1:1 with its actual CSS box (never distort when iOS keyboard opens!)
  const boxW = Math.max(320, c2dCanvas.clientWidth || window.innerWidth);
  const boxH = pageKind === "poses" ? Math.max(window.innerHeight, 1420) : Math.max(320, c2dCanvas.clientHeight || window.innerHeight);
  cssW = boxW;
  cssH = boxH;
  const vv = window.visualViewport;
  layoutH = pageKind === "poses" ? boxH : Math.max(220, Math.min(boxH, Math.round(vv ? vv.height : boxH)));
  dpr = Math.min(2.0, window.devicePixelRatio || 1);
  const pw = Math.round(cssW * dpr), ph = Math.round(cssH * dpr);
  if (c2dCanvas.width !== pw || c2dCanvas.height !== ph) {
    c2dCanvas.width = pw; c2dCanvas.height = ph;
  }
}
function syncVisualViewport() {
  const vv = window.visualViewport;
  if (!vv) return;
  layoutH = pageKind === "poses" ? cssH : Math.max(220, Math.min(cssH, Math.round(vv.height)));
  if (window.scrollY !== 0) window.scrollTo(0, 0);
}
window.addEventListener("resize", syncCanvasSize);
if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", syncVisualViewport);
  window.visualViewport.addEventListener("scroll", syncVisualViewport);
}
syncCanvasSize();

const SANS_FONT = '"PingFang SC", "Hiragino Sans GB", "Noto Sans SC", -apple-system, sans-serif';
const SERIF_FONT = '"Songti SC", "STSong", "Noto Serif CJK SC", "Source Han Serif SC", Georgia, serif';

function drawShapePath(c, item) {
  c.beginPath();
  if (item.kind === "c") {
    c.arc(item.cx, item.cy, item.r, 0, Math.PI * 2);
  } else {
    const pts = item.pts;
    if (pts.length >= 2) {
      c.moveTo(pts[0], pts[1]);
      for (let i = 2; i < pts.length; i += 2) c.lineTo(pts[i], pts[i + 1]);
      c.closePath();
    }
  }
}

let lastImeRectKey = "";
let currentImeId = null;

function syncImeOverlay(info) {
  if (!imeProxy) return;
  if (!info) {
    if (lastImeRectKey !== "none") {
      lastImeRectKey = "none";
      currentImeId = null;
      imeProxy.style.left = "-9999px";
      imeProxy.style.top = "0px";
      imeProxy.style.width = "1px";
      imeProxy.style.height = "1px";
      imeProxy.style.pointerEvents = "none";
    }
    return;
  }
  currentImeId = info.id;
  const rectKey = `${info.id}:${Math.round(info.x)},${Math.round(info.y)},${Math.round(info.w)},${Math.round(info.h)}`;
  if (rectKey !== lastImeRectKey) {
    lastImeRectKey = rectKey;
    imeProxy.style.left = `${info.x}px`;
    imeProxy.style.top = `${info.y}px`;
    imeProxy.style.width = `${info.w}px`;
    imeProxy.style.height = `${info.h}px`;
    imeProxy.style.pointerEvents = "auto";
  }
  if (document.activeElement !== imeProxy && imeProxy.value !== info.val) {
    imeProxy.value = info.val;
  }
}

function executeFrameBatch(batchStr) {
  ctx.save();
  ctx.scale(dpr, dpr);
  const lines = batchStr.split("\n");
  let actorDefaultFill = "#1b2521", actorOutline = "#f6f0e2", actorFlash = 0, partAlpha = 1;
  let partShapes = [], inJoin = false;
  let frameInput = null;

  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx];
    if (!line) continue;
    const p = line.split("|");
    switch (p[0]) {
      case "BG": {
        const w = cssW, h = cssH, isBattle = p[4] === "1";
        const g = ctx.createLinearGradient(0, 0, 0, h);
        g.addColorStop(0, isBattle ? "#f4efe4" : "#f7f3e9");
        g.addColorStop(0.58, isBattle ? "#ece4d4" : "#efe8d9");
        g.addColorStop(1, isBattle ? "#e3d9c5" : "#e7decb");
        ctx.globalAlpha = 1;
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, w, h);
        if (paperPattern) {
          ctx.fillStyle = paperPattern;
          ctx.fillRect(0, 0, w, h);
        }
        // Soft atmospheric warm-ink vignette around edges
        const vig = ctx.createRadialGradient(w * 0.5, h * 0.44, Math.min(w, h) * 0.25, w * 0.5, h * 0.5, Math.max(w, h) * 0.78);
        vig.addColorStop(0, "rgba(255, 252, 244, 0.14)");
        vig.addColorStop(1, "rgba(42, 34, 24, 0.08)");
        ctx.fillStyle = vig;
        ctx.fillRect(0, 0, w, h);
        break;
      }
      case "MT": {
        // Song-dynasty Shan-shui misty ink-wash mountain range (vertical fade into mist!)
        const yBase = +p[1], amp = +p[2], par = +p[3], camX = +p[4], al = +p[6];
        ctx.save();
        const mg = ctx.createLinearGradient(0, yBase - amp * 1.15, 0, yBase + amp * 2.8 + 80);
        mg.addColorStop(0, p[5]);
        mg.addColorStop(0.55, p[5]);
        mg.addColorStop(1, "rgba(235, 227, 210, 0)");
        ctx.globalAlpha = al;
        ctx.fillStyle = mg;
        ctx.beginPath();
        ctx.moveTo(0, cssH);
        for (let x = 0; x <= cssW + 24; x += 24) {
          const wx = (x + camX * par) * 0.0052;
          const y = yBase - (Math.sin(wx) * 0.52 + Math.sin(wx * 2.1 + 1.3) * 0.30 + Math.cos(wx * 3.7 + 0.6) * 0.18) * amp;
          ctx.lineTo(x, y);
        }
        ctx.lineTo(cssW, cssH);
        ctx.closePath();
        ctx.fill();
        ctx.restore();
        break;
      }
      case "CARD": {
        // Elevated Song-dynasty Xuan-paper plaque with soft diffused ink shadow + hairline border
        const x = +p[1], y = +p[2], w = Math.max(0, +p[3]), h = Math.max(0, +p[4]), r = +p[5];
        const fill = p[6], bd = p[7], lw = +p[8], al = +p[9], shY = +p[10], shBlur = +p[11], dbl = p[12] === "1";
        ctx.save();
        ctx.globalAlpha = al;
        if (shBlur > 0) {
          ctx.shadowColor = "rgba(28, 22, 16, 0.11)";
          ctx.shadowBlur = shBlur;
          ctx.shadowOffsetX = 0;
          ctx.shadowOffsetY = shY;
        }
        ctx.beginPath();
        ctx.roundRect(x, y, w, h, r);
        if (fill) {
          const cg = ctx.createLinearGradient(x, y, x, y + h);
          cg.addColorStop(0, fill);
          cg.addColorStop(1, fill === "#1c1915" ? "#26211c" : "#f2ebdc");
          ctx.fillStyle = cg;
          ctx.fill();
        }
        ctx.shadowColor = "transparent";
        ctx.shadowBlur = 0;
        ctx.shadowOffsetY = 0;
        if (bd && lw > 0) {
          ctx.strokeStyle = bd;
          ctx.lineWidth = lw;
          ctx.stroke();
        }
        if (dbl && w > 12 && h > 12) {
          ctx.strokeStyle = fill === "#1c1915" ? "rgba(196, 163, 99, 0.38)" : "rgba(130, 118, 98, 0.22)";
          ctx.lineWidth = 0.75;
          ctx.beginPath();
          ctx.roundRect(x + 3.5, y + 3.5, w - 7, h - 7, Math.max(1, r - 1));
          ctx.stroke();
        }
        ctx.restore();
        break;
      }
      case "BAR": {
        // Sleek mineral-pigment gradient progress bar with optional ghost trail
        const x = +p[1], y = +p[2], w = Math.max(0, +p[3]), h = Math.max(0, +p[4]), r = +p[5];
        const ratio = Math.max(0, Math.min(1, +p[6])), trail = +p[7];
        const c1 = p[8], c2 = p[9], trailCol = p[10];
        ctx.save();
        ctx.beginPath();
        ctx.roundRect(x, y, w, h, r);
        ctx.fillStyle = "rgba(42, 35, 26, 0.09)";
        ctx.fill();
        if (trail > ratio + 0.004 && trailCol) {
          ctx.beginPath();
          ctx.roundRect(x, y, w * Math.min(1, trail), h, r);
          ctx.fillStyle = trailCol;
          ctx.globalAlpha = 0.55;
          ctx.fill();
          ctx.globalAlpha = 1;
        }
        if (ratio > 0.003) {
          const fw = Math.max(h, w * ratio);
          const bg = ctx.createLinearGradient(x, y, x + fw, y);
          bg.addColorStop(0, c1);
          bg.addColorStop(1, c2 || c1);
          ctx.beginPath();
          ctx.roundRect(x, y, fw, h, r);
          ctx.fillStyle = bg;
          ctx.fill();
        }
        ctx.restore();
        break;
      }
      case "CLIP": {
        ctx.save();
        ctx.beginPath();
        ctx.rect(+p[1], +p[2], Math.max(0, +p[3]), Math.max(0, +p[4]));
        ctx.clip();
        break;
      }
      case "UNCLIP": {
        ctx.restore();
        break;
      }
      case "IMG": {
        const img = portraitImages.get(p[1]);
        const x = +p[2], y = +p[3], w = +p[4], h = +p[5], r = +p[6];
        ctx.save();
        ctx.beginPath();
        ctx.roundRect(x, y, w, h, r);
        ctx.clip();
        if (img && img.complete && img.naturalWidth > 0) {
          ctx.drawImage(img, x, y, w, h);
        } else {
          ctx.fillStyle = "#dfd5be";
          ctx.fillRect(x, y, w, h);
        }
        ctx.restore();
        ctx.save();
        ctx.strokeStyle = "#b8aa91";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.roundRect(x, y, w, h, r);
        ctx.stroke();
        ctx.restore();
        break;
      }
      case "LN": {
        ctx.save();
        ctx.globalAlpha = +p[7];
        ctx.strokeStyle = p[6];
        ctx.lineWidth = +p[5];
        if (p[8] === "1") ctx.setLineDash([5, 5]);
        ctx.beginPath();
        ctx.moveTo(+p[1], +p[2]);
        ctx.lineTo(+p[3], +p[4]);
        ctx.stroke();
        ctx.restore();
        break;
      }
      case "RR": {
        ctx.save();
        ctx.globalAlpha = +p[9];
        ctx.beginPath();
        ctx.roundRect(+p[1], +p[2], Math.max(0, +p[3]), Math.max(0, +p[4]), +p[5]);
        if (p[6]) { ctx.fillStyle = p[6]; ctx.fill(); }
        if (p[7] && +p[8] > 0) { ctx.strokeStyle = p[7]; ctx.lineWidth = +p[8]; ctx.stroke(); }
        ctx.restore();
        break;
      }
      case "CI": {
        const r = +p[3];
        if (r <= 0) break;
        ctx.save();
        ctx.globalAlpha = +p[7];
        ctx.beginPath();
        ctx.arc(+p[1], +p[2], r, 0, Math.PI * 2);
        if (p[4]) { ctx.fillStyle = p[4]; ctx.fill(); }
        if (p[5] && +p[6] > 0) { ctx.strokeStyle = p[5]; ctx.lineWidth = +p[6]; ctx.stroke(); }
        ctx.restore();
        break;
      }
      case "ELL": {
        const rx = +p[3], ry = +p[4];
        if (rx <= 0 || ry <= 0) break;
        ctx.save();
        ctx.globalAlpha = +p[6];
        ctx.fillStyle = p[5];
        ctx.beginPath();
        ctx.ellipse(+p[1], +p[2], rx, ry, 0, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
        break;
      }
      case "TX":
      case "TXS": {
        ctx.save();
        ctx.globalAlpha = +p[7];
        ctx.fillStyle = p[6];
        ctx.textAlign = p[5];
        ctx.font = `${p[4]} ${p[3]}px ${p[0] === "TXS" ? SERIF_FONT : SANS_FONT}`;
        ctx.fillText(p[8] || "", +p[1], +p[2]);
        ctx.restore();
        break;
      }
      case "ACTOR_BEGIN": {
        const wx = +p[1], wy = +p[2], sc = +p[3], rotDeg = +p[4];
        actorDefaultFill = p[5] || "#1b2521";
        actorOutline = p[6] || "#f6f0e2";
        actorFlash = +p[7];
        ctx.save();
        ctx.translate(wx, wy);
        if (rotDeg) ctx.rotate(rotDeg * Math.PI / 180);
        ctx.scale(sc, Math.abs(sc));
        ctx.lineJoin = "round";
        ctx.lineCap = "round";
        break;
      }
      case "APART_BEGIN": {
        partAlpha = +p[1] || 1;
        partShapes = [];
        break;
      }
      case "ACIRC": {
        const item = { kind: "c", cx: +p[1], cy: +p[2], r: +p[3], fill: p[4] || actorDefaultFill, op: +p[5] };
        if (inJoin) {
          ctx.globalAlpha = item.op;
          ctx.fillStyle = actorFlash > 0.2 ? "#a32c22" : item.fill;
          drawShapePath(ctx, item); ctx.fill();
        } else partShapes.push(item);
        break;
      }
      case "APOLY": {
        const nums = p[3] ? p[3].split(",").map(Number) : [];
        const item = { kind: "p", pts: nums, fill: p[1] || actorDefaultFill, op: +p[2] };
        if (inJoin) {
          ctx.globalAlpha = item.op;
          ctx.fillStyle = actorFlash > 0.2 ? "#a32c22" : item.fill;
          drawShapePath(ctx, item); ctx.fill();
        } else partShapes.push(item);
        break;
      }
      case "APART_FILL": {
        ctx.strokeStyle = actorOutline;
        ctx.lineWidth = 3.8;
        ctx.globalAlpha = partAlpha;
        for (const s of partShapes) { drawShapePath(ctx, s); ctx.stroke(); }
        for (const s of partShapes) {
          ctx.globalAlpha = s.op;
          ctx.fillStyle = actorFlash > 0.2 ? "#a32c22" : s.fill;
          drawShapePath(ctx, s); ctx.fill();
        }
        ctx.globalAlpha = 1;
        break;
      }
      case "AJOIN_BEGIN": {
        ctx.save();
        ctx.beginPath(); ctx.arc(+p[1], +p[2], +p[3], 0, Math.PI * 2); ctx.clip();
        inJoin = true;
        break;
      }
      case "AJOIN_END": {
        inJoin = false; ctx.restore();
        break;
      }
      case "ACTOR_END": {
        ctx.restore();
        break;
      }
      case "INPUT": {
        frameInput = { id: p[1], x: +p[2], y: +p[3], w: +p[4], h: +p[5], val: p[6] || "" };
        break;
      }
      case "SLASH": {
        const col = p[1];
        const segs = (p[2] || "").split(";").map((s) => s.split(",").map(Number)).filter((a) => a.length === 3);
        if (segs.length >= 2) {
          ctx.save(); ctx.lineCap = "round";
          for (let i = 0; i < segs.length - 1; i++) {
            const [x1, y1, a1] = segs[i], [x2, y2, a2] = segs[i + 1];
            ctx.globalAlpha = Math.max(a1, a2) * 0.88;
            ctx.strokeStyle = col;
            ctx.lineWidth = 3.5 + i * 3.8;
            ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
          }
          ctx.restore();
        }
        break;
      }
    }
  }
  ctx.restore();
  syncImeOverlay(frameInput);
}

// --- 6. Low-Latency Dual WebSocket + Piggybacked HTTP Bridge ---
let wsConn = null;
let bridgeSession = null;
let bridgeAborter = null;
let hsExports = null;
let hsQueue = Promise.resolve();

function runHs(fn) {
  hsQueue = hsQueue.then(fn).catch((e) => console.error("[hs]", e));
  return hsQueue;
}

async function startBridgeLoop(sessionId) {
  while (bridgeSession === sessionId) {
    try {
      bridgeAborter = new AbortController();
      const res = await fetch("/api/bridge/poll", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId }),
        signal: bridgeAborter.signal
      });
      if (!res.ok) break;
      const { messages, closed } = await res.json();
      for (const m of messages || []) await runHs(() => hsExports.hs_on_ws_message(m));
      if (closed) {
        bridgeSession = null;
        await runHs(() => hsExports.hs_on_ws_close());
        break;
      }
    } catch (e) {
      if (e.name === "AbortError") break;
      await new Promise((r) => setTimeout(r, 250));
    }
  }
}

async function openHttpBridge(mode, username, password) {
  try {
    const res = await fetch("/api/bridge/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}"
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const { sessionId } = await res.json();
    bridgeSession = sessionId;
    await runHs(() => hsExports.hs_on_ws_open(mode, username, password));
    startBridgeLoop(sessionId);
  } catch (_) {
    await runHs(() => hsExports.hs_on_ws_close());
  }
}

function connectServer(mode, username, password) {
  if (wsConn) { try { wsConn.close(); } catch (_) {} wsConn = null; }
  if (bridgeAborter) { try { bridgeAborter.abort(); } catch (_) {} }
  bridgeSession = null;

  const wsUrl = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`;
  let settled = false;
  const fallback = setTimeout(() => {
    if (!settled) {
      settled = true;
      if (wsConn) { try { wsConn.close(); } catch (_) {} wsConn = null; }
      openHttpBridge(mode, username, password);
    }
  }, 950);

  try {
    const sock = new WebSocket(wsUrl);
    wsConn = sock;
    sock.addEventListener("open", () => {
      if (settled) return;
      settled = true; clearTimeout(fallback);
      runHs(() => hsExports.hs_on_ws_open(mode, username, password));
    });
    sock.addEventListener("message", (ev) => {
      if (typeof ev.data === "string") runHs(() => hsExports.hs_on_ws_message(ev.data));
    });
    sock.addEventListener("error", () => {
      if (!settled) {
        settled = true; clearTimeout(fallback); wsConn = null;
        openHttpBridge(mode, username, password);
      }
    });
    sock.addEventListener("close", () => {
      if (settled && wsConn === sock) {
        wsConn = null;
        runHs(() => hsExports.hs_on_ws_close());
      }
    });
  } catch (_) {
    clearTimeout(fallback);
    openHttpBridge(mode, username, password);
  }
}

function sendServer(payload) {
  if (wsConn && wsConn.readyState === WebSocket.OPEN) {
    wsConn.send(payload);
  } else if (bridgeSession) {
    const sid = bridgeSession;
    fetch("/api/bridge/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId: sid, payload })
    })
      .then((r) => (r.ok ? r.json() : null))
      .then(async (data) => {
        if (data?.messages?.length) {
          for (const m of data.messages) await runHs(() => hsExports.hs_on_ws_message(m));
        }
      })
      .catch(() => {});
  }
}

// --- 7. Native Transparent IME Overlay (Works reliably on iOS Safari/WKWebView & third-party IMEs) ---
let activeInputId = null;

if (imeProxy) {
  imeProxy.addEventListener("focus", () => {
    if (currentImeId) activeInputId = currentImeId;
    if (activeInputId && hsExports) {
      const id = activeInputId;
      runHs(() => hsExports.hs_focus_input_id(id));
    }
  });
  const pushVal = () => {
    const id = activeInputId || currentImeId;
    if (id && hsExports) {
      const val = imeProxy.value;
      runHs(() => hsExports.hs_text_input(id, val));
    }
  };
  imeProxy.addEventListener("input", pushVal);
  imeProxy.addEventListener("compositionupdate", pushVal);
  imeProxy.addEventListener("compositionend", pushVal);
  imeProxy.addEventListener("keydown", (ev) => {
    const id = activeInputId || currentImeId;
    if (ev.key === "Enter" && !ev.isComposing && id && hsExports) {
      ev.preventDefault();
      runHs(() => hsExports.hs_text_submit(id));
    } else if (ev.key === "Escape" && hsExports) {
      ev.preventDefault();
      imeProxy.blur();
    }
  });
  imeProxy.addEventListener("blur", () => {
    activeInputId = null;
    if (hsExports) runHs(() => hsExports.hs_blur_input());
  });
}

// --- 8. Host Bridge + BattleLab & Fixtures API ---
let latestLabStateObj = {
  stageEventId: "idle",
  playerDashX: 0,
  playerDashY: 0,
  soundOn: false,
  logCount: 0,
  game: { battle: { active: false, player: null, enemy: null, presentation: null, animation: { activeTimeline: null, queueDepth: 0 } } },
  playback: { paused: false, speed: 1, elapsedMs: 0, durationMs: 0 }
};
let wasmReady = false;

globalThis.__tfHost = {
  submitFrame(batchStr) {
    executeFrameBatch(batchStr);
  },
  syncLabState(jsonStr) {
    latestLabStateObj = JSON.parse(jsonStr);
    if (stageProbe) {
      stageProbe.setAttribute("data-event-id", latestLabStateObj.stageEventId || "idle");
      const pNode = stageProbe.querySelector('[data-side="player"]');
      if (pNode) {
        const dx = +(latestLabStateObj.playerDashX || 0).toFixed(2);
        const dy = +(latestLabStateObj.playerDashY || 0).toFixed(2);
        pNode.style.transform = `matrix(1, 0, 0, 1, ${dx}, ${dy})`;
      }
    }
  },
  connectWs(mode, username, password) { connectServer(mode, username, password); },
  sendWs(payload) { sendServer(payload); },
  setCursor(cur) { document.body.style.cursor = cur; },
  playSfx(kind) { playSynthesizedSfx(kind); },
  saveLocal(k, v) { try { localStorage.setItem(k, v); } catch (_) {} },
  focusInput(inpId, val, _x, _y, _w, _h) {
    if (!imeProxy) return;
    activeInputId = inpId;
    imeProxy.value = val || "";
    imeProxy.focus({ preventScroll: true });
  },
  blurInput() {
    activeInputId = null;
    if (imeProxy && document.activeElement === imeProxy) imeProxy.blur();
  }
};

const syncReducedMotion = () =>
  runHs(() => hsExports?.hs_ui_action("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", ""));

const fixturesApi = {
  ready: () => wasmReady,
  seed: (p = "female", e = "male") =>
    runHs(async () => {
      await hsExports?.hs_ui_action("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
      await hsExports?.hs_lab_cmd("seed", p, e, "", 0);
    }),
  submit: (actionId = "rig.fist.punch_a", result = "hit", side = "player", damage = 18) =>
    runHs(async () => {
      await hsExports?.hs_ui_action("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
      await hsExports?.hs_lab_cmd("submit", actionId, result, side, damage);
    }),
  demo: () =>
    runHs(async () => {
      await hsExports?.hs_ui_action("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
      await hsExports?.hs_lab_cmd("demo", "", "", "", 0);
    }),
  pause: (paused = true) =>
    runHs(() => hsExports?.hs_lab_cmd("pause", paused ? "true" : "false", "", "", 0)),
  seek: (ms) =>
    runHs(async () => {
      await hsExports?.hs_ui_action("set_reduced_motion", reducedMotionQuery.matches ? "1" : "0", "");
      await hsExports?.hs_lab_cmd("seek", "", "", "", Number(ms) || 0);
    }),
  speed: (val) =>
    runHs(() => hsExports?.hs_lab_cmd("speed", "", "", "", Number(val) || 1)),
  ui: (kind, a1 = "", a2 = "") =>
    runHs(() => hsExports?.hs_ui_action(kind, a1, a2)),
  state: () => latestLabStateObj
};
window.__battleLab = fixturesApi;
globalThis.__tfHsFixtures = fixturesApi;

// --- 9. Boot Haskell Wasm Client ---
async function boot() {
  const [poseRes, stgRes, fistRes, swordRes, effRes, wasmRes] = await Promise.all([
    fetch("/data/svg-poses.json"),
    fetch("/data/staging.json"),
    fetch("/data/fist.json"),
    fetch("/data/sword.json"),
    fetch("/data/effects.json"),
    fetch("/wasm/tingfeng-hs.wasm")
  ]);
  const [poseTxt, stgTxt, fistTxt, swordTxt, effTxt, wasmBytes] = await Promise.all([
    poseRes.text(), stgRes.text(), fistRes.text(), swordRes.text(), effRes.text(), wasmRes.arrayBuffer()
  ]);

  const __exports = {};
  const wasi = createWasiShim(() => __exports.memory);
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    wasi_snapshot_preview1: wasi,
    ghc_wasm_jsffi: ghcWasmJsffi(__exports),
  });
  Object.assign(__exports, instance.exports);
  if (typeof instance.exports._initialize === "function") instance.exports._initialize();
  hsExports = instance.exports;

  await runHs(() => hsExports.hs_init_app(pageKind, poseTxt, stgTxt, fistTxt, swordTxt, effTxt, cssW, cssH, reducedMotionQuery.matches ? 1 : 0));
  wasmReady = true;
  if (resolveWasmReady) resolveWasmReady();
  reducedMotionQuery.addEventListener("change", syncReducedMotion);

  // Unified Canvas Pointer, Touch-Drag Scroll/Pan, Wheel Scroll/Zoom & Keyboard Forwarding
  const stageWrap = document.getElementById("stage-wrap");
  let dragging = false, dragMoved = false, startX = 0, startY = 0, lastX = 0, lastY = 0;

  stageWrap.addEventListener("pointerdown", (e) => {
    dragging = true; dragMoved = false;
    startX = e.clientX; startY = e.clientY;
    lastX = e.clientX; lastY = e.clientY;
  });
  stageWrap.addEventListener("pointermove", (e) => {
    if (dragging) {
      if (!dragMoved && Math.hypot(e.clientX - startX, e.clientY - startY) > 10) {
        dragMoved = true;
      }
      if (dragMoved) {
        const dx = e.clientX - lastX, dy = e.clientY - lastY;
        lastX = e.clientX; lastY = e.clientY;
        runHs(() => hsExports.hs_drag_at(e.clientX, e.clientY, dx, dy));
        return;
      }
    }
    runHs(() => hsExports.hs_pointer_move(e.clientX, e.clientY));
  });
  stageWrap.addEventListener("pointerup", (e) => {
    const wasTap = dragging && !dragMoved;
    dragging = false;
    dragMoved = false;
    if (wasTap && e.button <= 0) {
      runHs(() => hsExports.hs_pointer_click(e.clientX, e.clientY));
    }
  });
  window.addEventListener("pointerup", () => { dragging = false; dragMoved = false; });
  window.addEventListener("pointercancel", () => { dragging = false; dragMoved = false; });

  stageWrap.addEventListener("wheel", (e) => {
    if (pageKind === "poses") return;
    e.preventDefault();
    runHs(() => hsExports.hs_scroll_at(e.clientX, e.clientY, e.deltaY));
  }, { passive: false });

  window.addEventListener("keydown", (e) => {
    if (!hsExports || document.activeElement === imeProxy) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    runHs(() => hsExports.hs_key_down(e.key));
  });

  document.addEventListener("visibilitychange", () => {
    runHs(() => hsExports?.hs_set_hidden(document.hidden ? 1 : 0));
  });

  if (pageKind === "game") {
    let savedName = "";
    try { savedName = localStorage.getItem("tingfeng.lastUsername") || ""; } catch (_) {}
    const params = new URLSearchParams(location.search);
    const isTest = params.get("test") === "1";
    const urlUser = params.get("user");
    const initName = urlUser || savedName;
    if (initName) await runHs(() => hsExports.hs_ui_action("set_username", initName, ""));
    if (isTest || urlUser) {
      const targetUser = urlUser || "tester";
      const wantReset = isTest ? params.get("reset") !== "0" : params.get("reset") === "1";
      await runHs(() => hsExports.hs_ui_action("login_submit", targetUser, wantReset ? "reset" : ""));
    } else {
      await runHs(() => hsExports.hs_ui_action("request_creation_cfg", "", ""));
    }
  }

  let lastTs = performance.now();
  const frameLoop = async (ts) => {
    const dt = Math.min(220, Math.max(1, ts - lastTs));
    lastTs = ts;
    if (!document.hidden) {
      await runHs(() => hsExports.hs_step_frame(dt, cssW, layoutH, reducedMotionQuery.matches ? 1 : 0));
    }
    requestAnimationFrame(frameLoop);
  };
  requestAnimationFrame(frameLoop);
}

boot().catch((e) => console.error("Boot failed:", e));
