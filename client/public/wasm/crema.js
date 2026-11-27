// Crema Web Host (`host/web/crema.js`)
// Zero-dependency ES Module executing Crema's 8-byte word-aligned binary `DrawList`
// directly out of WebAssembly linear memory onto HiDPI HTML5 Canvas2D, with
// transparent `<input>` CJK IME proxy and frame-boundary Mark-Sweep GC.

const DEFAULT_FONTS = {
  sans: 'system-ui, -apple-system, "PingFang SC", "Hiragino Sans GB", "Noto Sans SC", sans-serif',
  serif: 'Georgia, "Songti SC", "Noto Serif CJK SC", "Source Han Serif SC", serif',
  mono: 'ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace',
};

function unpackCssColor(col) {
  const u = col >>> 0;
  if (u === 0) return "";
  const r = (u >>> 24) & 255;
  const g = (u >>> 16) & 255;
  const b = (u >>> 8) & 255;
  const a = u & 255;
  if (a === 255) return `rgb(${r},${g},${b})`;
  return `rgba(${r},${g},${b},${(a / 255).toFixed(3)})`;
}

export async function mountCremaApp(options = {}) {
  const canvas = options.canvas || document.getElementById("crema-canvas");
  const imeInput = options.imeInput || document.getElementById("crema-ime");
  const wasmUrl = options.wasmUrl || "./app.wasm";
  const assetsPrefix = options.assetsPrefix || "";
  const fitVisualViewport = options.fitVisualViewport !== false;
  const captureWheel = options.captureWheel !== false;
  const onClearBg = typeof options.onClearBg === "function" ? options.onClearBg : null;
  const fonts = {
    sans: options.fonts?.sans || DEFAULT_FONTS.sans,
    serif: options.fonts?.serif || DEFAULT_FONTS.serif,
    mono: options.fonts?.mono || DEFAULT_FONTS.mono,
  };

  const ctx = canvas.getContext("2d", { alpha: false });
  const utf8Dec = new TextDecoder("utf-8");
  const utf8Enc = new TextEncoder();

  let cssW = Math.max(320, canvas.clientWidth || window.innerWidth);
  let cssH = Math.max(220, canvas.clientHeight || window.innerHeight);
  let layoutH = cssH;
  let dpr = Math.min(2.0, window.devicePixelRatio || 1);

  function syncCanvasSize() {
    cssW = Math.max(320, canvas.clientWidth || window.innerWidth);
    cssH = Math.max(220, canvas.clientHeight || window.innerHeight);
    const vv = window.visualViewport;
    layoutH = fitVisualViewport && vv
      ? Math.max(220, Math.min(cssH, Math.round(vv.height)))
      : cssH;
    dpr = Math.min(2.0, window.devicePixelRatio || 1);
    const pw = Math.round(cssW * dpr);
    const ph = Math.round(cssH * dpr);
    if (canvas.width !== pw || canvas.height !== ph) {
      canvas.width = pw;
      canvas.height = ph;
    }
  }
  function syncVisualViewport() {
    const vv = window.visualViewport;
    if (!vv || !fitVisualViewport) return;
    layoutH = Math.max(220, Math.min(cssH, Math.round(vv.height)));
    if (window.scrollY !== 0) window.scrollTo(0, 0);
  }
  window.addEventListener("resize", syncCanvasSize);
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", syncVisualViewport);
    window.visualViewport.addEventListener("scroll", syncVisualViewport);
  }
  syncCanvasSize();

  // Cached image pool for OP_IMAGE
  const imageCache = new Map();
  function getImage(key) {
    let img = imageCache.get(key);
    if (!img) {
      img = new Image();
      img.decoding = "async";
      img.src = key.startsWith("/") || key.startsWith("http") || key.startsWith("data:")
        ? key
        : `${assetsPrefix}${key}`;
      imageCache.set(key, img);
    }
    return img;
  }

  let wasmExports = null;
  let callDepth = 0;
  let lastGcLive = 0;
  let activeImeId = "";
  let lastImeKey = "none";
  let lastCaretActivityMs = 0;
  let lastDrawSnap = null;
  let frameCount = 0;
  let presentCount = 0;

  function readStr(ptr) {
    const p = ptr >>> 0;
    if (!p || !wasmExports) return "";
    const len = wasmExports.gs_wasm_str_len(p) >>> 0;
    if (!len) return "";
    return utf8Dec.decode(new Uint8Array(wasmExports.memory.buffer, p, len));
  }

  function writeStr(str) {
    const raw = utf8Enc.encode(String(str ?? ""));
    const ptr = wasmExports.gs_wasm_alloc(raw.length + 1) >>> 0;
    const view = new Uint8Array(wasmExports.memory.buffer, ptr, raw.length + 1);
    view.set(raw);
    view[raw.length] = 0;
    return ptr;
  }

  function invokeWasm(fn) {
    callDepth++;
    try {
      return fn();
    } finally {
      callDepth--;
      if (callDepth === 0 && wasmExports) {
        const live = wasmExports.gs_wasm_heap_live() >>> 0;
        if (live > lastGcLive + 524288) {
          wasmExports.gs_wasm_gc_collect();
          lastGcLive = wasmExports.gs_wasm_heap_live() >>> 0;
        }
      }
    }
  }

  function syncImeBox(info) {
    if (!imeInput) return;
    if (!info) {
      if (lastImeKey !== "none") {
        lastImeKey = "none";
        imeInput.style.left = "-9999px";
        imeInput.style.top = "0px";
        imeInput.style.width = "1px";
        imeInput.style.height = "1px";
        imeInput.style.pointerEvents = "none";
      }
      return;
    }
    const padPx = Math.max(0, Math.round(info.padX || 0));
    const key = `${info.id}:${Math.round(info.x)},${Math.round(info.y)},${Math.round(info.w)},${Math.round(info.h)},${padPx}`;
    if (key !== lastImeKey) {
      lastImeKey = key;
      imeInput.style.left = `${info.x}px`;
      imeInput.style.top = `${info.y}px`;
      imeInput.style.width = `${info.w}px`;
      imeInput.style.height = `${info.h}px`;
      imeInput.style.paddingLeft = `${padPx}px`;
      imeInput.style.paddingRight = `${padPx}px`;
      imeInput.style.pointerEvents = "auto";
    }
    if (document.activeElement !== imeInput && imeInput.value !== info.val) {
      imeInput.value = info.val;
    }
  }

  function renderDrawListArrays(i32, f64, wordCount, getStr) {
    let frameIme = null;
    ctx.save();
    ctx.scale(dpr, dpr);

    let w = 0;
    while (w < wordCount) {
      const op = i32[w * 2];
      const aux = i32[w * 2 + 1];
      switch (op) {
        case 1: { // OP_CLEAR_BG (3 words)
          const topCol = unpackCssColor(i32[(w + 1) * 2]);
          const midCol = unpackCssColor(i32[(w + 1) * 2 + 1]);
          const botCol = unpackCssColor(i32[(w + 2) * 2]);
          const grad = ctx.createLinearGradient(0, 0, 0, cssH);
          grad.addColorStop(0, topCol || "#f8fafc");
          grad.addColorStop(0.55, midCol || topCol || "#f1f5f9");
          grad.addColorStop(1, botCol || midCol || "#e2e8f0");
          ctx.fillStyle = grad;
          ctx.fillRect(0, 0, cssW, cssH);
          if (onClearBg) {
            ctx.save();
            onClearBg(ctx, cssW, cssH);
            ctx.restore();
          }
          w += 3;
          break;
        }
        case 2: { // OP_RECT (11 words)
          const x = f64[w + 1], y = f64[w + 2], rw = f64[w + 3], rh = f64[w + 4], rad = f64[w + 5];
          const fillTop = i32[(w + 6) * 2], fillBot = i32[(w + 6) * 2 + 1];
          const bdCol = i32[(w + 7) * 2], shCol = i32[(w + 7) * 2 + 1];
          const lw = f64[w + 8], shY = f64[w + 9], shBlur = f64[w + 10];
          if (rw > 0 && rh > 0) {
            ctx.save();
            if (shCol !== 0 && shBlur > 0) {
              ctx.shadowColor = unpackCssColor(shCol);
              ctx.shadowBlur = shBlur;
              ctx.shadowOffsetX = 0;
              ctx.shadowOffsetY = shY;
            }
            ctx.beginPath();
            ctx.roundRect(x, y, rw, rh, rad);
            if (fillTop !== 0 || fillBot !== 0) {
              if (fillTop === fillBot || fillBot === 0) {
                ctx.fillStyle = unpackCssColor(fillTop || fillBot);
              } else {
                const g = ctx.createLinearGradient(x, y, x, y + rh);
                g.addColorStop(0, unpackCssColor(fillTop));
                g.addColorStop(1, unpackCssColor(fillBot));
                ctx.fillStyle = g;
              }
              ctx.fill();
            }
            ctx.shadowColor = "transparent";
            ctx.shadowBlur = 0;
            ctx.shadowOffsetY = 0;
            if (bdCol !== 0 && lw > 0) {
              ctx.strokeStyle = unpackCssColor(bdCol);
              ctx.lineWidth = lw;
              ctx.stroke();
            }
            ctx.restore();
          }
          w += 11;
          break;
        }
        case 3: { // OP_PROGRESS_BAR (10 words)
          const x = f64[w + 1], y = f64[w + 2], rw = f64[w + 3], rh = f64[w + 4], rad = f64[w + 5];
          const ratio = f64[w + 6], trail = f64[w + 7];
          const cStart = i32[(w + 8) * 2], cEnd = i32[(w + 8) * 2 + 1];
          const cTrail = i32[(w + 9) * 2], cTrack = i32[(w + 9) * 2 + 1];
          if (rw > 0 && rh > 0) {
            ctx.save();
            if (cTrack !== 0) {
              ctx.beginPath();
              ctx.roundRect(x, y, rw, rh, rad);
              ctx.fillStyle = unpackCssColor(cTrack);
              ctx.fill();
            }
            if (trail > ratio + 0.004 && cTrail !== 0) {
              ctx.beginPath();
              ctx.roundRect(x, y, rw * trail, rh, rad);
              ctx.fillStyle = unpackCssColor(cTrail);
              ctx.fill();
            }
            if (ratio > 0.003 && cStart !== 0) {
              const fw = Math.max(rh, rw * ratio);
              const g = ctx.createLinearGradient(x, y, x + fw, y);
              g.addColorStop(0, unpackCssColor(cStart));
              g.addColorStop(1, unpackCssColor(cEnd || cStart));
              ctx.beginPath();
              ctx.roundRect(x, y, fw, rh, rad);
              ctx.fillStyle = g;
              ctx.fill();
            }
            ctx.restore();
          }
          w += 10;
          break;
        }
        case 4: { // OP_ELLIPSE (7 words)
          const cx = f64[w + 1], cy = f64[w + 2], rx = f64[w + 3], ry = f64[w + 4];
          const fillCol = i32[(w + 5) * 2], strokeCol = i32[(w + 5) * 2 + 1];
          const lw = f64[w + 6];
          ctx.save();
          ctx.beginPath();
          ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
          if (fillCol !== 0) { ctx.fillStyle = unpackCssColor(fillCol); ctx.fill(); }
          if (strokeCol !== 0 && lw > 0) { ctx.strokeStyle = unpackCssColor(strokeCol); ctx.lineWidth = lw; ctx.stroke(); }
          ctx.restore();
          w += 7;
          break;
        }
        case 5: { // OP_LINE (7 words)
          const x1 = f64[w + 1], y1 = f64[w + 2], x2 = f64[w + 3], y2 = f64[w + 4], lw = f64[w + 5];
          const col = i32[(w + 6) * 2];
          if (col !== 0 && lw > 0) {
            ctx.save();
            ctx.strokeStyle = unpackCssColor(col);
            ctx.lineWidth = lw;
            ctx.lineCap = "round";
            if ((aux & 1) !== 0) ctx.setLineDash([5, 5]);
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
            ctx.stroke();
            ctx.restore();
          }
          w += 7;
          break;
        }
        case 6: { // OP_POLYGON (3 + 2*N words)
          const nPts = aux;
          const fillCol = i32[(w + 1) * 2], strokeCol = i32[(w + 1) * 2 + 1];
          const lw = f64[w + 2];
          if (nPts >= 2) {
            ctx.save();
            ctx.lineJoin = "round";
            ctx.lineCap = "round";
            ctx.beginPath();
            ctx.moveTo(f64[w + 3], f64[w + 4]);
            for (let i = 1; i < nPts; i++) {
              ctx.lineTo(f64[w + 3 + i * 2], f64[w + 4 + i * 2]);
            }
            ctx.closePath();
            if (fillCol !== 0) { ctx.fillStyle = unpackCssColor(fillCol); ctx.fill(); }
            if (strokeCol !== 0 && lw > 0) { ctx.strokeStyle = unpackCssColor(strokeCol); ctx.lineWidth = lw; ctx.stroke(); }
            ctx.restore();
          }
          w += 3 + nPts * 2;
          break;
        }
        case 7: { // OP_RIBBON (3 + 3*N words) — smooth tapered gradient ribbon polygon
          const nPts = aux;
          const rawCol = i32[(w + 1) * 2] >>> 0;
          const baseAlpha = f64[w + 2];
          if (nPts >= 2 && rawCol !== 0) {
            const r = (rawCol >>> 24) & 255, g = (rawCol >>> 16) & 255, b = (rawCol >>> 8) & 255;
            const a0 = ((rawCol & 255) / 255) * baseAlpha;
            const lx = new Float64Array(nPts), ly = new Float64Array(nPts);
            const rx = new Float64Array(nPts), ry = new Float64Array(nPts);
            for (let i = 0; i < nPts; i++) {
              const prev = w + 3 + Math.max(0, i - 1) * 3;
              const curr = w + 3 + i * 3;
              const next = w + 3 + Math.min(nPts - 1, i + 1) * 3;
              let tx = f64[next] - f64[prev], ty = f64[next + 1] - f64[prev + 1];
              const len = Math.hypot(tx, ty) || 1;
              tx /= len; ty /= len;
              const nx = -ty, ny = tx;
              const taper = 0.18 + 0.82 * (i / (nPts - 1));
              const hw = Math.max(0.4, f64[curr + 2] * 0.5 * taper);
              lx[i] = f64[curr] + nx * hw; ly[i] = f64[curr + 1] + ny * hw;
              rx[i] = f64[curr] - nx * hw; ry[i] = f64[curr + 1] - ny * hw;
            }
            const pStart = w + 3, pEnd = w + 3 + (nPts - 1) * 3;
            ctx.save();
            const grad = ctx.createLinearGradient(f64[pStart], f64[pStart + 1], f64[pEnd], f64[pEnd + 1]);
            grad.addColorStop(0, `rgba(${r},${g},${b},${(a0 * 0.06).toFixed(3)})`);
            grad.addColorStop(0.55, `rgba(${r},${g},${b},${(a0 * 0.55).toFixed(3)})`);
            grad.addColorStop(1, `rgba(${r},${g},${b},${a0.toFixed(3)})`);
            ctx.fillStyle = grad;
            ctx.beginPath();
            ctx.moveTo(lx[0], ly[0]);
            for (let i = 1; i < nPts; i++) ctx.lineTo(lx[i], ly[i]);
            for (let i = nPts - 1; i >= 0; i--) ctx.lineTo(rx[i], ry[i]);
            ctx.closePath();
            ctx.fill();
            ctx.restore();
          }
          w += 3 + nPts * 3;
          break;
        }
        case 8: { // OP_TEXT (5 words)
          const txt = getStr(aux);
          const x = f64[w + 1], y = f64[w + 2], sz = f64[w + 3];
          const styleBits = i32[(w + 4) * 2], col = i32[(w + 4) * 2 + 1];
          const famCode = (styleBits >>> 16) & 255;
          const alignCode = (styleBits >>> 8) & 255;
          const weight = Math.max(100, Math.min(900, (styleBits & 255) * 100));
          const fam = famCode === 1 ? fonts.serif : famCode === 2 ? fonts.mono : fonts.sans;
          ctx.save();
          ctx.fillStyle = unpackCssColor(col);
          ctx.font = `${weight} ${sz}px ${fam}`;
          ctx.textAlign = alignCode === 1 ? "center" : alignCode === 2 ? "right" : "left";
          ctx.fillText(txt, x, y);
          ctx.restore();
          w += 5;
          break;
        }
        case 9: { // OP_IMAGE (7 words)
          const key = getStr(aux);
          const x = f64[w + 1], y = f64[w + 2], rw = f64[w + 3], rh = f64[w + 4], rad = f64[w + 5], al = f64[w + 6];
          const img = getImage(key);
          ctx.save();
          ctx.globalAlpha = al;
          ctx.beginPath();
          ctx.roundRect(x, y, rw, rh, rad);
          ctx.clip();
          if (img.complete && img.naturalWidth > 0) {
            ctx.drawImage(img, x, y, rw, rh);
          } else {
            ctx.fillStyle = "rgba(128,128,128,0.14)";
            ctx.fillRect(x, y, rw, rh);
          }
          ctx.restore();
          w += 7;
          break;
        }
        case 10: { // OP_PUSH_CLIP (5 words)
          ctx.save();
          ctx.beginPath();
          ctx.rect(f64[w + 1], f64[w + 2], f64[w + 3], f64[w + 4]);
          ctx.clip();
          w += 5;
          break;
        }
        case 11: { // OP_POP_CLIP (1 word)
          ctx.restore();
          w += 1;
          break;
        }
        case 12: { // OP_PUSH_TRANSFORM (6 words)
          ctx.save();
          ctx.translate(f64[w + 1], f64[w + 2]);
          if (f64[w + 5] !== 0) ctx.rotate((f64[w + 5] * Math.PI) / 180);
          ctx.scale(f64[w + 3], f64[w + 4]);
          w += 6;
          break;
        }
        case 13: { // OP_POP_TRANSFORM (1 word)
          ctx.restore();
          w += 1;
          break;
        }
        case 14: { // OP_IME_INPUT (10 words): host-measured text + sub-pixel selectionStart caret
          const id = getStr(aux);
          const val = getStr(i32[(w + 1) * 2]);
          const ph = getStr(i32[(w + 1) * 2 + 1]);
          const bx = f64[w + 2], by = f64[w + 3], bw = f64[w + 4], bh = f64[w + 5];
          const padX = f64[w + 6], sz = f64[w + 7];
          const styleBits = i32[(w + 8) * 2], textCol = i32[(w + 8) * 2 + 1];
          const phCol = i32[(w + 9) * 2], caretCol = i32[(w + 9) * 2 + 1];
          const famCode = (styleBits >>> 16) & 255;
          const weight = Math.max(100, Math.min(900, (styleBits & 255) * 100));
          const fam = famCode === 1 ? fonts.serif : famCode === 2 ? fonts.mono : fonts.sans;

          const liveVal = (imeInput && document.activeElement === imeInput && activeImeId === id && imeInput.value !== undefined)
            ? imeInput.value
            : val;
          let caretIdx = liveVal.length;
          if (imeInput && document.activeElement === imeInput && activeImeId === id && typeof imeInput.selectionStart === "number") {
            caretIdx = Math.max(0, Math.min(liveVal.length, imeInput.selectionStart));
          }

          const ix = bx + padX;
          const iw = Math.max(4, bw - padX * 2);
          const ty = by + bh * 0.5 + sz * 0.36;

          ctx.save();
          ctx.beginPath();
          ctx.rect(ix - 1, by + 2, iw + 2, Math.max(0, bh - 4));
          ctx.clip();
          ctx.font = `${weight} ${sz}px ${fam}`;
          ctx.textAlign = "left";

          const prefixW = caretIdx > 0 ? ctx.measureText(liveVal.slice(0, caretIdx)).width : 0;
          const scrollX = prefixW > iw - 4 ? prefixW - (iw - 4) : 0;

          if (liveVal.length === 0) {
            if (ph) {
              ctx.fillStyle = unpackCssColor(phCol);
              ctx.fillText(ph, ix, ty);
            }
          } else {
            ctx.fillStyle = unpackCssColor(textCol);
            ctx.fillText(liveVal, ix - scrollX, ty);
          }

          const now = performance.now();
          const blinkOn = (now - lastCaretActivityMs < 480) || (Math.floor(now / 530) % 2 === 0);
          if (blinkOn && caretCol !== 0) {
            const padAfter = caretIdx >= liveVal.length && liveVal.length > 0 ? 1.0 : 0.0;
            const cx = ix + prefixW - scrollX + padAfter;
            const ch = sz * 1.18;
            const cy = by + (bh - ch) * 0.5;
            ctx.fillStyle = unpackCssColor(caretCol);
            ctx.beginPath();
            ctx.roundRect(cx, cy, 1.6, ch, 0.8);
            ctx.fill();
          }
          ctx.restore();

          frameIme = { id, val: liveVal, x: bx, y: by, w: bw, h: bh, padX };
          w += 10;
          break;
        }
        case 15: { // OP_IME_CLEAR (1 word)
          frameIme = null;
          w += 1;
          break;
        }
        case 16: { // OP_PUSH_CIRCLE_CLIP (4 words)
          const cx = f64[w + 1], cy = f64[w + 2], r = Math.max(0, f64[w + 3]);
          ctx.save();
          ctx.beginPath();
          ctx.arc(cx, cy, r, 0, Math.PI * 2);
          ctx.clip();
          w += 4;
          break;
        }
        default:
          w = wordCount;
          break;
      }
    }

    ctx.restore();
    syncImeBox(frameIme);
  }

  function executeBinaryDrawList(wordsPtr, wordCount, strsPtr, strCount) {
    presentCount++;
    const buf = wasmExports.memory.buffer;
    const wBase = (wordsPtr >>> 0) + 8;
    const sBase = (strsPtr >>> 0) + 8;
    const i32View = new Int32Array(buf, wBase, wordCount * 2);
    const f64View = new Float64Array(buf, wBase, wordCount);
    const strPtrs = strCount > 0 ? new Uint32Array(buf, sBase, strCount) : null;
    const strs = new Array(strCount);
    for (let i = 0; i < strCount; i++) strs[i] = readStr(strPtrs[i]);

    const wordBytes = new ArrayBuffer(wordCount * 8);
    new Float64Array(wordBytes).set(f64View);
    lastDrawSnap = {
      i32: new Int32Array(wordBytes),
      f64: new Float64Array(wordBytes),
      wordCount,
      strs,
    };
    renderDrawListArrays(i32View, f64View, wordCount, (idx) => (idx >= 0 && idx < strCount ? strs[idx] : ""));
  }

  function repaintCachedFrame() {
    if (!lastDrawSnap) return;
    renderDrawListArrays(
      lastDrawSnap.i32,
      lastDrawSnap.f64,
      lastDrawSnap.wordCount,
      (idx) => (idx >= 0 && idx < lastDrawSnap.strs.length ? lastDrawSnap.strs[idx] : "")
    );
  }

  const wasmBytes = await (await fetch(wasmUrl)).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    env: {
      sin: Math.sin,
      cos: Math.cos,
      acos: Math.acos,
      atan2: Math.atan2,
      sqrt: Math.sqrt,
      exp: Math.exp,
      gs_log: (ptr, len) => {
        if (!wasmExports || !len) return;
        const msg = utf8Dec.decode(new Uint8Array(wasmExports.memory.buffer, ptr >>> 0, len >>> 0));
        if (msg.trim()) console.log("[crema]", msg.trimEnd());
      },
      crema_host_present: executeBinaryDrawList,
      crema_host_set_cursor: (curPtr) => { canvas.style.cursor = readStr(curPtr) || "default"; },
      crema_host_focus_ime: (idPtr, valPtr, x, y, w, h) => {
        const id = readStr(idPtr);
        const val = readStr(valPtr);
        activeImeId = id;
        lastCaretActivityMs = performance.now();
        syncImeBox({ id, val, x, y, w, h, padX: 10 });
        if (imeInput) {
          imeInput.value = val;
          imeInput.focus({ preventScroll: true });
          try { imeInput.setSelectionRange(val.length, val.length); } catch (_) {}
        }
      },
      crema_host_blur_ime: () => {
        activeImeId = "";
        if (imeInput && document.activeElement === imeInput) imeInput.blur();
      },
      ...(options.extraImports ? options.extraImports({ readStr, writeStr, invokeWasm, getExports: () => wasmExports }) : {}),
    },
  });

  wasmExports = instance.exports;
  invokeWasm(() => wasmExports.__geisha_init());
  lastGcLive = wasmExports.gs_wasm_heap_live() >>> 0;
  if (options.beforeInit) {
    await options.beforeInit({ exports: wasmExports, readStr, writeStr, invokeWasm, cssW, cssH: layoutH });
  }
  invokeWasm(() => wasmExports.crema_init(cssW, layoutH));

  // Event listeners (unified pointer tap + touch/mouse drag + wheel + IME + keyboard)
  const rectOffset = (e) => {
    const r = canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };

  let dragging = false, dragMoved = false, startX = 0, startY = 0, lastX = 0, lastY = 0;

  canvas.addEventListener("pointerdown", (e) => {
    if (e.button > 0) return;
    const { x, y } = rectOffset(e);
    dragging = true;
    dragMoved = false;
    startX = x;
    startY = y;
    lastX = x;
    lastY = y;
  });

  canvas.addEventListener("pointermove", (e) => {
    const { x, y } = rectOffset(e);
    if (dragging) {
      if (!dragMoved && Math.hypot(x - startX, y - startY) > 8) {
        dragMoved = true;
      }
      if (dragMoved) {
        const dx = x - lastX;
        const dy = y - lastY;
        lastX = x;
        lastY = y;
        if (wasmExports.crema_pointer_drag) {
          invokeWasm(() => wasmExports.crema_pointer_drag(startX, startY, x, y, dx, dy));
        }
        return;
      }
    }
    if (wasmExports.crema_pointer_move) invokeWasm(() => wasmExports.crema_pointer_move(x, y));
  });

  canvas.addEventListener("pointerup", (e) => {
    const wasTap = dragging && !dragMoved;
    dragging = false;
    dragMoved = false;
    if (wasTap && e.button <= 0) {
      const { x, y } = rectOffset(e);
      if (wasmExports.crema_pointer_click) invokeWasm(() => wasmExports.crema_pointer_click(x, y));
      if (activeImeId && imeInput) {
        imeInput.focus({ preventScroll: true });
      }
    }
  });
  window.addEventListener("pointerup", () => { dragging = false; dragMoved = false; });
  window.addEventListener("pointercancel", () => { dragging = false; dragMoved = false; });

  canvas.addEventListener("wheel", (e) => {
    if (!captureWheel) return;
    e.preventDefault();
    const { x, y } = rectOffset(e);
    if (wasmExports.crema_scroll_wheel) invokeWasm(() => wasmExports.crema_scroll_wheel(x, y, e.deltaY));
  }, { passive: false });

  window.addEventListener("keydown", (e) => {
    if (imeInput && document.activeElement === imeInput) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (wasmExports.crema_key_down) invokeWasm(() => wasmExports.crema_key_down(writeStr(e.key)));
  });

  if (imeInput) {
    const syncText = () => {
      lastCaretActivityMs = performance.now();
      if (activeImeId && wasmExports.crema_text_input) {
        invokeWasm(() => wasmExports.crema_text_input(writeStr(activeImeId), writeStr(imeInput.value)));
      }
      repaintCachedFrame();
    };
    const syncSelectionOnly = () => {
      if (activeImeId && document.activeElement === imeInput) {
        lastCaretActivityMs = performance.now();
        repaintCachedFrame();
      }
    };
    imeInput.addEventListener("input", syncText);
    imeInput.addEventListener("compositionupdate", syncText);
    imeInput.addEventListener("compositionend", syncText);
    imeInput.addEventListener("keyup", syncSelectionOnly);
    imeInput.addEventListener("mouseup", syncSelectionOnly);
    imeInput.addEventListener("touchend", syncSelectionOnly);
    document.addEventListener("selectionchange", syncSelectionOnly);
    imeInput.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" && !ev.isComposing && activeImeId && wasmExports.crema_text_submit) {
        ev.preventDefault();
        invokeWasm(() => wasmExports.crema_text_submit(writeStr(activeImeId)));
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        imeInput.blur();
      }
    });
    imeInput.addEventListener("blur", () => {
      activeImeId = "";
      if (wasmExports.crema_blur_input) invokeWasm(() => wasmExports.crema_blur_input());
    });
  }

  let lastTs = performance.now();
  const loop = (ts) => {
    const dt = Math.min(200, Math.max(1, ts - lastTs));
    lastTs = ts;
    if (!document.hidden && wasmExports.crema_step_frame) {
      frameCount++;
      invokeWasm(() => wasmExports.crema_step_frame(dt, cssW, layoutH));
      if (options.onAfterFrame) options.onAfterFrame();
    }
    requestAnimationFrame(loop);
  };
  // Render initial frame synchronously before starting rAF
  if (wasmExports.crema_step_frame) {
    frameCount++;
    invokeWasm(() => wasmExports.crema_step_frame(16.6, cssW, layoutH));
    if (options.onAfterFrame) options.onAfterFrame();
  }
  requestAnimationFrame(loop);

  const api = {
    exports: wasmExports,
    readStr,
    writeStr,
    invokeWasm,
    syncSize: syncCanvasSize,
    stats: () => ({
      frameCount,
      presentCount,
      heapLiveBytes: wasmExports.gs_wasm_heap_live() >>> 0,
      heapUsedBytes: wasmExports.gs_wasm_heap_used() >>> 0,
    }),
    click: (x, y) => invokeWasm(() => wasmExports.crema_pointer_click(x, y)),
    move: (x, y) => invokeWasm(() => wasmExports.crema_pointer_move(x, y)),
    drag: (sx, sy, cx, cy, dx, dy) =>
      wasmExports.crema_pointer_drag && invokeWasm(() => wasmExports.crema_pointer_drag(sx, sy, cx, cy, dx, dy)),
    wheel: (x, y, dy) => invokeWasm(() => wasmExports.crema_scroll_wheel(x, y, dy)),
    key: (k) => invokeWasm(() => wasmExports.crema_key_down(writeStr(k))),
    step: (dt = 16.6) => invokeWasm(() => wasmExports.crema_step_frame(dt, cssW, layoutH)),
  };
  window.__crema = api;
  if (options.onReady) options.onReady(api);
  return api;
}
