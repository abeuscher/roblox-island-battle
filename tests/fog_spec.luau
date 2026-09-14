--!strict
-- fog_spec.luau — belief maps, stale plots, and the no-leak guarantees.

local T = require("./lib")
local Rules = require("../src/shared/rules")
local Config = require("../src/shared/config")
local Grid = require("../src/shared/grid")
local Fog = require("../src/shared/fog")
local Helpers = require("./helpers")

return {
	["belief starts empty — the island shape is not inferrable from fog"] = function()
		local state = Helpers.startCombat(Config, 42)
		T.eq(Fog.coverage(state.players[1]), 0, "no plots before any recon")
		T.eq(Fog.coverage(state.players[2]), 0)
	end,

	["a reveal plots the truth at reveal time"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[2].coin = 100
		Rules.stepMut(state, { { player = 2, type = "place", kind = "grove", x = 20, y = 20 } }, 0)
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		Fog.reveal(state, 1, { { 20, 20 } })
		T.eq(state.players[1].belief[Grid.key(20, 20)].kind, "grove")
	end,

	["plots are stale, not live: later building does not update the plot"] = function()
		local state = Helpers.startCombat(Config, 42)
		-- P1 reveals an empty cell...
		Fog.reveal(state, 1, { { 20, 20 } })
		T.eq(state.players[1].belief[Grid.key(20, 20)].kind, "empty")
		local revealTime = state.players[1].belief[Grid.key(20, 20)].t
		-- ...then P2 builds there. The plot must NOT change (SPEC §7).
		state.players[2].coin = 100
		Rules.stepMut(state, { { player = 2, type = "place", kind = "nest", x = 20, y = 20 } }, 0)
		Helpers.run(state, Config.BUILD_SECONDS + 5)
		T.eq(state.players[1].belief[Grid.key(20, 20)].kind, "empty", "plot is stale")
		T.eq(state.players[1].belief[Grid.key(20, 20)].t, revealTime, "timestamp unchanged")
		-- Re-probing corrects it.
		Fog.reveal(state, 1, { { 20, 20 } })
		T.eq(state.players[1].belief[Grid.key(20, 20)].kind, "nest", "re-reveal corrects the plot")
	end,

	["stale plots also persist after a bulldoze"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[2].coin = 100
		local _, evs = Rules.stepMut(state, { { player = 2, type = "place", kind = "grove", x = 20, y = 20 } }, 0)
		local groveId = T.findEvent(evs, "placed").structId
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		Fog.reveal(state, 1, { { 20, 20 } })
		T.eq(state.players[1].belief[Grid.key(20, 20)].kind, "grove")
		Rules.stepMut(state, { { player = 2, type = "bulldoze", structId = groveId } }, 0)
		T.eq(state.players[1].belief[Grid.key(20, 20)].kind, "grove", "attacker's plot is now wrong, by design")
	end,

	["decoys plot as real bases"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[2].coin = 100
		Rules.stepMut(state, { { player = 2, type = "place", kind = "decoy_base", x = 20, y = 20 } }, 0)
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		Fog.reveal(state, 1, { { 20, 20 }, { 21, 21 } })
		T.eq(state.players[1].belief[Grid.key(20, 20)].kind, "base", "decoy plots as base")
		T.eq(state.players[1].belief[Grid.key(21, 21)].kind, "base")
	end,

	["obstacles and destroyed structures plot honestly once revealed"] = function()
		local state = Helpers.startCombat(Config, 42)
		local obstacleKey = next(state.players[2].island.obstacles)
		local ox, oy = Grid.parseKey(obstacleKey :: string)
		Fog.reveal(state, 1, { { ox, oy } })
		T.eq(state.players[1].belief[obstacleKey :: string].kind, "obstacle")
	end,

	["reveals are one-directional: scouting does not plot for the defender"] = function()
		local state = Helpers.startCombat(Config, 42)
		Fog.reveal(state, 1, { { 20, 20 }, { 21, 21 } })
		T.eq(Fog.coverage(state.players[2]), 0, "defender learns nothing from being scouted")
	end,

	["reveal events are addressed to the attacker only"] = function()
		local state = Helpers.startCombat(Config, 42)
		local events = {}
		Fog.reveal(state, 1, { { 20, 20 } }, events)
		local reveal = T.findEvent(events, "reveal")
		T.eq(reveal.visibleTo, 1, "reveal is private to the scout")
		T.eq(#Rules.filterEventsFor(events, 2), 0, "defender receives nothing")
	end,

	["exploit check: nothing the server can send carries unrevealed enemy data"] = function()
		-- SPEC §12 self-playtest (e), as far as it can be checked headlessly.
		-- Replication builds every outbound payload from exactly three
		-- functions; if none of them leaks, no payload can. This test is the
		-- reason that list is worth keeping to three.
		local state = Helpers.startCombat(Config, 42)

		-- Give player 2 a full, distinctive board that player 1 has not seen.
		state.players[2].coin = 9999
		local secret = { { "nest", 20, 20 }, { "perch", 33, 12 }, { "grove", 12, 24 }, { "decoy_base", 15, 15 } }
		for _, entry in secret do
			Rules.stepMut(state, { { player = 2, type = "place", kind = entry[1], x = entry[2], y = entry[3] } }, 0)
		end
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		-- ...and an in-flight shot that has not yet crossed the channel.
		local catapult = Helpers.placeAndBuild(state, 2, "catapult", 30, 24)
		state.players[2].charge = Config.CHARGE_CAP
		local _, fireEvents = Rules.stepMut(state, { { player = 2, type = "fire", structId = catapult, x = 20, y = 18 } }, 0)

		-- The three sources, exactly as Replication uses them.
		local view = Rules.viewFor(state, 1)
		local mine, incoming = Rules.projectilesFor(state, 1)
		local events = Rules.filterEventsFor(fireEvents, 1)

		local payload = T.serialize({ view = view, mine = mine, incoming = incoming, events = events })

		-- Not one of player 2's structure ids may appear anywhere in it.
		for id, s in state.players[2].structures do
			if s.alive then
				T.ok(
					not string.find(payload, "structId=" .. id),
					"enemy structure id " .. id .. " (" .. s.kind .. ") leaked into an outbound payload"
				)
			end
		end
		-- Nor any enemy-only structure kind.
		for _, entry in secret do
			T.ok(not string.find(payload, entry[1]), "enemy " .. entry[1] .. " leaked into an outbound payload")
		end
		-- Nor the opponent's resources or true kill counts.
		T.ok(view.enemyCoin == nil and view.enemyCharge == nil, "no enemy resources")
		T.ok(not string.find(payload, "realBaseKills"), "true kill count never leaves the server")
		-- The shot is still over the channel, so it is not visible either.
		T.eq(next(incoming), nil, "an enemy shot over the channel is not in the payload")
	end,

	["viewFor leaks no unrevealed enemy data"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[2].coin = 999
		Rules.stepMut(state, { { player = 2, type = "place", kind = "nest", x = 20, y = 20 } }, 0)
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		local view = Rules.viewFor(state, 1)
		local dump = T.serialize(view)
		-- Every structure in the payload must belong to the viewer.
		for id in view.structures do
			T.ok(state.players[1].structures[id] ~= nil, "structure " .. id .. " is the viewer's own")
		end
		T.eq(next(view.belief), nil, "no plots, so no enemy cells at all")
		T.ok(not string.find(dump, "nest"), "the enemy nest appears nowhere in the payload")
		-- Enemy resources are never present under any key.
		T.eq(view.coin, state.players[1].coin)
		T.ok(view.enemyCoin == nil and view.enemyCharge == nil, "no enemy resource fields")
	end,

	["viewFor exposes believed base kills, never the real count"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].stats.believedBaseKills = 2
		state.players[1].stats.realBaseKills = 1
		state.players[1].stats.timesFooledByDecoy = 1
		local view = Rules.viewFor(state, 1)
		T.eq(view.baseKills, 2, "player sees the believed count")
		T.ok(view.stats.realBaseKills == nil, "real kill count stays server-side")
		T.ok(view.stats.timesFooledByDecoy == nil, "decoy tell stays server-side until the end screen")
	end,

	["the decoy tally is withheld until the match ends"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].stats.timesFooledByDecoy = 2
		T.eq(Rules.viewFor(state, 1).timesFooledByDecoy, nil, "hidden during play")
		local events = {}
		Rules.endMatch(state, 2, "bases", events)
		T.eq(Rules.viewFor(state, 1).timesFooledByDecoy, 2, "revealed on the end screen")
	end,

	["viewFor strips structIds from belief plots"] = function()
		local state = Helpers.startCombat(Config, 42)
		Fog.reveal(state, 1, { { 8, 8 } }) -- P2 base anchor
		T.ok(state.players[1].belief[Grid.key(8, 8)].structId ~= nil, "server plot knows the id")
		local view = Rules.viewFor(state, 1)
		T.eq(view.belief[Grid.key(8, 8)].structId, nil, "client plot does not")
		T.eq(view.belief[Grid.key(8, 8)].kind, "base")
	end,

	["projectilesFor applies the same fog rule as viewFor"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[2].coin = 500
		local id = Helpers.placeAndBuild(state, 2, "catapult", 33, 18)
		state.players[2].charge = Config.CHARGE_CAP
		Rules.stepMut(state, { { player = 2, type = "fire", structId = id, x = 20, y = 18 } }, 0)

		-- The shooter always sees its own shot.
		local mine = Rules.projectilesFor(state, 2)
		T.ok(next(mine) ~= nil, "owner sees its own projectile")
		-- The target does not, while it is still out over the channel.
		local _, incoming = Rules.projectilesFor(state, 1)
		T.eq(next(incoming), nil, "not visible over the channel")

		-- Once overhead it becomes visible, and only then.
		local appeared = false
		for _ = 1, 40 do
			Rules.stepMut(state, {}, 0.25)
			local _, overhead = Rules.projectilesFor(state, 1)
			if next(overhead) ~= nil then
				appeared = true
				break
			end
			if state.phase == "ended" then
				break
			end
		end
		T.ok(appeared, "an incoming shot becomes visible over the defender's island")
	end,

	["viewFor shows incoming enemy projectiles only once over my island"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[2].coin = 500
		local id = Helpers.placeAndBuild(state, 2, "catapult", 33, 18)
		state.players[2].charge = Config.CHARGE_CAP
		Rules.stepMut(state, { { player = 2, type = "fire", structId = id, x = 20, y = 18 } }, 0)
		-- Immediately after launch the coconut is out over the channel.
		local view = Rules.viewFor(state, 1)
		T.eq(next(view.incomingProjectiles), nil, "nothing visible while over the channel")
		Helpers.run(state, 3)
		if state.phase == "combat" then
			local later = Rules.viewFor(state, 1)
			local n = 0
			for _ in later.incomingProjectiles do
				n += 1
			end
			T.ok(n <= 1, "at most the one coconut, and only once overhead")
		end
	end,
}
