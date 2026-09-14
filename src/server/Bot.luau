--!strict
-- Bot.luau — the clock that drives the pure bot FSM (SPEC §9).
--
-- All the decision-making lives in ReplicatedStorage.Shared.botbrain, which
-- is pure Luau and therefore covered by the headless test suite and
-- runnable in the sim harness. This file only does the three things that
-- need a running game: keep a decision timer, hand the brain the same
-- fog-gated view a human client receives, and push its commands through
-- the identical validation every player's commands go through.
--
-- The bot has no privileged access. It cannot read the player's island
-- except through its own recon plots, which is why decoys fool it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared.rules)
local Agent = require(Shared.agent)
local BotBrain = require(Shared.botbrain)

local Bot = {}
Bot.__index = Bot

-- `preset` is one of config.BOT_PRESETS: beachcomber / skirmish / siege.
function Bot.new(config: any, playerIndex: number, preset: string, seed: number)
	local difficulty = BotBrain.difficulty(config, preset)
	local memory = BotBrain.asAgent(preset).newMemory(seed)
	memory.playerIndex = playerIndex
	return setmetatable({
		playerIndex = playerIndex,
		preset = preset,
		difficulty = difficulty,
		memory = memory,
		ctx = { config = config, difficulty = difficulty },
		nextDecision = 0,
	}, Bot)
end

-- The one asymmetry between the bot and a human, and it runs through the
-- rules rather than around them: difficulty scales income (SPEC §9).
function Bot:applyDifficulty(state: any)
	state.players[self.playerIndex].coinMultiplier = self.difficulty.coinMultiplier
end

-- Returns a command to queue this tick, or nil. `now` is match time.
function Bot:tick(state: any, now: number): any?
	if now < self.nextDecision then
		return nil
	end
	-- FOG BOUNDARY: the bot sees exactly what a client of the same seat
	-- would be sent, and nothing more.
	local view = Rules.viewFor(state, self.playerIndex)
	local cmd = BotBrain.decide(view, self.memory, self.ctx)
	if cmd then
		cmd.player = self.playerIndex
		self.nextDecision = now + self.difficulty.decisionSeconds
		return cmd
	end
	-- Nothing worth doing: look again shortly rather than idling out a
	-- whole decision interval.
	self.nextDecision = now + 1
	return nil
end

-- Feeds the bot only the events its seat is allowed to see. The decoy
-- deception lives entirely in here: a fake-kill event is byte-identical to
-- a real one, so the bot's kill count is a belief (SPEC §5).
function Bot:observe(events: { any }, now: number)
	Agent.observeEvents(self.memory, Rules.filterEventsFor(events, self.playerIndex), now)
end

function Bot:reset(seed: number)
	self.memory = BotBrain.asAgent(self.preset).newMemory(seed)
	self.memory.playerIndex = self.playerIndex
	self.nextDecision = 0
end

return Bot
