#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { CLIENT_DIR, REPO_ROOT, GSA_DIR, resolveGeishaBin } from "./geisha-toolchain.mjs";

const PUBLIC_DIR = path.join(CLIENT_DIR, "public");
const DIST_DIR = path.join(CLIENT_DIR, "dist");
const checkOnly = process.argv.includes("--check");
const geisha = resolveGeishaBin();

if (checkOnly) {
  const buildDir = path.join(GSA_DIR, "build");
  fs.mkdirSync(buildDir, { recursive: true });
  const checkLl = path.join(buildDir, "check.ll");
  execFileSync(geisha, ["build", "--target", "wasm32", "-e", "-o", checkLl], {
    cwd: GSA_DIR,
    stdio: "inherit",
  });
  fs.rmSync(checkLl, { force: true });
  console.log("✓ Crema + Geisha Wasm client typecheck & IR verification passed (0 errors).");
  process.exit(0);
}

const outWasmDir = path.join(PUBLIC_DIR, "wasm");
fs.mkdirSync(outWasmDir, { recursive: true });
const finalWasm = path.join(outWasmDir, "tingfeng.wasm");

console.log("[1/2] Compiling Tingfeng client via geisha.toml (wasm32 + crema web_assets)...");
execFileSync(geisha, ["build", "--target", "wasm32", "-o", finalWasm], {
  cwd: GSA_DIR,
  stdio: "inherit",
});

console.log("[2/2] Assembling dist/ bundle...");
fs.rmSync(DIST_DIR, { recursive: true, force: true });
fs.cpSync(PUBLIC_DIR, DIST_DIR, { recursive: true });
fs.mkdirSync(path.join(DIST_DIR, "data"), { recursive: true });
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_presentation/svg-poses.json"), path.join(DIST_DIR, "data/svg-poses.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_presentation/staging.json"), path.join(DIST_DIR, "data/staging.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_actions/fist.json"), path.join(DIST_DIR, "data/fist.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_actions/sword.json"), path.join(DIST_DIR, "data/sword.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_actions/weapons.json"), path.join(DIST_DIR, "data/weapons.json"));
fs.copyFileSync(path.join(REPO_ROOT, "resources/scripts/combat_actions/effects.json"), path.join(DIST_DIR, "data/effects.json"));

const portraitSrc = fs.existsSync(path.join(PUBLIC_DIR, "portraits"))
  ? path.join(PUBLIC_DIR, "portraits")
  : path.join(CLIENT_DIR, "src/assets/portraits");
if (fs.existsSync(portraitSrc)) {
  fs.cpSync(portraitSrc, path.join(DIST_DIR, "portraits"), { recursive: true });
}

const sz = fs.statSync(path.join(DIST_DIR, "wasm/tingfeng.wasm")).size;
console.log(`✓ Built dist/wasm/tingfeng.wasm (${(sz / 1024).toFixed(1)} KB raw) with Crema.`);
