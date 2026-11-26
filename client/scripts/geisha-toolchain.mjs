import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export const CLIENT_DIR = path.resolve(import.meta.dirname, "..");
export const REPO_ROOT = path.resolve(CLIENT_DIR, "..");
export const GSA_DIR = path.join(CLIENT_DIR, "gsa");

function firstExisting(paths) {
  for (const p of paths) {
    if (p && fs.existsSync(p)) return p;
  }
  return null;
}

function whichCmd(cmd) {
  try {
    const out = execFileSync("sh", ["-c", `command -v ${cmd}`], { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
    return out && fs.existsSync(out) ? out : null;
  } catch (_) {
    return null;
  }
}

export function resolveGeishaToolchain() {
  const home = process.env.HOME || "";
  const buildDirs = [
    path.resolve(REPO_ROOT, "../geisha.gsa/build"),
    path.join(home, "code/geisha.gsa/build"),
  ];

  const geisha =
    firstExisting([process.env.GEISHA]) ||
    whichCmd("geisha") ||
    whichCmd("geisha3") ||
    whichCmd("geisha2") ||
    firstExisting(buildDirs.flatMap((d) => [
      path.join(d, "geisha"),
      path.join(d, "geisha3"),
      path.join(d, "geisha2"),
    ]));

  if (!geisha) {
    throw new Error("Geisha compiler not found. Set GEISHA=/path/to/geisha3 or build ../geisha.gsa.");
  }

  const geishaDir = path.dirname(geisha);
  const nativeRuntime = firstExisting([
    process.env.GEISHA_RUNTIME,
    path.join(geishaDir, "libgeisha_runtime.a"),
    ...buildDirs.map((d) => path.join(d, "libgeisha_runtime.a")),
  ]);

  const wasmRuntime = firstExisting([
    process.env.GEISHA_WASM_RUNTIME,
    path.join(geishaDir, "wasm_rt.o"),
    ...buildDirs.map((d) => path.join(d, "wasm_rt.o")),
  ]);

  const kaguraLib = firstExisting([
    process.env.KAGURA_LIB,
    path.resolve(REPO_ROOT, "../kagura/lib"),
    path.join(home, "code/kagura/lib"),
  ]);
  if (!kaguraLib) {
    throw new Error("Kagura library not found. Set KAGURA_LIB=/path/to/kagura/lib or clone ../kagura.");
  }

  const kaguraWebHost = firstExisting([
    path.resolve(kaguraLib, "../host/web/kagura.js"),
    path.join(CLIENT_DIR, "public/kagura.js"),
  ]);

  return { geisha, nativeRuntime, wasmRuntime, kaguraLib, kaguraWebHost };
}

export function buildNativeClientSpec() {
  const { geisha, nativeRuntime, kaguraLib } = resolveGeishaToolchain();
  const buildDir = path.join(GSA_DIR, "build");
  fs.mkdirSync(buildDir, { recursive: true });
  const bin = path.join(buildDir, "client-spec");
  const srcDir = path.join(GSA_DIR, "src");
  const entry = path.join(srcDir, "mod.gsa");
  const stubC = path.join(GSA_DIR, "kagura_host_stub.c");

  let needsBuild = !fs.existsSync(bin);
  if (!needsBuild) {
    const binMtime = fs.statSync(bin).mtimeMs;
    for (const f of fs.readdirSync(srcDir)) {
      if (f.endsWith(".gsa")) {
        if (fs.statSync(path.join(srcDir, f)).mtimeMs > binMtime) {
          needsBuild = true;
          break;
        }
      }
    }
  }

  if (needsBuild) {
    const tmpLl = path.join(buildDir, "client-spec.ll");
    execFileSync(geisha, ["--src-root", GSA_DIR, "-L", kaguraLib, "-e", "-o", tmpLl, entry], {
      cwd: CLIENT_DIR,
      stdio: "inherit",
    });
    const ccArgs = [
      "-target", "arm64-apple-macosx14.0",
      "-O2", "-Wno-override-module",
      "-x", "ir", tmpLl,
      "-x", "none", stubC,
    ];
    if (nativeRuntime) ccArgs.push(nativeRuntime);
    ccArgs.push("-lm", "-lpthread", "-o", bin);
    execFileSync("cc", ccArgs, {
      cwd: CLIENT_DIR,
      env: { ...process.env, MACOSX_DEPLOYMENT_TARGET: "14.0" },
      stdio: "inherit",
    });
    fs.rmSync(tmpLl, { force: true });
  }
  return bin;
}
