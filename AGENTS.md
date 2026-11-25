# AGENTS.md

## Project and task routing

听风录（Tingfeng）— a Wuxia MUD with a pure-Geisha WebSocket server (`server/src/`), YAML game content (`resources/scripts/`), and a
Haskell GHC Wasm Canvas2D web client (`client/hs/`). Player persistence uses JSON saves (`saves/`).

Read the documentation relevant to the change; a full documentation pass is
not required. [docs/README.md](docs/README.md) indexes the rest.

| Task | Reference |
| --- | --- |
| Start server/client, development fixtures | [docs/running.md](docs/running.md) |
| State boundaries and threading | [docs/architecture.md](docs/architecture.md), [docs/tick-loop-and-heartbeat.md](docs/tick-loop-and-heartbeat.md) |
| YAML content and quests | [docs/content-scripting.md](docs/content-scripting.md) |
| Combat and progression | [docs/gameplay-systems.md](docs/gameplay-systems.md), [docs/character-progression.md](docs/character-progression.md) |
| Protocol or player saves | [docs/protocol-and-persistence.md](docs/protocol-and-persistence.md) |
| Client UI | [docs/client-ui.md](docs/client-ui.md) |
| Animation integration | [docs/battle-animation.md](docs/battle-animation.md) |
| Animation appearance and motion | [docs/combat-animation-design-guide.md](docs/combat-animation-design-guide.md) |
| Feature planning | [docs/status-and-roadmap.md](docs/status-and-roadmap.md); verify relevant claims against current code |

## Commands and completion

Run backend commands from the repository root; client commands use `npm --prefix client`.

| Change or task | Relevant command / evidence |
| --- | --- |
| Build / run backend | `make build` / `make run` (`./server/build/tingfeng-server`, 127.0.0.1:9160) |
| Backend gameplay, parsing, persistence, WS hub | `make test` (`./server/build/tingfeng-server --test`) |
| Client Wasm check | `npm --prefix client run check` |
| Client production bundle | `npm --prefix client run build` |
| Animation catalog and asset references | `npm --prefix client run validate:animations` |
| Timeline, clock, battle presentation logic | `npm --prefix client run test:battle` |
| Browser battle interaction | `npm --prefix client run test:battle:browser` |
| Visual animation change | Record the relevant running scene and inspect it with `animation-visual-qa` |

Select checks for the changed behavior. `check` and `build` already include
animation validation; avoid redundant runs unless something changed or failed.
Documentation-only edits need link/command/consistency checks, not a full game build.

Within the requested scope, continue through implementation, relevant verification,
and fixes for failures caused by the change without asking for approval at each
local step. For visual work, completion includes inspecting the running result;
a successful build alone does not establish visual quality. Report what was
verified and any unresolved limitation. Do not expand a review-only request into edits.

For full-game development, `scripts/dev-test.sh` starts both processes and normally
resets the named test player's save. Use a dedicated test user or `--no-reset` to
preserve an existing save. The battle lab provides client fixtures for animation
work without needing a gameplay save.

## Implementation constraints

- Keep `Combat` pure over `Battle` and read-only `World` (`combat.gsa`); it does not directly mutate `GameState`.
- Use `GameException`, `CombatException`, or `WorldException` and `throwErr` in the corresponding MTL effect layer rather than aborting.
- Keep shared concurrent server coordination inside the sequential `Actor HubState` (`hub.gsa`) and per-client `Chan OutboxCmd` rather than ad-hoc shared locks.
- Use YAML/JSON for content supported by the existing schema (`yaml.gsa` + `std.codec.Decoder` pipelines); extend parsing and world validation (`world.gsa`) when adding new content semantics.

## Image Asset Generation Policy

When creating or modifying visual game assets, especially character sprites,
animation frames, skill effects, icons, and style reference images, use the
Codex `imagegen` skill / `image_gen` tool as the source of the actual artwork.

Do **not** manually create final artwork with SVG path tracing, hand-authored
vector shapes, PIL/canvas geometry drawing, pixel-by-pixel edits, or other
code-native/manual drawing techniques. Do not "fix" an image by redrawing the
character or effect manually unless the user explicitly asks for a code-native
vector/SVG asset.

Allowed deterministic post-processing is limited to clearly mechanical steps
that do not invent or redraw the artwork: copying/moving generated files,
cropping, resizing, padding, spritesheet slicing/assembly, format conversion,
alpha/chroma-key removal, palette cleanup, compression, and alignment against
an existing generated frame. If a visual change affects the shape, pose,
style, anatomy, silhouette, costume, weapon, VFX design, or perceived art
direction, perform it through `image_gen` generation/editing instead of manual
editing.

If `image_gen` cannot produce the needed asset, stop and report the limitation
or ask before using a fallback workflow.

## Agent Harness Artifacts

Use `harness/` for agent-generated material that should remain available for
future QA, prompt reuse, or design decisions. Do not create new top-level
`reports/` or `tmp/` directories for agent work.

Current layout:

- `harness/animation-qa/runs/` - review prompts, QA verdicts, bounding boxes,
  and other lightweight records from local animation checks.
- `harness/animation-qa/references/` - reusable reference clips and analysis
  notes for animation timing or visual style.
- `harness/portrait-generation/jobs/` - prompt histories, QA manifests, notes,
  and contact sheets for portrait-generation jobs.
- `harness/portrait-generation/candidates/` - reusable generated candidates
  that are not final in-game assets or documentation assets yet.
- `harness/tmp/` - ignored runtime scratch space for recordings, storyboards,
  crop tests, generated lists, markers, and other files that can be regenerated.

Commit files that preserve a decision, a repeatable prompt, a source reference,
or a reusable generated candidate. Put pure execution byproducts under
`harness/tmp/` so they stay local. If a generated visual becomes a final game
asset, move it into the appropriate `client/src/assets/` or `docs/assets/`
location and keep only the supporting prompt/QA notes in `harness/`.
