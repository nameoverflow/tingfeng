import ghcWasmJsffi from "/wasm/ghc_wasm_jsffi.js";

const pageKind = document.body.dataset.page || "game";
const c2dCanvas = document.getElementById("c2d-stage");
const glCanvas = document.getElementById("gl-stage");
const stageProbe = document.getElementById("stage-probe");
const uiRoot = document.getElementById("ui-root");
const ctx = c2dCanvas.getContext("2d", { alpha: false });
const isTouch = matchMedia("(pointer: coarse)").matches || window.innerWidth <= 768;
const reducedMotionQuery = matchMedia("(prefers-reduced-motion: reduce)");
let resolveWasmReady = null;
globalThis.__tfHsReady = new Promise((r) => { resolveWasmReady = r; });

// --- 1. Self-contained WASI preview1 shim ---
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

// --- 2. Single WebGL2 Xuan-Paper + Radial Sword-Impact Shockwave Pipeline ---
function initWebGL2Pipeline(canvas) {
  if (pageKind === "poses") return null;
  const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, premultipliedAlpha: false });
  if (!gl) return null;

  const vsSrc = `#version 300 es
  in vec2 aPos;
  out vec2 vUv;
  void main() { vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos, 0.0, 1.0); }`;

  const fsSrc = `#version 300 es
  precision highp float;
  in vec2 vUv;
  out vec4 fragColor;
  uniform sampler2D uStageTex;
  uniform vec2 uResolution;
  uniform vec2 uShockPos;
  uniform float uShockAge;
  uniform float uShockPower;

  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
  }
  void main() {
    vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
    float aspect = uResolution.x / max(1.0, uResolution.y);
    vec2 shockUv = vec2(uShockPos.x, 1.0 - uShockPos.y);
    vec2 delta = (uv - shockUv) * vec2(aspect, 1.0);
    float dist = length(delta);
    float wave = uShockPower * exp(-uShockAge * 3.8) * exp(-abs(dist - uShockAge * 1.15) * 26.0);
    vec2 dir = dist > 0.0001 ? normalize(delta) / vec2(aspect, 1.0) : vec2(0.0);
    vec2 wUv = clamp(uv + dir * wave * 0.016, 0.001, 0.999);

    float split = wave * 0.006;
    float r = texture(uStageTex, clamp(wUv + dir * split, 0.001, 0.999)).r;
    vec4 base = texture(uStageTex, wUv);
    float b = texture(uStageTex, clamp(wUv - dir * split, 0.001, 0.999)).b;
    vec3 col = vec3(r, base.g, b);

    float fiber = noise(uv * uResolution * 0.30) - 0.5;
    col += fiber * 0.020 + vec3(0.88, 0.78, 0.55) * wave * 0.25;
    vec2 vigUv = vUv * (1.0 - vUv.yx);
    col *= mix(0.74, 1.02, pow(clamp(vigUv.x * vigUv.y * 16.0, 0.0, 1.0), 0.20));
    fragColor = vec4(col, 1.0);
  }`;

  const mk = (t, s) => {
    const sh = gl.createShader(t); gl.shaderSource(sh, s); gl.compileShader(sh);
    return gl.getShaderParameter(sh, gl.COMPILE_STATUS) ? sh : null;
  };
  const vs = mk(gl.VERTEX_SHADER, vsSrc), fs = mk(gl.FRAGMENT_SHADER, fsSrc);
  if (!vs || !fs) return null;
  const prog = gl.createProgram();
  gl.attachShader(prog, vs); gl.attachShader(prog, fs); gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;

  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  const aPos = gl.getAttribLocation(prog, "aPos");
  gl.enableVertexAttribArray(aPos);
  gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  const locs = {
    uStageTex: gl.getUniformLocation(prog, "uStageTex"),
    uResolution: gl.getUniformLocation(prog, "uResolution"),
    uShockPos: gl.getUniformLocation(prog, "uShockPos"),
    uShockAge: gl.getUniformLocation(prog, "uShockAge"),
    uShockPower: gl.getUniformLocation(prog, "uShockPower")
  };

  let texW = 0, texH = 0, lost = false;
  canvas.addEventListener("webglcontextlost", (e) => { e.preventDefault(); lost = true; canvas.style.opacity = "0"; });

  return {
    isAvailable() { return !lost && !gl.isContextLost(); },
    render(srcCanvas, shockU, shockV, shockAge, shockPower) {
      if (lost || gl.isContextLost()) return false;
      if (canvas.width !== srcCanvas.width || canvas.height !== srcCanvas.height) {
        canvas.width = srcCanvas.width; canvas.height = srcCanvas.height;
      }
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.useProgram(prog);
      gl.bindVertexArray(vao);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      if (texW !== srcCanvas.width || texH !== srcCanvas.height) {
        texW = srcCanvas.width; texH = srcCanvas.height;
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, srcCanvas);
      } else {
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, srcCanvas);
      }
      gl.uniform1i(locs.uStageTex, 0);
      gl.uniform2f(locs.uResolution, canvas.width, canvas.height);
      gl.uniform2f(locs.uShockPos, shockU, shockV);
      gl.uniform1f(locs.uShockAge, shockAge);
      gl.uniform1f(locs.uShockPower, shockPower);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      return true;
    }
  };
}

const glPipeline = initWebGL2Pipeline(glCanvas);

// --- 3. Procedural WebAudio Synthesizer (opt-in sound effects) ---
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

// --- 4. Canvas2D Batch Executor ---
let cssW = window.innerWidth;
let cssH = pageKind === "poses" ? 1420 : window.innerHeight;
let dpr = Math.min(isTouch ? 1.65 : 2.0, window.devicePixelRatio || 1);

function syncCanvasSize() {
  cssW = window.innerWidth;
  cssH = pageKind === "poses" ? Math.max(window.innerHeight, 1420) : window.innerHeight;
  dpr = Math.min(isTouch ? 1.65 : 2.0, window.devicePixelRatio || 1);
  const pw = Math.round(cssW * dpr), ph = Math.round(cssH * dpr);
  if (c2dCanvas.width !== pw || c2dCanvas.height !== ph) {
    c2dCanvas.width = pw; c2dCanvas.height = ph;
  }
}
window.addEventListener("resize", syncCanvasSize);
syncCanvasSize();

function drawShapePath(ctx, item) {
  ctx.beginPath();
  if (item.kind === "c") {
    ctx.arc(item.cx, item.cy, item.r, 0, Math.PI * 2);
  } else {
    const pts = item.pts;
    if (pts.length >= 2) {
      ctx.moveTo(pts[0], pts[1]);
      for (let i = 2; i < pts.length; i += 2) ctx.lineTo(pts[i], pts[i + 1]);
      ctx.closePath();
    }
  }
}

function executeFrameBatch(batchStr) {
  ctx.save();
  ctx.scale(dpr, dpr);
  const lines = batchStr.split("\n");
  let actorDefaultFill = "#dfeee8", actorOutline = "#08110f", actorFlash = 0, partAlpha = 1;
  let partShapes = [], inJoin = false;

  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx];
    if (!line) continue;
    const p = line.split("|");
    switch (p[0]) {
      case "BG": {
        const w = +p[1], h = +p[2], isBattle = p[4] === "1";
        const g = ctx.createLinearGradient(0, 0, 0, h);
        g.addColorStop(0, isBattle ? "#101e1b" : "#0c1816");
        g.addColorStop(0.58, isBattle ? "#182c27" : "#142723");
        g.addColorStop(1, "#070f0d");
        ctx.globalAlpha = 1; ctx.fillStyle = g; ctx.fillRect(0, 0, w, h);
        break;
      }
      case "MT": {
        const yBase = +p[1], amp = +p[2], par = +p[3], camX = +p[4];
        ctx.save();
        ctx.globalAlpha = +p[6]; ctx.fillStyle = p[5];
        ctx.beginPath(); ctx.moveTo(0, cssH);
        for (let x = 0; x <= cssW + 28; x += 28) {
          const wx = (x + camX * par) * 0.0065;
          const y = yBase - (Math.sin(wx) * 0.55 + Math.sin(wx * 2.3 + 1.4) * 0.3 + Math.cos(wx * 4.1) * 0.15) * amp;
          ctx.lineTo(x, y);
        }
        ctx.lineTo(cssW, cssH); ctx.closePath(); ctx.fill(); ctx.restore();
        break;
      }
      case "LN": {
        ctx.save();
        ctx.globalAlpha = +p[7]; ctx.strokeStyle = p[6]; ctx.lineWidth = +p[5];
        if (p[8] === "1") ctx.setLineDash([5, 5]);
        ctx.beginPath(); ctx.moveTo(+p[1], +p[2]); ctx.lineTo(+p[3], +p[4]); ctx.stroke();
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
        ctx.beginPath(); ctx.arc(+p[1], +p[2], r, 0, Math.PI * 2);
        if (p[4]) { ctx.fillStyle = p[4]; ctx.fill(); }
        if (p[5] && +p[6] > 0) { ctx.strokeStyle = p[5]; ctx.lineWidth = +p[6]; ctx.stroke(); }
        ctx.restore();
        break;
      }
      case "TX": {
        ctx.save();
        ctx.globalAlpha = +p[7]; ctx.fillStyle = p[6]; ctx.textAlign = p[5];
        ctx.font = `${p[4]} ${p[3]}px "PingFang SC", "Songti SC", "Noto Serif SC", sans-serif`;
        ctx.fillText(p[8] || "", +p[1], +p[2]);
        ctx.restore();
        break;
      }
      case "ACTOR_BEGIN": {
        const wx = +p[1], wy = +p[2], sc = +p[3], rotDeg = +p[4];
        actorDefaultFill = p[5] || "#dfeee8";
        actorOutline = p[6] || "#08110f";
        actorFlash = +p[7];
        ctx.save();
        ctx.translate(wx, wy);
        if (rotDeg) ctx.rotate(rotDeg * Math.PI / 180);
        ctx.scale(sc, Math.abs(sc));
        ctx.lineJoin = "round"; ctx.lineCap = "round";
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
          ctx.fillStyle = actorFlash > 0.2 ? "#fff8ed" : item.fill;
          drawShapePath(ctx, item); ctx.fill();
        } else partShapes.push(item);
        break;
      }
      case "APOLY": {
        const nums = p[3] ? p[3].split(",").map(Number) : [];
        const item = { kind: "p", pts: nums, fill: p[1] || actorDefaultFill, op: +p[2] };
        if (inJoin) {
          ctx.globalAlpha = item.op;
          ctx.fillStyle = actorFlash > 0.2 ? "#fff8ed" : item.fill;
          drawShapePath(ctx, item); ctx.fill();
        } else partShapes.push(item);
        break;
      }
      case "APART_FILL": {
        ctx.strokeStyle = actorOutline;
        ctx.lineWidth = 4.4;
        ctx.globalAlpha = partAlpha;
        for (const s of partShapes) { drawShapePath(ctx, s); ctx.stroke(); }
        for (const s of partShapes) {
          ctx.globalAlpha = s.op;
          ctx.fillStyle = actorFlash > 0.2 ? "#fff8ed" : s.fill;
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
      case "SLASH": {
        const col = p[1];
        const segs = (p[2] || "").split(";").map((s) => s.split(",").map(Number)).filter((a) => a.length === 3);
        if (segs.length >= 2) {
          ctx.save(); ctx.lineCap = "round";
          for (let i = 0; i < segs.length - 1; i++) {
            const [x1, y1, a1] = segs[i], [x2, y2, a2] = segs[i + 1];
            ctx.globalAlpha = Math.max(a1, a2) * 0.86;
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
}

// --- 5. Low-Latency Dual WebSocket + Piggybacked/Long-Poll HTTP Bridge ---
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
  // Server.hs accepts exactly one handshake message per socket (either RequestCharacterCreationConfig or Login),
  // so always open a fresh socket/bridge session for each handshake.
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

// --- 6. Thin Responsive UI Renderer (Preserves Input Focus & Zero Layout Thrash) ---
let latestUiState = null;
let draftSayText = "";
let draftResetChecked = false;
let labSelectedAction = "rig.fist.punch_a";
let labSelectedOutcome = "hit";
let labSelectedSide = "player";
let labSelectedProfile = "female";

function esc(s) {
  return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function renderOnboarding(st) {
  const zh = st.locale === "zh";
  const errHtml = st.lastError ? `<p class="error-banner" role="alert">${esc(st.lastError)}</p>` : "";
  if (st.loginMode !== "create") {
    return `<div class="onboarding-wrap">
      <div class="mode-tabs">
        <button type="button" class="active" data-ui="login_mode" data-a1="login">${zh ? "登录江湖" : "Sign In"}</button>
        <button type="button" data-ui="login_mode" data-a1="create">${zh ? "创建角色" : "New Character"}</button>
      </div>
      <h2 class="onboard-title">${zh ? "重入江湖" : "Return to Jianghu"}</h2>
      <p class="onboard-sub">${zh ? "输入角色名号续接存档，或切换至「创建角色」定制身世与先天根骨。" : "Enter your character name to continue your journey."}</p>
      <div class="input-row">
        <input id="login-name-input" type="text" value="${esc(st.username)}" placeholder="${zh ? "输入角色名号" : "Character Name"}" autocomplete="off" />
        <button type="button" class="primary-btn" id="btn-do-login" ${st.connecting ? "disabled" : ""}>${st.connecting ? (zh ? "入世中…" : "Connecting…") : (zh ? "踏入江湖" : "Enter")}</button>
      </div>
      <label class="sub-muted" style="display:inline-flex;align-items:center;gap:6px;">
        <input type="checkbox" id="chk-dev-reset" ${draftResetChecked ? "checked" : ""} />
        ${zh ? "测试重开存档（需 MUD_DEV_MODE=1）" : "Dev reset save"}
      </label>
      ${errHtml}
    </div>`;
  }

  const c = st.creation;
  if (!c) {
    return `<div class="onboarding-wrap">
      <div class="mode-tabs">
        <button type="button" data-ui="login_mode" data-a1="login">${zh ? "登录江湖" : "Sign In"}</button>
        <button type="button" class="active" data-ui="login_mode" data-a1="create">${zh ? "创建角色" : "New Character"}</button>
      </div>
      <p class="onboard-sub">${zh ? "正在向服务端读取身世配置…" : "Loading creation config…"}</p>
      <button type="button" data-ui="request_creation_cfg">${zh ? "重试读取" : "Retry"}</button>
    </div>`;
  }

  const step = c.step;
  let stepBody = "";
  if (step === 0) {
    stepBody = `<h2 class="onboard-title">${zh ? "立定名号" : "Choose a Name"}</h2>
      <p class="onboard-sub">${zh ? "输入新角色名号，随后择定性别、出身与少时际遇。" : "Enter a name for your new character."}</p>
      <div class="input-row">
        <input id="login-name-input" type="text" value="${esc(st.username)}" placeholder="${zh ? "如：沈青蝉" : "Name"}" autocomplete="off" />
        <button type="button" class="primary-btn" data-ui="create_step" data-a1="1">${zh ? "下一步" : "Next"}</button>
      </div>`;
  } else if (step === 1) {
    stepBody = `<h2 class="onboard-title">${esc(st.username || "无名客")} ${zh ? "是：" : "Gender:"}</h2>
      <div class="option-grid">${c.genders.map((g) => `
        <button type="button" class="option-card ${c.gender === g.id ? "selected" : ""}" data-ui="create_pick" data-a1="gender" data-a2="${esc(g.id)}">
          <strong>${esc(g.label)}</strong>
        </button>`).join("")}</div>`;
  } else if (step >= 2 && step <= 4) {
    const field = step === 2 ? "origin" : step === 3 ? "childhood1" : "childhood2";
    const list = step === 2 ? c.origins : step === 3 ? c.childhood1List : c.childhood2List;
    const curId = c[field];
    const titles = { 2: zh ? "出身来历" : "Origin", 3: zh ? "幼年经历" : "Childhood", 4: zh ? "后来际遇" : "Youth" };
    stepBody = `<h2 class="onboard-title">${titles[step]}</h2>
      <div class="option-grid">${list.map((o) => `
        <button type="button" class="option-card ${curId === o.id ? "selected" : ""}" data-ui="create_pick" data-a1="${field}" data-a2="${esc(o.id)}">
          <strong>${esc(o.label)}</strong>
          <div class="sub-muted" style="margin-top:4px;">${esc(o.story)}</div>
        </button>`).join("")}</div>`;
  } else {
    const pv = c.preview;
    stepBody = `<h2 class="onboard-title">${zh ? "入世预览" : "Character Preview"}</h2>
      <div class="preview-hero">
        <img src="${esc(pv.portrait)}" alt="portrait" />
        <div>
          <strong style="font-size:16px;color:var(--gold);">${esc(st.username || "无名客")}</strong>
          <div class="sub-muted" style="margin-top:4px;">
            臂力 ${pv.strength} · 身法 ${pv.agility} · 根骨 ${pv.vitality} · 内力 ${pv.maxQi} · 容貌 ${pv.appearance}
          </div>
        </div>
      </div>
      <div class="btn-row">
        <button type="button" class="primary-btn" id="btn-do-create" ${st.connecting ? "disabled" : ""}>${zh ? "确认踏入江湖" : "Create & Enter"}</button>
      </div>`;
  }

  return `<div class="onboarding-wrap">
    <div class="mode-tabs">
      <button type="button" data-ui="login_mode" data-a1="login">${zh ? "登录江湖" : "Sign In"}</button>
      <button type="button" class="active" data-ui="login_mode" data-a1="create">${zh ? "创建角色" : "New Character"}</button>
    </div>
    <div class="btn-row" style="margin-bottom:12px;">
      ${[0, 1, 2, 3, 4, 5].map((idx) => `<button type="button" class="${step === idx ? "primary-btn" : ""}" data-ui="create_step" data-a1="${idx}">${["名号", "性别", "出身", "幼年", "后来", "预览"][idx]}</button>`).join("")}
    </div>
    ${stepBody}
    ${errHtml}
  </div>`;
}

function renderCharacterPanel(st) {
  const zh = st.locale === "zh";
  const idle = st.connected && !st.inBattle && !st.storyActive && !st.busy;
  const hpPct = Math.min(100, Math.round((st.hp / Math.max(1, st.maxHp)) * 100));
  const qiPct = Math.min(100, Math.round((st.qi / Math.max(1, st.maxQi)) * 100));
  const jingPct = Math.min(100, Math.round((st.jing / Math.max(1, st.maxJing)) * 100));

  const body = st.charSubTab === "inventory"
    ? `<div class="card-stack">
        <div class="info-card"><span>${zh ? "随身碎银" : "Silver"}：</span><strong style="color:var(--gold);">${st.money}</strong></div>
        ${st.inventory.length === 0 ? `<p class="sub-muted">${zh ? "行囊空空如也。" : "Empty."}</p>` : st.inventory.map((it) => `
          <div class="info-card">
            <div style="display:flex;justify-content:space-between;align-items:center;">
              <div><strong>${esc(it.name)}</strong> <span class="sub-muted">×${it.amount}</span> ${it.equipped ? `<span class="sub-muted">· ${zh ? "已佩带" : "Equipped"}</span>` : ""}</div>
              <div class="btn-row" style="margin-top:0;">
                ${it.usable ? `<button type="button" ${st.inBattle || st.storyActive ? "disabled" : ""} data-ui="use" data-a1="${esc(it.id)}">${it.hasSlot ? (it.equipped ? (zh ? "卸下" : "Unequip") : (zh ? "佩带" : "Equip")) : (zh ? "使用" : "Use")}</button>` : ""}
                ${it.studyable ? `<button type="button" ${!idle ? "disabled" : ""} data-ui="study" data-a1="${esc(it.id)}">${zh ? "研读" : "Study"}</button>` : ""}
              </div>
            </div>
          </div>`).join("")}
      </div>`
    : `<div>
        <div class="preview-hero">
          <img src="${esc(st.portrait)}" alt="portrait" />
          <div>
            <strong style="font-size:15px;color:var(--gold);">${esc(st.username)}</strong>
            <div class="sub-muted">${esc(st.genderLabel)} · ${esc(st.appearanceText || `${zh ? "容貌" : "Looks"} ${st.appearance}`)}</div>
            ${st.injuredSec > 0 ? `<div class="blocker-txt">${zh ? `重伤未愈 (${st.injuredSec}s)` : `Injured (${st.injuredSec}s)`}</div>` : ""}
            ${st.combatInsight > 0 ? `<div class="sub-muted" style="color:var(--jade);">${zh ? `实战印证 ${st.combatInsight} 层` : `Insight ×${st.combatInsight}`}</div>` : ""}
          </div>
        </div>
        <div class="info-card">
          <div class="sub-muted">${zh ? "气血" : "HP"} ${st.hp}/${st.maxHp}</div>
          <div class="progress-track"><span style="width:${hpPct}%;background:var(--crimson);"></span></div>
          <div class="sub-muted">${zh ? "内力" : "Qi"} ${st.qi}/${st.maxQi}</div>
          <div class="progress-track"><span style="width:${qiPct}%;"></span></div>
          <div class="sub-muted">${zh ? "精神" : "Spirit"} ${st.jing}/${st.maxJing}</div>
          <div class="progress-track"><span style="width:${jingPct}%;background:var(--gold);"></span></div>
          <div class="btn-row">
            <button type="button" ${!idle || st.qi < 20 ? "disabled" : ""} data-ui="meditate">${zh ? "打坐周天 (20×10)" : "Meditate"}</button>
            <button type="button" data-ui="refresh">${zh ? "刷新状态" : "Refresh"}</button>
          </div>
        </div>
        <dl class="stat-grid">
          <div class="stat-cell"><dt>${zh ? "碎银" : "Silver"}</dt><dd>${st.money}</dd></div>
          <div class="stat-cell"><dt>${zh ? "潜能" : "Potential"}</dt><dd>${st.potential}</dd></div>
          <div class="stat-cell"><dt>${zh ? "实战经验" : "Exp"}</dt><dd>${st.combatExp}</dd></div>
          <div class="stat-cell"><dt>${zh ? "臂力" : "STR"}</dt><dd>${st.strength}</dd></div>
          <div class="stat-cell"><dt>${zh ? "身法" : "AGI"}</dt><dd>${st.agility}</dd></div>
          <div class="stat-cell"><dt>${zh ? "根骨" : "VIT"}</dt><dd>${st.vitality}</dd></div>
        </dl>
      </div>`;

  return `<aside class="side-drawer">
    <div class="drawer-head">
      <div class="btn-row" style="margin-top:0;">
        <button type="button" class="${st.charSubTab === "status" ? "primary-btn" : ""}" data-ui="char_subtab" data-a1="status">${zh ? "角色属性" : "Status"}</button>
        <button type="button" class="${st.charSubTab === "inventory" ? "primary-btn" : ""}" data-ui="char_subtab" data-a1="inventory">${zh ? "行囊器物" : "Bag"} (${st.inventory.length})</button>
      </div>
      <button type="button" class="desktop-only-close" data-ui="desktop_drawer" data-a1="">×</button>
    </div>
    ${body}
  </aside>`;
}

function renderArtsPanel(st) {
  const zh = st.locale === "zh";
  const idle = st.connected && !st.inBattle && !st.storyActive && !st.busy;
  const busyHtml = st.busy
    ? `<div class="info-card" style="border-color:var(--gold);margin-bottom:10px;">
        <div style="display:flex;justify-content:space-between;align-items:center;">
          <strong style="color:var(--gold);font-size:12.5px;">${esc(st.busy.label)} · ${st.busy.remainingSec.toFixed(1)}s</strong>
          <button type="button" class="danger-btn" data-ui="halt">${zh ? "停下" : "Stop"}</button>
        </div>
        <div class="progress-track"><span style="width:${Math.min(100, Math.max(5, Math.round(((st.busy.stepSec - st.busy.remainingSec) / st.busy.stepSec) * 100)))}%;background:var(--gold);"></span></div>
      </div>`
    : "";

  return `<aside class="side-drawer">
    <div class="drawer-head">
      <h2>${zh ? "武学修为" : "Martial Arts"} (${st.arts.length})</h2>
      <button type="button" class="desktop-only-close" data-ui="desktop_drawer" data-a1="">×</button>
    </div>
    ${busyHtml}
    <div class="card-stack">
      ${st.arts.length === 0 ? `<p class="sub-muted">${zh ? "尚未习得武学。" : "No martial arts learned."}</p>` : st.arts.map((a) => `
        <div class="info-card ${a.enabled ? "enabled" : ""}">
          <div style="display:flex;justify-content:space-between;">
            <strong>${esc(a.name)}</strong>
            <span class="sub-muted">${esc(a.typeLabel)}</span>
          </div>
          <div class="sub-muted">${esc(a.rank)} · ${esc(a.levelText)}</div>
          ${a.nextProgress > 0 ? `<div class="progress-track"><span style="width:${Math.min(100, Math.round((a.progress / a.nextProgress) * 100))}%;"></span></div>` : ""}
          ${a.blocker ? `<span class="blocker-txt">${esc(a.blocker)}</span>` : ""}
          ${a.moves ? `<div class="sub-muted" style="margin-top:3px;">${esc(a.moves)}</div>` : ""}
          ${!a.foundation ? `<div class="btn-row">
            ${!a.maxed ? `<button type="button" ${!idle ? "disabled" : ""} data-ui="practice" data-a1="${esc(a.id)}" data-a2="1">${zh ? "练功" : "Practice"}</button>
              <button type="button" ${!idle ? "disabled" : ""} data-ui="practice" data-a1="${esc(a.id)}" data-a2="10">${zh ? "练十次" : "×10"}</button>` : ""}
            ${a.canResearch ? `<button type="button" ${!idle ? "disabled" : ""} data-ui="research" data-a1="${esc(a.id)}">${zh ? "自研" : "Research"}</button>` : ""}
            ${a.enabled ? `<span class="sub-muted" style="color:var(--gold);align-self:center;">${zh ? "✓ 已启用" : "✓ Enabled"}</span>` : `<button type="button" ${st.inBattle ? "disabled" : ""} data-ui="enable" data-a1="${esc(a.typeRaw)}" data-a2="${esc(a.id)}">${zh ? "启用" : "Enable"}</button>`}
          </div>` : ""}
        </div>`).join("")}
    </div>
  </aside>`;
}

function renderQuestsPanel(st) {
  const zh = st.locale === "zh";
  return `<aside class="side-drawer">
    <div class="drawer-head">
      <h2>${zh ? "江湖轶闻" : "Quests"} (${st.quests.length})</h2>
      <button type="button" class="desktop-only-close" data-ui="desktop_drawer" data-a1="">×</button>
    </div>
    <div class="card-stack">
      ${st.quests.length === 0 ? `<p class="sub-muted">${zh ? "暂无记录。" : "No quests yet."}</p>` : st.quests.map((q) => `
        <div class="info-card">
          <div style="display:flex;justify-content:space-between;">
            <strong>${esc(q.name)}</strong>
            <span class="sub-muted" style="color:${q.done ? "var(--jade)" : "var(--gold)"};">${q.done ? (zh ? "已完成" : "Done") : (zh ? "进行中" : "Active")}</span>
          </div>
          ${q.objective ? `<div style="font-size:12px;margin-top:4px;">${esc(q.objective)}</div>` : ""}
          ${q.rewards ? `<div class="sub-muted" style="margin-top:4px;">${zh ? "奖励：" : "Reward: "}${esc(q.rewards)}</div>` : ""}
        </div>`).join("")}
    </div>
  </aside>`;
}

function renderBattleSection(st) {
  const zh = st.locale === "zh";
  const pHpPct = Math.min(100, Math.max(0, (st.hp / Math.max(1, st.maxHp)) * 100));
  const pQiPct = Math.min(100, Math.max(0, (st.qi / Math.max(1, st.maxQi)) * 100));
  const eHpPct = Math.min(100, Math.max(0, (st.enemyHp / Math.max(1, st.enemyMaxHp)) * 100));
  const eQiPct = Math.min(100, Math.max(0, (st.enemyQi / Math.max(1, st.enemyMaxQi)) * 100));
  const soundLabel = zh ? (st.soundOn ? "音效：开" : "音效：关") : (st.soundOn ? "Sound on" : "Sound off");

  const topHtml = `<div class="battle-top-bar">
    <div class="combatant player">
      <strong>${esc(st.username || "行者")}</strong>
      <div class="micro-meter hp"><span style="width:${pHpPct.toFixed(1)}%"></span><em>${st.hp}/${st.maxHp}</em></div>
      <div class="micro-meter qi"><span style="width:${pQiPct.toFixed(1)}%"></span><em>${st.qi}/${st.maxQi}</em></div>
    </div>
    <div class="battle-vs-mid" style="display:flex;flex-direction:column;align-items:center;gap:6px;">
      <button type="button" aria-pressed="${st.soundOn ? "true" : "false"}" data-ui="toggle_sound">${soundLabel}</button>
    </div>
    <div class="combatant enemy">
      <strong>${esc(st.enemyName)}</strong>
      <div class="micro-meter hp"><span style="width:${eHpPct.toFixed(1)}%"></span><em>${st.enemyHp}/${st.enemyMaxHp}</em></div>
      <div class="micro-meter qi"><span style="width:${eQiPct.toFixed(1)}%"></span><em>${st.enemyQi}/${st.enemyMaxQi}</em></div>
    </div>
  </div>`;

  const skillsHtml = st.skills.length > 0
    ? `<section class="active-skill-panel">
        ${st.skills.map((sk, i) => {
          const cdPct = sk.cdRem > 0.05 ? Math.min(100, (sk.cdRem / sk.cdTotal) * 100) : 0;
          return `<button type="button" class="skill-btn ${sk.queued ? "queued" : ""}" ${!sk.ready ? "disabled" : ""} data-ui="perform" data-a1="${esc(sk.id)}" title="${esc(sk.desc)}">
            <i class="skill-cd-fill" style="width:${cdPct.toFixed(1)}%"></i>
            ${i < 6 ? `<kbd class="skill-key">${i + 1}</kbd>` : ""}
            <strong>${esc(sk.name)}</strong>
            <div class="sub-muted">${sk.queued ? (zh ? "蓄势待发" : "Queued") : sk.cdRem > 0.05 ? `${Math.ceil(sk.cdRem)}s` : `${zh ? "动" : "AP"} ${sk.ap} · ${zh ? "气" : "Qi"} ${sk.cost}`}</div>
          </button>`;
        }).join("")}
      </section>`
    : "";

  return { topHtml, skillsHtml, soundLabel };
}

function renderMessageDock(st, fullHeight = false) {
  const zh = st.locale === "zh";
  return `<div class="message-dock" style="${fullHeight ? "height:100%;display:flex;flex-direction:column;" : ""}">
    <div class="log-scroll" id="log-scroll-box" style="${fullHeight ? "flex:1;height:auto;" : ""}">
      ${st.logs.map((l) => `<div class="log-line log-${esc(l.kind)}">${esc(l.text)}</div>`).join("")}
    </div>
    <form class="say-row" id="say-form">
      <input id="say-input" type="text" value="${esc(draftSayText)}" placeholder="${zh ? "输入发言，回车发送…" : "Say something…"}" autocomplete="off" />
      <button type="submit">${zh ? "发送" : "Send"}</button>
      <button type="button" data-ui="clear_logs">${zh ? "清屏" : "Clear"}</button>
    </form>
  </div>`;
}

function renderUiShell(st) {
  latestUiState = st;
  if (stageProbe) {
    stageProbe.setAttribute("data-event-id", st.stageEventId || "idle");
    const pNode = stageProbe.querySelector('[data-side="player"]');
    if (pNode) {
      const dx = +(st.playerDashX || 0).toFixed(2);
      const dy = +(st.playerDashY || 0).toFixed(2);
      pNode.style.transform = `matrix(1, 0, 0, 1, ${dx}, ${dy})`;
    }
  }

  // Preserve focused input cursor if user is actively typing!
  const activeEl = document.activeElement;
  if (activeEl && (activeEl.id === "login-name-input" || activeEl.id === "say-input")) {
    return;
  }

  if (st.page === "poses") return;

  if (st.page === "lab") {
    const { topHtml } = renderBattleSection(st);
    uiRoot.innerHTML = `<div class="workspace-area">
      <div>
        ${topHtml}
        <div style="pointer-events:auto;margin-top:8px;display:flex;justify-content:flex-end;">
          <a href="/" style="color:var(--gold);font-size:12.5px;align-self:center;">返回游戏</a>
        </div>
      </div>
      <div class="lab-dock">
        <div class="lab-row">
          <button type="button" class="primary-btn" id="lab-btn-demo">播放完整交锋</button>
          <button type="button" id="lab-btn-pause">${st.labPaused ? "继续" : "暂停"}</button>
          <select id="lab-sel-action">${st.labActions.map((a) => `<option value="${esc(a.id)}" ${a.id === labSelectedAction ? "selected" : ""}>${esc(a.label)} (${esc(a.id)})</option>`).join("")}</select>
          <select id="lab-sel-outcome">
            <option value="hit" ${labSelectedOutcome === "hit" ? "selected" : ""}>命中</option>
            <option value="dodge" ${labSelectedOutcome === "dodge" ? "selected" : ""}>闪避</option>
            <option value="parry" ${labSelectedOutcome === "parry" ? "selected" : ""}>招架</option>
            <option value="effect" ${labSelectedOutcome === "effect" ? "selected" : ""}>效果</option>
          </select>
          <select id="lab-sel-side">
            <option value="player" ${labSelectedSide === "player" ? "selected" : ""}>行者</option>
            <option value="enemy" ${labSelectedSide === "enemy" ? "selected" : ""}>守擂人</option>
          </select>
          <select id="lab-sel-look">
            <option value="maiden" ${st.lookStyle === "maiden" ? "selected" : ""}>发髻披发</option>
            <option value="ponytail" ${st.lookStyle === "ponytail" ? "selected" : ""}>高马尾</option>
          </select>
          <button type="button" id="lab-btn-one">播放这一招</button>
          <button type="button" data-ui="toggle_render">${st.renderMode === "webgl2" ? "WebGL2 水墨" : "Canvas2D"}</button>
        </div>
        <div class="lab-row">
          <span id="lab-time-span">时间轴 ${Math.round(st.labElapsedMs)} / ${Math.round(st.labDurationMs)} ms</span>
          <input type="range" id="lab-slider" min="0" max="${Math.max(1, Math.round(st.labDurationMs))}" value="${Math.round(st.labElapsedMs)}" />
        </div>
      </div>
    </div>`;
    return;
  }

  const zh = st.locale === "zh";
  if (!st.connected && !st.inBattle) {
    uiRoot.innerHTML = `<header class="desktop-header">
        <div class="hud-left"><strong style="color:var(--gold);font-size:17px;letter-spacing:0.08em;">${zh ? "听风录 · 纯 Haskell 客户端" : "Tingfeng · Haskell Wasm"}</strong></div>
        <div class="hud-right">
          <button type="button" data-ui="toggle_render">${st.renderMode === "webgl2" ? "WebGL2 水墨" : "Canvas 2D"}</button>
          <button type="button" data-ui="toggle_locale">${zh ? "EN" : "中"}</button>
        </div>
      </header>
      <div class="workspace-area">${renderOnboarding(st)}</div>`;
    return;
  }

  const hpPct = Math.min(100, Math.max(0, (st.hp / Math.max(1, st.maxHp)) * 100));
  const qiPct = Math.min(100, Math.max(0, (st.qi / Math.max(1, st.maxQi)) * 100));
  const activeQuests = st.quests.filter((q) => !q.done).length;
  const isMobileView = window.innerWidth <= 768;

  const headerHtml = `<header class="desktop-header">
      <div class="hud-left">
        <button type="button" class="player-pill" data-ui="desktop_drawer" data-a1="character">
          <img src="${esc(st.portrait)}" alt="avatar" />
          <div class="pill-bars">
            <strong style="font-size:12.5px;text-align:left;">${esc(st.username)}</strong>
            <span class="mini-bar hp"><i style="transform:scaleX(${(hpPct / 100).toFixed(3)})"></i></span>
            <span class="mini-bar qi"><i style="transform:scaleX(${(qiPct / 100).toFixed(3)})"></i></span>
          </div>
          <span class="vital-nums"><em class="hp-n">${st.hp}</em> / <em class="qi-n">${st.qi}</em></span>
        </button>
        ${st.busy && !st.inBattle ? `<button type="button" class="busy-chip" data-ui="desktop_drawer" data-a1="arts">${esc(st.busy.label)}</button>` : ""}
      </div>
      <div class="hud-right">
        <button type="button" class="${st.desktopDrawer === "arts" ? "primary-btn" : ""}" data-ui="desktop_drawer" data-a1="arts">${zh ? "武学" : "Arts"}</button>
        <button type="button" class="${st.desktopDrawer === "quests" ? "primary-btn" : ""}" data-ui="desktop_drawer" data-a1="quests">${zh ? "任务" : "Quests"}${activeQuests > 0 ? `<i class="nav-dot"></i>` : ""}</button>
        <button type="button" data-ui="toggle_render" title="切换 WebGL2 水墨管线 / 纯 Canvas 2D">${st.renderMode === "webgl2" ? "WebGL2 水墨 ✦" : "Canvas 2D"}</button>
        <button type="button" data-ui="toggle_locale">${zh ? "EN" : "中"}</button>
      </div>
    </header>
    <header class="mobile-header">
      <div class="mobile-header-row">
        <span class="mobile-loc-title">${esc(st.inBattle ? st.enemyName : (st.roomName || (zh ? "听风录" : "Tingfeng")))}</span>
        <div style="display:flex;gap:6px;align-items:center;">
          ${st.busy && !st.inBattle ? `<button type="button" class="busy-chip" data-ui="mobile_tab" data-a1="arts">${esc(st.busy.label)}</button>` : ""}
          <button type="button" class="vital-nums" data-ui="mobile_tab" data-a1="character"><em class="hp-n">${st.hp}</em>/<em class="qi-n">${st.qi}</em></button>
          <button type="button" data-ui="toggle_render" style="padding:3px 7px;font-size:11px;">${st.renderMode === "webgl2" ? "GL" : "2D"}</button>
          <button type="button" data-ui="toggle_locale" style="padding:3px 7px;font-size:11px;">${zh ? "EN" : "中"}</button>
        </div>
      </div>
      <div class="mobile-bars">
        <span class="mini-bar hp"><i style="transform:scaleX(${(hpPct / 100).toFixed(3)})"></i></span>
        <span class="mini-bar qi"><i style="transform:scaleX(${(qiPct / 100).toFixed(3)})"></i></span>
      </div>
    </header>`;

  let centerTop = "", centerBottom = "";
  if (st.inBattle) {
    const b = renderBattleSection(st);
    centerTop = b.topHtml;
    centerBottom = `<div class="battle-bottom-wrap">${b.skillsHtml}${!isMobileView ? renderMessageDock(st) : ""}</div>`;
  } else {
    const selNpc = st.npcs.find((n) => n.id === st.selectedNpc);
    const idle = !st.storyActive && !st.busy;
    const npcModalHtml = selNpc
      ? `<div class="npc-modal">
          <div style="display:flex;justify-content:space-between;align-items:center;">
            <h3>${esc(selNpc.name)}</h3>
            <button type="button" data-ui="select_npc" data-a1="">×</button>
          </div>
          ${selNpc.desc ? `<p>${esc(selNpc.desc)}</p>` : ""}
          <div class="btn-row">
            ${(selNpc.actions.includes("talk") || selNpc.actions.includes("dialogue") || selNpc.actions.length === 0) ? `<button type="button" class="primary-btn" data-ui="talk" data-a1="${esc(selNpc.id)}">${zh ? "交谈" : "Talk"}</button>` : ""}
            ${selNpc.actions.includes("attack") ? `<button type="button" class="danger-btn" data-ui="attack" data-a1="${esc(selNpc.id)}">${zh ? "动手攻击" : "Attack"}</button>` : ""}
          </div>
          ${selNpc.teaches.length > 0 ? `<div class="npc-sublist"><div class="sub-muted">${zh ? "可传武学" : "Teaches"}</div>${selNpc.teaches.map((t) => `
            <div class="npc-subrow">
              <span>${esc(t.name)} <small class="sub-muted">(≤Lv.${t.maxLevel})</small></span>
              <span class="btn-row" style="margin-top:0;">
                <button type="button" ${!idle ? "disabled" : ""} data-ui="learn" data-a1="${esc(selNpc.id)}:${esc(t.id)}" data-a2="1">${zh ? "学艺" : "Learn"}</button>
                <button type="button" ${!idle ? "disabled" : ""} data-ui="learn" data-a1="${esc(selNpc.id)}:${esc(t.id)}" data-a2="10">${zh ? "学十次" : "×10"}</button>
              </span>
            </div>`).join("")}</div>` : ""}
          ${selNpc.shop.length > 0 ? `<div class="npc-sublist"><div class="sub-muted">${zh ? "行商货架" : "Shop"}</div>${selNpc.shop.map((s) => `
            <div class="npc-subrow">
              <span>${esc(s.name)} <small class="sub-muted">(${s.price} ${zh ? "碎银" : "silver"})</small></span>
              <button type="button" data-ui="buy" data-a1="${esc(selNpc.id)}:${esc(s.id)}">${zh ? "购买" : "Buy"}</button>
            </div>`).join("")}</div>` : ""}
        </div>`
      : "";

    centerTop = `<div>
      <div class="room-float">
        <h2>${esc(st.roomName)}</h2>
        <p>${esc(st.roomDesc)}</p>
        ${st.npcs.length > 0 ? `<div class="npc-chips">${st.npcs.map((n) => `
          <button type="button" class="${st.selectedNpc === n.id ? "primary-btn" : ""}" data-ui="select_npc" data-a1="${esc(n.id)}">${esc(n.name)}</button>`).join("")}</div>` : ""}
      </div>
      ${npcModalHtml}
    </div>`;

    centerBottom = isMobileView
      ? `<div class="message-dock" style="cursor:pointer;" data-ui="mobile_tab" data-a1="log">
          <div class="log-scroll" style="height:54px;">
            ${st.logs.slice(-2).map((l) => `<div class="log-line log-${esc(l.kind)}">${esc(l.text)}</div>`).join("")}
          </div>
        </div>`
      : renderMessageDock(st);
  }

  let drawerHtml = "";
  if (isMobileView) {
    if (st.mobileTab === "log") drawerHtml = `<aside class="side-drawer">${renderMessageDock(st, true)}</aside>`;
    else if (st.mobileTab === "character") drawerHtml = renderCharacterPanel(st);
    else if (st.mobileTab === "arts") drawerHtml = renderArtsPanel(st);
    else if (st.mobileTab === "quests") drawerHtml = renderQuestsPanel(st);
  } else {
    if (st.desktopDrawer === "character") drawerHtml = renderCharacterPanel(st);
    else if (st.desktopDrawer === "arts") drawerHtml = renderArtsPanel(st);
    else if (st.desktopDrawer === "quests") drawerHtml = renderQuestsPanel(st);
  }

  const mobileNavHtml = `<nav class="mobile-tabbar">
    <button type="button" class="${st.mobileTab === "world" ? "active" : ""}" data-ui="mobile_tab" data-a1="world">${zh ? (st.inBattle ? "交锋" : "江湖") : (st.inBattle ? "Battle" : "World")}</button>
    <button type="button" class="${st.mobileTab === "log" ? "active" : ""}" data-ui="mobile_tab" data-a1="log">
      ${zh ? "纪事" : "Log"}${st.unreadLogs > 0 ? `<span class="unread-badge">${st.unreadLogs}</span>` : ""}
    </button>
    <button type="button" class="${st.mobileTab === "arts" ? "active" : ""}" data-ui="mobile_tab" data-a1="arts">${zh ? "武学" : "Arts"}</button>
    <button type="button" class="${st.mobileTab === "character" ? "active" : ""}" data-ui="mobile_tab" data-a1="character">${zh ? "角色" : "Hero"}</button>
    <button type="button" class="${st.mobileTab === "quests" ? "active" : ""}" data-ui="mobile_tab" data-a1="quests">${zh ? "任务" : "Quests"}</button>
  </nav>`;

  uiRoot.innerHTML = `${headerHtml}
    <div class="workspace-area ${!isMobileView && st.desktopDrawer ? "with-drawer" : ""}">${isMobileView && st.mobileTab !== "world" ? "" : `${centerTop}${centerBottom}`}</div>
    ${drawerHtml}
    ${mobileNavHtml}`;

  const logBox = document.getElementById("log-scroll-box");
  if (logBox) logBox.scrollTop = logBox.scrollHeight;
}

// --- 7. Delegated DOM Events & Keyboard Shortcuts ---
uiRoot.addEventListener("input", (ev) => {
  if (ev.target.id === "login-name-input" && hsExports) {
    runHs(() => hsExports.hs_ui_action("set_username", ev.target.value, ""));
  } else if (ev.target.id === "say-input") {
    draftSayText = ev.target.value;
  } else if (ev.target.id === "chk-dev-reset") {
    draftResetChecked = ev.target.checked;
  } else if (ev.target.id === "lab-slider" && hsExports) {
    const ms = +ev.target.value;
    runHs(async () => {
      await hsExports.hs_lab_cmd("pause", "true", "", "", 0);
      await hsExports.hs_lab_cmd("seek", "", "", "", ms);
    });
  }
});

uiRoot.addEventListener("change", (ev) => {
  if (ev.target.id === "lab-sel-action") labSelectedAction = ev.target.value;
  else if (ev.target.id === "lab-sel-outcome") labSelectedOutcome = ev.target.value;
  else if (ev.target.id === "lab-sel-side") labSelectedSide = ev.target.value;
  else if (ev.target.id === "lab-sel-look" && hsExports) {
    runHs(() => hsExports.hs_ui_action("set_look", ev.target.value, ""));
  }
});

uiRoot.addEventListener("submit", (ev) => {
  if (ev.target.id === "say-form") {
    ev.preventDefault();
    const txt = draftSayText.trim();
    if (!txt || !hsExports) return;
    draftSayText = "";
    const inp = document.getElementById("say-input");
    if (inp) { inp.value = ""; inp.blur(); }
    runHs(() => hsExports.hs_ui_action("say", txt, ""));
  }
});

uiRoot.addEventListener("click", (ev) => {
  if (!hsExports) return;
  if (ev.target.id === "btn-do-login") {
    const inp = document.getElementById("login-name-input");
    const u = inp ? inp.value : (latestUiState?.username || "");
    if (inp) inp.blur();
    runHs(() => hsExports.hs_ui_action("login_submit", u, draftResetChecked ? "reset" : ""));
    return;
  }
  if (ev.target.id === "btn-do-create") {
    runHs(() => hsExports.hs_ui_action("create_submit", latestUiState?.username || "", draftResetChecked ? "reset" : ""));
    return;
  }
  if (ev.target.id === "lab-btn-demo") {
    runHs(() => hsExports.hs_lab_cmd("demo", "", "", "", 0));
    return;
  }
  if (ev.target.id === "lab-btn-pause") {
    runHs(() => hsExports.hs_lab_cmd("pause", latestUiState?.labPaused ? "false" : "true", "", "", 0));
    return;
  }
  if (ev.target.id === "lab-btn-one") {
    runHs(async () => {
      await hsExports.hs_lab_cmd("seed", labSelectedProfile, "male", "", 0);
      await hsExports.hs_lab_cmd("submit", labSelectedAction, labSelectedOutcome, labSelectedSide, 18);
    });
    return;
  }
  const el = ev.target.closest("[data-ui]");
  if (el) {
    runHs(() => hsExports.hs_ui_action(el.dataset.ui, el.dataset.a1 || "", el.dataset.a2 || ""));
  }
});

window.addEventListener("keydown", (ev) => {
  if (!hsExports) return;
  const tag = ev.target?.tagName;
  if (ev.key === "Enter" && ev.target?.id === "login-name-input") {
    ev.preventDefault();
    const u = ev.target.value;
    ev.target.blur();
    if (latestUiState?.loginMode === "create") {
      runHs(() => hsExports.hs_ui_action("create_step", "1", ""));
    } else {
      runHs(() => hsExports.hs_ui_action("login_submit", u, draftResetChecked ? "reset" : ""));
    }
    return;
  }
  if (ev.key === "Escape" && latestUiState?.desktopDrawer) {
    runHs(() => hsExports.hs_ui_action("desktop_drawer", "", ""));
    return;
  }
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
  if (latestUiState?.inBattle && !ev.metaKey && !ev.ctrlKey && !ev.altKey) {
    const idx = Number(ev.key) - 1;
    if (Number.isInteger(idx) && idx >= 0 && idx < 6) {
      ev.preventDefault();
      runHs(() => hsExports.hs_ui_action("perform_index", String(idx), ""));
    }
  }
});

// --- 8. Host Bridge + Synchronous BattleLab & Fixtures API ---
let latestLabStateObj = {
  game: { battle: { active: false, player: null, enemy: null, presentation: null, animation: { activeTimeline: null, queueDepth: 0 } } },
  playback: { paused: false, speed: 1, elapsedMs: 0, durationMs: 0 }
};
let wasmReady = false;

globalThis.__tfHost = {
  submitFrame(batchStr, modeInt, shockU, shockV, shockAge, shockPower) {
    executeFrameBatch(batchStr);
    const wantGl = modeInt === 1 && glPipeline !== null && glPipeline.isAvailable();
    if (wantGl && glPipeline.render(c2dCanvas, shockU, shockV, shockAge, shockPower)) {
      glCanvas.style.opacity = "1";
    } else {
      glCanvas.style.opacity = "0";
    }
  },
  syncOverlay(jsonStr) {
    renderUiShell(JSON.parse(jsonStr));
  },
  syncLabState(jsonStr) {
    latestLabStateObj = JSON.parse(jsonStr);
    const tsEl = document.getElementById("lab-time-span");
    const slEl = document.getElementById("lab-slider");
    if (tsEl && latestLabStateObj.playback) {
      const eMs = Math.round(latestLabStateObj.playback.elapsedMs || 0);
      const dMs = Math.round(latestLabStateObj.playback.durationMs || 0);
      tsEl.textContent = `时间轴 ${eMs} / ${dMs} ms`;
      if (slEl && document.activeElement !== slEl) {
        slEl.max = String(Math.max(1, dMs));
        slEl.value = String(eMs);
      }
    }
  },
  connectWs(mode, username, password) {
    connectServer(mode, username, password);
  },
  sendWs(payload) {
    sendServer(payload);
  },
  setCursor(cur) {
    document.body.style.cursor = cur;
  },
  playSfx(kind) {
    playSynthesizedSfx(kind);
  },
  saveLocal(k, v) {
    try { localStorage.setItem(k, v); } catch (_) {}
  }
};

// Expose __battleLab & __tfHsFixtures (for /battle-lab.html and Playwright E2E tests!)
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

  // Stage pointer drag-to-pan, wheel zoom & click hit-testing
  const stageWrap = document.getElementById("stage-wrap");
  let dragging = false, dragMoved = false, lastX = 0, lastY = 0;

  stageWrap.addEventListener("pointerdown", (e) => {
    dragging = true; dragMoved = false; lastX = e.clientX; lastY = e.clientY;
  });
  stageWrap.addEventListener("pointermove", (e) => {
    if (dragging) {
      const dx = e.clientX - lastX, dy = e.clientY - lastY;
      if (Math.hypot(dx, dy) > 4) dragMoved = true;
      if (dragMoved) {
        lastX = e.clientX; lastY = e.clientY;
        runHs(() => hsExports.hs_pan_zoom(dx, dy, 1.0));
        return;
      }
    }
    runHs(() => hsExports.hs_pointer_move(e.clientX, e.clientY));
  });
  window.addEventListener("pointerup", () => { dragging = false; });
  stageWrap.addEventListener("click", (e) => {
    if (dragMoved) { dragMoved = false; return; }
    runHs(() => hsExports.hs_pointer_click(e.clientX, e.clientY));
  });
  stageWrap.addEventListener("wheel", (e) => {
    if (pageKind === "poses") return;
    e.preventDefault();
    const factor = e.deltaY < 0 ? 1.09 : 0.92;
    runHs(() => hsExports.hs_pan_zoom(0, 0, factor));
  }, { passive: false });

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
      draftResetChecked = wantReset;
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
      syncCanvasSize();
      await runHs(() => hsExports.hs_step_frame(dt, cssW, cssH, reducedMotionQuery.matches ? 1 : 0));
    }
    requestAnimationFrame(frameLoop);
  };
  requestAnimationFrame(frameLoop);
}

boot().catch((e) => console.error("Boot failed:", e));
