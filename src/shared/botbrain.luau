--!strict
-- botbrain.luau — the bot opponent's finite state machine (SPEC §9).
--
-- Pure Luau, and deliberately NOT a Roblox script: the bot is shipping
-- scope, so it gets the same headless test coverage and the same sim
-- harness runs as everything else. src/server/Bot.luau is only the clock
-- that drives it.
--
-- The bot plays by identical rules — same costs, same cooldowns — and by
-- its OWN fog. Its knowledge of the player's island comes only from the
-- view it is handed, which is the same Rules.viewFor payload a human
-- client gets. There is no path from here to true player state, which is
-- also why decoys genuinely fool it: a decoy's death feedback is
-- indistinguishable from a real kill, so the bot's target count is a
-- belief, and it stops shelling a site it believes is dead.

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

local Agent = import("agent")
local Grid = import("grid")

local BotBrain = {}

-- Phase minimums the REBUILD interleave restores before anything else.
local PHASE_MINIMUMS = {
	grove = 2,
	nest = 1,
	perch = 1,
	catapult = 2,
}

-- Setup build order from SPEC §9 FOUNDATION, after the three bases.
local OPENING = { "grove", "grove", "catapult", "nest", "perch" }

local BASE_KINDS = { base = true }
local NEST_KINDS = { nest = true }
local GROVE_KINDS = { grove = true }

----------------------------------------------------------------------------
-- Setup (FOUNDATION)
----------------------------------------------------------------------------

-- Bases go far apart and at least one hugs an obstacle, so a lucky sweep
-- of the island's middle doesn't hand over all three at once.
local function placeBase(view: any, config: any, memory: any): any?
	local existing = {}
	for _, s in view.structures do
		if s.kind == "base" then
			table.insert(existing, { s.x, s.y, 11 })
		end
	end

	if #existing == 0 then
		for key in view.island.obstacles do
			local ox, oy = Grid.parseKey(key)
			for _, delta in { { 2, 0 }, { -3, 0 }, { 0, 2 }, { 0, -3 }, { 2, 2 }, { -3, -3 } } do
				local x, y = ox + delta[1], oy + delta[2]
				if Agent.cellFree(view, config, "base", x, y) then
					return { type = "place_base", x = x, y = y }
				end
			end
		end
	end

	local d = config.ISLAND_DIAMETER
	local site = Agent.findSite(view, config, "base", { 2, d - 3 }, memory, existing)
	if not site then
		-- Fall back to any legal cell rather than forfeiting a base.
		site = Agent.findSite(view, config, "base", { 1, d }, memory, nil)
	end
	if site then
		return { type = "place_base", x = site[1], y = site[2] }
	end
	return nil
end

local function bandFor(kind: string): string
	if kind == "catapult" or kind == "perch" then
		return "shore"
	elseif kind == "nest" then
		return "mid"
	elseif kind == "grove" then
		return "inland"
	end
	return "any"
end

local function placeCommand(view: any, config: any, memory: any, kind: string): any?
	local avoid = {}
	if kind == "decoy_base" then
		-- A decoy next to a real base teaches the enemy where the real one
		-- is, so decoys are kept well clear of them.
		for _, s in view.structures do
			if s.kind == "base" then
				table.insert(avoid, { s.x, s.y, 9 })
			end
		end
	end
	local site = Agent.findSite(view, config, kind, Agent.band(config, bandFor(kind)), memory, avoid)
	if site then
		return { type = "place", kind = kind, x = site[1], y = site[2] }
	end
	return nil
end

local function setupDecision(view: any, config: any, memory: any): any?
	if view.basesPlaced < config.BASES_PER_PLAYER then
		return placeBase(view, config, memory)
	end
	-- One decoy, spaced away from the real bases (SPEC §9 FOUNDATION).
	if not memory.openingDecoyPlaced and Agent.canAfford(view, config, "decoy_base") then
		local cmd = placeCommand(view, config, memory, "decoy_base")
		if cmd then
			memory.openingDecoyPlaced = true
			return cmd
		end
		memory.openingDecoyPlaced = true
	end
	local index = memory.openingIndex or 1
	while index <= #OPENING do
		local kind = OPENING[index]
		if not Agent.canAfford(view, config, kind) then
			break
		end
		-- Recon may be barred from the opening loadout (see config).
		if not config.SETUP_ALLOWS_RECON and config.WEAPONS[kind].role == "find" then
			index += 1
			memory.openingIndex = index
			continue
		end
		local cmd = placeCommand(view, config, memory, kind)
		memory.openingIndex = index + 1
		if cmd then
			return cmd
		end
		index += 1
	end
	return { type = "ready" }
end

----------------------------------------------------------------------------
-- Phase selection (hysteresis, not hard gates — SPEC §9)
----------------------------------------------------------------------------

-- Is a nest believed live near the straight lane from `shooter` to the
-- target? The bot only commits to a kill when it thinks the lane is clear;
-- this is what makes SUPPRESS worth doing rather than skippable.
local function laneLooksClear(view: any, config: any, memory: any, tx: number, ty: number): boolean
	local threat = config.WEAPONS.nest.range + 1
	for _, cell in Agent.plotted(view, NEST_KINDS, memory, true) do
		if Grid.dist(cell[1], cell[2], tx, ty) <= threat then
			return false
		end
	end
	return true
end

function BotBrain.choosePhase(view: any, config: any, memory: any): string
	local hasBaseTarget = #Agent.plotted(view, BASE_KINDS, memory) > 0
	local nestsPlotted = #Agent.plotted(view, NEST_KINDS, memory) > 0
	local coverage = Agent.coverage(view, config)

	-- REBUILD is interleaved, not a phase the bot sits in: it is checked
	-- first every tick and only pre-empts when something is genuinely below
	-- its minimum.
	for kind, minimum in PHASE_MINIMUMS do
		if Agent.countOwn(view, kind) < minimum and Agent.canAfford(view, config, kind) then
			return "REBUILD"
		end
	end

	-- Hysteresis: once in KILL the bot stays there while it still has a
	-- target, instead of flapping back to SCOUT every time coverage dips.
	if hasBaseTarget then
		if memory.phase == "KILL" then
			return "KILL"
		end
		if laneLooksClear(view, config, memory, 0, 0) or not nestsPlotted then
			return "KILL"
		end
		return "SUPPRESS"
	end

	if nestsPlotted and (memory.birdLossStreak > 0 or coverage > 0.35) then
		return "SUPPRESS"
	end
	return "SCOUT"
end

----------------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------------

local function tryScout(view: any, config: any, memory: any, difficulty: any): any?
	if view.time < memory.nextScoutTime then
		return nil
	end
	local perches = Agent.ownStructures(view, "perch", true)
	if #perches == 0 or view.charge < config.WEAPONS.perch.charge_cost then
		return nil
	end
	-- Center first, then sweep outward: Agent.bestLane already biases to
	-- the center and scores lanes by unexplored ground.
	local lane = Agent.bestLane(view, config, memory, difficulty.laneRepeatAfter, difficulty.minLaneValue)
	if not lane then
		return nil
	end
	memory.lanesFlown[lane] = view.time
	return { type = "launch_bird", structId = perches[1].id, laneY = lane }
end

local function tryFireAt(view: any, config: any, memory: any, kinds: any): any?
	if view.charge < config.WEAPONS.catapult.charge_cost then
		return nil
	end
	for _, cell in Agent.plotted(view, kinds, memory) do
		local cmd = Agent.fireAt(view, config, memory, cell[1], cell[2])
		if cmd then
			return cmd
		end
	end
	return nil
end

local function tryRebuild(view: any, config: any, memory: any): any?
	-- Cheapest shortfall first, so one lost grove doesn't stall the bot
	-- while it saves for a nest.
	local best, bestCost = nil, math.huge
	for kind, minimum in PHASE_MINIMUMS do
		if Agent.countOwn(view, kind) < minimum then
			local cost = config.WEAPONS[kind].coin_cost
			if cost <= view.coin and cost < bestCost then
				best, bestCost = kind, cost
			end
		end
	end
	if best then
		return placeCommand(view, config, memory, best)
	end
	return nil
end

-- Beyond the minimums, the bot expands toward a balanced board rather than
-- massing one weapon: SPEC §1 — birds find, catapults kill, nests blind,
-- and it needs all three legs.
local EXPANSION = {
	{ kind = "grove", cap = 5 },
	{ kind = "catapult", cap = 5 },
	{ kind = "nest", cap = 3 },
	{ kind = "perch", cap = 2 },
	{ kind = "decoy_base", cap = 2 },
}

local function tryExpand(view: any, config: any, memory: any): any?
	for _, entry in EXPANSION do
		if Agent.countOwn(view, entry.kind) < entry.cap and Agent.canAfford(view, config, entry.kind) then
			local cmd = placeCommand(view, config, memory, entry.kind)
			if cmd then
				return cmd
			end
		end
	end
	-- Nothing left to build: bank it into upgrades, cheapest first.
	local best, bestCost = nil, math.huge
	for _, s in view.structures do
		local def = config.WEAPONS[s.kind]
		if s.buildRemaining <= 0 and s.tier < #def.upgrades then
			local cost = def.upgrades[s.tier + 1].coin_cost
			if cost <= view.coin and cost < bestCost then
				best, bestCost = s, cost
			end
		end
	end
	if best then
		return { type = "upgrade", structId = best.id }
	end
	return nil
end

----------------------------------------------------------------------------
-- Public interface (identical shape to a sim archetype)
----------------------------------------------------------------------------

function BotBrain.difficulty(config: any, preset: string)
	local p = config.BOT_PRESETS[preset] or config.BOT_PRESETS.skirmish
	return {
		name = preset,
		decisionSeconds = p.decision_seconds,
		coinMultiplier = p.coin_multiplier,
		-- Easy is fooled by a decoy forever; hard re-probes a site it
		-- believes it killed after this many seconds (SPEC §9).
		reprobeAfter = p.reprobe_after,
		laneRepeatAfter = 90,
		minLaneValue = 90,
	}
end

function BotBrain.decide(view: any, memory: any, ctx: any): any?
	local config = ctx.config
	local difficulty = ctx.difficulty or BotBrain.difficulty(config, "skirmish")

	if view.phase == "setup" then
		return setupDecision(view, config, memory)
	elseif view.phase ~= "combat" then
		return nil
	end

	Agent.forgetOldKills(memory, view.time, difficulty.reprobeAfter)
	local phase = BotBrain.choosePhase(view, config, memory)
	memory.phase = phase

	if phase == "REBUILD" then
		local cmd = tryRebuild(view, config, memory)
		if cmd then
			return cmd
		end
	end

	if phase == "KILL" then
		local cmd = tryFireAt(view, config, memory, BASE_KINDS)
		if cmd then
			return cmd
		end
	end

	if phase == "SUPPRESS" or phase == "KILL" then
		local cmd = tryFireAt(view, config, memory, NEST_KINDS)
		if cmd then
			return cmd
		end
	end

	local scout = tryScout(view, config, memory, difficulty)
	if scout then
		return scout
	end

	-- Bombard plotted groves when there is nothing better: it is the reason
	-- bombardment is worth doing before a base has been found (SPEC §5).
	if phase == "SUPPRESS" then
		local cmd = tryFireAt(view, config, memory, GROVE_KINDS)
		if cmd then
			return cmd
		end
	end

	return tryExpand(view, config, memory)
end

-- Packages the brain as a sim-harness agent so the shipping bot can be run
-- against the scripted archetypes, not just against a human.
function BotBrain.asAgent(preset: string)
	return {
		name = "bot_" .. preset,
		preset = preset,
		newMemory = function(seed: number)
			local memory = Agent.newMemory(seed)
			memory.openingIndex = 1
			memory.openingDecoyPlaced = false
			return memory
		end,
		decide = function(view: any, memory: any, ctx: any): any?
			local difficulty = BotBrain.difficulty(ctx.config, preset)
			return BotBrain.decide(view, memory, { config = ctx.config, difficulty = difficulty })
		end,
		observe = function(memory: any, events: { any }, now: number)
			Agent.observeEvents(memory, events, now)
		end,
	}
end

return BotBrain
