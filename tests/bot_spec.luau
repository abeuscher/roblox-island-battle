--!strict
-- bot_spec.luau — the bot plays by the same rules and the same fog (SPEC §9).

local T = require("./lib")
local Rules = require("../src/shared/rules")
local Config = require("../src/shared/config")
local Grid = require("../src/shared/grid")
local BotBrain = require("../src/shared/botbrain")
local Agent = require("../src/shared/agent")
local Helpers = require("./helpers")

-- Drives a bot in seat `seat` for `seconds`, one decision per decision tick.
local function runBot(state, seat: number, seconds: number, preset: string?)
	local difficulty = BotBrain.difficulty(state.config, preset or "skirmish")
	local memory = BotBrain.asAgent(preset or "skirmish").newMemory(7)
	memory.playerIndex = seat
	local ctx = { config = state.config, difficulty = difficulty }
	local nextDecision = 0
	local elapsed = 0
	local dt = 0.25
	local issued = {}
	while elapsed < seconds and state.phase ~= "ended" do
		local commands = {}
		if elapsed >= nextDecision then
			local view = Rules.viewFor(state, seat)
			local cmd = BotBrain.decide(view, memory, ctx)
			if cmd then
				cmd.player = seat
				table.insert(commands, cmd)
				table.insert(issued, cmd)
				nextDecision = elapsed + difficulty.decisionSeconds
			else
				nextDecision = elapsed + 1
			end
		end
		local _, events = Rules.stepMut(state, commands, dt)
		Agent.observeEvents(memory, Rules.filterEventsFor(events, seat), state.time)
		elapsed += dt
	end
	return memory, issued
end

return {
	["the bot places three bases and a decoy during setup"] = function()
		local state = Rules.newMatch(Config, 31)
		runBot(state, 1, Config.SETUP_SECONDS + 2)
		T.eq(state.players[1].basesPlaced, 3, "three bases")
		T.ok(Agent.countOwn(Rules.viewFor(state, 1), "decoy_base") >= 1, "at least one decoy")
	end,

	["the bot's bases are spread out and one sits by an obstacle"] = function()
		local state = Rules.newMatch(Config, 31)
		runBot(state, 1, Config.SETUP_SECONDS + 2)
		local bases = {}
		for _, s in state.players[1].structures do
			if s.kind == "base" then
				table.insert(bases, s)
			end
		end
		T.eq(#bases, 3)
		for i = 1, #bases do
			for j = i + 1, #bases do
				T.ok(
					Grid.dist(bases[i].x, bases[i].y, bases[j].x, bases[j].y) >= 8,
					"bases are spread apart"
				)
			end
		end
		local nearObstacle = false
		for _, b in bases do
			for key in state.players[1].island.obstacles do
				local ox, oy = Grid.parseKey(key)
				if Grid.dist(b.x, b.y, ox, oy) <= 4 then
					nearObstacle = true
				end
			end
		end
		T.ok(nearObstacle, "at least one base is tucked against an obstacle")
	end,

	["the bot never issues an illegal command"] = function()
		local state = Helpers.startCombat(Config, 55)
		local rejected = 0
		local memory = BotBrain.asAgent("skirmish").newMemory(7)
		memory.playerIndex = 1
		local ctx = { config = Config, difficulty = BotBrain.difficulty(Config, "skirmish") }
		local nextDecision, elapsed = 0, 0
		while elapsed < 300 and state.phase ~= "ended" do
			local commands = {}
			if elapsed >= nextDecision then
				local cmd = BotBrain.decide(Rules.viewFor(state, 1), memory, ctx)
				if cmd then
					cmd.player = 1
					table.insert(commands, cmd)
					nextDecision = elapsed + 3
				else
					nextDecision = elapsed + 1
				end
			end
			local _, events = Rules.stepMut(state, commands, 0.25)
			for _, e in events do
				if e.type == "command_rejected" then
					rejected += 1
				end
			end
			Agent.observeEvents(memory, Rules.filterEventsFor(events, 1), state.time)
			elapsed += 0.25
		end
		T.eq(rejected, 0, "the bot obeys the same validation as a player")
	end,

	["the bot builds all three legs: find, kill, blind"] = function()
		local state = Helpers.startCombat(Config, 55)
		runBot(state, 1, 240)
		local view = Rules.viewFor(state, 1)
		T.ok(Agent.countOwn(view, "perch") >= 1, "has a perch (find)")
		T.ok(Agent.countOwn(view, "catapult") >= 1, "has a catapult (kill)")
		T.ok(Agent.countOwn(view, "nest") >= 1, "has a nest (blind)")
		T.ok(Agent.countOwn(view, "grove") >= 1, "has income")
	end,

	["the bot scouts, then converts intel into fire"] = function()
		local state = Helpers.startCombat(Config, 55)
		runBot(state, 1, 400)
		T.ok(state.players[1].stats.birdsFlown > 0, "flew birds")
		T.ok(state.players[1].stats.shotsFired > 0, "fired shots")
		T.ok(state.players[1].stats.cellsRevealed > 200, "opened real map")
	end,

	["a decoy genuinely fools the bot"] = function()
		local state = Helpers.startCombat(Config, 55)
		-- The enemy's only "base" the bot will ever plot at (20,20) is fake.
		state.players[2].coin = 200
		Rules.stepMut(state, { { player = 2, type = "place", kind = "decoy_base", x = 20, y = 20 } }, 0)
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		-- Hand the bot the plot directly, then let it act on it.
		local Fog = require("../src/shared/fog")
		Fog.reveal(state, 1, { { 20, 20 }, { 21, 21 }, { 22, 22 } })
		-- Short window: long enough for the bot to shell the plot it was
		-- handed, short enough that it has not gone on to find real bases.
		local memory = runBot(state, 1, 120)
		T.ok(memory.believedKills >= 1, "the bot believes it killed a base")
		T.ok(state.players[1].stats.timesFooledByDecoy >= 1, "it was fooled")
		T.ok(
			state.players[1].stats.believedBaseKills > state.players[1].stats.realBaseKills,
			"its own kill count overstates reality — the deception landed"
		)
		T.ok(memory.killedSites[Grid.key(20, 20)] ~= nil, "it stops shelling the site it thinks is dead")
	end,

	["easy stays fooled forever, hard re-probes"] = function()
		local easy = Agent.newMemory(1)
		local hard = Agent.newMemory(1)
		local site = Grid.key(20, 20)
		easy.killedSites[site] = 0
		hard.killedSites[site] = 0
		local easyDiff = BotBrain.difficulty(Config, "beachcomber")
		local hardDiff = BotBrain.difficulty(Config, "siege")
		Agent.forgetOldKills(easy, 200, easyDiff.reprobeAfter)
		Agent.forgetOldKills(hard, 200, hardDiff.reprobeAfter)
		T.ok(easy.killedSites[site] ~= nil, "beachcomber never re-probes")
		T.eq(hard.killedSites[site], nil, "siege re-probes after 90s")
	end,

	["difficulty presets differ only in the documented knobs"] = function()
		local easy = BotBrain.difficulty(Config, "beachcomber")
		local mid = BotBrain.difficulty(Config, "skirmish")
		local hard = BotBrain.difficulty(Config, "siege")
		T.eq(easy.decisionSeconds, 5)
		T.eq(mid.decisionSeconds, 3)
		T.eq(hard.decisionSeconds, 2)
		T.eq(easy.coinMultiplier, 0.8)
		T.eq(mid.coinMultiplier, 1.0)
		T.eq(hard.coinMultiplier, 1.25)
	end,

	["the coin multiplier runs through the economy, not around it"] = function()
		local state = Helpers.startCombat(Config, 55)
		state.players[1].coinMultiplier = 2
		local before1, before2 = state.players[1].coin, state.players[2].coin
		Helpers.run(state, Config.COIN_TICK_SECONDS * 3 + 0.01)
		T.eq(state.players[1].coin - before1, 6, "doubled income")
		T.eq(state.players[2].coin - before2, 3, "opponent unaffected")
	end,

	["the bot reads only its own view"] = function()
		-- BotBrain.decide takes (view, memory, ctx). Passing a view whose
		-- belief map is empty must leave it with nothing to shoot at, even
		-- though the true state is full of enemy structures.
		local state = Helpers.startCombat(Config, 55)
		state.players[2].coin = 500
		for _, cell in { { 20, 20 }, { 22, 22 }, { 24, 24 } } do
			Rules.stepMut(state, { { player = 2, type = "place", kind = "nest", x = cell[1], y = cell[2] } }, 0)
		end
		Helpers.run(state, Config.BUILD_SECONDS + 0.01)
		state.players[1].coin = 500
		Helpers.placeAndBuild(state, 1, "catapult", 33, 18)
		state.players[1].charge = Config.CHARGE_CAP
		local memory = BotBrain.asAgent("siege").newMemory(3)
		memory.playerIndex = 1
		local view = Rules.viewFor(state, 1)
		T.eq(next(view.belief), nil, "no plots yet")
		local cmd = BotBrain.decide(view, memory, { config = Config, difficulty = BotBrain.difficulty(Config, "siege") })
		T.ok(cmd == nil or cmd.type ~= "fire", "with no intel the bot does not fire, despite targets existing")
	end,
}
