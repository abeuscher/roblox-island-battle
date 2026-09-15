--!strict
-- fog.luau — reveal + belief map. Pure Luau.
--
-- Each player holds a belief map (stale plots) of the enemy island (SPEC §7):
-- * Unrevealed cells simply have no entry — clients render uniform haze.
-- * A revealed cell is recorded AS IT WAS at reveal time and never
--   live-updates. Re-revealing overwrites the plot with the new truth.
-- * Decoys plot as real bases. Rubble plots as rubble.
-- * The defender's island shape/obstacles are only plotted where revealed,
--   so the island outline cannot be inferred from fog.

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
local State = import("state")

local Fog = {}

-- What the attacker truthfully sees in one defender cell right now.
local function observe(defender: State.Player, x: number, y: number): (string, number?)
	local key = Grid.key(x, y)
	local s = State.structureAt(defender, x, y)
	if s and s.alive then
		-- Deception: a decoy is indistinguishable from a base once revealed.
		local kind = s.kind == "decoy_base" and "base" or s.kind
		return kind, s.id
	end
	if defender.island.rubble[key] then
		return "rubble", nil
	end
	if defender.island.obstacles[key] then
		return "obstacle", nil
	end
	return "empty", nil
end

-- Reveal a list of {x, y} cells of the defender's island to the attacker.
-- Cells off the island are ignored (there is nothing to plot over water).
-- Returns the number of newly-revealed cells (never seen before).
function Fog.reveal(
	state: State.MatchState,
	attackerIndex: number,
	cells: { { number } },
	events: { State.Event }?
): number
	local attacker = state.players[attackerIndex]
	local defender = State.enemyOf(state, attackerIndex)
	local newlyRevealed = 0
	local revealedCells: { { number } } = {}

	local d = defender.island.diameter
	for _, cell in cells do
		local x, y = cell[1], cell[2]
		if x >= 1 and y >= 1 and x <= d and y <= d then
			local key = Grid.key(x, y)
			if attacker.belief[key] == nil then
				newlyRevealed += 1
			end
			if Grid.inIsland(d, x, y) then
				local kind, structId = observe(defender, x, y)
				attacker.belief[key] = { t = state.time, kind = kind, structId = structId }
			else
				-- Overflown water inside the board plots as water: honestly
				-- revealed, so the client can distinguish it from haze.
				attacker.belief[key] = { t = state.time, kind = "water", structId = nil }
			end
			table.insert(revealedCells, { x, y })
		end
	end

	attacker.stats.cellsRevealed += newlyRevealed

	if events and #revealedCells > 0 then
		-- The reveal event carries plots only, and is visible only to the
		-- attacker — the defender never learns what was scouted (SPEC §8).
		table.insert(events, {
			type = "reveal",
			visibleTo = attackerIndex,
			cells = revealedCells,
		})
	end

	return newlyRevealed
end

-- When the attacker's own shot destroys a plotted structure, their belief
-- of that footprint flips to rubble immediately (they watched it die).
function Fog.plotDestruction(
	state: State.MatchState,
	attackerIndex: number,
	defenderStruct: State.Structure,
	footprint: number
)
	local attacker = state.players[attackerIndex]
	for _, cell in Grid.footprintCells(defenderStruct.x, defenderStruct.y, footprint) do
		local key = Grid.key(cell[1], cell[2])
		attacker.belief[key] = { t = state.time, kind = "rubble", structId = nil }
	end
end

-- Count belief cells currently plotted (coverage metric for the harness).
function Fog.coverage(player: State.Player): number
	local n = 0
	for _ in player.belief do
		n += 1
	end
	return n
end

return Fog
