--!strict
-- rules.luau — the pure game core: step(state, commands, dt) -> state, events.
--
-- Pure Luau, zero Roblox APIs. `step` never mutates its input (it clones and
-- delegates to `stepMut`). The headless sim harness may call `stepMut`
-- directly for speed — identical logic, documented in DECISIONS.md.
--
-- Everything the server and the sim agree on lives here: phases, command
-- validation, build timers, economy, projectiles, fog, win detection.

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

local Config = import("config")
local Grid = import("grid")
local State = import("state")
local Economy = import("economy")
local Weapons = import("weapons")
local Fog = import("fog")

local Rules = {}

export type Command = {
	player: number,
	type: string, -- "place_base" | "place" | "bulldoze" | "upgrade"
	--            | "fire" | "launch_bird" | "ready"
	kind: string?, -- for "place"
	x: number?,
	y: number?,
	structId: number?,
	laneY: number?,
}

function Rules.newMatch(config: any?, seed: number): State.MatchState
	return State.newMatch(config or Config, seed)
end

----------------------------------------------------------------------------
-- Validation (shared verbatim by the server's CommandHandler — SPEC §8)
----------------------------------------------------------------------------

local function ownedUsableStruct(player: State.Player, structId: number?): (State.Structure?, string?)
	if type(structId) ~= "number" then
		return nil, "missing structId"
	end
	local s = player.structures[structId]
	if not s or not s.alive then
		return nil, "no such structure"
	end
	return s, nil
end

local function canPlaceAt(player: State.Player, kind: string, x: number, y: number, config: any): (boolean, string?)
	local def = config.WEAPONS[kind]
	if not def then
		return false, "unknown kind"
	end
	if type(x) ~= "number" or type(y) ~= "number" or x ~= math.floor(x) or y ~= math.floor(y) then
		return false, "bad cell"
	end
	for _, cell in Grid.footprintCells(x, y, def.footprint) do
		if not Grid.isBuildableGround(player.island, cell[1], cell[2]) then
			return false, "not buildable"
		end
		if player.occ[Grid.key(cell[1], cell[2])] then
			return false, "occupied"
		end
	end
	return true, nil
end

-- Validates a command against the current state WITHOUT applying it.
-- The server calls this for every remote request; the sim calls it for
-- every agent command. Returns (ok, error).
function Rules.validateCommand(state: State.MatchState, cmd: Command): (boolean, string?)
	local config = state.config
	local player = state.players[cmd.player]
	if not player then
		return false, "bad player"
	end
	if state.phase == "ended" then
		return false, "match over"
	end

	if cmd.type == "ready" then
		if state.phase ~= "setup" then
			return false, "not setup"
		end
		return true, nil
	elseif cmd.type == "place_base" then
		if state.phase ~= "setup" then
			return false, "bases place during setup only"
		end
		if player.basesPlaced >= config.BASES_PER_PLAYER then
			return false, "all bases placed"
		end
		return canPlaceAt(player, "base", cmd.x :: number, cmd.y :: number, config)
	elseif cmd.type == "place" then
		local kind = cmd.kind
		if type(kind) ~= "string" or kind == "base" then
			return false, "bad kind"
		end
		local purchasable = false
		for _, id in config.PURCHASABLE do
			if id == kind then
				purchasable = true
			end
		end
		if not purchasable then
			return false, "not purchasable"
		end
		if player.coin < config.WEAPONS[kind].coin_cost then
			return false, "cannot afford"
		end
		if
			state.phase == "setup"
			and not config.SETUP_ALLOWS_RECON
			and config.WEAPONS[kind].role == "find"
		then
			return false, "no recon in the opening loadout"
		end
		return canPlaceAt(player, kind, cmd.x :: number, cmd.y :: number, config)
	elseif cmd.type == "bulldoze" then
		local s, err = ownedUsableStruct(player, cmd.structId)
		if not s then
			return false, err
		end
		if s.kind == "base" then
			return false, "cannot bulldoze a base"
		end
		return true, nil
	elseif cmd.type == "upgrade" then
		local s, err = ownedUsableStruct(player, cmd.structId)
		if not s then
			return false, err
		end
		if s.buildRemaining > 0 then
			return false, "under construction"
		end
		local def = config.WEAPONS[s.kind]
		if s.tier >= #def.upgrades then
			return false, "max tier"
		end
		if player.coin < def.upgrades[s.tier + 1].coin_cost then
			return false, "cannot afford"
		end
		return true, nil
	elseif cmd.type == "fire" or cmd.type == "launch_bird" then
		if state.phase ~= "combat" then
			return false, "combat only"
		end
		local s, err = ownedUsableStruct(player, cmd.structId)
		if not s then
			return false, err
		end
		if s.buildRemaining > 0 then
			return false, "under construction"
		end
		if s.cooldownRemaining > 0 then
			return false, "cooling down"
		end
		local def = config.WEAPONS[s.kind]
		if player.charge < def.charge_cost then
			return false, "no charge"
		end
		local d = config.ISLAND_DIAMETER
		if cmd.type == "fire" then
			if def.role ~= "kill" then
				return false, "not a firing weapon"
			end
			local tx, ty = cmd.x, cmd.y
			if type(tx) ~= "number" or type(ty) ~= "number" or tx < 1 or ty < 1 or tx > d or ty > d then
				-- Any board cell is a legal target, island or water — the
				-- attacker cannot see the shoreline through fog, so target
				-- validation must not leak it (SPEC §7).
				return false, "target off board"
			end
			local range = Weapons.getStat(config, s.kind, s.tier, "range")
			if Grid.attackDistance(config, s.x, s.y, tx, ty) > range then
				return false, "out of range"
			end
			return true, nil
		else
			if def.role ~= "find" then
				return false, "not a perch"
			end
			local laneY = cmd.laneY
			if type(laneY) ~= "number" or laneY < 1 or laneY > d or laneY ~= math.floor(laneY) then
				return false, "bad lane"
			end
			return true, nil
		end
	end
	return false, "unknown command"
end

----------------------------------------------------------------------------
-- Application
----------------------------------------------------------------------------

local function addStructure(
	state: State.MatchState,
	player: State.Player,
	kind: string,
	x: number,
	y: number,
	buildTime: number
): State.Structure
	local config = state.config
	local def = config.WEAPONS[kind]
	local s: State.Structure = {
		id = state.nextStructId,
		kind = kind,
		x = x,
		y = y,
		hp = buildTime > 0 and def.hp * def.max_hp_building_factor or def.hp,
		maxHp = def.hp,
		tier = 0,
		buildRemaining = buildTime,
		cooldownRemaining = 0,
		alive = true,
		revealedNest = false,
	}
	state.nextStructId += 1
	player.structures[s.id] = s
	for _, cell in Grid.footprintCells(x, y, def.footprint) do
		local key = Grid.key(cell[1], cell[2])
		player.occ[key] = s.id
		-- Building over old rubble clears it — the ground is in use again.
		player.island.rubble[key] = nil
	end
	if kind == "base" then
		player.basesAlive += 1
		player.basesPlaced += 1
	end
	return s
end

-- Applies an ALREADY-VALIDATED command.
local function applyCommand(state: State.MatchState, cmd: Command, events: { State.Event })
	local config = state.config
	local player = state.players[cmd.player]

	if cmd.type == "ready" then
		player.setupReady = true
	elseif cmd.type == "place_base" then
		-- Bases are pre-placed and free: complete immediately.
		local s = addStructure(state, player, "base", cmd.x :: number, cmd.y :: number, 0)
		table.insert(events, { type = "placed", visibleTo = player.index, structId = s.id, kind = "base" })
	elseif cmd.type == "place" then
		local def = config.WEAPONS[cmd.kind :: string]
		Economy.spendCoin(player, def.coin_cost)
		local s = addStructure(state, player, cmd.kind :: string, cmd.x :: number, cmd.y :: number, config.BUILD_SECONDS)
		table.insert(events, { type = "placed", visibleTo = player.index, structId = s.id, kind = s.kind })
	elseif cmd.type == "bulldoze" then
		local s = player.structures[cmd.structId :: number] :: State.Structure
		s.alive = false
		local def = config.WEAPONS[s.kind]
		for _, cell in Grid.footprintCells(s.x, s.y, def.footprint) do
			-- Bulldozing is clean: no rubble, the cell is simply free again.
			player.occ[Grid.key(cell[1], cell[2])] = nil
		end
		table.insert(events, { type = "bulldozed", visibleTo = player.index, structId = s.id, kind = s.kind })
	elseif cmd.type == "upgrade" then
		local s = player.structures[cmd.structId :: number] :: State.Structure
		local def = config.WEAPONS[s.kind]
		Economy.spendCoin(player, def.upgrades[s.tier + 1].coin_cost)
		s.tier += 1
		-- HP upgrades apply their delta to current HP too.
		local newMax = Weapons.getStat(config, s.kind, s.tier, "hp")
		if newMax ~= s.maxHp then
			s.hp += newMax - s.maxHp
			s.maxHp = newMax
		end
		table.insert(events, { type = "upgraded", visibleTo = player.index, structId = s.id, tier = s.tier })
	elseif cmd.type == "fire" then
		local s = player.structures[cmd.structId :: number] :: State.Structure
		local def = config.WEAPONS[s.kind]
		Economy.spendCharge(player, def.charge_cost)
		Weapons.fireCatapult(state, player, s, cmd.x :: number, cmd.y :: number, events)
	elseif cmd.type == "launch_bird" then
		local s = player.structures[cmd.structId :: number] :: State.Structure
		local def = config.WEAPONS[s.kind]
		Economy.spendCharge(player, def.charge_cost)
		Weapons.launchBird(state, player, s, cmd.laneY :: number, events)
	end
end

----------------------------------------------------------------------------
-- Phase transitions & win detection
----------------------------------------------------------------------------

local function autoPlaceMissingBases(state: State.MatchState, events: { State.Event })
	local config = state.config
	for _, player in state.players do
		local rng = State.rng(state)
		local guard = 0
		while player.basesPlaced < config.BASES_PER_PLAYER and guard < 5000 do
			guard += 1
			local d = config.ISLAND_DIAMETER
			local x = rng:nextInt(1, d - config.BASE_FOOTPRINT + 1)
			local y = rng:nextInt(1, d - config.BASE_FOOTPRINT + 1)
			local ok = canPlaceAt(player, "base", x, y, config)
			if ok then
				addStructure(state, player, "base", x, y, 0)
				table.insert(events, { type = "placed", visibleTo = player.index, kind = "base", auto = true })
			end
		end
		assert(player.basesPlaced >= config.BASES_PER_PLAYER, "auto-placement failed")
	end
end

function Rules.endMatch(state: State.MatchState, winner: number, reason: string, events: { State.Event })
	state.phase = "ended"
	state.winner = winner
	state.endReason = reason
	table.insert(events, { type = "match_ended", visibleTo = "all", winner = winner, reason = reason })
end

-- Tiebreak chain (SPEC §6): bases remaining, structures remaining, Coin
-- spent (more spent wins — the aggressor takes the timeout), else draw (0).
local function tiebreakWinner(state: State.MatchState): number
	local p1, p2 = state.players[1], state.players[2]
	if p1.basesAlive ~= p2.basesAlive then
		return p1.basesAlive > p2.basesAlive and 1 or 2
	end
	local function aliveCount(p: State.Player): number
		local n = 0
		for _, s in p.structures do
			if s.alive then
				n += 1
			end
		end
		return n
	end
	local a1, a2 = aliveCount(p1), aliveCount(p2)
	if a1 ~= a2 then
		return a1 > a2 and 1 or 2
	end
	if p1.stats.coinSpent ~= p2.stats.coinSpent then
		return p1.stats.coinSpent > p2.stats.coinSpent and 1 or 2
	end
	return 0
end

local function checkWin(state: State.MatchState, events: { State.Event })
	local p1, p2 = state.players[1], state.players[2]
	if p1.basesAlive <= 0 and p2.basesAlive <= 0 then
		Rules.endMatch(state, tiebreakWinner(state), "bases", events)
	elseif p2.basesAlive <= 0 then
		Rules.endMatch(state, 1, "bases", events)
	elseif p1.basesAlive <= 0 then
		Rules.endMatch(state, 2, "bases", events)
	elseif state.time >= state.config.MATCH_TIMEOUT then
		Rules.endMatch(state, tiebreakWinner(state), "timeout", events)
	end
end

----------------------------------------------------------------------------
-- Step
----------------------------------------------------------------------------

-- Mutating step: identical semantics to Rules.step but writes into `state`.
-- The public pure `step` wraps this with a clone; the headless harness may
-- call this directly for throughput.
function Rules.stepMut(state: State.MatchState, commands: { Command }, dt: number): (State.MatchState, { State.Event })
	local events: { State.Event } = {}
	local config = state.config

	if state.phase == "ended" then
		return state, events
	end

	-- 1. Commands (invalid ones are rejected with an event, never applied).
	for _, cmd in commands do
		local ok, err = Rules.validateCommand(state, cmd)
		if ok then
			applyCommand(state, cmd, events)
		else
			table.insert(events, {
				type = "command_rejected",
				visibleTo = cmd.player,
				command = cmd.type,
				reason = err,
			})
		end
	end

	state.time += dt

	-- 2. Build timers and cooldowns always advance.
	for _, player in state.players do
		for _, s in player.structures do
			if s.alive then
				if s.buildRemaining > 0 then
					s.buildRemaining = math.max(0, s.buildRemaining - dt)
					if s.buildRemaining == 0 then
						s.hp = s.maxHp -- construction completes at full HP
						table.insert(events, {
							type = "build_complete",
							visibleTo = player.index,
							structId = s.id,
							kind = s.kind,
						})
					end
				end
				if s.cooldownRemaining > 0 then
					s.cooldownRemaining = math.max(0, s.cooldownRemaining - dt)
				end
			end
		end
	end

	if state.phase == "setup" then
		state.setupRemaining -= dt
		local bothReady = state.players[1].setupReady and state.players[2].setupReady
		if state.setupRemaining <= 0 or bothReady then
			autoPlaceMissingBases(state, events)
			state.phase = "combat"
			state.time = 0 -- combat clock starts at zero
			table.insert(events, { type = "combat_started", visibleTo = "all" })
		end
		return state, events
	end

	-- 3. Combat: economy, projectiles, win check.
	Economy.tick(state, dt, events)
	Weapons.advanceProjectiles(state, dt, events)
	checkWin(state, events)

	return state, events
end

-- Pure step: clones the input, applies stepMut to the clone.
function Rules.step(state: State.MatchState, commands: { Command }, dt: number): (State.MatchState, { State.Event })
	local clone = State.deepClone(state)
	return Rules.stepMut(clone, commands, dt)
end

----------------------------------------------------------------------------
-- Fog-safe views (the ONLY sanctioned read path for clients, bots, agents)
----------------------------------------------------------------------------

-- Events a given player is allowed to see.
function Rules.filterEventsFor(events: { State.Event }, playerIndex: number): { State.Event }
	local out = {}
	for _, e in events do
		if e.visibleTo == "all" or e.visibleTo == playerIndex then
			table.insert(out, e)
		end
	end
	return out
end

-- A deep-copied, fog-filtered snapshot for one player. Contains that
-- player's full own state, their stale belief map of the enemy, and only
-- the enemy projectiles that are visibly over their island. It NEVER
-- contains unrevealed enemy data, the enemy's resources, or truth counters
-- that would expose decoys (SPEC §4, §5, §8).
function Rules.viewFor(state: State.MatchState, playerIndex: number)
	local config = state.config
	local player = state.players[playerIndex]
	local d = config.ISLAND_DIAMETER

	local belief = {}
	for key, plot in player.belief do
		-- structId is server-internal; strip it from anything that leaves.
		belief[key] = { t = plot.t, kind = plot.kind }
	end

	local structures = {}
	local occ = {}
	for id, s in player.structures do
		if s.alive then
			structures[id] = State.deepClone(s)
		end
	end
	-- Own-island occupancy: fully known to its owner, so safe to ship and
	-- needed by the build palette (and by any agent picking a legal cell).
	for key, id in player.occ do
		occ[key] = id
	end

	local myProjectiles = {}
	local incoming = {}
	for id, proj in state.projectiles do
		if proj.owner == playerIndex then
			myProjectiles[id] = { kind = proj.kind, x = proj.x, y = proj.y, hp = proj.hp, laneY = proj.laneY }
		elseif proj.x <= d then
			-- Enemy projectile over MY island: visibly incoming.
			incoming[id] = { kind = proj.kind, x = proj.x, y = proj.y, laneY = proj.laneY }
		end
	end

	return {
		playerIndex = playerIndex,
		time = state.time,
		phase = state.phase,
		setupRemaining = state.setupRemaining,
		winner = state.winner,
		coin = player.coin,
		charge = player.charge,
		basesAlive = player.basesAlive,
		basesPlaced = player.basesPlaced,
		setupReady = player.setupReady,
		island = State.deepClone(player.island),
		structures = structures,
		occ = occ,
		belief = belief,
		myProjectiles = myProjectiles,
		incomingProjectiles = incoming,
		-- The kill counter the player SEES — includes decoy fake-kills.
		baseKills = player.stats.believedBaseKills,
		-- Withheld until the match is over: showing a live count of decoy
		-- kills would defeat the deception it describes (SPEC §6 end
		-- screen).
		timesFooledByDecoy = state.phase == "ended" and player.stats.timesFooledByDecoy or nil,
		stats = {
			shotsFired = player.stats.shotsFired,
			birdsFlown = player.stats.birdsFlown,
			birdsLost = player.stats.birdsLost,
			cellsRevealed = player.stats.cellsRevealed,
			coinEarned = player.stats.coinEarned,
			coinSpent = player.stats.coinSpent,
			structuresLost = player.stats.structuresLost,
		},
	}
end

return Rules
