# ISLAND SIEGE (working title) — Build Specification

A 1v1 Roblox strategy game. Two round islands face each other across a narrow channel. Each player hides three bases on their island and defends them with soft weapons — coconuts, birds, slingshots. Neither player can see the other's island. First to knock out all three enemy bases wins.

Lineage: *Metal Marines* (hidden placement, two-resource economy, indirect attack, intel-as-weapon) with *Bloons*-style data-driven weapon roster and in-match upgrade paths.

This document is written for autonomous execution by a coding agent. **Read the whole spec, then build the milestones in order without stopping to ask questions.** When a decision is ambiguous, make a reasonable call, record it in `DECISIONS.md`, and continue.

---

## 1. Points of Consideration

Not hard rules — but if you deviate from one, say so in `DECISIONS.md`.

1. **Birds find, catapults kill, anti-air blinds.** Every weapon added later should strengthen one of those three legs and cost something on the other two.
2. **Information is the resource.** Fog of war + flight-path recon + decoy bases is the whole game. An enemy cell is never rendered truthfully until it has been revealed by the server.
3. **Simultaneous, never alternating.** Both players act continuously. Pacing comes from firing costs and cooldowns, not from turn-taking.
4. **Placeholder art everywhere, model-swappable later.** Colored parts and billboard glyphs. Never block on art.
5. **Short matches.** 8–12 minutes, then immediately offer a rematch.

---

## 2. Tech Stack & Constraints

- **Roblox / Luau, file-based via Rojo.** The project must be authored as files on disk and synced into Studio with `rojo serve`. Nothing may live only inside a `.rbxl`. This is non-negotiable — an agent cannot edit inside Studio.
- **The rules core is engine-agnostic.** Everything in `src/shared/` must be pure Luau with **zero Roblox API calls** — no `Instance`, no `workspace`, no `task.wait`. It takes a state table and inputs and returns a new state. The Roblox layer is a thin adapter over it.
  - This exists so the rules can be run and tested headlessly under **Lune** (`lune run test`). It is the only part of this project an agent can verify without a human opening Studio, so it should carry as much of the game's logic as possible.
- **One serializable `MatchState` table.** `rules.step(state, commands, dt) -> state, events`. Pure. No mutation of the input.
- **All tuning numbers live in `src/shared/config.luau`** — one file, exported constants, heavily commented. Nothing numeric hardcoded anywhere else.
- **Server is authoritative over everything.** See §8.
- **No external dependencies** beyond Rojo and Lune.

### Repo layout

```
/src
  shared/
    config.luau        -- ALL tuning constants
    state.luau         -- MatchState types + initializers
    rules.luau         -- pure step(state, commands, dt)
    grid.luau          -- island generation, cell math, line-of-flight
    economy.luau
    weapons.luau       -- roster data + resolution
    fog.luau           -- reveal + belief map
  server/
    MatchService.luau  -- lifecycle: lobby -> setup -> combat -> result
    Replication.luau   -- fog-gated state push (see §8)
    CommandHandler.luau-- validates every client request
    Bot.luau
  client/
    Render.luau        -- structures, projectiles, fog
    Input.luau
    Camera.luau
    UI/                -- build palette, resources, targeting, end screen
/sim
  harness.luau         -- headless match runner over src/shared
  archetypes/          -- scripted strategies (see §11)
  sweep.luau           -- parameter grid runner
  out/                 -- match logs + aggregate CSVs (gitignored)
/tests                 -- Lune specs against src/shared
default.project.json
DECISIONS.md
SPEC.md                -- this file
```

---

## 3. Playfield

Grid units (`u`) are logical cells. `STUDS_PER_CELL` (default **4**) converts to world space.

| Element | Value | Constant |
|---|---|---|
| Island diameter | 36u (~144 studs) | `ISLAND_DIAMETER` (valid 30–50) |
| Channel width | 15u (~60 studs) | `CHANNEL_WIDTH` |
| Total field | ~87u (~348 studs) | derived |
| Buildable cells per island | ~1,000 | derived |
| Base footprint | 3×3u | `BASE_FOOTPRINT` |
| Obstacle cells | 8–14, seeded random | `OBSTACLE_COUNT` |

Islands are generated from a shared seed and are mirror-fair: both get the same buildable cell count ±2. Obstacles are unbuildable and block nothing else.

Camera is fixed top-down on your own island, with a toggle to the enemy intel view. Both islands need not be on screen at once.

**Placement tension (preserve this):** shore-side weapons reach deeper into the enemy island but sit in the most-searched band. Inland weapons are safe but only reach the enemy shoreline. Do not give any weapon enough range to cover the whole enemy island from anywhere — that flattens the only spatial decision in the game.

---

## 4. Economy

Two resources, mirroring Metal Marines' money/energy split. Keeping them separate is what stops "build more" and "shoot more" from being the same decision.

| Resource | Earned | Spent on |
|---|---|---|
| **Coin** | +`COIN_BASE_RATE` (default 1) per `COIN_TICK_SECONDS` (default 2s), plus +1 per surviving **Grove** per tick. | Placing structures, upgrades, rebuilding. |
| **Charge** | Flat regen: +1 per `CHARGE_REGEN_SECONDS` (default 6s), capped at `CHARGE_CAP` (default 6). | Firing. Every shot costs Charge. |

**Firing must cost.** If shots are free, the dominant strategy is blind saturation of the entire enemy island and fog of war stops mattering. Charge cost is what makes a shot a decision.

**Charge regen is deliberately flat and not tied to bases.** Income comes from Groves, which are bombable and rebuildable; bases are purely the win condition and generate nothing. This is the anti-snowball measure — losing a base costs you the match, not your ability to play it.

Both players accrue in real time. Never display the opponent's resources.

---

## 5. Structures (v1 roster)

IDs in `snake_case` are canonical — used for config keys, model filenames, and replication.

| id | Name | Role | Coin | HP | Behavior |
|---|---|---|---|---|---|
| `base` | Base | Win condition | free (3 pre-placed) | 40 | 3×3. Placed during setup. Lose all 3 → defeat. Generates nothing. |
| `decoy_base` | Decoy Base | Deception | 8 | 1 | 3×3. Renders to the enemy *exactly* as `base` when revealed. Any hit destroys it. See `DECOY_FAKE_KILL_FEEDBACK` below. |
| `grove` | Grove | Income | 10 | 6 | +1 Coin per income tick. The reason bombardment is worth doing when you haven't found a base yet. |
| `catapult` | Coconut Catapult | Kill | 12 | 5 | Lobbed shot at a chosen cell. `CATAPULT_DAMAGE` (default 8) on impact. Reveals a 3u-radius area at impact plus its flight path (§7). Cooldown `CATAPULT_COOLDOWN` (default 6s). Charge cost 1. |
| `perch` | Bird Perch | Find | 14 | 6 | Launches a **Spotter Bird** along a chosen straight path across the enemy island. No damage. Reveals an 8u-wide lane live along its flight until shot down or exiting the far side. Cooldown `PERCH_COOLDOWN` (default 20s). Charge cost 2. |
| `nest` | Slingshot Nest | Blind | 16 | 8 | Anti-air. Auto-fires at any bird entering radius `NEST_RADIUS` (default 6), dealing `NEST_DPS` (default 10) per second to it. Reveals nothing. Invisible to the enemy until it fires — a firing nest reveals its own cell. |

**Rules:**
- One structure per cell (bases and decoys occupy 3×3).
- Build time `BUILD_SECONDS` (default 4s). Inert and at half HP while under construction.
- Bulldoze: free, instant, no refund.
- No repair in v1. Destroyed is gone; rebuild from scratch.
- **Upgrades (Bloons-style):** each weapon has 2 purchasable tiers that modify config values only — range, cooldown, reveal size, damage, HP. **No tier may grant a new role.** An upgraded catapult never becomes a scout.

`DECOY_FAKE_KILL_FEEDBACK` (default **true**): when a decoy is destroyed, the attacker gets the identical "Base destroyed!" feedback as a real kill, but their kill counter does not advance. The bot must be genuinely fooled by this too (§9).

**v2 candidates** (do not build now, but leave room in the schema): a long-range inaccurate lobber, a short-range heavy hitter, a mine that triggers on reveal, a jammer that suppresses a zone's weapons for N seconds.

### Weapon schema

Weapons are data, not bespoke code. Adding a type should mean adding a config entry and, at most, one resolution branch.

```
id, display_name, role, coin_cost, charge_cost, cooldown,
range, damage, splash, reveal_shape, reveal_size, reveal_duration,
projectile_speed, interceptable, upgrades[]
```

---

## 6. Match Flow

1. **Lobby.** Two players matched into a match. Island seed generated.
2. **Setup** (`SETUP_SECONDS`, default 75s, simultaneous): each player places 3 bases and an opening loadout from `STARTING_COIN` (default 40). Hidden from the opponent. Auto-place on timeout.
3. **Combat** (continuous, simultaneous): resources tick; players place, upgrade, and fire freely under cooldowns and Charge cost. **No pausing and no turn alternation** — targeting happens live.
4. **Resolution:** first to destroy all three enemy bases wins. Hard cap `MATCH_TIMEOUT` (default 15min) with tiebreak on bases remaining, then structures remaining, then Coin spent.
5. **End screen:** result + stats (duration, shots fired, cells revealed, times you were fooled by a decoy) + Rematch (new seed) + Leave.

Disconnect: opponent wins after `DISCONNECT_GRACE` (default 30s).

---

## 7. Fog of War & Intel

Each player holds a **belief map** of the enemy island.

- Unrevealed cells render as **uniform haze**. Do not render terrain, water, or obstacles truthfully in unrevealed cells — the shape of the island must not be inferrable from fog.
- **Flight-path recon:** every projectile reveals the true contents of cells along its flight line (width 1) in addition to its impact area. A bird reveals an 8u-wide lane for as long as it is airborne.
- **Plots are stale, not live.** A revealed cell is recorded *as it was at reveal time* and stays plotted. If the defender later builds or bulldozes there, the attacker's plot is wrong until re-revealed. This is the Metal Marines behavior and it is what makes decoys and re-probing matter. Do not live-update the belief map.
- Destroyed structures observed during a reveal update the plot to rubble.
- Decoys plot as real bases.
- Your own island is always fully visible to you.

### Search math (why the numbers in §3 and §5 are what they are)

Island area at d=36 is ~1,018 cells.

- A bird pass reveals 8 × 36 ≈ 288 cells — roughly 28% of the island per flight. Four uncontested passes reveal nearly everything.
- A catapult impact reveals ~28 cells with a 3u radius — under 3%. Finding three bases by catapult alone would take dozens of shots.

Therefore birds are the only viable search tool, and **anti-air coverage is the single strongest balance lever in the game.** Too little and matches resolve in two minutes; too much and neither player finds anything. Tune `NEST_DPS`, `NEST_RADIUS`, and bird HP first, everything else second.

The 3×3 base footprint exists for the same reason — a single-cell base in a thousand-cell island makes catapult hits pure luck.

---

## 8. Server Authority (critical — build this in from day one)

This is the section most likely to be quietly skipped and the most expensive to retrofit.

- The server holds the full `MatchState`. Clients hold only their own island plus their belief map.
- **Never create enemy structure Instances on the client until the server reveals them.** Hiding enemy models with `Transparency` or `CollisionGroup` or a fog overlay is not fog of war — the positions can be read out of the client's workspace in seconds and the entire game is defeated. Revealed enemy structures are spawned client-side on reveal and despawned when the reveal expires.
- All player actions are RemoteEvent *requests*. The server validates every one: ownership, affordability, cell legality, build state, cooldown, range. The client never computes damage, reveal, or resource change — it predicts visuals only.
- Replication is per-player and filtered. A client must never receive a payload containing unrevealed enemy data, even in a field it doesn't render.
- Rate-limit all remotes.

---

## 9. Bot Opponent

A finite state machine on a decision tick every `BOT_DECISION_SECONDS` (default 3s, difficulty-scaled). The bot plays by identical rules — same costs, same cooldowns, and **its own fog**: its knowledge of the player's island comes only from its own recon plots. It must never read true player state.

**Phases (hysteresis, not hard gates):**

1. **FOUNDATION** — setup placement: bases far apart, at least one adjacent to obstacles, 1 decoy + spacing away from real bases. Build order: Grove, Grove, Catapult, Nest, Perch.
2. **SCOUT** — once a perch is up and Charge allows, fly birds across unexplored bands (center first, then sweep outward). Goal: coverage.
3. **SUPPRESS** — when plots show nests, prioritize catapult fire on them to open flight lanes. Bombard plotted groves when no better target exists.
4. **KILL** — when a plotted base (real *or* decoy) exists and no nest is believed live near the lane to it, concentrate fire. If the fake-kill feedback fires, the bot believes it scored and decrements its internal target count. Decoys should genuinely fool it.
5. **REBUILD** — always interleaved: if groves or nests fall below phase minimums, rebuild before advancing.

**Difficulty knobs:** `BOT_DECISION_SECONDS` (5/3/2), Coin multiplier (0.8/1.0/1.25), and whether the bot is fooled by decoys permanently or re-probes "killed" base sites after 90s (easy: fooled forever; hard: re-probes). Three presets: **Beachcomber / Skirmish / Siege**.

The bot exists for two reasons: solo practice, and because a 1v1 game with an empty player base cannot be played at launch. Treat it as shipping scope, not a stretch goal.

---

## 10. Rendering & the Asset Swap Contract

**Placeholder-first.** Every structure renders as a colored `Part` at cell size, plus a `BillboardGui` glyph and an HP pip bar. Ship the full color/glyph map in `Render.luau`. Suggested: `base` dark brown + 🥥, `grove` green + 🌴, `catapult` red + 🥥, `perch` amber + 🐦, `nest` yellow + 🎯, obstacle gray, haze dark blue-gray.

**Swap contract (do not skip):** at boot, look for a Model at `ReplicatedStorage/Assets/Structures/<id>` for every structure id, plus `projectile_coconut`, `bird`, `impact`, `rubble`. If present, clone and scale it to cell size; if absent, fall back to the placeholder silently. Document the full expected name list in `README.md`. This lets art be dropped in later with zero code changes.

**Feedback (cheap, high value):** projectile arcs with a ground shadow dot, impact particles, floating damage numbers, a distinct shake when a base takes a hit, a visible puff when a nest fires (it is revealing itself — the player should feel that), fog peeling back along a bird's lane in real time.

---

## 11. Simulation Harness & Balance Sweep

Because the rules core is pure and headless (§2), balance can be measured before any UI exists. Build this immediately after M1 and before touching Studio — the point is to eliminate broken parameter regions while changing a number is still free.

### 11.1 Harness

`sim/harness.luau` runs `N` matches given a config, a seed range, and two strategy modules. It writes one JSONL match log per game plus an aggregate CSV. No Roblox, no rendering.

**Two constraints on agents, both mandatory — results are meaningless without them:**

1. **Action rate limit.** Agents may issue at most one command per `SIM_AGENT_ACTION_INTERVAL` (default 2.5s of simulated time). Combat is continuous and simultaneous, so an unconstrained agent has infinite APM and will report a game no human can play.
2. **Fog discipline.** Agents read *only* their own belief map — the same stale-plot structure a player sees (§7). Any agent that can see true enemy state invalidates the run. This is the same hard requirement as the bot in §9 and should share the interface.

Log per match: seed, config hash, winner, duration, per-player timeline of actions, resource curves, reveal coverage over time, first-base-found timestamp, decoy kills, structures lost.

### 11.2 Archetypes

Use **scripted** strategies, not learned agents. Scripted is interpretable: when one dominates you know which constant to move. A learned agent that beats the field only tells you that learned agents are good at your game.

| Archetype | Behavior |
|---|---|
| `turtle` | Heavy nest coverage early, minimal offense, wins on opponent attrition. |
| `rusher` | Catapults first, bombards blind at high-probability cells, accepts poor economy. |
| `boomer` | Groves first, no offense until Coin income is compounding, then mass buys. |
| `scout` | Perch-heavy, prioritizes full map coverage before committing any kill fire. |
| `trickster` | Multiple decoys, minimal real defense, wins by wasting opponent fire. |

Run full round robin including self-play, `SIM_MATCHES_PER_PAIR` (default 200) per pairing, seeds shared across pairings so map variance cancels.

### 11.3 Metrics

**Primary — the number the whole harness exists to produce:**

- **Time to first real base found.** The direct readout on the anti-air lever (§7). Target window: 25–45% into expected match length. Below that, fog is decorative; above it, matches stall.

**Secondary:**

- Match length distribution, not the mean. A bimodal 2-or-25-minute result signals a broken dominant line that an average conceals.
- Comeback rate — matches won by the player behind on structures at the 5-minute mark. This reads directly on the snowball risk called out in §4.
- Per-weapon purchase share and per-weapon Coin efficiency. Anything never bought is miscosted; anything always bought first is underpriced.
- Reveal coverage curve — how fast the map opens. Should be steep early and flatten as nests come online.
- Decoy return on investment: Coin of enemy fire absorbed per Coin spent on decoys. Below 1.0, decoys are a trap; far above, they're mandatory.
- Win rate matrix across archetypes. **No archetype should exceed 60% against the field.**

### 11.4 Rubric pass

Feed match logs to a model for pathology detection, not enjoyment scoring. Ask it to flag specific failure shapes: long stretches where no consequential action occurs, losing players whose final actions had no bearing on the outcome, matches decided during setup placement, weapons that appear in logs but never affect an outcome.

Treat balance and fairness scores as reliable. Treat any direct "is this fun" score as near-noise — the rubric pass is for finding pathologies a human would notice, not for ranking configs.

### 11.5 Sweep

`sim/sweep.luau` runs the archetype round robin across a parameter grid. First sweep, in priority order: `NEST_DPS` × `NEST_RADIUS` × bird HP × `CATAPULT_COOLDOWN`. Second sweep: `COIN_BASE_RATE` × `CHARGE_REGEN_SECONDS` × `grove` cost.

Output: the region of parameter space where time-to-first-base lands in the target window, no archetype exceeds 60%, and comeback rate is non-trivial.

**The sweep narrows; it does not decide.** Expected output is roughly five surviving configurations, which then go to human playtesting after M5. Do not ship a config chosen by simulation alone.

### 11.6 Known limitation

This is a hidden-information search game, and results transfer only as far as agent search behavior resembles human search behavior. A scripted agent sweeps methodically and never forgets a cleared lane. Humans get hunches, fixate on decoys, and re-search ground they already covered. The experience of this game lives largely in that gap, so the harness is authoritative on *dominance and pacing* and merely suggestive on everything else.

---

## 12. Milestones & Acceptance Criteria

Build in order. After each: the rules core must still pass `lune run test` with zero failures, and the Rojo project must sync into Studio without errors. Log notable choices in `DECISIONS.md`.

- **M1 — Rules core, headless.** `src/shared/` complete and pure: island generation from seed, placement legality, economy tick, weapon resolution, fog reveal and stale plots, win detection. Lune specs cover each. *Accept: I can run a full scripted match end to end in the terminal with no Roblox involved, and the test suite is green.*
- **M1.5 — Simulation harness & first sweep.** `sim/` per §11: harness with the action-rate and fog constraints, five scripted archetypes, round robin, metrics aggregation, and the first parameter sweep on the anti-air lever. *Accept: I can run a 5,000-match round robin from the terminal and get a win-rate matrix, a time-to-first-base distribution, and a shortlist of surviving configs.*
- **M2 — Board & building.** Rojo project, island geometry, camera, build palette, place/bulldoze with cost and build timers, setup phase for 3 bases. *Accept: I can lay out a base in Studio.*
- **M3 — Economy & UI.** Coin/Charge accrual with Groves applying, resource readouts, cooldown indicators. *Accept: numbers tick visibly and respond to what I build.*
- **M4 — Weapons & fog, vs. a dummy.** Catapults, birds, nests firing with animation and interception; reveals, stale plots, haze rendering. Temporary static enemy layout to shoot at. *Accept: I can bombard and scout an enemy island and the fog behaves correctly.*
- **M5 — Real 1v1.** Two-client matchmaking, setup, simultaneous combat, server-authoritative replication per §8, win/lose, end screen, rematch. *Accept: two Studio clients can play a complete match against each other.*
- **M6 — Bot.** Full §9 FSM, three difficulties, decoy deception working. *Accept: the bot builds, scouts, bombards, and kills my bases; I can lose to it.*
- **M7 — Ship.** Feedback polish, README (run, sync, asset names, config tuning guide), first-pass balance on the AA lever per §7.

### Self-playtest before declaring done

- (a) A full win path against the bot.
- (b) A full loss by idling.
- (c) A decoy base absorbs a kill without advancing the counter, for both the player and the bot.
- (d) A nest visibly downs a bird mid-lane and the reveal stops there.
- (e) **Exploit check:** with a client attached, confirm no unrevealed enemy structure exists anywhere in the client's Instance tree or in any received remote payload.
- (f) Rematch produces a fresh seeded island without rejoining.

---

## 13. Out of Scope (v1)

Free-for-all above 2 players, cross-match persistence or unlocks, cosmetics, monetization, mobile-specific UI, leaderboards, spectating, voice/chat features, sound design beyond basic impact cues, balance perfection — expose knobs in `config.luau` instead.

---

## 14. Open Decisions

Resolve in `DECISIONS.md` and continue; do not block.

1. Theming and naming — the roster is currently tropical/food-adjacent but unthemed. Display names are placeholders.
2. Whether birds are fire-and-forget along a pre-drawn line or steerable in flight.
3. Whether rubble persists on the belief map as a permanent information source or decays.
4. Whether bases can be relocated mid-match at high Coin cost.
5. Mobile input — the game is grid-and-tap and should port well, but targeting precision on a phone needs a pass.