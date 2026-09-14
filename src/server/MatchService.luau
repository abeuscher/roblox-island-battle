--!strict
-- MatchService.luau — match lifecycle: lobby -> setup -> combat -> result.
--
-- The server holds the full MatchState and is authoritative over all of it
-- (SPEC §8). It advances the pure rules core on a fixed timestep, so the
-- simulation the sweep measured and the game people play are the same
-- system stepped by different clocks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)
local Rules = require(Shared.rules)

local Replication = require(script.Parent.Replication)
local CommandHandler = require(script.Parent.CommandHandler)
local Bot = require(script.Parent.Bot)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RequestRemote = Remotes:WaitForChild("Request") :: RemoteEvent

-- Fixed timestep: the rules core is deterministic, so it must not be fed
-- variable frame deltas. Leftover time carries to the next frame.
local STEP = 1 / 20

local MatchService = {}
MatchService.__index = MatchService

function MatchService.new(config: any?)
	local self = setmetatable({
		config = config or Config,
		state = nil :: any,
		-- seat index (1|2) -> Player, or nil when that seat is the bot
		seats = {} :: { [number]: Player? },
		seatOf = {} :: { [Player]: number },
		bot = nil :: any,
		botSeat = nil :: number?,
		replication = Replication.new(),
		commands = CommandHandler.new(),
		queue = {} :: { any },
		accumulator = 0,
		disconnected = {} :: { [number]: number },
		running = false,
	}, MatchService)
	return self
end

----------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------

function MatchService:startMatch(seed: number?)
	local actualSeed = seed or math.random(1, 2 ^ 31 - 1)
	self.state = Rules.newMatch(self.config, actualSeed)
	self.queue = {}
	self.accumulator = 0
	self.disconnected = {}

	if self.bot then
		self.bot:reset(actualSeed)
		self.bot:applyDifficulty(self.state)
	end

	for seat = 1, 2 do
		self.replication:reset(seat)
		self.replication:pushFull(self.state, seat, self.seats[seat])
	end
	self.running = true
end

-- Seats a player. The second seat falls back to a bot so a 1v1 game is
-- playable with an empty player base (SPEC §9).
function MatchService:addPlayer(player: Player): number?
	for seat = 1, 2 do
		if self.seats[seat] == nil and self.botSeat ~= seat then
			self.seats[seat] = player
			self.seatOf[player] = seat
			self.disconnected[seat] = nil
			if self.state then
				self.replication:reset(seat)
				self.replication:pushFull(self.state, seat, player)
			end
			return seat
		end
	end
	return nil
end

function MatchService:removePlayer(player: Player)
	local seat = self.seatOf[player]
	if not seat then
		return
	end
	self.seats[seat] = nil
	self.seatOf[player] = nil
	-- Grace period before the opponent is awarded the win (SPEC §6).
	self.disconnected[seat] = 0
end

function MatchService:useBot(seat: number, preset: string)
	self.botSeat = seat
	self.seats[seat] = nil
	self.bot = Bot.new(self.config, seat, preset, os.time())
	if self.state then
		self.bot:applyDifficulty(self.state)
	end
end

-- Rematch: a fresh seeded island without anyone rejoining (SPEC §6).
function MatchService:rematch()
	self:startMatch(nil)
end

----------------------------------------------------------------------------
-- Requests
----------------------------------------------------------------------------

function MatchService:onRequest(player: Player, payload: any)
	local seat = self.seatOf[player]
	if not seat or not self.state then
		return
	end

	-- Rematch is a lifecycle request rather than a game command, so it is
	-- handled here, but it still goes through the rate limiter and is only
	-- honoured once the match has actually ended.
	if type(payload) == "table" and payload.type == "rematch" then
		if self.commands:allow(seat, os.clock()) and self.state.phase == "ended" then
			self:rematch()
		end
		return
	end

	-- Every gate lives in CommandHandler; nothing here bypasses it. The
	-- seat comes from the server's own mapping, never from the payload.
	local cmd, reason = self.commands:accept(self.state, seat, payload, os.clock())
	if cmd then
		table.insert(self.queue, cmd)
	elseif reason and reason ~= "rate limited" then
		-- Tell the player why their click did nothing. Rate-limit drops are
		-- deliberately silent: answering a flood is how a flood becomes an
		-- amplification vector.
		self.replication:pushEvents(
			{ { type = "command_rejected", visibleTo = seat, reason = reason } },
			seat,
			player
		)
	end
end

----------------------------------------------------------------------------
-- The authoritative loop
----------------------------------------------------------------------------

function MatchService:step(dt: number)
	if not self.running or not self.state then
		return
	end
	local state = self.state

	self.accumulator += dt
	local pushEvents: { any } = {}
	local phaseBefore = state.phase

	while self.accumulator >= STEP do
		self.accumulator -= STEP

		if self.bot and state.phase ~= "ended" then
			local botCommand = self.bot:tick(state, state.time)
			if botCommand then
				-- The bot's command goes through the same validation a
				-- human's does; a bot that cheats is a bot that is not
				-- playing the game being balanced.
				local ok = Rules.validateCommand(state, botCommand)
				if ok then
					table.insert(self.queue, botCommand)
				end
			end
		end

		local commands = self.queue
		self.queue = {}
		local _, events = Rules.stepMut(state, commands, STEP)
		for _, e in events do
			table.insert(pushEvents, e)
		end
		if self.bot then
			self.bot:observe(events, state.time)
		end

		self:checkDisconnects(STEP, pushEvents)

		if state.phase == "ended" then
			break
		end
	end

	for seat = 1, 2 do
		local player = self.seats[seat]
		if player then
			if state.phase ~= phaseBefore then
				self.replication:pushFull(state, seat, player)
			else
				self.replication:pushDelta(state, seat, player)
			end
			self.replication:pushEvents(pushEvents, seat, player)
		end
	end

	if state.phase == "ended" then
		self.running = false
	end
end

function MatchService:checkDisconnects(dt: number, events: { any })
	if self.state.phase == "ended" then
		return
	end
	for seat, elapsed in self.disconnected do
		local waited = elapsed + dt
		self.disconnected[seat] = waited
		if waited >= self.config.DISCONNECT_GRACE then
			Rules.endMatch(self.state, 3 - seat, "disconnect", events)
			self.disconnected[seat] = nil
		end
	end
end

function MatchService:bind()
	RequestRemote.OnServerEvent:Connect(function(player, payload)
		self:onRequest(player, payload)
	end)
	Players.PlayerAdded:Connect(function(player)
		self:addPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:removePlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		self:addPlayer(player)
	end
	RunService.Heartbeat:Connect(function(dt)
		self:step(dt)
	end)
end

return MatchService
