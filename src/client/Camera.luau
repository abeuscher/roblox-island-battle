--!strict
-- Camera.luau — fixed top-down over your own island, with a toggle to the
-- enemy intel view (SPEC §3). Both islands never need to be on screen at
-- once, which is what lets each one fill the frame.

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)

local Camera = {}
Camera.__index = Camera

local S = Config.STUDS_PER_CELL
local D = Config.ISLAND_DIAMETER

-- High enough to frame a 36-cell island with margin, tilted slightly so
-- structures read as objects rather than flat tiles.
local HEIGHT = D * S * 1.15
local TILT = math.rad(-72)

function Camera.new()
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local self = setmetatable({
		camera = camera,
		side = "own",
	}, Camera)
	self:snapTo("own", true)
	return self
end

local function centerOf(side: string): Vector3
	local mid = (D + 1) / 2
	if side == "own" then
		return Vector3.new(mid * S, 0, mid * S)
	end
	-- Enemy island center, using the same geometry the rules use.
	local enemyX = D + Config.CHANNEL_WIDTH + (D - mid)
	return Vector3.new(enemyX * S, 0, mid * S)
end

function Camera:snapTo(side: string, instant: boolean?)
	self.side = side
	local center = centerOf(side)
	local position = center + Vector3.new(0, HEIGHT, HEIGHT * 0.32)
	local target = CFrame.new(position, center)
	if instant then
		self.camera.CFrame = target
	else
		TweenService:Create(self.camera, TweenInfo.new(0.45, Enum.EasingStyle.Quad), { CFrame = target }):Play()
	end
end

-- Toggling to the intel view is how a player reads their belief map. It is
-- purely a camera move: the enemy island's contents were already decided by
-- what the server revealed, so there is nothing here to gate.
function Camera:toggle()
	self:snapTo(self.side == "own" and "enemy" or "own")
	return self.side
end

function Camera:isOnEnemy(): boolean
	return self.side == "enemy"
end

-- Converts a screen position to a grid cell on the side currently framed.
-- Returns cell x, y and which island was hit, or nil when the ray misses
-- the play plane.
function Camera:cellUnderCursor(screenPosition: Vector2): (number?, number?, string?)
	local ray = self.camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
	if math.abs(ray.Direction.Y) < 1e-6 then
		return nil, nil, nil
	end
	-- Intersect the y = 0 ground plane.
	local t = -ray.Origin.Y / ray.Direction.Y
	if t < 0 then
		return nil, nil, nil
	end
	local hit = ray.Origin + ray.Direction * t
	local worldX = hit.X / S
	local y = math.floor(hit.Z / S + 0.5)

	if self.side == "own" then
		local x = math.floor(worldX + 0.5)
		if x >= 1 and x <= D and y >= 1 and y <= D then
			return x, y, "own"
		end
	else
		-- Invert the enemy-frame mapping from Render:worldPosition.
		local x = math.floor(D + Config.CHANNEL_WIDTH + D - worldX + 0.5)
		if x >= 1 and x <= D and y >= 1 and y <= D then
			return x, y, "enemy"
		end
	end
	return nil, nil, nil
end

-- A distinct shake when one of your own bases takes a hit (SPEC §10).
function Camera:shake(intensity: number)
	local original = self.camera.CFrame
	task.spawn(function()
		for i = 1, 8 do
			local decay = intensity * (1 - i / 8)
			self.camera.CFrame = original * CFrame.new(
				(math.random() - 0.5) * decay,
				(math.random() - 0.5) * decay,
				0
			)
			task.wait(0.03)
		end
		self.camera.CFrame = original
	end)
end

return Camera
