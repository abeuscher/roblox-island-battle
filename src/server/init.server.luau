--!strict
-- Server entry point. Seats the first player, gives the second seat to the
-- bot so a 1v1 game is playable solo (SPEC §9), and starts the match.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)

local MatchService = require(script.MatchService)

local service = MatchService.new(Config)

-- Seat 2 is the bot until a second human joins the server. Difficulty
-- presets: beachcomber / skirmish / siege (SPEC §9).
service:useBot(2, "skirmish")
service:bind()
service:startMatch()

-- A finished match offers an immediate rematch on a fresh seed (SPEC §6).
_G.IslandSiegeRematch = function()
	service:rematch()
end
