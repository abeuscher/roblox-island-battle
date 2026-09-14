--!strict
-- rules_setup_spec.luau — setup phase, placement legality, phase transition.

local T = require("./lib")
local Rules = require("../src/shared/rules")
local Config = require("../src/shared/config")
local Grid = require("../src/shared/grid")
local Helpers = require("./helpers")

return {
	["match starts in setup with starting resources"] = function()
		local state = Rules.newMatch(Config, 42)
		T.eq(state.phase, "setup")
		T.eq(state.players[1].coin, Config.STARTING_COIN)
		T.eq(state.players[1].charge, Config.STARTING_CHARGE)
		T.eq(state.players[1].basesAlive, 0)
	end,

	["both islands are identical (mirror-fair)"] = function()
		local state = Rules.newMatch(Config, 42)
		T.eq(
			T.serialize(state.players[1].island.obstacles),
			T.serialize(state.players[2].island.obstacles),
			"identical obstacle layout"
		)
	end,

	["placing three bases and readying starts combat"] = function()
		local state = Helpers.startCombat(Config, 42)
		T.eq(state.phase, "combat")
		T.eq(state.players[1].basesAlive, 3)
		T.eq(state.players[2].basesAlive, 3)
	end,

	["a fourth base is rejected"] = function()
		local state = Rules.newMatch(Config, 42)
		local cmds = {}
		for _, cell in { { 8, 8 }, { 8, 26 }, { 26, 8 }, { 26, 26 } } do
			table.insert(cmds, { player = 1, type = "place_base", x = cell[1], y = cell[2] })
		end
		local _, events = Rules.stepMut(state, cmds, 0.1)
		T.eq(T.countEvents(events, "command_rejected"), 1, "exactly one rejection")
		T.eq(state.players[1].basesPlaced, 3)
	end,

	["placement legality: off-island, obstacle, overlap all rejected"] = function()
		local state = Rules.newMatch(Config, 42)
		-- off-island corner (1,1) is water for a circular island
		local ok = Rules.validateCommand(state, { player = 1, type = "place_base", x = 1, y = 1 })
		T.eq(ok, false, "corner rejected")
		-- overlap: place at (8,8), then overlapping (9,9)
		Rules.stepMut(state, { { player = 1, type = "place_base", x = 8, y = 8 } }, 0)
		local ok2 = Rules.validateCommand(state, { player = 1, type = "place_base", x = 9, y = 9 })
		T.eq(ok2, false, "overlap rejected")
		-- obstacle: find one and try to place on it
		local obstacleKey = next(state.players[1].island.obstacles)
		local ox, oy = Grid.parseKey(obstacleKey :: string)
		local ok3 = Rules.validateCommand(state, { player = 1, type = "place", kind = "grove", x = ox, y = oy })
		T.eq(ok3, false, "obstacle rejected")
	end,

	["setup timeout auto-places missing bases"] = function()
		local state = Rules.newMatch(Config, 42)
		-- nobody places anything; run past SETUP_SECONDS
		local t = 0
		while state.phase == "setup" and t < Config.SETUP_SECONDS + 5 do
			Rules.stepMut(state, {}, 1)
			t += 1
		end
		T.eq(state.phase, "combat")
		T.eq(state.players[1].basesPlaced, 3, "p1 auto-placed")
		T.eq(state.players[2].basesPlaced, 3, "p2 auto-placed")
	end,

	["firing is rejected during setup"] = function()
		local state = Rules.newMatch(Config, 42)
		local ok, err = Rules.validateCommand(state, { player = 1, type = "fire", structId = 1, x = 18, y = 18 })
		T.eq(ok, false)
		T.eq(err, "combat only")
	end,

	["setup loadout purchases spend starting coin"] = function()
		local state = Rules.newMatch(Config, 42)
		Rules.stepMut(state, { { player = 1, type = "place", kind = "grove", x = 14, y = 14 } }, 0.1)
		T.eq(state.players[1].coin, Config.STARTING_COIN - Config.WEAPONS.grove.coin_cost)
	end,
}
