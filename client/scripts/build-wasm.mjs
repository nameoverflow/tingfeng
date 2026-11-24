#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const CLIENT_DIR = path.resolve(import.meta.dirname, "..");
const REPO_ROOT = path.resolve(CLIENT_DIR, "..");
const HS_DIR = path.join(CLIENT_DIR, "hs");
const PUBLIC_DIR = path.join(CLIENT_DIR, "public");
const DIST_DIR = path.join(CLIENT_DIR, "dist");

const checkOnly = process.argv.includes("--check");

// Locate wasm32-wasi-ghc (checks session ghc-wasm, ~/.ghc-wasm, or PATH)
const candidates = [
  path.resolve(REPO_ROOT, "../ghc-wasm"),
  path.join(process.env.HOME || "", ".ghc-wasm"),
];
let wasmPrefix = candidates.find((p) => fs.existsSync(path.join(p, "wasm32-wasi-ghc/bin/wasm32-wasi-ghc")));

const env = { ...process.env };
let wasmGhc = "wasm32-wasi-ghc";
let wasmOpt = "wasm-opt";

if (wasmPrefix) {
  wasmGhc = path.join(wasmPrefix, "wasm32-wasi-ghc/bin/wasm32-wasi-ghc");
  wasmOpt = path.join(wasmPrefix, "binaryen/bin/wasm-opt");
  env.PATH = `${path.join(wasmPrefix, "binaryen/bin")}:${path.join(wasmPrefix, "wasi-sdk/bin")}:${path.join(wasmPrefix, "wasm32-wasi-ghc/bin")}:${env.PATH}`;
  env.AR = path.join(wasmPrefix, "wasi-sdk/bin/llvm-ar");
  env.CC = path.join(wasmPrefix, "wasi-sdk/bin/wasm32-wasi-clang");
  env.CXX = path.join(wasmPrefix, "wasi-sdk/bin/wasm32-wasi-clang++");
  env.LD = path.join(wasmPrefix, "wasi-sdk/bin/wasm-ld");
  env.NM = path.join(wasmPrefix, "wasi-sdk/bin/llvm-nm");
  env.RANLIB = path.join(wasmPrefix, "wasi-sdk/bin/llvm-ranlib");
}

if (checkOnly) {
  const buildCheck = path.join(HS_DIR, "build-check");
  fs.mkdirSync(buildCheck, { recursive: true });
  execFileSync(wasmGhc, [
    "-Wall", "-Werror", "-Wno-x-partial", "-Wno-type-defaults", "-fno-code",
    "-isrc", "-outputdir", buildCheck,
    path.join(HS_DIR, "src/Main.hs")
  ], { cwd: HS_DIR, env, stdio: "inherit" });
  console.log("✓ Haskell Wasm client typecheck passed (0 warnings/errors).");
  process.exit(0);
}

const buildWasm = path.join(HS_DIR, "build-wasm");
const outWasmDir = path.join(PUBLIC_DIR, "wasm");
fs.mkdirSync(buildWasm, { recursive: true });
fs.mkdirSync(outWasmDir, { recursive: true });

const rawWasm = path.join(outWasmDir, "tingfeng-hs.raw.wasm");
const finalWasm = path.join(outWasmDir, "tingfeng-hs.wasm");
const jsffiOut = path.join(outWasmDir, "ghc_wasm_jsffi.js");

const exportsList = [
  "hs_init_app", "hs_step_frame", "hs_on_ws_open", "hs_on_ws_message",
  "hs_on_ws_close", "hs_set_hidden", "hs_pointer_move", "hs_pointer_click",
  "hs_pan_zoom", "hs_ui_action", "hs_lab_cmd"
].map((e) => `--export=${e}`).join(",");

console.log("[1/3] Compiling Haskell client to wasm32-wasi...");
execFileSync(wasmGhc, [
  "-O2", "-Wall", "-Wno-x-partial", "-Wno-type-defaults",
  "-no-hs-main", "-optl-mexec-model=reactor",
  `-optl-Wl,${exportsList}`,
  "-isrc", "-outputdir", buildWasm,
  "src/Main.hs", "-o", rawWasm
], { cwd: HS_DIR, env, stdio: "inherit" });

const libDir = execFileSync(wasmGhc, ["--print-libdir"], { env }).toString().trim();
console.log("[2/3] Generating GHC Wasm JSFFI bindings...");
execFileSync(process.execPath, [
  path.join(libDir, "post-link.mjs"),
  "-i", rawWasm, "-o", jsffiOut
], { env, stdio: "inherit" });

console.log("[3/3] Optimizing Wasm binary with binaryen wasm-opt -O2...");
execFileSync(wasmOpt, [
  "-O2", "--enable-reference-types", "--enable-bulk-memory", "--enable-simd",
  "--enable-nontrapping-float-to-int", "--enable-sign-ext", "--enable-mutable-globals",
  rawWasm, "-o", finalWasm
], { env, stdio: "inherit" });
fs.rmSync(rawWasm, { force: true });

// Assemble self-contained dist/ bundle
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

const sz = fs.statSync(path.join(DIST_DIR, "wasm/tingfeng-hs.wasm")).size;
console.log(`✓ Built dist/wasm/tingfeng-hs.wasm (${(sz / 1048576).toFixed(2)} MB raw).`);
