--!strict
-- common.luau — the shared body of every scripted archetype.
--
-- An archetype is DATA (a build order plus a handful of policy weights)
-- over this one interpretable decision function. That is deliberate
-- (SPEC §11.2): when an archetype dominates the round robin you can point
-- at the constant that caused it, which a learned agent would never let
-- you do.
--
-- Every archetype sees only a fog-filtered view. There is no argument here
-- through which true enemy state could arrive.

local Agent = require("../../src/shared/agent")
local Grid = require("../../src/shared/grid")

local Common = {}

export type Policy = {
	name: string,
	-- Setup purchases, in order, spent from STARTING_COIN.
	openingBuild: { string },
	-- Combat build order, cycled: the agent buys the first entry it can
	-- afford whose live count is below the cap.
	buildOrder: { { kind: string, cap: number, band: string } },
	-- Fire at plotted bases as soon as one is known?
	killOnSight: boolean,
	-- Coverage fraction below which the agent refuses to spend charge on
	-- kill fire (a scout wants the map open first).
	coverageBeforeKill: number,
	-- Shell plotted nests to open flight lanes?
	suppressNests: boolean,
	-- Shell plotted groves when there is nothing better?
	bombardGroves: boolean,
	-- Fire at unrevealed cells when no plot is worth shooting?
	blindFire: boolean,
	-- Keep this much charge in reserve for the next bird.
	birdChargeReserve: number,
	-- Don't re-fly a lane for this many seconds.
	laneRepeatAfter: number,
	-- Stop flying birds once this much of the enemy island is plotted.
	scoutUntilCoverage: number,
	-- A lane must have at least this many unplotted island cells to be
	-- worth two Charge (which is otherwise two catapult shots).
	minLaneValue: number,
	-- Coin floor kept for rebuilding rather than spent on offense.
	coinFloor: number,
}

----------------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------------

-- Bases go far apart, and at least one is tucked against an obstacle
-- (SPEC §9 FOUNDATION). Decoys, when an archetype buys them, are kept
-- clear of the real bases so a decoy kill teaches the enemy nothing.
local function placeBase(view: any, config: any, memory: Memory_): any?
	local placed = {}
	for _, s in view.structures do
		if s.kind == "base" or s.kind == "decoy_base" then
			table.insert(placed, { s.x, s.y, 9 })
		end
	end
	local d = config.ISLAND_DIAMETER
	-- First base hugs an obstacle; the rest simply spread out.
	if #placed == 0 then
		local best = nil
		for key in view.island.obstacles do
			local ox, oy = Grid.parseKey(key)
			for _, delta in { { 2, 0 }, { -3, 0 }, { 0, 2 }, { 0, -3 } } do
				local x, y = ox + delta[1], oy + delta[2]
				if Agent.cellFree(view, config, "base", x, y) then
					best = { x, y }
					break
				end
			end
			if best then
				break
			end
		end
		if best then
			return { type = "place_base", x = best[1], y = best[2] }
		end
	end
	local site = Agent.findSite(view, config, "base", { 2, d - 3 }, memory, placed)
	if site then
		return { type = "place_base", x = site[1], y = site[2] }
	end
	return nil
end

export type Memory_ = any

function Common.setupDecision(policy: Policy, view: any, memory: Memory_, ctx: any): any?
	local config = ctx.config
	if view.basesPlaced < config.BASES_PER_PLAYER then
		return placeBase(view, config, memory)
	end
	-- Opening loadout, in order, while coin lasts.
	local bought = memory.openingIndex or 1
	while bought <= #policy.openingBuild do
		local kind = policy.openingBuild[bought]
		if not Agent.canAfford(view, config, kind) then
			break
		end
		-- Recon may be barred from the opening loadout (see config).
		if not config.SETUP_ALLOWS_RECON and config.WEAPONS[kind].role == "find" then
			bought += 1
			memory.openingIndex = bought
			continue
		end
		local band = Common.bandFor(kind)
		local avoid = {}
		if kind == "decoy_base" then
			for _, s in view.structures do
				if s.kind == "base" then
					table.insert(avoid, { s.x, s.y, 8 })
				end
			end
		end
		local site = Agent.findSite(view, config, kind, Agent.band(config, band), memory, avoid)
		if site then
			memory.openingIndex = bought + 1
			return { type = "place", kind = kind, x = site[1], y = site[2] }
		end
		bought += 1
		memory.openingIndex = bought
	end
	return { type = "ready" }
end

-- Where each structure kind wants to live. Catapults and perches want
-- reach, so they take the exposed shore band; groves and nests sit back.
function Common.bandFor(kind: string): string
	if kind == "catapult" then
		return "shore"
	elseif kind == "perch" then
		return "shore"
	elseif kind == "nest" then
		return "mid"
	elseif kind == "grove" then
		return "inland"
	elseif kind == "decoy_base" then
		return "any"
	end
	return "any"
end

----------------------------------------------------------------------------
-- Combat
----------------------------------------------------------------------------

local BASE_KINDS = { base = true }
local NEST_KINDS = { nest = true }
local GROVE_KINDS = { grove = true }

-- A blind shot: an unrevealed, in-range cell this agent has not shelled.
local function blindTarget(view: any, config: any, memory: Memory_): ({ number }?)
	local d = config.ISLAND_DIAMETER
	local rng = Agent.rng(memory)
	for _ = 1, 60 do
		local x = rng:nextInt(1, d)
		local y = rng:nextInt(1, d)
		local key = Grid.key(x, y)
		if view.belief[key] == nil and memory.shelled[key] == nil then
			if Agent.shooterFor(view, config, x, y) then
				return { x, y }
			end
		end
	end
	return nil
end

-- Next thing worth building, respecting caps and the coin floor.
local function buildDecision(policy: Policy, view: any, memory: Memory_, ctx: any): any?
	local config = ctx.config
	for _, entry in policy.buildOrder do
		if Agent.countOwn(view, entry.kind) < entry.cap and Agent.canAfford(view, config, entry.kind) then
			local avoid = {}
			if entry.kind == "decoy_base" then
				for _, s in view.structures do
					if s.kind == "base" then
						table.insert(avoid, { s.x, s.y, 8 })
					end
				end
			end
			local site = Agent.findSite(view, config, entry.kind, Agent.band(config, entry.band), memory, avoid)
			if site then
				return { type = "place", kind = entry.kind, x = site[1], y = site[2] }
			end
		end
	end
	return nil
end

function Common.combatDecision(policy: Policy, view: any, memory: Memory_, ctx: any): any?
	local config = ctx.config
	local coverage = Agent.coverage(view, config)
	local spendableCharge = view.charge - policy.birdChargeReserve
	local canShoot = spendableCharge >= config.WEAPONS.catapult.charge_cost

	-- 1. Kill fire on plotted bases (real or decoy — the agent cannot tell
	--    the difference, which is the whole point of decoys). This outranks
	--    scouting: a known base is worth more than more map, and an agent
	--    that scouts first forever never converts intel into a win.
	local plottedBases = Agent.plotted(view, BASE_KINDS, memory)
	if canShoot and policy.killOnSight and coverage >= policy.coverageBeforeKill then
		for _, cell in plottedBases do
			local cmd = Agent.fireAt(view, config, memory, cell[1], cell[2])
			if cmd then
				return cmd
			end
		end
	end

	-- 2. Scouting. Birds are the only viable search tool (SPEC §7), but a
	--    bird costs two Charge, so an agent only flies when a lane still
	--    holds real unexplored ground and the map is not yet open enough.
	local perches = Agent.ownStructures(view, "perch", true)
	local scoutingAllowed = view.time >= memory.nextScoutTime and coverage < policy.scoutUntilCoverage
	if #perches > 0 and view.charge >= config.WEAPONS.perch.charge_cost and scoutingAllowed then
		local lane = Agent.bestLane(view, config, memory, policy.laneRepeatAfter, policy.minLaneValue)
		if lane then
			memory.lanesFlown[lane] = view.time
			return { type = "launch_bird", structId = perches[1].id, laneY = lane }
		end
	end

	-- 3. Suppression: nests first (they blind the search), then groves
	--    (they fund the enemy). SPEC §9 SUPPRESS.
	if canShoot and policy.suppressNests then
		for _, cell in Agent.plotted(view, NEST_KINDS, memory) do
			local cmd = Agent.fireAt(view, config, memory, cell[1], cell[2])
			if cmd then
				return cmd
			end
		end
	end

	-- 4. Building, before speculative fire — economy and coverage compound,
	--    blind shots do not.
	if view.coin >= policy.coinFloor then
		local build = buildDecision(policy, view, memory, ctx)
		if build then
			return build
		end
	end

	if canShoot and policy.bombardGroves then
		for _, cell in Agent.plotted(view, GROVE_KINDS, memory) do
			local cmd = Agent.fireAt(view, config, memory, cell[1], cell[2])
			if cmd then
				return cmd
			end
		end
	end

	-- 5. Blind saturation, last and only if the archetype accepts the waste.
	if canShoot and policy.blindFire then
		local target = blindTarget(view, config, memory)
		if target then
			return Agent.fireAt(view, config, memory, target[1], target[2])
		end
	end

	-- 6. Idle coin goes into upgrades, cheapest first.
	local bestUpgrade, bestCost = nil, math.huge
	for _, s in view.structures do
		local def = config.WEAPONS[s.kind]
		if s.buildRemaining <= 0 and s.tier < #def.upgrades then
			local cost = def.upgrades[s.tier + 1].coin_cost
			if cost <= view.coin - policy.coinFloor and cost < bestCost then
				bestUpgrade, bestCost = s, cost
			end
		end
	end
	if bestUpgrade then
		return { type = "upgrade", structId = bestUpgrade.id }
	end

	return nil
end

-- Builds a complete archetype module from a policy table.
function Common.make(policy: Policy)
	return {
		name = policy.name,
		policy = policy,
		newMemory = function(seed: number)
			local memory = Agent.newMemory(seed)
			memory.openingIndex = 1
			return memory
		end,
		decide = function(view: any, memory: Memory_, ctx: any): any?
			if view.phase == "setup" then
				return Common.setupDecision(policy, view, memory, ctx)
			elseif view.phase == "combat" then
				return Common.combatDecision(policy, view, memory, ctx)
			end
			return nil
		end,
		observe = function(memory: Memory_, events: { any }, now: number)
			Agent.observeEvents(memory, events, now)
		end,
	}
end

return Common
