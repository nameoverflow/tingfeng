#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { CLIENT_DIR, REPO_ROOT, GSA_DIR, resolveGeishaToolchain } from "./geisha-toolchain.mjs";

const PUBLIC_DIR = path.join(CLIENT_DIR, "public");
const DIST_DIR = path.join(CLIENT_DIR, "dist");
const checkOnly = process.argv.includes("--check");

const WASM_EXPORTS = [
  "kagura_init",
  "kagura_step_frame",
  "kagura_pointer_move",
  "kagura_pointer_click",
  "kagura_pointer_drag",
  "kagura_scroll_wheel",
  "kagura_text_input",
  "kagura_text_submit",
  "kagura_blur_input",
  "kagura_key_down",
  "kagura_on_net_open",
  "kagura_on_net_message",
  "kagura_on_net_close",
  "tf_seed_assets",
  "tf_ui_action",
  "tf_lab_cmd",
  "tf_set_hidden",
  "tf_lab_state_json",
];

const { geisha, wasmRuntime, kaguraLib, kaguraWebHost } = resolveGeishaToolchain();
const entryFile = path.join(GSA_DIR, "src/mod.gsa");
const exportFlags = WASM_EXPORTS.flatMap((fn) => ["--export", fn]);

if (checkOnly) {
  const buildDir = path.join(GSA_DIR, "build");
  fs.mkdirSync(buildDir, { recursive: true });
  const checkLl = path.join(buildDir, "check.ll");
  execFileSync(
    geisha,
    ["--target", "wasm32", "--src-root", GSA_DIR, "-L", kaguraLib, ...exportFlags, "-e", "-o", checkLl, entryFile],
    { cwd: CLIENT_DIR, stdio: "inherit" }
  );
  fs.rmSync(checkLl, { force: true });
  console.log("✓ Kagura + Geisha Wasm client typecheck & IR verification passed (0 errors).");
  process.exit(0);
}

if (!wasmRuntime) {
  throw new Error("wasm_rt.o not found. Run 'make wasm-runtime' in geisha.gsa or set GEISHA_WASM_RUNTIME.");
}

if (kaguraWebHost && path.resolve(kaguraWebHost) !== path.join(PUBLIC_DIR, "kagura.js")) {
  fs.copyFileSync(kaguraWebHost, path.join(PUBLIC_DIR, "kagura.js"));
}

const outWasmDir = path.join(PUBLIC_DIR, "wasm");
fs.mkdirSync(outWasmDir, { recursive: true });
const finalWasm = path.join(outWasmDir, "tingfeng.wasm");

console.log("[1/2] Compiling Tingfeng client with Kagura (-L kagura) to wasm32...");
execFileSync(
  geisha,
  ["--target", "wasm32", "--src-root", GSA_DIR, "-L", kaguraLib, "--runtime", wasmRuntime, ...exportFlags, "-o", finalWasm, entryFile],
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
console.log(`✓ Built dist/wasm/tingfeng.wasm (${(sz / 1024).toFixed(1)} KB raw) with Kagura.`);
