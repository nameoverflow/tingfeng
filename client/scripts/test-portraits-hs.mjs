#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const clientDir = path.resolve(import.meta.dirname, "..");
const hsDir = path.join(clientDir, "hs");
const buildDir = path.join(hsDir, "build-native-portraits");
fs.mkdirSync(buildDir, { recursive: true });
const candidates = [
  path.join(process.env.HOME || "", ".ghcup/bin/ghc-9.10.3"),
  path.join(process.env.HOME || "", ".ghcup/bin/ghc"),
  "ghc",
];
const ghc = candidates.find((p) => p === "ghc" || fs.existsSync(p));
const bin = path.join(buildDir, "portrait-spec");
execFileSync(ghc, [
  "-O1", "-Wall", "-Wno-x-partial", "-Wno-type-defaults",
  "-isrc", "-outputdir", buildDir, "test/PortraitSpec.hs", "-o", bin,
], { cwd: hsDir, stdio: "inherit" });
execFileSync(bin, [], { cwd: hsDir, stdio: "inherit" });
