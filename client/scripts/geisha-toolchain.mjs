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

export function resolveGeishaBin() {
  const home = process.env.HOME || "";
  const geisha =
    firstExisting([process.env.GEISHA]) ||
    whichCmd("geisha") ||
    firstExisting([
      path.join(home, ".geisha/bin/geisha"),
      path.join(home, ".local/bin/geisha"),
      path.resolve(REPO_ROOT, "../geisha.gsa/build/geisha3"),
      path.join(home, "code/geisha.gsa/build/geisha3"),
    ]);

  if (!geisha) {
    throw new Error("Geisha compiler not found. Install geisha into ~/.geisha/bin or set GEISHA=/path/to/geisha.");
  }
  return geisha;
}

export function buildNativeClientSpec() {
  const geisha = resolveGeishaBin();
  const bin = path.join(GSA_DIR, "build/tests/test_spec");
  const watchFiles = [
    path.join(GSA_DIR, "geisha.toml"),
    path.join(GSA_DIR, "geisha.lock"),
  ];
  for (const sub of ["src", "tests"]) {
    const dir = path.join(GSA_DIR, sub);
    if (fs.existsSync(dir)) {
      for (const f of fs.readdirSync(dir)) {
        if (f.endsWith(".gsa")) watchFiles.push(path.join(dir, f));
      }
    }
  }

  let needsBuild = !fs.existsSync(bin);
  if (!needsBuild) {
    const binMtime = fs.statSync(bin).mtimeMs;
    for (const f of watchFiles) {
      if (fs.existsSync(f) && fs.statSync(f).mtimeMs > binMtime) {
        needsBuild = true;
        break;
      }
    }
  }

  if (needsBuild) {
    execFileSync(geisha, ["test"], {
      cwd: GSA_DIR,
      env: { ...process.env, MACOSX_DEPLOYMENT_TARGET: "14.0" },
      stdio: "inherit",
    });
  }
  return bin;
}
