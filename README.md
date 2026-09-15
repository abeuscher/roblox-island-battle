# Island Siege

A 1v1 Roblox strategy game. Two round islands face each other across a
narrow channel. Each player hides three bases on their island and defends
them with soft weapons — coconuts, birds, slingshots. Neither player can see
the other's island. First to knock out all three enemy bases wins.

The full design is in [`spec.md`](spec.md); every judgement call made while
building it is in [`DECISIONS.md`](DECISIONS.md).

---

## Running it

### Headless (no Roblox needed)

The rules core is pure Luau with zero Roblox API calls, so the whole game
can be run and tested from a terminal. This is the fast loop — use it for
anything that is not rendering or input.

```sh
lune run test          # the full spec suite; must be green before anything else
lune run sim           # one match per archetype pairing, printed as a summary
lune run roundrobin    # win-rate matrix + every SPEC §11.3 metric + pathology pass
lune run sweep first   # the anti-air parameter grid
lune run shortlist     # rank every swept configuration, best first
```

Requires [Lune](https://github.com/lune-org/lune) on `PATH` (built against
0.10.4). Nothing else — no package manager, no build step.

`roundrobin` and `sweep` take arguments:

```sh
lune run roundrobin 200          # matches per pairing (default 40)
lune run roundrobin 340          # ~5,000 matches, the M1.5 acceptance run (~8 min)
lune run roundrobin 200 --bot    # also enter the shipping bot's three presets
lune run sweep first 1 4 16      # grid, shard index, shard count, matches per pairing
lune run sweep pacing 1 1 40     # a different grid, unsharded
```

Sweeps are shardable because they are embarrassingly parallel. To use four
cores:

```sh
for s in 1 2 3 4; do lune run sweep first $s 4 16 & done; wait
```

Output lands in `sim/out/` (gitignored): one CSV per shard, plus
`flagged.jsonl` from the pathology pass. `lune run shortlist [grid]` reads
all of it back and ranks the configurations — surviving ones if any survive,
and otherwise by how many gates each misses and by how far, which is the
current state and a finding in itself (see `DECISIONS.md` §3).

### In Studio

```sh
rojo serve
```

Then connect from the Rojo plugin in Studio and press Play. The server seats
you as player 1 and gives player 2 to the bot, so a single client is a
complete game. A second client joining takes seat 2 and the bot steps aside.

To change bot difficulty, edit the preset name in
`src/server/init.server.luau`: `beachcomber`, `skirmish`, or `siege`.

---

## How it is put together

```
src/shared/     pure Luau, zero Roblox APIs, runs under both Lune and Roblox
  config.luau     ALL tuning constants — nothing numeric lives anywhere else
  state.luau      MatchState types and initializers
  rules.luau      step(state, commands, dt) -> state, events   (the whole game)
  grid.luau       island generation, cell math, cross-channel geometry
  economy.luau    Coin and Charge
  weapons.luau    roster data access + projectile resolution
  fog.luau        reveals and the stale belief map
  agent.luau      the fog-disciplined toolkit shared by the bot and the sim
  botbrain.luau   the bot's FSM (pure, so it is tested and simulatable)

src/server/     authoritative: holds MatchState, validates every request
src/client/     a viewer and a requester; holds only its own island + beliefs
sim/            headless harness, five archetypes, sweeps, metrics, rubric
tests/          Lune specs against src/shared
```

Two properties are load-bearing and everything else follows from them.

**The rules core is engine-agnostic.** `src/shared` takes a state table and
inputs and returns a new state. It has no `Instance`, no `workspace`, no
`task.wait`. That is what lets the same code be stepped by a Roblox
`Heartbeat` and by a `for` loop running ten thousand matches, and it is
enforced by `tests/purity_spec.luau` rather than by good intentions.

**The server is authoritative and replication is fog-gated.** Enemy
structures do not exist on the client until the server reveals them. They
are not hidden with `Transparency` or a fog overlay — a client that holds a
hidden Instance has already lost the game's only secret. Every outbound
payload is built from `Rules.viewFor`, which contains the player's own
island and their stale belief map and nothing else.

---

## The asset swap contract

Everything renders as a colored `Part` with a glyph and an HP bar. Art can
be dropped in later with **zero code changes**: at boot the client looks for
a `Model` at each name below, clones and scales it to cell size if present,
and silently falls back to the placeholder if absent.

`ReplicatedStorage/Assets/Structures/`

| Name | What it is |
|---|---|
| `base` | 3×3 win condition |
| `decoy_base` | 3×3, must be visually identical to `base` |
| `grove` | 1×1 income |
| `catapult` | 1×1 kill |
| `perch` | 1×1 bird launcher |
| `nest` | 1×1 anti-air |

`ReplicatedStorage/Assets/Effects/`

| Name | What it is |
|---|---|
| `projectile_coconut` | the lobbed shot |
| `bird` | the spotter bird |
| `impact` | impact burst |
| `rubble` | destroyed-structure marker |

Two rules for anyone making this art. `decoy_base` **must** be
indistinguishable from `base` — the entire deception depends on it, and the
server already plots decoys as `base` so the client could not tell them
apart even if the art did. And every model needs a `PrimaryPart`, because
scaling to cell size uses `Model:ScaleTo`.

---

## Tuning

Every number lives in `src/shared/config.luau`, commented, with the
balance-critical ones marked `[AA-LEVER]`. Nothing numeric is hardcoded
anywhere else, so tuning never means reading code.

To try a change, do not edit the file — override it, so the change is
reproducible and comparable:

```lua
local Config = require("src/shared/config")
local variant = Config.withOverrides({
	BIRD_LANE_WIDTH = 5,
	["WEAPONS.base.hp"] = 90,
})
```

That is exactly how the sweep works; see `sim/sweep.luau` for the grids.

**Read `DECISIONS.md` §3 before tuning.** Eight parameter grids found that
the lever the spec names as strongest — anti-air — is close to inert on the
metric it is supposed to control. Moving `NEST_DPS` from 10 to 24 changes
time-to-first-base by under two seconds.

The reason matters more than the number. Intel reaches a player through
**three independent channels**, and §7's search math models only the first:

1. bird lanes — the perch's `reveal_size` (tier-aware)
2. catapult impact circles — the catapult's `reveal_size`
3. projectile flight lines — `FLIGHT_LINE_REVEAL_WIDTH`

Throttle one and discovery simply moves to the others, which is why
single-lever tuning kept hitting the same ~40-60s floor. Anti-air contests
channel 1 only, and channels 2 and 3 ride on catapult fire that nests cannot
touch at all. **If you want to move discovery, move all three together** —
that is the only thing that ever put the primary metric inside its target
window.

### What to watch

`lune run roundrobin` prints all of these:

| Metric | Target | Why |
|---|---|---|
| Time to first **real** base | 25–45% into the match | Below: fog is decorative. Above: matches stall. |
| Match length distribution | 8–12 min, unimodal | A bimodal 2-or-25-minute result hides a dominant line. |
| Win rate vs the field | no archetype above 60% | The dominance check. |
| Comeback rate | non-trivial | Reads on the snowball risk. |
| Per-weapon purchase share | nothing near 0% | Anything never bought is miscosted. |
| Decoy ROI | above 1.0 | Below 1.0 decoys are a trap. |

### What the harness is and is not authoritative on

It is authoritative on **dominance and pacing**: those depend on costs,
cooldowns and rates, which scripted agents exercise faithfully.

It is merely suggestive on everything else. This is a hidden-information
search game, and a scripted agent sweeps methodically and never forgets a
cleared lane. Humans get hunches, fixate on decoys, and re-search ground
they already covered. Much of the actual experience lives in that gap. Per
§11.5, the sweep narrows the space; it does not pick the shipping config.
