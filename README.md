# 听风录（Tingfeng）

《听风录》是一款以 **Geisha 服务端**与 **Haskell Canvas2D Wasm 网页客户端**构建的写实武侠文字 MUD。

The project has a playable local flow: WebSocket login, room movement through a clickable map, NPC popup interactions, multi-chapter story lines, AP/Qi combat, martial arts progression, item rewards, manual-based martial art learning, and JSON player saves.

## Tech Stack

- Pure Geisha backend (`server/src/*.gsa` -> native LLVM 20 binary `server/build/tingfeng-server`)
- WebSocket server on `127.0.0.1:9160`
- YAML/JSON content under `resources/scripts/`
- Haskell GHC Wasm Canvas2D client under `client/hs/`
- JSON player saves under `saves/`

## Run

One-command local test mode:

```bash
make dev-test
```

This builds the Geisha server executable if needed, starts the server with `MUD_DEV_MODE=1`, starts the client server, and opens `http://127.0.0.1:8080/?test=1&user=tester`.

Manual commands:

```bash
make build
make test
make run
```

In another shell:

```bash
cd client
npm install
npm run dev
```

Open `http://127.0.0.1:8080`.

For repeated local story-flow testing without typing a login name:

```bash
MUD_DEV_MODE=1 ./server/build/tingfeng-server
```

Then open:

```text
http://localhost:8080/?test=1
```

This auto-connects as `tester` and requests a fresh save reset. Use `?test=1&user=name` for another test user, or `?test=1&reset=0` to auto-login without resetting.

## Current Features

- YAML-loaded maps, rooms, NPCs, martial arts, effects, items, and quests.
- Player-specific story state with quest stages, flags, and hidden NPCs.
- Clickable room map and NPC popup interactions.
- Linear story events driven by triggers, conditions, and actions.
- One-on-one AP combat with Qi, cooldowns, status effects, active moves, and battle snapshots.
- Character progression through martial art levels rather than character levels.
- Foundation arts that rise when related martial arts are trained.
- Inventory, quest log, rewards, manual items, and martial art learning through item use.
- Web UI fixed-field Chinese/English i18n. Story text, entity names, item names, martial art names, and move names stay in content scripts.
- Dev-only auto-login/reset entry for fast local testing.

## Docs

Start with [docs/README.md](docs/README.md).

- [Run and develop](docs/running.md)
- [Architecture](docs/architecture.md)
- [Content and story scripting](docs/content-scripting.md)
- [Combat, martial arts, and items](docs/gameplay-systems.md)
- [Character attributes and derived stats](docs/character-attributes.md)
- [Character progression](docs/character-progression.md)
- [Client UI](docs/client-ui.md)
- [Protocol and persistence](docs/protocol-and-persistence.md)
- [Status and roadmap](docs/status-and-roadmap.md)
