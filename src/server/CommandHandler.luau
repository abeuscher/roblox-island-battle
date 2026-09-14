--!strict
-- CommandHandler.luau — validates every client request (SPEC §8).
--
-- The client never computes damage, reveal, or resource change. It sends
-- REQUESTS; this module decides whether they happen. Three gates, in order:
--
--   1. Rate limit. Remotes are cheap to spam, so every player has a token
--      bucket and floods are dropped before any work is done.
--   2. Shape. A remote payload is attacker-controlled data, so every field
--      is type- and range-checked before it is allowed near the rules.
--   3. Rules. The surviving command goes through the identical
--      Rules.validateCommand the simulation and the bot use. There is no
--      second, more permissive validation path anywhere in the codebase.
--
-- The player index is stamped here from the server's own mapping, never
-- read from the payload, so a client cannot act for its opponent.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared.rules)

local CommandHandler = {}
CommandHandler.__index = CommandHandler

-- Token bucket: a burst of BURST actions, refilling at RATE per second.
-- Generous next to the ~1 action/2.5s a human plays at, tight enough that
-- a scripted client cannot flood the server loop.
local RATE = 6
local BURST = 12

export type Bucket = { tokens: number, last: number }

function CommandHandler.new()
	return setmetatable({
		buckets = {} :: { [number]: Bucket },
		rejections = {} :: { [number]: number },
	}, CommandHandler)
end

function CommandHandler:allow(playerIndex: number, now: number): boolean
	local bucket = self.buckets[playerIndex]
	if not bucket then
		bucket = { tokens = BURST, last = now }
		self.buckets[playerIndex] = bucket
	end
	bucket.tokens = math.min(BURST, bucket.tokens + (now - bucket.last) * RATE)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local VALID_TYPES = {
	place_base = true,
	place = true,
	bulldoze = true,
	upgrade = true,
	fire = true,
	launch_bird = true,
	ready = true,
}

local function isCell(value: any, max: number): boolean
	return type(value) == "number"
		and value == value -- reject NaN
		and value == math.floor(value)
		and value >= 1
		and value <= max
end

-- Shape check. Returns a clean command table built field by field from the
-- payload — the payload table itself is never passed through, so no extra
-- attacker-supplied fields can ride along into the rules.
function CommandHandler:sanitize(playerIndex: number, payload: any, config: any): (any?, string?)
	if type(payload) ~= "table" then
		return nil, "malformed"
	end
	local commandType = payload.type
	if type(commandType) ~= "string" or not VALID_TYPES[commandType] then
		return nil, "unknown command"
	end

	local d = config.ISLAND_DIAMETER
	local cmd: any = { player = playerIndex, type = commandType }

	if commandType == "place_base" or commandType == "place" then
		if not isCell(payload.x, d) or not isCell(payload.y, d) then
			return nil, "bad cell"
		end
		cmd.x, cmd.y = payload.x, payload.y
		if commandType == "place" then
			if type(payload.kind) ~= "string" or config.WEAPONS[payload.kind] == nil then
				return nil, "bad kind"
			end
			cmd.kind = payload.kind
		end
	elseif commandType == "bulldoze" or commandType == "upgrade" then
		if type(payload.structId) ~= "number" or payload.structId ~= math.floor(payload.structId) then
			return nil, "bad structId"
		end
		cmd.structId = payload.structId
	elseif commandType == "fire" then
		if type(payload.structId) ~= "number" or payload.structId ~= math.floor(payload.structId) then
			return nil, "bad structId"
		end
		if not isCell(payload.x, d) or not isCell(payload.y, d) then
			return nil, "bad cell"
		end
		cmd.structId, cmd.x, cmd.y = payload.structId, payload.x, payload.y
	elseif commandType == "launch_bird" then
		if type(payload.structId) ~= "number" or payload.structId ~= math.floor(payload.structId) then
			return nil, "bad structId"
		end
		if not isCell(payload.laneY, d) then
			return nil, "bad lane"
		end
		cmd.structId, cmd.laneY = payload.structId, payload.laneY
	end

	return cmd, nil
end

-- Full pipeline for one request. Returns the command to queue, or nil plus
-- the reason it was refused.
function CommandHandler:accept(state: any, playerIndex: number, payload: any, now: number): (any?, string?)
	if not self:allow(playerIndex, now) then
		self.rejections[playerIndex] = (self.rejections[playerIndex] or 0) + 1
		return nil, "rate limited"
	end
	local cmd, shapeError = self:sanitize(playerIndex, payload, state.config)
	if not cmd then
		return nil, shapeError
	end
	-- Same validation the sim and the bot go through, no exceptions.
	local ok, ruleError = Rules.validateCommand(state, cmd)
	if not ok then
		return nil, ruleError
	end
	return cmd, nil
end

return CommandHandler
