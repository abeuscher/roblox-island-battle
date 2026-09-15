--!strict
-- agent.luau — the shared, fog-disciplined agent toolkit.
--
-- This is the single interface used by BOTH the in-game bot (SPEC §9) and
-- the simulation archetypes (SPEC §11.2), which is the point: the bot and
-- the balance agents must be subject to identical information limits or the
-- sweep measures a game nobody plays.
--
-- HARD RULE, enforced by construction: every function here takes a `view`
-- (the output of Rules.viewFor) and never a MatchState. A view contains the
-- agent's own island plus its stale belief map — nothing else. There is no
-- code path from here to true enemy state.
--
-- Pure Luau. `config` is passed in explicitly: tuning constants are public
-- knowledge (both sides play by the same numbers), but they are NOT part of
-- the fog-gated payload, so they never travel inside a view.

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
local Weapons = import("weapons")

local Agent = {}

export type Memory = {
	-- lanes already flown, laneY -> sim time of the last flight
	lanesFlown: { [number]: number },
	-- lanes where a bird was shot down, laneY -> time. A contested lane is
	-- worth re-flying only after it has been suppressed, so this is how an
	-- agent stops feeding birds into a nest it cannot see.
	lanesLost: { [number]: number },
	-- cells already shelled, "x,y" -> sim time of the last shot
	shelled: { [string]: number },
	-- believed-dead base sites, "x,y" -> time they were "killed"
	killedSites: { [string]: number },
	-- the agent's own count of enemy bases it believes it has destroyed
	believedKills: number,
	-- Consecutive birds lost without one getting through. Feeding birds
	-- into anti-air you cannot see is the single most expensive mistake an
	-- agent can make (two Charge a bird), so this backs scouting off until
	-- the lanes have been suppressed.
	birdLossStreak: number,
	nextScoutTime: number,
	phase: string,
	rngState: number,
	-- Which seat this agent occupies, so it can tell its own losses from
	-- the opponent's in the events both sides can see.
	playerIndex: number,
}

function Agent.newMemory(seed: number): Memory
	return {
		lanesFlown = {},
		lanesLost = {},
		shelled = {},
		killedSites = {},
		believedKills = 0,
		birdLossStreak = 0,
		nextScoutTime = 0,
		phase = "FOUNDATION",
		rngState = seed,
		playerIndex = 0,
	}
end

function Agent.rng(memory: Memory): any
	local rng = Grid.makeRng(memory.rngState)
-- Multiplier and increment are the same Numerical Recipes pair Grid.makeRng
-- uses, chosen so the product stays inside the 2^53 range doubles represent
-- exactly. A larger multiplier (1103515245, say) overflows that range and
-- the low bits are rounded away before the modulo sees them, which zeroes
-- the low byte of every subsequent state permanently.
	memory.rngState = (memory.rngState * 1664525 + 1013904223) % 4294967296
	return rng
end

----------------------------------------------------------------------------
-- Reading the agent's own side
----------------------------------------------------------------------------

-- All alive own structures of a kind. `readyOnly` additionally requires
-- construction complete and cooldown clear.
function Agent.ownStructures(view: any, kind: string, readyOnly: boolean?): { any }
	local out = {}
	for _, s in view.structures do
		if s.kind == kind and (not readyOnly or (s.buildRemaining <= 0 and s.cooldownRemaining <= 0)) then
			table.insert(out, s)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function Agent.countOwn(view: any, kind: string): number
	local n = 0
	for _, s in view.structures do
		if s.kind == kind then
			n += 1
		end
	end
	return n
end

function Agent.canAfford(view: any, config: any, kind: string): boolean
	return view.coin >= config.WEAPONS[kind].coin_cost
end

-- Is this own cell legal for a structure of this footprint right now?
function Agent.cellFree(view: any, config: any, kind: string, x: number, y: number): boolean
	local def = config.WEAPONS[kind]
	for _, cell in Grid.footprintCells(x, y, def.footprint) do
		local cx, cy = cell[1], cell[2]
		if not Grid.inIsland(view.island.diameter, cx, cy) then
			return false
		end
		if view.island.obstacles[Grid.key(cx, cy)] then
			return false
		end
		if view.occ[Grid.key(cx, cy)] then
			return false
		end
	end
	return true
end

-- Picks a legal own cell for `kind` inside an x band, scanning
-- deterministically from a random start so agents don't all stack up in
-- the same corner. `band` is {minX, maxX} in island-local coordinates,
-- where x = diameter is the shore facing the enemy.
function Agent.findSite(
	view: any,
	config: any,
	kind: string,
	band: { number },
	memory: Memory,
	avoid: { { number } }?
): ({ number }?)
	local d = view.island.diameter
	local lo = math.max(1, band[1])
	local hi = math.min(d, band[2])
	local rng = Agent.rng(memory)
	local startX = rng:nextInt(lo, hi)
	local startY = rng:nextInt(1, d)

	for ix = 0, hi - lo do
		local x = lo + ((startX - lo + ix) % (hi - lo + 1))
		for iy = 0, d - 1 do
			local y = 1 + ((startY - 1 + iy) % d)
			if Agent.cellFree(view, config, kind, x, y) then
				local okDistance = true
				if avoid then
					for _, other in avoid do
						if Grid.dist(x, y, other[1], other[2]) < (other[3] or 6) then
							okDistance = false
							break
						end
					end
				end
				if okDistance then
					return { x, y }
				end
			end
		end
	end
	return nil
end

-- Standard placement bands. Shore-side weapons reach deeper into the enemy
-- island but sit in the most-searched band; inland is safe but short
-- (SPEC §3 — this is the game's only spatial decision, so agents must
-- actually make it rather than placing uniformly).
function Agent.band(config: any, which: string): { number }
	local d = config.ISLAND_DIAMETER
	if which == "shore" then
		return { d - 6, d }
	elseif which == "mid" then
		return { math.floor(d * 0.4), d - 7 }
	elseif which == "inland" then
		return { 1, math.floor(d * 0.4) - 1 }
	end
	return { 1, d }
end

----------------------------------------------------------------------------
-- Reading the belief map (stale plots only — SPEC §7)
----------------------------------------------------------------------------

-- Every plotted enemy cell whose remembered contents match `kinds`.
-- Results are sorted for determinism. Cells the agent believes it has
-- already destroyed are skipped unless `includeKilled`.
function Agent.plotted(view: any, kinds: { [string]: boolean }, memory: Memory, includeKilled: boolean?): { { number } }
	local out = {}
	for key, plot in view.belief do
		if kinds[plot.kind] then
			if includeKilled or not memory.killedSites[key] then
				local x, y = Grid.parseKey(key)
				table.insert(out, { x, y, plot.t })
			end
		end
	end
	table.sort(out, function(a, b)
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2] < b[2]
	end)
	return out
end

-- Fraction of the enemy ISLAND the agent has ever plotted. Water plots are
-- excluded: a bird's lane crosses open sea at the island's edges, and
-- counting that as coverage would tell the agent it had searched ground it
-- never saw.
function Agent.coverage(view: any, config: any): number
	local n = 0
	for _, plot in view.belief do
		if plot.kind ~= "water" then
			n += 1
		end
	end
	local d = config.ISLAND_DIAMETER
	return n / (math.pi * (d / 2) * (d / 2))
end

-- The least-explored bird lane, and how many island cells in it are still
-- unplotted. Returns nil when no lane is worth the charge: a bird costs
-- two Charge, which is two catapult shots, so flying a lane that is
-- already plotted is a straight loss.
--
-- `repeatAfter` keeps an agent from re-flying the same line back to back;
-- the unexplored count is what actually drives lane choice, so a scout
-- sweeps outward from the center instead of grinding one lane.
function Agent.bestLane(
	view: any,
	config: any,
	memory: Memory,
	repeatAfter: number,
	minUnexplored: number?
): (number?, number)
	local d = config.ISLAND_DIAMETER
	local width = config.BIRD_LANE_WIDTH
	local halfLo = math.floor((width - 1) / 2)
	local halfHi = width - 1 - halfLo

	-- Island cells already plotted, per row.
	local rowPlotted: { [number]: number } = {}
	for key, plot in view.belief do
		if plot.kind ~= "water" then
			local _, y = Grid.parseKey(key)
			rowPlotted[y] = (rowPlotted[y] or 0) + 1
		end
	end
	-- Island cells that exist, per row.
	local rowTotal: { [number]: number } = {}
	for y = 1, d do
		local n = 0
		for x = 1, d do
			if Grid.inIsland(d, x, y) then
				n += 1
			end
		end
		rowTotal[y] = n
	end

	local bestY, bestUnexplored, bestScore = nil, 0, -math.huge
	for laneY = 1 + halfLo, d - halfHi do
		local lastFlown = memory.lanesFlown[laneY]
		local lastLost = memory.lanesLost[laneY]
		-- A lane that ate a bird stays off the list for twice as long: the
		-- nest that killed it is still there, and unexplored ground behind
		-- a live nest is not actually reachable.
		local contested = lastLost ~= nil and (view.time - lastLost) < repeatAfter * 2
		if not contested and (not lastFlown or (view.time - lastFlown) >= repeatAfter) then
			local unexplored = 0
			for y = laneY - halfLo, laneY + halfHi do
				unexplored += math.max(0, (rowTotal[y] or 0) - (rowPlotted[y] or 0))
			end
			-- Tie-break toward the center, where lanes are longest and a
			-- pass reveals the most ground (SPEC §9: center first).
			local centerBias = -math.abs(laneY - (d + 1) / 2) * 0.5
			local score = unexplored + centerBias
			if score > bestScore then
				bestScore, bestY, bestUnexplored = score, laneY, unexplored
			end
		end
	end

	if bestY and bestUnexplored < (minUnexplored or 0) then
		return nil, bestUnexplored
	end
	return bestY, bestUnexplored
end

----------------------------------------------------------------------------
-- Firing
----------------------------------------------------------------------------

-- The ready catapult that can reach (tx, ty), or nil. Prefers the catapult
-- with the least slack range so long-reach shore pieces stay free for
-- deep targets.
function Agent.shooterFor(view: any, config: any, tx: number, ty: number): any?
	local best, bestSlack = nil, math.huge
	for _, s in Agent.ownStructures(view, "catapult", true) do
		local range = Weapons.getStat(config, "catapult", s.tier, "range")
		local dist = Grid.attackDistance(config, s.x, s.y, tx, ty)
		if dist <= range then
			local slack = range - dist
			if slack < bestSlack then
				best, bestSlack = s, slack
			end
		end
	end
	return best
end

-- Builds a `fire` command at (tx, ty) if any ready catapult reaches it and
-- the agent can pay the charge. Records the shot in memory.
function Agent.fireAt(view: any, config: any, memory: Memory, tx: number, ty: number): any?
	if view.charge < config.WEAPONS.catapult.charge_cost then
		return nil
	end
	local shooter = Agent.shooterFor(view, config, tx, ty)
	if not shooter then
		return nil
	end
	memory.shelled[Grid.key(tx, ty)] = view.time
	return { type = "fire", structId = shooter.id, x = tx, y = ty }
end

-- Cells inside a 3x3 plotted base footprint are interchangeable targets;
-- aiming at the plotted anchor's center is the highest-value single cell.
function Agent.aimPoint(x: number, y: number): (number, number)
	return x, y
end

----------------------------------------------------------------------------
-- Bookkeeping the agent does about ITSELF (never about the enemy)
----------------------------------------------------------------------------

-- Called with the events this agent is allowed to see. The decoy deception
-- lives here: a `base_destroyed_feedback` event is indistinguishable
-- between a real base and a decoy, so the agent's own kill count is a
-- BELIEF, exactly like a human player's (SPEC §5, §9).
function Agent.observeEvents(memory: Memory, events: { any }, now: number)
	for _, e in events do
		if e.type == "bird_down" and e.owner == memory.playerIndex then
			if e.laneY then
				memory.lanesLost[e.laneY] = now
			end
			memory.birdLossStreak += 1
			-- Back off geometrically, capped: after three straight losses
			-- the agent stops scouting for a minute and spends the Charge
			-- on opening the lanes instead.
			memory.nextScoutTime = now + math.min(120, 20 * memory.birdLossStreak)
		elseif e.type == "bird_exit" then
			-- A bird that crossed clean means the lanes are open again.
			memory.birdLossStreak = 0
			memory.nextScoutTime = 0
		elseif e.type == "base_destroyed_feedback" then
			memory.believedKills += 1
			-- Mark the whole footprint so the agent stops re-shelling a site
			-- it believes is dead — the behaviour a decoy exists to exploit.
			for _, cell in Grid.footprintCells(e.x, e.y, e.footprint or 1) do
				memory.killedSites[Grid.key(cell[1], cell[2])] = now
			end
		end
	end
end

-- Hard difficulty re-probes sites it believes it already killed, which is
-- how a decoy's value decays against a strong opponent (SPEC §9).
function Agent.forgetOldKills(memory: Memory, now: number, reprobeAfter: number)
	if reprobeAfter <= 0 then
		return
	end
	for key, t in memory.killedSites do
		if now - t >= reprobeAfter then
			memory.killedSites[key] = nil
		end
	end
end

return Agent
