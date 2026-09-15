--!strict
-- Input.luau — grid-and-tap input. Every action leaves here as a REQUEST;
-- the client never decides whether it succeeds (SPEC §8).
--
-- Three modes:
--   build    — a palette entry is selected; clicking your own island asks
--              the server to place it there
--   target   — a catapult is selected; clicking the enemy intel view asks
--              the server to fire at that cell
--   lane     — a perch is selected; clicking the enemy view picks the
--              bird's lane
-- Right click or Escape clears the mode. Tab toggles the intel view.

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RequestRemote = Remotes:WaitForChild("Request") :: RemoteEvent

local Input = {}
Input.__index = Input

-- `getView` returns the client's current fog-gated snapshot. It is used
-- only to resolve a clicked own-island cell to one of the player's own
-- structure ids; every resulting request is still validated server-side.
function Input.new(camera: any, getView: (() -> any)?, onModeChanged: ((string, any) -> ())?)
	return setmetatable({
		camera = camera,
		getView = getView,
		mode = "none",
		payload = nil :: any,
		onModeChanged = onModeChanged,
	}, Input)
end

-- Resolved from the structures the client already holds rather than from a
-- replicated occupancy map, so it stays correct after a delta that only
-- carried the structure list. These are all the player's OWN structures;
-- there is no enemy equivalent, by design.
local function structureAt(view: any, x: number, y: number): number?
	if not view or not view.structures then
		return nil
	end
	for id, s in view.structures do
		local def = Config.WEAPONS[s.kind]
		local footprint = def and def.footprint or 1
		if x >= s.x and x < s.x + footprint and y >= s.y and y < s.y + footprint then
			return id
		end
	end
	return nil
end

function Input:setMode(mode: string, payload: any?)
	self.mode = mode
	self.payload = payload
	-- Targeting lives on the enemy island, building on your own, so the
	-- camera follows the mode instead of making the player do it.
	if mode == "target" or mode == "lane" then
		self.camera:snapTo("enemy")
	elseif mode == "build" then
		self.camera:snapTo("own")
	end
	if self.onModeChanged then
		self.onModeChanged(mode, payload)
	end
end

function Input:clear()
	self:setMode("none", nil)
end

function Input:send(request: any)
	RequestRemote:FireServer(request)
end

function Input:handleClick(screenPosition: Vector2, phase: string)
	local x, y, side = self.camera:cellUnderCursor(screenPosition)
	if not x or not y then
		return
	end

	if self.mode == "build" and side == "own" then
		local kind = self.payload
		if kind == "base" then
			self:send({ type = "place_base", x = x, y = y })
			-- Placing bases is a setup-phase sequence, so the mode stays
			-- active until all three are down.
		else
			self:send({ type = "place", kind = kind, x = x, y = y })
		end
	elseif self.mode == "target" and side == "enemy" then
		self:send({ type = "fire", structId = self.payload, x = x, y = y })
		self:clear()
	elseif self.mode == "lane" and side == "enemy" then
		self:send({ type = "launch_bird", structId = self.payload, laneY = y })
		self:clear()
	elseif self.mode == "bulldoze" and side == "own" then
		local view = self.getView and self.getView() or nil
		local structId = structureAt(view, x, y)
		if structId then
			self:send({ type = "bulldoze", structId = structId })
		end
		-- Bulldoze mode stays active so several can be cleared in a row;
		-- right click or Escape exits it.
	elseif self.mode == "upgrade" and side == "own" then
		local view = self.getView and self.getView() or nil
		local structId = structureAt(view, x, y)
		if structId then
			self:send({ type = "upgrade", structId = structId })
		end
	end
end

function Input:bind()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local position = input.Position
			self:handleClick(Vector2.new(position.X, position.Y), "")
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:clear()
		elseif input.KeyCode == Enum.KeyCode.Escape then
			self:clear()
		elseif input.KeyCode == Enum.KeyCode.Tab then
			self.camera:toggle()
		end
	end)
end

return Input
