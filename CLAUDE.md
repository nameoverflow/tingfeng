# CLAUDE.md

This file provides guidance when working with code in this repository.

## Project Overview

**听风录（Tingfeng）** is a Wuxia MUD with a **pure-Geisha WebSocket backend** (`server/src/`) and a **Haskell GHC Wasm Canvas2D web client** (`client/hs/`).

**Tech Stack:**
- **Backend (`server/src/*.gsa`)**: Self-hosted Geisha (LLVM 20 native compilation), built on `std.control` HKT hierarchy (`Functor -> Applicative -> Monad`), multi-parameter `Concept`s with functional dependencies (`MonadState`, `MonadReader`, `MonadError`, `MonadWriter`, `MonadRng`), symmetric combat `Lens`, persistent AVL `OrdMap`/`OrdSet`, native indentation-aware YAML -> `std.codec.Value` parser + combinator `Decoder`/`Encode` pipelines, and sequential `std.actor.Actor` session/outbox concurrency.
- **Client (`client/hs/`)**: Haskell GHC Wasm Canvas2D UI + animation presentation.
- **Content (`resources/scripts/`)**: Data-driven YAML/JSON maps, NPCs, martial arts, items, effects, combat action timings, and quests.
- **Persistence (`saves/`)**: PlayerSave v6 JSON files.

## Build & Verification Commands

```bash
# Compile server/build/tingfeng-server
make build

# Run the full 9-suite backend & live WebSocket loopback tests
make test

# Run the WebSocket server (listens on 127.0.0.1:9160 by default)
make run

# One-command local dev mode (MUD_DEV_MODE=1 server + client dev server)
make dev-test

# Client checks & tests
npm --prefix client run check
npm --prefix client run test:battle
```

## Backend Module Layout (`server/src/`)

- `mod.gsa` — CLI entry point (`--test`, `--host`, `--port`, `--scripts`, `--saves`)
- `fp.gsa` — Higher-kinded & multi-param effect prelude (`Ord`, `Semigroup`, `Monoid`, `MonadWriter`, `MonadRng`, `Lens`, rounding/UTF-8 helpers)
- `ordmap.gsa` — Persistent `Send`-safe AVL `OrdMap k v` & `OrdSet k`
- `yaml.gsa` — Native pure-Geisha YAML 1.2 subset parser -> `std.codec.Value` + `Configurable` Concept
- `entity.gsa` — Domain models, `Decoder`/`Encode` pipelines, and derived stat formulas
- `creation.gsa` — Character creation `Monoid` bonus algebra & initial player setup
- `progression.gsa` — Pure martial art leveling, foundation sharing, and reward curves
- `quest.gsa` — Quest models and `tagged` story trigger/condition/action decoders
- `world.gsa` — Asset directory loading and referential/tier integrity validation
- `message.gsa` — 100% Aeson-compatible `NetEvent` / `PlayerAction` / `ActionResp` wire codecs
- `combat.gsa` — Pure deterministic `Combat a` monad with symmetric `Lens Battle BattleState` (`playerSideL` / `enemySideL`)
- `state.gsa` — Transactional `Game a` monad over persistent `GameState` (free rollback on `GameException`)
- `gameplay.gsa` — Story machine, training queue, shop/equipment/medicine, recovery, and battle orchestration
- `database.gsa` — `PlayerSave` v6 JSON persistence & legacy migration/prepared-slot folding
- `logging.gsa` — Structured `$MUD_LOG_LEVEL` logger
- `hub.gsa` — `Actor HubState` coordinator, per-client `Actor WsConn` FIFO outbox, and `1000ms` / `50ms` monotonic tickers
- `spec.gsa` — Full gameplay, combat, progression, story, persistence & WebSocket loopback test suite
