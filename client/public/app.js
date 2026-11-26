// Tingfeng (《听风录》) Thin Kagura Bootstrapper (`client/public/app.js`).
// All layout, rendering, binary DrawList execution, WebAudio, IME, and WS/HTTP bridging
// are handled by `geisha-lang/kagura` (`/kagura.js` + `/wasm/tingfeng.wasm`).

import { mountKaguraApp } from "/kagura.js";

const pageKind = document.body.dataset.page || "game";
const canvas = document.getElementById("c2d-stage");
const imeInput = document.getElementById("ime-proxy");
const stageProbe = document.getElementById("stage-probe");
const reducedMotionQuery = matchMedia("(prefers-reduced-motion: reduce)");

let resolveWasmReady = null;
globalThis.__tfHsReady = new Promise((r) => { resolveWasmReady = r; });

let kaguraApp = null;
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

function pullLabState() {
  if (!kaguraApp) return latestLabStateObj;
  const { exports, readStr, invokeWasm } = kaguraApp;
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
  if (!kaguraApp) return;
  const { exports, writeStr, invokeWasm } = kaguraApp;
  invokeWasm(() => exports.tf_ui_action(writeStr(kind), writeStr(a1), writeStr(a2)));
}

function callLab(cmd, a1 = "", a2 = "", a3 = "", numArg = 0) {
  if (!kaguraApp) return;
  const { exports, writeStr, invokeWasm } = kaguraApp;
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
  ui: (kind, a1 = "", a2 = "") => {
    callUi(kind, a1, a2);
    pullLabState();
  },
  state: () => pullLabState(),
};
window.__battleLab = fixturesApi;
globalThis.__tfHsFixtures = fixturesApi;

async function boot() {
  const [poseTxt, stgTxt, fistTxt, swordTxt, effTxt] = await Promise.all([
    fetch("/data/svg-poses.json").then((r) => r.text()),
    fetch("/data/staging.json").then((r) => r.text()),
    fetch("/data/fist.json").then((r) => r.text()),
    fetch("/data/sword.json").then((r) => r.text()),
    fetch("/data/effects.json").then((r) => r.text()),
  ]);

  kaguraApp = await mountKaguraApp({
    canvas,
    imeInput,
    wasmUrl: "/wasm/tingfeng.wasm",
    httpBridgePrefix: "/api/bridge",
    allowPageScroll: pageKind === "poses",
    minHeight: pageKind === "poses" ? 1420 : 0,
    beforeInit: ({ exports, writeStr, invokeWasm }) => {
      invokeWasm(() =>
        exports.tf_seed_assets(
          writeStr(pageKind),
          writeStr(poseTxt),
          writeStr(stgTxt),
          writeStr(fistTxt),
          writeStr(swordTxt),
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
    if (!kaguraApp) return;
    const { exports, invokeWasm } = kaguraApp;
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

boot().catch((e) => console.error("[tingfeng-kagura] Boot failed:", e));
