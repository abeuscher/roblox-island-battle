--!strict
-- grid_spec.luau — island generation, cell math, cross-channel geometry.

local T = require("./lib")
local Grid = require("../src/shared/grid")
local Config = require("../src/shared/config")

return {
	["same seed generates the same island"] = function()
		local a = Grid.generateIsland(Config, 1234)
		local b = Grid.generateIsland(Config, 1234)
		T.eq(T.serialize(a.obstacles), T.serialize(b.obstacles), "obstacles deterministic")
		T.eq(a.buildableCount, b.buildableCount, "buildable count deterministic")
	end,

	["different seeds diverge"] = function()
		local a = Grid.generateIsland(Config, 1)
		local b = Grid.generateIsland(Config, 2)
		T.ok(T.serialize(a.obstacles) ~= T.serialize(b.obstacles), "seeds diverge")
	end,

	["obstacle count within configured range"] = function()
		for seed = 1, 20 do
			local island = Grid.generateIsland(Config, seed)
			local n = 0
			for _ in island.obstacles do
				n += 1
			end
			T.ok(n >= Config.OBSTACLE_MIN and n <= Config.OBSTACLE_MAX, "obstacles in [8,14], got " .. n)
		end
	end,

	["buildable cell count is ~1000 at d=36"] = function()
		local island = Grid.generateIsland(Config, 7)
		-- SPEC §3: ~1,000 buildable cells; land area of the d=36 circle is
		-- ~1018 cells minus 8–14 obstacles.
		T.ok(island.buildableCount > 950 and island.buildableCount < 1050, "got " .. island.buildableCount)
	end,

	["attack distance: shore to shore equals channel width"] = function()
		local d = Config.ISLAND_DIAMETER
		T.near(Grid.attackDistance(Config, d, 18, d, 18), Config.CHANNEL_WIDTH, 1e-9)
	end,

	["attack distance: inland catapult reaches exactly the enemy shoreline"] = function()
		local d = Config.ISLAND_DIAMETER
		-- From the inland edge (x=1), the enemy shore column (x=d) straight
		-- across is (d-1) + channel = 50 away — exactly catapult range.
		local dist = Grid.attackDistance(Config, 1, 18, d, 18)
		T.near(dist, 50, 1e-9)
		T.ok(dist <= Config.WEAPONS.catapult.range, "inland reaches enemy shore")
		-- One cell deeper is out of range.
		T.ok(Grid.attackDistance(Config, 1, 18, d - 1, 18) > Config.WEAPONS.catapult.range, "no deeper")
	end,

	["no single catapult position covers the whole enemy island"] = function()
		local d = Config.ISLAND_DIAMETER
		local range = Config.WEAPONS.catapult.range
		-- Even from the shore center, far corners must be out of range
		-- (SPEC §3: never allow full-island coverage from one spot).
		local best = Grid.attackDistance(Config, d, math.ceil(d / 2), 1, 1)
		T.ok(best > range, "far corner uncovered from shore center: " .. best)
	end,

	["line cells connect endpoints"] = function()
		local line = Grid.lineCells(1, 1, 6, 4)
		T.eq(line[1][1], 1)
		T.eq(line[1][2], 1)
		T.eq(line[#line][1], 6)
		T.eq(line[#line][2], 4)
		T.ok(#line >= 6, "line long enough")
	end,

	["impact circle at r=3 is ~28 cells"] = function()
		local cells = Grid.cellsInRadius(18, 18, Config.WEAPONS.catapult.reveal_size)
		-- SPEC §7: a catapult impact reveals ~28 cells (under 3% of island).
		T.ok(#cells >= 25 and #cells <= 32, "got " .. #cells)
	end,

	["no generator loses its low bits to double overflow"] = function()
		-- A multiplier large enough to push the product past 2^53 gets its
		-- low bits rounded away before the modulo, and the stream quietly
		-- collapses onto multiples of a power of two. Every advance in the
		-- project must stay inside the exact range.
		local State = require("../src/shared/state")
		local Agent = require("../src/shared/agent")

		local function lowByteEntropy(advance: () -> number): number
			local seen = {}
			local distinct = 0
			for _ = 1, 64 do
				local byte = advance() % 256
				if not seen[byte] then
					seen[byte] = true
					distinct += 1
				end
			end
			return distinct
		end

		local matchState = State.newMatch(Config, 12345)
		T.ok(
			lowByteEntropy(function()
				State.rng(matchState)
				return matchState.rngState
			end) > 20,
			"match rng keeps its low bits"
		)

		local memory = Agent.newMemory(12345)
		T.ok(
			lowByteEntropy(function()
				Agent.rng(memory)
				return memory.rngState
			end) > 20,
			"agent rng keeps its low bits"
		)

		local rng = Grid.makeRng(12345)
		T.ok(
			lowByteEntropy(function()
				return math.floor(rng:next() * 4294967296)
			end) > 20,
			"grid rng keeps its low bits"
		)
	end,

	["rng is deterministic and in range"] = function()
		local a = Grid.makeRng(99)
		local b = Grid.makeRng(99)
		for _ = 1, 100 do
			local x = a:nextInt(3, 9)
			T.eq(x, b:nextInt(3, 9))
			T.ok(x >= 3 and x <= 9, "int in range")
		end
	end,
}
