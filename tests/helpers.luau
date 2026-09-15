--!strict
-- helpers.luau — shared match-construction helpers for the specs.

local Rules = require("../src/shared/rules")
local Config = require("../src/shared/config")

local Helpers = {}

-- Standard base spots used across specs (well inside the d=36 island,
-- clear of the seeded obstacles for the seeds the specs use).
Helpers.P1_BASES = { { 8, 8 }, { 8, 26 }, { 26, 8 } }
Helpers.P2_BASES = { { 8, 8 }, { 8, 26 }, { 26, 8 } }

-- Builds a match, places three bases per player, readies both, and steps
-- once so the match enters combat. Returns the state.
function Helpers.startCombat(config: any?, seed: number?)
	local state = Rules.newMatch(config or Config, seed or 42)
	local commands = {}
	for _, cell in Helpers.P1_BASES do
		table.insert(commands, { player = 1, type = "place_base", x = cell[1], y = cell[2] })
	end
	for _, cell in Helpers.P2_BASES do
		table.insert(commands, { player = 2, type = "place_base", x = cell[1], y = cell[2] })
	end
	table.insert(commands, { player = 1, type = "ready" })
	table.insert(commands, { player = 2, type = "ready" })
	local newState, events = Rules.stepMut(state, commands, 0.1)
	assert(newState.phase == "combat", "expected combat phase, got " .. newState.phase)
	for _, e in events do
		assert(e.type ~= "command_rejected", "setup command rejected: " .. tostring(e.reason))
	end
	return newState
end

-- Steps with no commands until `seconds` of match time pass.
function Helpers.run(state, seconds: number, dt: number?)
	local step = dt or 0.25
	local events = {}
	local t = 0
	while t < seconds do
		local _, e = Rules.stepMut(state, {}, step)
		for _, ev in e do
			table.insert(events, ev)
		end
		t += step
	end
	return events
end

-- Places a structure for a player and finishes its construction.
function Helpers.placeAndBuild(state, player: number, kind: string, x: number, y: number): number
	local _, events = Rules.stepMut(state, { { player = player, type = "place", kind = kind, x = x, y = y } }, 0)
	for _, e in events do
		assert(e.type ~= "command_rejected", "place rejected: " .. tostring(e.reason))
	end
	local placed
	for _, e in events do
		if e.type == "placed" then
			placed = e.structId
		end
	end
	Helpers.run(state, state.config.BUILD_SECONDS + 0.01)
	return placed
end

return Helpers
