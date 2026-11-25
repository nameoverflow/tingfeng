#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { CLIENT_DIR, REPO_ROOT, GSA_DIR, resolveGeishaToolchain } from "./geisha-toolchain.mjs";

const PUBLIC_DIR = path.join(CLIENT_DIR, "public");
const DIST_DIR = path.join(CLIENT_DIR, "dist");
const checkOnly = process.argv.includes("--check");

const WASM_EXPORTS = [
  "tf_init_app",
  "tf_step_frame",
  "tf_on_ws_open",
  "tf_on_ws_message",
  "tf_on_ws_close",
  "tf_set_hidden",
  "tf_pointer_move",
  "tf_pointer_click",
  "tf_pan_zoom",
  "tf_drag_at",
  "tf_scroll_at",
  "tf_text_input",
  "tf_text_submit",
  "tf_focus_input_id",
  "tf_blur_input",
  "tf_key_down",
  "tf_ui_action",
  "tf_lab_cmd",
];

const { geisha, wasmRuntime } = resolveGeishaToolchain();
const entryFile = path.join(GSA_DIR, "src/mod.gsa");
const exportFlags = WASM_EXPORTS.flatMap((fn) => ["--export", fn]);

if (checkOnly) {
  const buildDir = path.join(GSA_DIR, "build");
  fs.mkdirSync(buildDir, { recursive: true });
  const checkLl = path.join(buildDir, "check.ll");
  execFileSync(
    geisha,
    ["--target", "wasm32", "--src-root", GSA_DIR, ...exportFlags, "-e", "-o", checkLl, entryFile],
    { cwd: CLIENT_DIR, stdio: "inherit" }
  );
  fs.rmSync(checkLl, { force: true });
  console.log("✓ Pure-Geisha Wasm client typecheck & IR verification passed (0 errors).");
  process.exit(0);
}

if (!wasmRuntime) {
  throw new Error("wasm_rt.o not found. Run 'make wasm-runtime' in geisha.gsa or set GEISHA_WASM_RUNTIME.");
}

const outWasmDir = path.join(PUBLIC_DIR, "wasm");
fs.mkdirSync(outWasmDir, { recursive: true });
const finalWasm = path.join(outWasmDir, "tingfeng.wasm");

console.log("[1/2] Compiling pure-Geisha client to wasm32...");
execFileSync(
  geisha,
  ["--target", "wasm32", "--src-root", GSA_DIR, "--runtime", wasmRuntime, ...exportFlags, "-o", finalWasm, entryFile],
  { cwd: CLIENT_DIR, stdio: "inherit" }
);

console.log("[2/2] Assembling dist/ bundle...");
fs.rmSync(DIST_DIR, { recursive: true, force: true });
fs.cpSync(PUBLIC_DIR, DIST_DIR, { recursive: true });
fs.mkdirSync(path.join(DIST_DIR, "data"), { recursive: true });
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_presentation/svg-poses.json"), path.join(DIST_DIR, "data/svg-poses.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_presentation/staging.json"), path.join(DIST_DIR, "data/staging.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_actions/fist.json"), path.join(DIST_DIR, "data/fist.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_actions/sword.json"), path.join(DIST_DIR, "data/sword.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_actions/effects.json"), path.join(DIST_DIR, "data/effects.json"));

const portraitSrc = fs.existsSync(path.join(PUBLIC_DIR, "portraits"))
  ? path.join(PUBLIC_DIR, "portraits")
  : path.join(CLIENT_DIR, "src/assets/portraits");
if (fs.existsSync(portraitSrc)) {
  fs.cpSync(portraitSrc, path.join(DIST_DIR, "portraits"), { recursive: true });
}

const sz = fs.statSync(path.join(DIST_DIR, "wasm/tingfeng.wasm")).size;
console.log(`✓ Built dist/wasm/tingfeng.wasm (${(sz / 1024).toFixed(1)} KB raw).`);
