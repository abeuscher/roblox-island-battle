--!strict
-- economy_spec.luau — Coin/Charge accrual, groves, caps.

local T = require("./lib")
local Rules = require("../src/shared/rules")
local Config = require("../src/shared/config")
local Helpers = require("./helpers")

return {
	["coin ticks at base rate in combat"] = function()
		local state = Helpers.startCombat(Config, 42)
		local before = state.players[1].coin
		Helpers.run(state, Config.COIN_TICK_SECONDS * 4 + 0.01)
		T.eq(state.players[1].coin, before + Config.COIN_BASE_RATE * 4)
	end,

	["a completed grove adds income; one under construction does not"] = function()
		local state = Helpers.startCombat(Config, 42)
		-- Place a grove; during its BUILD_SECONDS it must not earn.
		Rules.stepMut(state, { { player = 1, type = "place", kind = "grove", x = 14, y = 14 } }, 0)
		local afterPurchase = state.players[1].coin
		Helpers.run(state, Config.COIN_TICK_SECONDS) -- 2 s: still building (4 s)
		T.eq(state.players[1].coin, afterPurchase + Config.COIN_BASE_RATE, "no grove income while building")
		Helpers.run(state, Config.BUILD_SECONDS) -- construction completes
		local beforeTicks = state.players[1].coin
		Helpers.run(state, Config.COIN_TICK_SECONDS * 3 + 0.01)
		T.eq(
			state.players[1].coin,
			beforeTicks + (Config.COIN_BASE_RATE + Config.GROVE_INCOME) * 3,
			"grove income applies once built"
		)
	end,

	["charge regens flat and caps"] = function()
		local state = Helpers.startCombat(Config, 42)
		Helpers.run(state, Config.CHARGE_REGEN_SECONDS * 20)
		T.eq(state.players[1].charge, Config.CHARGE_CAP, "capped")
	end,

	["charge regen is flat regardless of structures (anti-snowball)"] = function()
		local state = Helpers.startCombat(Config, 42)
		-- P1 owns nothing but the three bases; regen must still be full rate.
		local p1 = state.players[1]
		p1.charge = 0
		Helpers.run(state, Config.CHARGE_REGEN_SECONDS * 3 + 0.01)
		T.eq(p1.charge, 3, "flat regen with only bases standing")
	end,

	["upgraded grove earns more"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].coin = 100
		local id = Helpers.placeAndBuild(state, 1, "grove", 14, 14)
		Rules.stepMut(state, { { player = 1, type = "upgrade", structId = id } }, 0)
		local before = state.players[1].coin
		local ticks = 2
		Helpers.run(state, Config.COIN_TICK_SECONDS * ticks + 0.01)
		-- tier 1 grove income = 2
		T.eq(state.players[1].coin, before + (Config.COIN_BASE_RATE + 2) * ticks)
	end,

	["cannot place what you cannot afford"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].coin = 3
		local ok, err = Rules.validateCommand(state, { player = 1, type = "place", kind = "nest", x = 14, y = 14 })
		T.eq(ok, false)
		T.eq(err, "cannot afford")
	end,
}
