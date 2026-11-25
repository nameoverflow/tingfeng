#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { REPO_ROOT, buildNativeClientSpec } from "./geisha-toolchain.mjs";

const bin = buildNativeClientSpec();
execFileSync(bin, ["--portraits", "--root", REPO_ROOT], { cwd: REPO_ROOT, stdio: "inherit" });
