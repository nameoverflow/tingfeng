#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const CLIENT_DIR = path.resolve(import.meta.dirname, "..");
const HS_DIR = path.join(CLIENT_DIR, "hs");
const BUILD_DIR = path.join(HS_DIR, "build-native");
fs.mkdirSync(BUILD_DIR, { recursive: true });

const ghcCandidates = [
  path.join(process.env.HOME || "", ".ghcup/bin/ghc-9.10.3"),
  path.join(process.env.HOME || "", ".ghcup/bin/ghc"),
  "ghc",
];
const ghc = ghcCandidates.find((p) => p === "ghc" || fs.existsSync(p));

const bin = path.join(BUILD_DIR, "battle-spec");
execFileSync(ghc, [
  "-O1", "-Wall", "-Wno-x-partial", "-Wno-type-defaults",
  "-isrc", "-outputdir", BUILD_DIR,
  "test/BattleSpec.hs", "-o", bin
], { cwd: HS_DIR, stdio: "inherit" });

execFileSync(bin, [], { cwd: HS_DIR, stdio: "inherit" });
