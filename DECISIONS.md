# DECISIONS

Every ambiguous call, every deviation from a "Point of Consideration", and
every resolution of an §14 Open Decision. Written as the build went, in the
order the questions came up.

---

## 1. Open Decisions from §14

**1.1 Theming and naming — kept as-is, placeholders marked.**
The roster stays tropical (`coconut`, `grove`, `perch`). Every user-facing
string is a `display_name` field in `config.luau`, and nothing else reads it,
so a rename is a one-line change per weapon with no code impact. The
snake_case `id` is the canonical key everywhere else and should outlive any
theme change.

**1.2 Birds are fire-and-forget along a pre-drawn lane.**
A launched bird flies a fixed `laneY` in a straight line until it exits or
is shot down. Steering was rejected for two reasons: it would make anti-air
an avoidance minigame rather than an area-denial tool (weakening the third
leg of §1), and a steerable bird makes the sim's fog discipline much harder
to state — the agent would need a control loop, not a decision. Revisit only
if playtests show lanes feel arbitrary rather than committal.

**1.3 Rubble is permanent.**
A destroyed structure leaves rubble on the ground forever, and rubble plots
as `rubble` when revealed. It is therefore a permanent information source:
seeing rubble tells you something *was* here and is gone. Decay was rejected
because it quietly converts stale plots into live ones, which is the exact
property §7 forbids. Bulldozing, by contrast, leaves nothing — it is a
deliberate, voluntary act and should not brand the cell.

**1.4 Bases cannot be relocated in v1.**
Relocation would undercut the whole placement decision: the hidden layout is
what you are defending, and being able to move it after it is found converts
a lost position into a coin cost. Left out. The schema does not block it —
`base` is an ordinary structure with a footprint — so it could be added as a
purchasable action later.

**1.5 Mobile input — grid-and-tap, precision pass deferred.**
`Input.luau` already treats `Enum.UserInputType.Touch` identically to a left
click and works entirely in whole cells, so the game is playable on a phone
today. What is deferred is targeting *precision*: at phone width a 36-cell
island is about 10 px per cell, which is below a comfortable touch target.
The fix is a confirm-tap (tap to preview the cell, tap again to commit)
rather than anything structural. Out of scope per §13.

---

## 2. Deviations from the spec, and why

**2.1 A dual-target `import` shim sits at the top of every `src/shared`
module.** (§2 — "zero Roblox API calls")

The spec requires the same files to run under Lune *and* sync into Studio
via Rojo, but the two have incompatible module systems: Roblox needs
`require(script.Parent.grid)`, Lune needs `require("./grid")`. With no build
step allowed, the only way to serve both is a runtime branch:

```lua
local function import(name: string): any
	if script ~= nil then
		return require((script :: any).Parent[name])
	end
	return require("./" .. name)
end
```

This *names* a Roblox global, which brushes against the purity rule, so the
rule is enforced mechanically instead of by trust: `tests/purity_spec.luau`
scans `src/shared` for Roblox APIs and separately asserts that the only
mention of `script` in each file is inside this shim. The shim only ever
tests the global for nil; it never calls a Roblox API.

**2.2 `rules.stepMut` exists alongside the pure `rules.step`.** (§2 — "Pure.
No mutation of the input.")

`Rules.step` is pure exactly as specified: it deep-clones its input and
returns a new state. But the sweep runs millions of steps, and cloning the
entire MatchState (including a belief map of up to ~1,000 plots) per tick
made the round robin roughly an order of magnitude slower for no behavioural
difference. So `step` is now a thin wrapper over `stepMut`, which writes in
place. The server and the harness call `stepMut`; `step` remains the public
contract. `purity_spec` asserts both that `step` leaves its input untouched
and that the two produce identical states from identical command streams, so
the fast path cannot silently diverge.

**2.3 The two islands are *identical*, not "within ±2 buildable cells".** (§3)

Both are generated from the same seed and the same local coordinate frame,
so buildable counts match exactly rather than approximately. This is
strictly stronger than the spec's fairness requirement and it removes a
whole class of "the map was unfair" complaints. It is possible only because
each island lives in its own local frame (x = diameter is always *your*
shore), so no mirroring is needed anywhere and the rules stay symmetric.

**2.4 Catapult range is 50, chosen to make the placement tension exact.** (§3)

The spec asks that shore weapons reach deeper than inland ones and that no
weapon cover the whole enemy island from anywhere. Rather than guess, range
is pinned to a specific geometric fact: from the inland edge (x = 1) a
catapult reaches the enemy shoreline column *exactly* and not one cell
further; from the shore it reaches the enemy's far edge straight across, but
the enemy's far *corners* are ~53 away and stay out of reach. Both facts are
asserted in `grid_spec.luau`, so a future range change that flattens the
spatial decision fails the suite rather than shipping.

**2.5 In-board water is plotted as `water`, not left as haze.** (§7)

A bird's 8-wide lane crosses open sea near the island's edges. Those cells
are revealed honestly as `water` so the client can draw them as seen-and-
empty. This does not leak the island's shape, because a cell is only ever
plotted once a projectile has actually flown over it. Unrevealed cells
remain uniform haze with no terrain information whatsoever, which is the
property §7 actually protects. `Agent.coverage` explicitly excludes water
plots, so an agent cannot mistake overflown sea for searched ground.

**2.6 Bot difficulty's coin multiplier runs through the economy.** (§9)

`Player.coinMultiplier` is a field of MatchState applied inside
`Economy.tick`, not a bonus the server grants on the side. §9 insists the
bot "plays by identical rules"; making its one sanctioned advantage a
first-class, visible, testable part of the rules core is how that claim
stays checkable. Human players are always 1.0.

**2.7 The §11.4 rubric pass is mechanical, and writes out only the matches
worth reading.**

The spec asks for match logs to be fed to a model for pathology detection. A
model is not reachable from a headless Lune process, so `sim/rubric.luau`
implements the structural half directly — it flags exactly the four failure
shapes the spec names (long stretches with no consequential action, losing
players whose final actions had no bearing, matches decided during setup,
weapons that appear but never affect an outcome) — and `lune run roundrobin`
writes the flagged matches to `sim/out/flagged.jsonl`. A model pass is then a
cheap follow-up over a few dozen matches instead of thousands. No "is this
fun" score is produced anywhere, per §11.4.

**2.8 A third sweep grid was added, because the spec's stated priority order
turned out to be wrong for this build.** (§7, §11.5)

This is the largest deviation and the most important finding of M1.5; it has
its own section below.

**2.9 `SIM_IDLE_RECHECK` is a harness knob, not a game rule.**

An agent that returns "nothing worth doing" must not be re-offered a
decision on the very next tick — building a fog-filtered view is the most
expensive operation in the loop, and idle agents polling it four times a
second dominated the sweep's runtime. Idle agents wait 1s. This cannot
affect outcomes: it only applies when the agent has already declined to act.

---

## 3. What the simulation actually found

### 3.1 The anti-air lever is close to inert

> Read §3.6 with this section. The measurement below holds, but the
> explanation offered here — that anti-air arrives too late to contest the
> first bird — was tested in §3.3 and refuted. The explanation that
> survived is in §3.6: intel reaches a player through three channels and
> anti-air contests only one of them. The sections are left in the order
> they were written because the wrong turn is part of the finding.

§7 states that anti-air coverage is "the single strongest balance lever in
the game" and instructs tuning `NEST_DPS`, `NEST_RADIUS` and bird HP first.
The first sweep ran that exact grid — 54 configurations, 120 matches each,
6,480 matches. Result, as medians across the grid:

| dimension | range swept | median time-to-first-base | median match length |
|---|---|---|---|
| `NEST_DPS` | 10 → 24 | 33.0s → 31.1s | 155s → 163s |
| `NEST_RADIUS` | 6 → 10 | 31.0s → 31.0s | 160s → 165s |
| `BIRD_HP` | 12 → 32 | 31.0s → 30.6s | 160s → 156s |
| `CATAPULT_COOLDOWN` | 6 → 9 | 31.5s → 31.0s | 160s → 155s |

Moving anti-air across its entire plausible range changes time-to-first-base
by under two seconds.

The cause is a timing fact the spec's search math does not model. §7 reasons
about how much a bird pass reveals versus how much anti-air can shoot down,
and that reasoning is correct — but it assumes the two are contemporaries.
They are not. The opening loadout is bought during setup, a perch is a
standard opening buy, and so the first bird launches at t ≈ 0. Nests cost 16
Coin and take `BUILD_SECONDS` to come up. **The flight that actually finds
the bases happens before any anti-air exists**, so anti-air's numbers cannot
contest it, no matter how large they are.

The spec's own numbers predict this once the timing is added: one pass
reveals ~288 of ~1,018 cells (28%), three bases occupy 27 cells, so a single
uncontested pass finds at least one base about 63% of the time. First base
found ≈ first bird flown, and the first bird is free of opposition.

So the levers that actually move discovery are the ones that change what a
*single early pass* is worth (`BIRD_LANE_WIDTH`) and how soon a second one
can be afforded (perch `charge_cost`), not the ones that contest passes that
arrive later. Hence the third sweep grid (`Sweep.PACING`). Anti-air is not
useless — it shapes the *middle* of the match, where re-probing happens —
but it is not the primary lever on the primary metric, and tuning it first
is tuning the wrong thing.

That conclusion stands. The reasoning that produced it was half right: see
§3.3 for the part that failed its test, and §3.6 for the part that replaced
it.

**Recommendation:** treat `BIRD_LANE_WIDTH` and perch charge cost as the
first-order search levers. Keep anti-air as the second-order lever it
measurably is. A design fix worth considering instead of a tuning one:
forbid buying a perch during setup, which would restore the spec's intended
ordering by making the first flight arrive after the first nests.

### 3.2 Secondary findings from the first grid

- **`scout` is the strongest archetype**, top of the field in 26 of 54
  cells, peaking at 0.84 against the field where the gate is 0.60. Consistent
  with §1's "information is the resource", but currently past the point of
  being a choice.
- **Decoy ROI is 0.73**, below 1.0, which by §11.3's own reading makes
  decoys a trap at current costs. Worth a cost cut or a second decoy tier
  before ship.
- **Every weapon is bought** (share: grove 29%, catapult 25%, nest 23%,
  decoy 12%, perch 10%), so nothing in the roster is miscosted to the point
  of never being taken.
- **Match length is 150–170s against an 8–12 minute target** (§1). This is
  not an anti-air problem; it is a total-HP-versus-fire-rate problem. Three
  bases at 40 HP against 8 damage is 15 hits, and Charge regen allows ~10
  shots a minute, so ~90s of firing ends a match.

### 3.3 A hypothesis I wrote down, tested, and had to throw away

§3.1 above ends with a proposed design fix: forbid buying a perch during
setup, so the first bird arrives after the first nests and anti-air has
something to contest. That is a plausible story and it is wrong.

It was tested properly rather than adopted. `SETUP_ALLOWS_RECON` was added
as a config flag (default `true`, the spec's behaviour) and swept as a
*dimension* against base HP × Charge regen × lane width — 36 cells, 18 with
the opening perch allowed and 18 with it barred, otherwise identical:

| | median time-to-first-base | as % of match | median match length |
|---|---|---|---|
| perch buyable in setup | 39.6s | 8.5% | 482s |
| perch barred from setup | 40.5s | 8.5% | 496s |

Paired cell by cell, barring recon from the opening loadout changes
time-to-first-base by a **median of −0.5s** (range −14.8s to +20.0s). It is
not a fix; it is not even an effect.

The reason is obvious in hindsight and is the actual finding: agents denied
an opening perch simply buy one in the first seconds of combat instead. A
perch is 14 Coin against 40 starting Coin and a 4s build, so the first bird
flies at t ≈ 8s rather than t ≈ 0. Discovery time is not set by when recon
becomes *legal*; it is set by how long it takes to get one bird over the
island, which is a handful of seconds either way.

The deeper version of the finding, which survived every grid: **a single
bird pass is decisive whenever it happens.** A lane 8 cells wide crossing a
36-cell island overlaps a given 3×3 base's rows with probability ≈ 0.3, so
across three bases one uncontested pass finds something about two times in
three. Nothing that delays or contests *later* passes can matter much when
the first one usually settles it.

### 3.4 Match length is solved; the ratio is not

The pacing and recon grids did fix the §1 match-length target. 15 of the 36
recon-grid cells land a median match between 8 and 12 minutes, with base HP
around 90–200 and Charge regen around 7–11s, and they do it with healthy
comeback rates (0.45–0.55) rather than by making matches drag.

But raising match length makes the §11.3 ratio *worse*, not better, because
time-to-first-base does not move with it: a constant ~40s becomes a smaller
fraction of a longer match. Across four grids and 180 configurations,
time-to-first-real-base stayed between roughly 30 and 50 seconds no matter
which lever moved.

That means the 25–45% window and the 8–12 minute window are, with these
mechanics, close to mutually exclusive. Satisfying both requires first base
at 120–320s. The only configurations that ever put the ratio in window were
ones where the *match* was short (a 148s match with first base at 46s is
31%) — which fails §1 instead.

So the recommendation is a design one, not a tuning one, and it is the
reason §2 of this document now lists lane width as a perch stat: **intel has
to scale with the match.** If the opening lane is narrow and widens only
with purchased upgrades, early discovery is poor, late discovery is good,
and time-to-first-base can grow with match length instead of staying pinned
to the first minute. §5 already allows this — `reveal_size` is explicitly
listed among the stats an upgrade may modify — it simply was not wired up,
because lane width was reading a global instead of the perch's own stat.

### 3.5 Scaling intel moves the right dial, but not far enough

With lane width wired to the perch's tier-aware `reveal_size` (§2 above),
the fifth grid swept what a tier-0 pass is worth — 36 cells over lane width
× perch cooldown × base HP × Charge regen:

| tier-0 lane width | time to first base | as % of match | top archetype | decoy ROI |
|---|---|---|---|---|
| 8 (the spec's value) | 37.9s | 9.7% | 0.71 | 0.75 |
| 5 | 44.1s | 10.4% | 0.63 | 0.77 |
| 3 | 48.0s | 10.8% | 0.65 | 0.78 |

Every column moves the right way, monotonically: narrowing the opening lane
delays discovery, flattens archetype dominance toward the 0.60 gate, and
lifts decoy ROI toward the 1.0 mark below which §11.3 calls decoys a trap.
It is the first lever in five grids that moves more than one metric in the
intended direction at once.

The best single cell found so far — tier-0 lane 3, perch cooldown 14, base
HP 140, Charge regen 11s — misses **only one gate**: 577s matches inside
the §1 window, top archetype at 0.56 against a 0.60 gate, 43% comebacks,
20% timeouts, decoy ROI 0.80. The one gate it misses is the first-base
window, at 10.2% against a target of 25%.

So the direction is established and the magnitude is not. Reaching 25% of a
577s match means first base near 145s, and the narrowest lane tested still
lands at 59s. The sixth grid (`lune run sweep narrow`) takes the lever to
its limit — lane widths 1, 2 and 3, where a width of 1 is a bird that
reveals only its exact flight line, the same rule every other projectile
already follows.

### 3.6 The lever saturates, and that is the real answer

Taking bird lane width to its limit does not keep working. Across the sixth
grid:

| tier-0 lane width | time to first base |
|---|---|
| 8 (the spec's value) | 37.9s |
| 5 | 44.1s |
| 3 | ~47s |
| 2 | 62.2s |
| 1 | 63.0s |

Widths 2 and 1 are indistinguishable. A bird that reveals a single cell of
its flight line is as good at finding bases as one that reveals a
three-wide lane, which only makes sense if by then the bases are not being
found by birds at all.

They are not. **Intel reaches a player through three independent channels**,
and the spec's §7 search math only models the first:

1. bird lanes — `BIRD_LANE_WIDTH` / the perch's `reveal_size`
2. catapult impact circles — ~28 cells per shot at `reveal_size` 3
3. projectile flight lines — every shot traces its whole path over the
   enemy island

Throttle one and discovery simply moves to the others. That is why five
grids of single-lever tuning all hit the same ~40-60s floor: the floor is
not set by the lever being moved, it is set by whichever channel is left.
It also explains §3.1 — anti-air contests channel 1 only, and channels 2
and 3 ride on catapult fire, which nests cannot touch at all.

The seventh grid (`lune run sweep floor`) throttles all three at once. It
exists to answer the question the first six could not: whether the §11.3
window is reachable in principle, or unreachable one lever at a time
because it was never a one-lever problem.

Wiring this up also turned up dead config: `FLIGHT_LINE_REVEAL_WIDTH` was
declared, documented and never read — channel 3 was hardcoded. It is a real
knob now.

### 3.7 Status of the sweep

Four grids have been run, 180 configurations and roughly 22,000 matches:

| grid | what it moved | result |
|---|---|---|
| `first` | the §11.5 anti-air lever | 0/54 survive; the lever is inert (§3.1) |
| `pacing` | lane width, base HP, Charge regen, perch cost | 0/54 survive; match length responds, the ratio does not |
| `recon` | recon-in-setup, as a controlled A/B | hypothesis refuted (§3.3) |
| `intel` | tier-0 lane width, perch cooldown, base HP, Charge regen | 0/36 survive, but every metric moves the right way (§3.5) |
| `narrow` | lane widths 1–3, base HP, Charge regen | the lever saturates at ~62s (§3.6) |
| `floor` | all three reveal channels at once | the reachability test |

Per §11.5 the sweep narrows and does not decide. **No shipping config has
been chosen**, and `config.luau` still holds the spec's stated defaults, so
the numbers in the repo match the numbers in the document. What the sweep
has produced is the thing it exists to produce: the knowledge that two of
the spec's acceptance targets are in tension, which lever is actually load-
bearing, and one design change that could reconcile them — to be decided by
a human, after playtesting, not by this run.

---

## 4. Smaller calls, recorded for completeness

- **Tiebreak on Coin spent goes to the bigger spender.** §6 names the chain
  (bases, then structures, then Coin spent) but not the direction. Awarding
  it to the player who spent more gives the timeout to the aggressor, which
  is the right incentive for a game whose failure mode is two players
  turtling to the cap.
- **Bases complete instantly; everything else takes `BUILD_SECONDS`.** Bases
  are pre-placed during setup and free, so a build timer on them would only
  add a way to run out the setup clock.
- **`STARTING_CHARGE = 2`.** Not specified. Zero would mean the first six
  seconds of combat are dead for both players; two lets an opening bird or
  two opening shots happen immediately.
- **Belief plots carry a server-only `structId`.** It never leaves the
  server — `Rules.viewFor` strips it — but it lets the server answer "is
  this plot still the same structure" without a second lookup.
  `fog_spec.luau` asserts the client copy has no `structId`.
- **`timesFooledByDecoy` is withheld until the match ends.** §6 lists it as
  an end-screen stat; sending it live would let a player detect a decoy from
  the HUD, defeating the thing it counts.
- **Nest reveal is permanent, not momentary.** A nest that fires plots its
  own cell for the bird's owner, and that plot is stale like any other — so
  a nest that is later bulldozed still shows on the attacker's map. This is
  the §7 behaviour applied consistently rather than a special case.
- **Lune is not vendored.** The repo assumes `lune` on PATH (built against
  0.10.4). Adding a binary to the repo would violate "no external
  dependencies beyond Rojo and Lune" more than requiring the tool does.
