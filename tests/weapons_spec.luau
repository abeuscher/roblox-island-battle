--!strict
-- weapons_spec.luau — catapults, birds, nests, decoys, win detection.

local T = require("./lib")
local Rules = require("../src/shared/rules")
local Config = require("../src/shared/config")
local Grid = require("../src/shared/grid")
local Helpers = require("./helpers")

-- Fires P1's catapult `id` at (tx, ty) and runs until the impact resolves.
local function fireAndLand(state, id: number, tx: number, ty: number)
	local _, events = Rules.stepMut(state, { { player = 1, type = "fire", structId = id, x = tx, y = ty } }, 0)
	for _, e in events do
		assert(e.type ~= "command_rejected", "fire rejected: " .. tostring(e.reason))
	end
	local all = {}
	for _ = 1, 200 do
		local _, evs = Rules.stepMut(state, {}, 0.25)
		for _, e in evs do
			table.insert(all, e)
		end
		if T.findEvent(all, "impact") then
			break
		end
	end
	T.ok(T.findEvent(all, "impact"), "coconut landed")
	return all
end

-- Gives P1 a ready catapult at a shore cell and tops up resources.
local function armCatapult(state): number
	state.players[1].coin = 500
	local id = Helpers.placeAndBuild(state, 1, "catapult", 33, 18)
	state.players[1].charge = Config.CHARGE_CAP
	return id
end

return {
	["catapult hit damages the structure under the impact cell"] = function()
		local state = Helpers.startCombat(Config, 42)
		local id = armCatapult(state)
		-- P2 base anchored at (8,8) covers 8..10 — aim at its center cell.
		fireAndLand(state, id, 9, 9)
		local base
		for _, s in state.players[2].structures do
			if s.kind == "base" and s.x == 8 and s.y == 8 then
				base = s
			end
		end
		T.eq(base.hp, Config.WEAPONS.base.hp - Config.WEAPONS.catapult.damage, "8 damage dealt")
	end,

	["firing spends charge and starts the cooldown"] = function()
		local state = Helpers.startCombat(Config, 42)
		local id = armCatapult(state)
		local chargeBefore = state.players[1].charge
		Rules.stepMut(state, { { player = 1, type = "fire", structId = id, x = 18, y = 18 } }, 0)
		T.eq(state.players[1].charge, chargeBefore - Config.WEAPONS.catapult.charge_cost)
		local s = state.players[1].structures[id]
		T.eq(s.cooldownRemaining, Config.WEAPONS.catapult.cooldown)
		-- Second shot while cooling down is rejected.
		local ok, err = Rules.validateCommand(state, { player = 1, type = "fire", structId = id, x = 18, y = 18 })
		T.eq(ok, false)
		T.eq(err, "cooling down")
	end,

	["range: inland catapult reaches only the enemy shoreline"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].coin = 500
		-- x=14 is well inland; enemy shore is x=36 in enemy-local coords.
		local id = Helpers.placeAndBuild(state, 1, "catapult", 14, 18)
		state.players[1].charge = Config.CHARGE_CAP
		local okDeep = Rules.validateCommand(state, { player = 1, type = "fire", structId = id, x = 18, y = 18 })
		T.eq(okDeep, false, "deep target out of range from inland")
		local okShore = Rules.validateCommand(state, { player = 1, type = "fire", structId = id, x = 36, y = 18 })
		T.eq(okShore, true, "enemy shore in range from x=14")
	end,

	["impact reveals the flight line and impact circle as stale plots"] = function()
		local state = Helpers.startCombat(Config, 42)
		local id = armCatapult(state)
		fireAndLand(state, id, 20, 18)
		local belief = state.players[1].belief
		T.ok(belief[Grid.key(20, 18)], "impact cell plotted")
		T.ok(belief[Grid.key(20, 20)], "circle cell plotted")
		-- Flight line: catapult at (33,18) → virtual x = 36+15+3 = 54, so the
		-- line into (20,18) crosses the enemy island along y=18, x=20..36.
		T.ok(belief[Grid.key(30, 18)], "flight line plotted")
		T.ok(belief[Grid.key(25, 18)], "flight line plotted")
		-- Cells far from line+circle stay unrevealed haze.
		T.eq(belief[Grid.key(10, 30)], nil, "far cell still fog")
	end,

	["destroying all three bases wins the match"] = function()
		local state = Helpers.startCombat(Config, 42)
		local id = armCatapult(state)
		local hitsPerBase = math.ceil(Config.WEAPONS.base.hp / Config.WEAPONS.catapult.damage)
		for _, cell in Helpers.P2_BASES do
			for _ = 1, hitsPerBase do
				state.players[1].charge = Config.CHARGE_CAP
				local s = state.players[1].structures[id]
				s.cooldownRemaining = 0
				fireAndLand(state, id, cell[1] + 1, cell[2] + 1)
				if state.phase == "ended" then
					break
				end
			end
		end
		T.eq(state.phase, "ended")
		T.eq(state.winner, 1)
		T.eq(state.endReason, "bases")
		T.eq(state.players[1].stats.realBaseKills, 3)
	end,

	["decoy dies to one hit with identical feedback, no real kill"] = function()
		local state = Helpers.startCombat(Config, 42)
		-- P2 builds a decoy; P1 shells it.
		state.players[2].coin = 100
		Rules.stepMut(state, { { player = 2, type = "place", kind = "decoy_base", x = 20, y = 20 } }, 0)
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		local id = armCatapult(state)
		local events = fireAndLand(state, id, 21, 21)
		local feedback = T.findEvent(events, "base_destroyed_feedback")
		T.ok(feedback, "attacker got the fake base-destroyed feedback")
		T.eq(feedback.visibleTo, 1)
		T.eq(state.players[1].stats.believedBaseKills, 1, "believed counter advanced")
		T.eq(state.players[1].stats.realBaseKills, 0, "real counter did not")
		T.eq(state.players[1].stats.timesFooledByDecoy, 1)
		T.eq(state.players[2].basesAlive, 3, "no real base lost")
		T.eq(state.phase, "combat", "match continues")
		-- The attacker's plot now shows rubble there, same as a real kill.
		T.eq(state.players[1].belief[Grid.key(21, 21)].kind, "rubble")
	end,

	["a bird pass reveals its full lane (~288 cells)"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].coin = 500
		local id = Helpers.placeAndBuild(state, 1, "perch", 30, 18)
		state.players[1].charge = Config.CHARGE_CAP
		Rules.stepMut(state, { { player = 1, type = "launch_bird", structId = id, laneY = 18 } }, 0)
		local exited = false
		for _ = 1, 400 do
			local _, evs = Rules.stepMut(state, {}, 0.25)
			if T.findEvent(evs, "bird_exit") then
				exited = true
				break
			end
		end
		T.ok(exited, "bird crossed uncontested")
		local revealed = state.players[1].stats.cellsRevealed
		-- SPEC §7: ~8 × 36 = 288 cells per uncontested pass.
		T.ok(revealed >= 270 and revealed <= 300, "lane reveal ~288, got " .. revealed)
	end,

	["a nest downs a bird mid-lane and the reveal stops there"] = function()
		-- Weaker birds via config override so the kill is unambiguous.
		local config = Config.withOverrides({ BIRD_HP = 10 })
		local state = Helpers.startCombat(config, 42)
		-- P2 nest at island center; P1 flies the center lane.
		state.players[2].coin = 100
		Rules.stepMut(state, { { player = 2, type = "place", kind = "nest", x = 18, y = 18 } }, 0)
		Helpers.run(state, config.BUILD_SECONDS + 0.01)
		state.players[1].coin = 500
		local id = Helpers.placeAndBuild(state, 1, "perch", 30, 18)
		state.players[1].charge = config.CHARGE_CAP
		Rules.stepMut(state, { { player = 1, type = "launch_bird", structId = id, laneY = 18 } }, 0)
		local all = {}
		for _ = 1, 400 do
			local _, evs = Rules.stepMut(state, {}, 0.25)
			for _, e in evs do
				table.insert(all, e)
			end
			if T.findEvent(all, "bird_down") then
				break
			end
		end
		T.ok(T.findEvent(all, "bird_down"), "bird shot down")
		T.ok(T.findEvent(all, "nest_fired"), "nest revealed itself by firing")
		-- The firing nest's own cell is now plotted for the attacker.
		T.eq(state.players[1].belief[Grid.key(18, 18)].kind, "nest")
		-- Reveal stopped mid-island: the far edge of the lane is still fog.
		T.eq(state.players[1].belief[Grid.key(4, 18)], nil, "reveal stopped where the bird fell")
		T.eq(state.players[1].stats.birdsLost, 1)
	end,

	["bird lane width is the perch's tier stat, and tier 0 matches the config"] = function()
		local Weapons = require("../src/shared/weapons")
		T.eq(
			Weapons.getStat(Config, "perch", 0, "reveal_size"),
			Config.BIRD_LANE_WIDTH,
			"tier 0 lane width is the documented BIRD_LANE_WIDTH"
		)
		-- Upgrading widens the lane, so a bird flown late in a match
		-- reveals more than the opening one did.
		T.ok(Weapons.getStat(Config, "perch", 1, "reveal_size") > Config.BIRD_LANE_WIDTH, "tier 1 is wider")
		T.ok(
			Weapons.getStat(Config, "perch", 2, "reveal_size")
				> Weapons.getStat(Config, "perch", 1, "reveal_size"),
			"tier 2 is wider still"
		)
		T.eq(Weapons.getStat(Config, "perch", 2, "role"), "find", "still a scout, never a weapon")
		T.eq(Weapons.getStat(Config, "perch", 2, "damage"), 0, "an upgraded perch still does no damage")

		-- And the widened lane actually reveals more ground in play.
		local function laneCells(tier: number): number
			local state = Helpers.startCombat(Config, 42)
			state.players[1].coin = 500
			local id = Helpers.placeAndBuild(state, 1, "perch", 30, 18)
			state.players[1].structures[id].tier = tier
			state.players[1].charge = Config.CHARGE_CAP
			Rules.stepMut(state, { { player = 1, type = "launch_bird", structId = id, laneY = 18 } }, 0)
			for _ = 1, 400 do
				local _, evs = Rules.stepMut(state, {}, 0.25)
				if T.findEvent(evs, "bird_exit") then
					break
				end
			end
			return state.players[1].stats.cellsRevealed
		end
		T.ok(laneCells(1) > laneCells(0), "an upgraded perch reveals more per pass")
	end,

	["FLIGHT_LINE_REVEAL_WIDTH actually controls the flight-line reveal"] = function()
		-- Flight lines are a second source of intel alongside bird lanes,
		-- so this constant has to be a real knob, not a comment.
		local function lineRevealed(width: number): boolean
			local config = Config.withOverrides({ FLIGHT_LINE_REVEAL_WIDTH = width })
			local state = Helpers.startCombat(config, 42)
			state.players[1].coin = 500
			local id = Helpers.placeAndBuild(state, 1, "catapult", 33, 18)
			state.players[1].charge = config.CHARGE_CAP
			Rules.stepMut(state, { { player = 1, type = "fire", structId = id, x = 20, y = 18 } }, 0)
			for _ = 1, 200 do
				local _, evs = Rules.stepMut(state, {}, 0.25)
				if T.findEvent(evs, "impact") then
					break
				end
			end
			-- (30,18) lies on the flight path but well outside the 3-cell
			-- impact circle around (20,18).
			return state.players[1].belief[Grid.key(30, 18)] ~= nil
		end
		T.eq(lineRevealed(1), true, "width 1 traces the flight path")
		T.eq(lineRevealed(0), false, "width 0 disables flight-line recon")
		T.eq(lineRevealed(3), true, "wider still traces it")
	end,

	["upgrades change stats but never grant a new role"] = function()
		local state = Helpers.startCombat(Config, 42)
		local id = armCatapult(state)
		Rules.stepMut(state, { { player = 1, type = "upgrade", structId = id } }, 0)
		local s = state.players[1].structures[id]
		T.eq(s.tier, 1)
		local Weapons = require("../src/shared/weapons")
		T.eq(Weapons.getStat(Config, "catapult", 1, "cooldown"), 4.5, "tier 1 cooldown")
		T.eq(Weapons.getStat(Config, "catapult", 1, "damage"), 8, "tier 1 damage unchanged")
		T.eq(Weapons.getStat(Config, "catapult", 2, "damage"), 11, "tier 2 damage")
		T.eq(Weapons.getStat(Config, "catapult", 2, "cooldown"), 4.5, "tier overrides are cumulative")
		T.eq(Weapons.getStat(Config, "catapult", 2, "role"), "kill", "role never changes")
		-- Third upgrade rejected at max tier.
		Rules.stepMut(state, { { player = 1, type = "upgrade", structId = id } }, 0)
		local ok, err = Rules.validateCommand(state, { player = 1, type = "upgrade", structId = id })
		T.eq(ok, false)
		T.eq(err, "max tier")
	end,

	["bulldoze frees the cells with no refund"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].coin = 100
		local id = Helpers.placeAndBuild(state, 1, "grove", 14, 14)
		local coinBefore = state.players[1].coin
		Rules.stepMut(state, { { player = 1, type = "bulldoze", structId = id } }, 0)
		T.eq(state.players[1].coin, coinBefore, "no refund")
		T.eq(state.players[1].occ[Grid.key(14, 14)], nil, "cell free")
		local ok = Rules.validateCommand(state, { player = 1, type = "place", kind = "grove", x = 14, y = 14 })
		T.eq(ok, true, "can rebuild on the spot")
	end,

	["match timeout resolves by tiebreak"] = function()
		local config = Config.withOverrides({ MATCH_TIMEOUT = 10 })
		local state = Helpers.startCombat(config, 42)
		-- P2 loses a (non-base) structure so P1 leads on structures? Bases
		-- are equal; give P1 an extra structure instead.
		state.players[1].coin = 100
		Helpers.placeAndBuild(state, 1, "grove", 14, 14)
		Helpers.run(state, 12)
		T.eq(state.phase, "ended")
		T.eq(state.endReason, "timeout")
		T.eq(state.winner, 1, "more structures/coin spent wins the tiebreak")
	end,
}
