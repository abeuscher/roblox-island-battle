--!strict
-- state.luau — MatchState types + initializers. Pure Luau, no Roblox APIs.
-- One serializable table describes the whole match. rules.step consumes and
-- produces these; nothing outside src/shared may reach into internals the
-- fog would hide (Replication and viewFor are the only sanctioned readers).

-- Dual-target module loading: under Rojo/Roblox `script` exists and modules
-- are instances; under Lune `script` is nil and modules are files. Keeping
-- this shim here is what lets the identical pure core run in both places
-- with no build step (see DECISIONS.md).
local function import(name: string): any
	if script ~= nil then
		return require((script :: any).Parent[name])
	end
	return require("./" .. name)
end

local Grid = import("grid")

export type Structure = {
	id: number, -- unique per match
	kind: string, -- weapon id: "base", "grove", ...
	x: number, -- anchor (top-left) cell, island-local
	y: number,
	hp: number,
	maxHp: number,
	tier: number, -- 0 = base weapon, 1..2 = purchased upgrades
	buildRemaining: number, -- seconds; 0 = construction complete
	cooldownRemaining: number,
	alive: boolean,
	revealedNest: boolean, -- a nest that has fired and given itself away
}

export type BeliefPlot = {
	t: number, -- match time the cell was last revealed
	-- what the attacker saw there AT REVEAL TIME (stale thereafter):
	-- "empty" | "rubble" | "obstacle" | a structure kind ("decoy_base"
	-- is never plotted — decoys plot as "base", SPEC §7)
	kind: string,
	structId: number?, -- defender's structure id if one was seen (server-only info)
}

export type PlayerStats = {
	shotsFired: number,
	birdsFlown: number,
	birdsLost: number,
	cellsRevealed: number,
	timesFooledByDecoy: number, -- decoys of the ENEMY that this player "killed"
	coinEarned: number,
	coinSpent: number,
	structuresLost: number,
	believedBaseKills: number, -- includes decoy fake-kills
	realBaseKills: number,
}

export type Player = {
	index: number, -- 1 or 2
	coin: number,
	charge: number,
	coinAcc: number, -- fractional-tick accumulators
	chargeAcc: number,
	island: Grid.Island,
	structures: { [number]: Structure },
	-- occupancy index: cell key -> structure id (kept in sync by rules)
	occ: { [string]: number },
	basesAlive: number,
	basesPlaced: number,
	setupReady: boolean,
	-- belief map of the ENEMY island, cell key -> stale plot
	belief: { [string]: BeliefPlot },
	stats: PlayerStats,
	disconnectTimer: number?, -- counts up while disconnected (server sets)
	-- Income scaling, used only by bot difficulty presets (SPEC §9). The
	-- bot plays by identical rules; this is the one dial that differs, and
	-- it runs through the economy like everything else rather than around
	-- it. Always 1 for human players.
	coinMultiplier: number,
}

export type Projectile = {
	id: number,
	kind: string, -- "coconut" | "bird"
	owner: number, -- attacking player index
	-- Position is tracked in the DEFENDER island's local frame (x > diameter
	-- means still over the channel). Coconuts fly a straight line to their
	-- target; birds fly a fixed lane in -x at laneY.
	x: number,
	y: number,
	spawnX: number?, -- coconut launch point (for the flight-line reveal)
	spawnY: number?,
	targetX: number?, -- coconut only
	targetY: number?,
	dirX: number?, -- coconut unit direction
	dirY: number?,
	laneY: number?, -- bird only
	speed: number,
	hp: number, -- birds only (coconuts are not interceptable)
	damage: number,
	splash: number,
	revealSize: number,
	lastRevealX: number?, -- birds: frontier of the live lane reveal
	sourceStructId: number,
}

export type MatchState = {
	seed: number,
	config: any, -- the (possibly overridden) config table used by this match
	time: number,
	phase: string, -- "setup" | "combat" | "ended"
	setupRemaining: number,
	winner: number?, -- 1 | 2 | 0 (draw), set when phase == "ended"
	endReason: string?, -- "bases" | "timeout" | "disconnect"
	players: { Player },
	projectiles: { [number]: Projectile },
	nextStructId: number,
	nextProjId: number,
	rngState: number, -- deterministic in-match RNG (auto-placement etc.)
}

export type Event = {
	type: string,
	-- who may see this event: "all", or a player index (1 | 2)
	visibleTo: number | string,
	[string]: any,
}

local State = {}

function State.deepClone(t: any): any
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in t do
		out[k] = State.deepClone(v)
	end
	return out
end

local function newStats(): PlayerStats
	return {
		shotsFired = 0,
		birdsFlown = 0,
		birdsLost = 0,
		cellsRevealed = 0,
		timesFooledByDecoy = 0,
		coinEarned = 0,
		coinSpent = 0,
		structuresLost = 0,
		believedBaseKills = 0,
		realBaseKills = 0,
	}
end

local function newPlayer(index: number, config: any, seed: number): Player
	return {
		index = index,
		coin = config.STARTING_COIN,
		charge = config.STARTING_CHARGE,
		coinAcc = 0,
		chargeAcc = 0,
		-- Same seed for both players: identical (mirror-fair) layouts.
		island = Grid.generateIsland(config, seed),
		structures = {},
		occ = {},
		basesAlive = 0,
		basesPlaced = 0,
		setupReady = false,
		belief = {},
		stats = newStats(),
		disconnectTimer = nil,
		coinMultiplier = 1,
	}
end

function State.newMatch(config: any, seed: number): MatchState
	return {
		seed = seed,
		config = config,
		time = 0,
		phase = "setup",
		setupRemaining = config.SETUP_SECONDS,
		winner = nil,
		endReason = nil,
		players = { newPlayer(1, config, seed), newPlayer(2, config, seed) },
		projectiles = {},
		nextStructId = 1,
		nextProjId = 1,
		rngState = (seed * 7919 + 17) % 4294967296,
	}
end

-- In-match deterministic RNG (used for auto-placement on setup timeout).
function State.rng(state: MatchState): Grid.Rng
	local rng = Grid.makeRng(state.rngState)
	-- persist advanced state back so successive calls differ
	state.rngState = (state.rngState * 1103515245 + 12345) % 4294967296
	return rng
end

function State.enemyOf(state: MatchState, playerIndex: number): Player
	return state.players[3 - playerIndex]
end

function State.structureAt(player: Player, x: number, y: number): Structure?
	local id = player.occ[Grid.key(x, y)]
	if id then
		return player.structures[id]
	end
	return nil
end

-- Counts completed, alive structures of a kind.
function State.countKind(player: Player, kind: string, includeBuilding: boolean?): number
	local n = 0
	for _, s in player.structures do
		if s.alive and s.kind == kind and (includeBuilding or s.buildRemaining <= 0) then
			n += 1
		end
	end
	return n
end

return State
