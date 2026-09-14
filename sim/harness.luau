--!strict
-- harness.luau — headless match runner over src/shared (SPEC §11.1).
-- No Roblox, no rendering, no UI. This is where balance is measured before
-- any of it exists.
--
-- Two constraints are mandatory and enforced here, not left to agents:
--
--  1. ACTION RATE LIMIT. An agent is offered a decision at most once per
--     SIM_AGENT_ACTION_INTERVAL of simulated time. Combat is continuous and
--     simultaneous, so an unconstrained agent has infinite APM and reports
--     a game no human can play.
--
--  2. FOG DISCIPLINE. An agent is handed Rules.viewFor(state, i) and the
--     events Rules.filterEventsFor allows it. The true MatchState never
--     reaches agent code. The harness itself reads true state, but only to
--     compute metrics an observer is entitled to.

local Rules = require("../src/shared/rules")
local Grid = require("../src/shared/grid")
local Metrics = require("./metrics")

local Harness = {}

-- Ground truth: the real base footprint cells of `defender`, used ONLY by
-- the observer to decide when a base has genuinely been found.
local function realBaseCells(defender: any, config: any): { [string]: boolean }
	local cells = {}
	for _, s in defender.structures do
		if s.alive and s.kind == "base" then
			for _, cell in Grid.footprintCells(s.x, s.y, config.WEAPONS.base.footprint) do
				cells[Grid.key(cell[1], cell[2])] = true
			end
		end
	end
	return cells
end

export type MatchOptions = {
	-- sample coverage/resources this often, in combat seconds
	sampleInterval: number?,
	-- record a per-action timeline (large; off for sweep runs)
	timeline: boolean?,
	maxSeconds: number?,
}

-- Runs one match. `agents` is a two-element array of archetype modules.
function Harness.runMatch(config: any, seed: number, agents: { any }, opts: MatchOptions?): any
	local options = opts or {}
	local sampleInterval = options.sampleInterval or 30
	local dt = config.SIM_DT
	local state = Rules.newMatch(config, seed)

	local memories = {
		agents[1].newMemory(seed * 2 + 1),
		agents[2].newMemory(seed * 2 + 2),
	}
	-- An agent needs to know which seat it holds to read the events both
	-- sides can see (a downed bird, a nest firing) as its own or not.
	memories[1].playerIndex = 1
	memories[2].playerIndex = 2
	local ctx = { config = config }

	-- Action-rate gate, in cumulative simulated seconds.
	local nextAction = { 0, 0 }
	local simTime = 0

	local log = {
		seed = seed,
		configHash = Metrics.configHash(config),
		agents = { agents[1].name, agents[2].name },
		winner = nil :: number?,
		endReason = nil :: string?,
		duration = 0,
		-- Observer-only: per seat, the combat time at which that player's
		-- belief map first plotted a cell of a genuinely real enemy base.
		firstRealBaseFound = {} :: { number },
		decoyKills = 0,
		decoySpend = 0,
		fireAbsorbedByDecoys = 0,
		purchases = {} :: { [string]: number },
		weaponKills = {} :: { [string]: number },
		coverage = {} :: { any },
		timeline = {} :: { any },
		structuresLost = { 0, 0 },
		shotsFired = { 0, 0 },
		birdsFlown = { 0, 0 },
		birdsLost = { 0, 0 },
		comeback = false,
		comebackEligible = false,
	}

	-- Observer-only trackers.
	local foundRealBase = { false, false }
	local nextSample = 0
	local structuresAt5min: { number }? = nil
	local maxSeconds = options.maxSeconds or (config.MATCH_TIMEOUT + config.SETUP_SECONDS + 10)

	while state.phase ~= "ended" and simTime < maxSeconds do
		local commands = {}
		for i = 1, 2 do
			if simTime >= nextAction[i] then
				-- FOG BOUNDARY: this is the only state an agent ever sees.
				local view = Rules.viewFor(state, i)
				local cmd = agents[i].decide(view, memories[i], ctx)
				if cmd then
					-- The harness stamps the player itself: an agent cannot
					-- issue a command on behalf of its opponent.
					cmd.player = i
					table.insert(commands, cmd)
					nextAction[i] = simTime + config.SIM_AGENT_ACTION_INTERVAL
					if options.timeline then
						table.insert(log.timeline, {
							t = simTime,
							player = i,
							action = cmd.type,
							kind = cmd.kind,
							x = cmd.x,
							y = cmd.y,
						})
					end
					if cmd.type == "place" then
						log.purchases[cmd.kind] = (log.purchases[cmd.kind] or 0) + 1
						if cmd.kind == "decoy_base" then
							log.decoySpend += config.WEAPONS.decoy_base.coin_cost
						end
					end
				else
					-- No useful move. Don't burn the agent's action budget,
					-- but don't re-offer a decision every tick either: a
					-- view is a full fog-filtered snapshot, and an idle
					-- agent polling it 4x a second dominates the runtime of
					-- the whole sweep.
					nextAction[i] = simTime + (config.SIM_IDLE_RECHECK or 1)
				end
			end
		end

		local _, events = Rules.stepMut(state, commands, dt)
		simTime += dt

		for i = 1, 2 do
			agents[i].observe(memories[i], Rules.filterEventsFor(events, i), state.time)
		end

		-- Observer metrics.
		for _, e in events do
			if e.type == "structure_destroyed" then
				log.weaponKills[e.kind] = (log.weaponKills[e.kind] or 0) + 1
				if e.kind == "decoy_base" then
					log.decoyKills += 1
					-- Coin of enemy fire absorbed: one catapult shot's worth
					-- of the shooter's investment per hit that landed on a
					-- decoy instead of a real structure.
					log.fireAbsorbedByDecoys += config.WEAPONS.catapult.coin_cost
				end
			end
		end

		if state.phase == "combat" then
			-- Only newly revealed cells can turn a base up, so this checks
			-- the reveal events rather than rescanning ~1,000 belief cells
			-- per tick. A decoy plots as "base" but is not in `truth`, so a
			-- fooled agent does NOT count as having found one.
			for _, e in events do
				if e.type == "reveal" and not foundRealBase[e.visibleTo] then
					local i = e.visibleTo
					local truth = realBaseCells(state.players[3 - i], config)
					for _, cell in e.cells do
						if truth[Grid.key(cell[1], cell[2])] then
							foundRealBase[i] = true
							log.firstRealBaseFound[i] = state.time
							break
						end
					end
				end
			end

			if state.time >= nextSample then
				local function aliveCount(p: any): number
					local n = 0
					for _, s in p.structures do
						if s.alive then
							n += 1
						end
					end
					return n
				end
				table.insert(log.coverage, {
					t = nextSample,
					p1 = state.players[1].stats.cellsRevealed,
					p2 = state.players[2].stats.cellsRevealed,
					coin1 = state.players[1].coin,
					coin2 = state.players[2].coin,
					structs1 = aliveCount(state.players[1]),
					structs2 = aliveCount(state.players[2]),
					bases1 = state.players[1].basesAlive,
					bases2 = state.players[2].basesAlive,
				})
				if not structuresAt5min and state.time >= 300 then
					structuresAt5min = { aliveCount(state.players[1]), aliveCount(state.players[2]) }
				end
				nextSample += sampleInterval
			end
		end
	end

	log.winner = state.winner or 0
	log.endReason = state.endReason or "unresolved"
	log.duration = state.time
	for i = 1, 2 do
		log.structuresLost[i] = state.players[i].stats.structuresLost
		log.shotsFired[i] = state.players[i].stats.shotsFired
		log.birdsFlown[i] = state.players[i].stats.birdsFlown
		log.birdsLost[i] = state.players[i].stats.birdsLost
	end

	-- Comeback: the player behind on structures at the 5-minute mark won.
	-- Reads directly on the snowball risk called out in SPEC §4.
	if structuresAt5min and structuresAt5min[1] ~= structuresAt5min[2] and log.winner ~= 0 then
		log.comebackEligible = true
		local behind = structuresAt5min[1] < structuresAt5min[2] and 1 or 2
		log.comeback = (log.winner == behind)
	end

	return log
end

----------------------------------------------------------------------------
-- Round robin
----------------------------------------------------------------------------

-- Runs every archetype against every archetype (including self-play) over a
-- shared seed list, so map variance cancels across pairings (SPEC §11.2).
-- Each pairing plays both seatings of each seed to cancel any seat effect.
function Harness.roundRobin(config: any, archetypes: { any }, matchesPerPair: number, opts: any?): any
	local options = opts or {}
	local seeds = {}
	local baseSeed = options.baseSeed or 1000
	local half = math.max(1, math.floor(matchesPerPair / 2))
	for i = 1, half do
		table.insert(seeds, baseSeed + i)
	end

	local results = {
		configHash = Metrics.configHash(config),
		pairings = {} :: { any },
		overall = Metrics.newAggregate(),
		-- winRateMatrix[a][b] = a's win rate playing against b
		winRateMatrix = {} :: { [string]: { [string]: number } },
		logs = {} :: { any },
	}

	for _, a in archetypes do
		results.winRateMatrix[a.name] = {}
	end

	for ai = 1, #archetypes do
		for bi = ai, #archetypes do
			local a, b = archetypes[ai], archetypes[bi]
			local agg = Metrics.newAggregate()
			local aWins, bWins, played = 0, 0, 0

			for _, seed in seeds do
				for seating = 1, 2 do
					local pair = seating == 1 and { a, b } or { b, a }
					local log = Harness.runMatch(config, seed, pair, options.matchOptions)
					Metrics.absorb(agg, log)
					Metrics.absorb(results.overall, log)
					played += 1
					if log.winner ~= 0 then
						-- log.agents is indexed by seat, so this resolves the
						-- winner by archetype regardless of which seat it took.
						if log.agents[log.winner] == a.name then
							aWins += 1
						else
							bWins += 1
						end
					end
					if options.keepLogs then
						table.insert(results.logs, log)
					end
					if a.name == b.name then
						break -- self-play: seatings are symmetric
					end
				end
			end

			table.insert(results.pairings, {
				a = a.name,
				b = b.name,
				played = played,
				aWins = aWins,
				bWins = bWins,
				agg = agg,
			})
			if a.name ~= b.name then
				results.winRateMatrix[a.name][b.name] = aWins / math.max(1, played)
				results.winRateMatrix[b.name][a.name] = bWins / math.max(1, played)
			else
				results.winRateMatrix[a.name][b.name] = 0.5
			end
		end
	end

	return results
end

-- Win rate of each archetype against the whole field (excluding self-play),
-- the SPEC §11.3 "no archetype above 60%" check.
function Harness.fieldWinRates(results: any, archetypes: { any }): { [string]: number }
	local out = {}
	for _, a in archetypes do
		local wins, played = 0, 0
		for _, p in results.pairings do
			if p.a ~= p.b then
				if p.a == a.name then
					wins += p.aWins
					played += p.played
				elseif p.b == a.name then
					wins += p.bWins
					played += p.played
				end
			end
		end
		out[a.name] = played > 0 and wins / played or 0
	end
	return out
end

function Harness.loadArchetypes(): { any }
	return {
		require("./archetypes/turtle"),
		require("./archetypes/rusher"),
		require("./archetypes/boomer"),
		require("./archetypes/scout"),
		require("./archetypes/trickster"),
	}
end

return Harness
