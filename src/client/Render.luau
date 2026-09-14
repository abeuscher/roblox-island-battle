--!strict
-- Render.luau — structures, projectiles, fog (SPEC §10).
--
-- PLACEHOLDER-FIRST. Every structure is a colored Part at cell size plus a
-- BillboardGui glyph and an HP pip bar. Art is never a blocker.
--
-- THE SWAP CONTRACT (SPEC §10): at boot this looks for a Model at
-- ReplicatedStorage/Assets/Structures/<id> for every structure id, and at
-- Assets/Effects/<id> for projectile_coconut, bird, impact and rubble. If
-- one is present it is cloned and scaled to cell size; if absent the
-- placeholder is used silently. Dropping art in later needs zero code
-- changes. The full expected name list is in README.md.
--
-- THE FOG RULE (SPEC §8): enemy structure Instances are created only when
-- the server reveals them, and destroyed when the plot says they are gone.
-- Nothing on the enemy island is ever spawned-then-hidden: a client that
-- holds a hidden Instance has already lost the game's only secret.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)
local Grid = require(Shared.grid)

local Render = {}
Render.__index = Render

local S = Config.STUDS_PER_CELL

-- Placeholder colors and glyphs, one entry per structure id plus terrain.
local LOOK = {
	base = { color = Color3.fromRGB(92, 64, 44), glyph = "🥥", height = 3 },
	decoy_base = { color = Color3.fromRGB(92, 64, 44), glyph = "🥥", height = 3 },
	grove = { color = Color3.fromRGB(64, 148, 72), glyph = "🌴", height = 2.5 },
	catapult = { color = Color3.fromRGB(184, 68, 56), glyph = "🥥", height = 2 },
	perch = { color = Color3.fromRGB(216, 160, 64), glyph = "🐦", height = 2.5 },
	nest = { color = Color3.fromRGB(226, 208, 72), glyph = "🎯", height = 2 },
	obstacle = { color = Color3.fromRGB(122, 122, 128), glyph = "", height = 1.6 },
	rubble = { color = Color3.fromRGB(78, 70, 64), glyph = "", height = 0.6 },
	empty = { color = Color3.fromRGB(196, 176, 128), glyph = "", height = 0.4 },
	water = { color = Color3.fromRGB(44, 86, 124), glyph = "", height = 0.2 },
	-- Unrevealed enemy cells. Deliberately uniform: terrain, water and
	-- obstacles must NOT be renderable through fog or the island's shape
	-- leaks (SPEC §7).
	haze = { color = Color3.fromRGB(38, 46, 58), glyph = "", height = 1.2 },
}

-- Asset names the swap contract looks for. Keep in sync with README.md.
local EFFECT_ASSETS = { "projectile_coconut", "bird", "impact", "rubble" }

function Render.new(parent: Instance)
	local self = setmetatable({
		root = Instance.new("Folder"),
		assets = { structures = {}, effects = {} },
		ownCells = {},
		ownStructures = {} :: { [number]: Instance },
		enemyCells = {} :: { [string]: Instance },
		projectiles = {} :: { [number]: any },
		diameter = Config.ISLAND_DIAMETER,
	}, Render)
	self.root.Name = "IslandSiege"
	self.root.Parent = parent

	for _, name in { "OwnIsland", "EnemyIsland", "Projectiles", "Effects" } do
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = self.root
	end

	self:loadAssets()
	return self
end

-- The swap contract. Absent art is not an error; it is the default.
function Render:loadAssets()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return
	end
	local structures = assets:FindFirstChild("Structures")
	if structures then
		for id in Config.WEAPONS do
			local model = structures:FindFirstChild(id)
			if model and model:IsA("Model") then
				self.assets.structures[id] = model
			end
		end
	end
	local effects = assets:FindFirstChild("Effects")
	if effects then
		for _, name in EFFECT_ASSETS do
			local model = effects:FindFirstChild(name)
			if model and model:IsA("Model") then
				self.assets.effects[name] = model
			end
		end
	end
end

----------------------------------------------------------------------------
-- Coordinates
----------------------------------------------------------------------------

-- Own island sits at the origin; the enemy island is placed across the
-- channel using the identical geometry the rules use (Grid.toEnemyFrame),
-- so what the player sees and what the server computes cannot drift apart.
function Render:worldPosition(x: number, y: number, enemy: boolean, height: number): Vector3
	local wx = x
	if enemy then
		wx = Config.ISLAND_DIAMETER + Config.CHANNEL_WIDTH + (Config.ISLAND_DIAMETER - x)
	end
	return Vector3.new(wx * S, height * 0.5, y * S)
end

----------------------------------------------------------------------------
-- Placeholder construction
----------------------------------------------------------------------------

local function makeGlyph(parent: BasePart, glyph: string)
	if glyph == "" then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(2, 2)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, S * 0.8, 0)
	billboard.AlwaysOnTop = false
	billboard.Parent = parent
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = glyph
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = billboard
end

local function makeHpBar(parent: BasePart)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HpBar"
	billboard.Size = UDim2.fromScale(3, 0.4)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, S * 1.4, 0)
	billboard.Parent = parent
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	back.BorderSizePixel = 0
	back.Parent = billboard
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(96, 208, 112)
	fill.BorderSizePixel = 0
	fill.Parent = back
end

-- Builds one structure, from real art when it exists and a colored part
-- when it does not.
function Render:buildStructure(kind: string, x: number, y: number, enemy: boolean): Instance
	local def = Config.WEAPONS[kind]
	local footprint = def and def.footprint or 1
	local look = LOOK[kind] or LOOK.empty
	local asset = self.assets.structures[kind]

	local anchorOffset = (footprint - 1) * 0.5
	local position = self:worldPosition(x + anchorOffset, y + anchorOffset, enemy, look.height)

	if asset then
		local model = asset:Clone()
		model:PivotTo(CFrame.new(position))
		-- Scale the art to the cell footprint so any model fits the grid.
		local extents = model:GetExtentsSize()
		local target = footprint * S
		local scale = math.min(target / math.max(extents.X, 0.01), target / math.max(extents.Z, 0.01))
		if model.PrimaryPart then
			model:ScaleTo(scale)
		end
		return model
	end

	local part = Instance.new("Part")
	part.Name = kind
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(footprint * S * 0.92, look.height * S * 0.5, footprint * S * 0.92)
	part.Position = position
	part.Color = look.color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	makeGlyph(part, look.glyph)
	if kind ~= "obstacle" and kind ~= "rubble" and kind ~= "empty" then
		makeHpBar(part)
	end
	return part
end

----------------------------------------------------------------------------
-- Own island (always fully visible to its owner)
----------------------------------------------------------------------------

function Render:buildOwnIsland(island: any)
	local folder = self.root.OwnIsland
	folder:ClearAllChildren()
	self.ownCells = {}
	local d = island.diameter
	for x = 1, d do
		for y = 1, d do
			if Grid.inIsland(d, x, y) then
				local key = Grid.key(x, y)
				local kind = island.obstacles[key] and "obstacle" or "empty"
				local cell = self:buildStructure(kind, x, y, false)
				cell.Name = key
				cell.Parent = folder
				self.ownCells[key] = cell
			end
		end
	end
end

function Render:syncOwnStructures(structures: { [number]: any }, removed: { number }?)
	local folder = self.root.OwnIsland
	if removed then
		for _, id in removed do
			local existing = self.ownStructures[id]
			if existing then
				existing:Destroy()
				self.ownStructures[id] = nil
			end
		end
	end
	for id, s in structures do
		local existing = self.ownStructures[id]
		if existing then
			existing:Destroy()
		end
		local model = self:buildStructure(s.kind, s.x, s.y, false)
		model.Name = "struct_" .. id
		-- Under construction: inert and translucent so the build timer is
		-- legible without a separate readout.
		if model:IsA("BasePart") then
			model.Transparency = s.buildRemaining > 0 and 0.55 or 0
			local bar = model:FindFirstChild("HpBar")
			if bar then
				local fill = bar:FindFirstChild("Frame") and bar.Frame:FindFirstChild("Fill")
				if fill then
					fill.Size = UDim2.fromScale(math.clamp(s.hp / math.max(s.maxHp, 1), 0, 1), 1)
				end
			end
		end
		model.Parent = folder
		self.ownStructures[id] = model
	end
end

----------------------------------------------------------------------------
-- Enemy island (fog)
----------------------------------------------------------------------------

-- The enemy board starts as uniform haze. No terrain, no water, no
-- obstacles — nothing that would let the island's shape be inferred.
function Render:buildHaze()
	local folder = self.root.EnemyIsland
	folder:ClearAllChildren()
	self.enemyCells = {}
	local d = self.diameter
	for x = 1, d do
		for y = 1, d do
			local key = Grid.key(x, y)
			local cell = self:buildStructure("haze", x, y, true)
			cell.Name = key
			cell.Parent = folder
			self.enemyCells[key] = cell
		end
	end
end

-- Applies revealed plots. This is the ONLY way an enemy structure Instance
-- ever comes into existence on this client.
function Render:applyPlots(plots: { [string]: any })
	local folder = self.root.EnemyIsland
	for key, plot in plots do
		local existing = self.enemyCells[key]
		if existing then
			existing:Destroy()
		end
		local x, y = Grid.parseKey(key)
		local kind = plot.kind
		-- A decoy arrives already disguised: the server plots it as "base"
		-- (SPEC §7), so this code cannot tell them apart either.
		local cell = self:buildStructure(kind, x, y, true)
		cell.Name = key
		if cell:IsA("BasePart") then
			-- Plots are stale. Age them visually so the player can see that
			-- what they are looking at is a memory, not a live feed.
			local age = plot.t or 0
			cell.Transparency = 0
			local hpBar = cell:FindFirstChild("HpBar")
			if hpBar then
				hpBar:Destroy() -- enemy HP is not known, only the sighting
			end
		end
		cell.Parent = folder
		self.enemyCells[key] = cell
	end
end

-- Fog peeling back along a bird's lane, in real time (SPEC §10).
function Render:peelLane(cells: { { number } })
	for _, cell in cells do
		local key = Grid.key(cell[1], cell[2])
		local instance = self.enemyCells[key]
		if instance and instance:IsA("BasePart") then
			TweenService:Create(instance, TweenInfo.new(0.35), { Transparency = 0.25 }):Play()
		end
	end
end

----------------------------------------------------------------------------
-- Projectiles and feedback
----------------------------------------------------------------------------

local function makeShadowDot(parent: Instance): BasePart
	local dot = Instance.new("Part")
	dot.Name = "Shadow"
	dot.Anchored = true
	dot.CanCollide = false
	dot.Shape = Enum.PartType.Cylinder
	dot.Size = Vector3.new(0.2, S * 0.6, S * 0.6)
	dot.CFrame = CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.rad(90))
	dot.Color = Color3.new(0, 0, 0)
	dot.Transparency = 0.6
	dot.Material = Enum.Material.SmoothPlastic
	dot.Parent = parent
	return dot
end

-- Projectiles are rendered from the positions the server sends, which are
-- already fog-filtered: an enemy coconut appears only once it is over this
-- player's island.
function Render:syncProjectiles(mine: { [number]: any }, incoming: { [number]: any })
	local folder = self.root.Projectiles
	local seen = {}

	local function place(id: number, proj: any, enemySide: boolean)
		seen[id] = true
		local entry = self.projectiles[id]
		if not entry then
			local asset = self.assets.effects[proj.kind == "bird" and "bird" or "projectile_coconut"]
			local body
			if asset then
				body = asset:Clone()
			else
				body = Instance.new("Part")
				body.Anchored = true
				body.CanCollide = false
				body.Shape = proj.kind == "bird" and Enum.PartType.Block or Enum.PartType.Ball
				body.Size = proj.kind == "bird" and Vector3.new(S * 0.7, S * 0.35, S * 0.5)
					or Vector3.new(S * 0.5, S * 0.5, S * 0.5)
				body.Color = proj.kind == "bird" and Color3.fromRGB(216, 160, 64)
					or Color3.fromRGB(140, 92, 48)
				body.Material = Enum.Material.SmoothPlastic
			end
			body.Name = "proj_" .. id
			body.Parent = folder
			entry = { body = body, shadow = makeShadowDot(folder) }
			self.projectiles[id] = entry
		end
		-- Projectile x is in the DEFENDER's frame, so an enemy-side
		-- projectile draws on the enemy island and an incoming one draws
		-- on ours.
		local altitude = proj.kind == "bird" and S * 3 or S * 2.2
		local position = self:worldPosition(proj.x, proj.y, enemySide, 0) + Vector3.new(0, altitude, 0)
		if entry.body:IsA("BasePart") then
			entry.body.Position = position
		elseif entry.body:IsA("Model") then
			entry.body:PivotTo(CFrame.new(position))
		end
		entry.shadow.Position = Vector3.new(position.X, 0.2, position.Z)
	end

	for id, proj in mine do
		place(id, proj, true)
	end
	for id, proj in incoming do
		place(id, proj, false)
	end

	for id, entry in self.projectiles do
		if not seen[id] then
			entry.body:Destroy()
			entry.shadow:Destroy()
			self.projectiles[id] = nil
		end
	end
end

function Render:impact(x: number, y: number, enemySide: boolean)
	local asset = self.assets.effects.impact
	local position = self:worldPosition(x, y, enemySide, 0)
	if asset then
		local model = asset:Clone()
		model:PivotTo(CFrame.new(position))
		model.Parent = self.root.Effects
		Debris:AddItem(model, 1.5)
		return
	end
	local burst = Instance.new("Part")
	burst.Anchored = true
	burst.CanCollide = false
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.new(S, S, S)
	burst.Position = position + Vector3.new(0, S * 0.5, 0)
	burst.Color = Color3.fromRGB(240, 208, 128)
	burst.Material = Enum.Material.Neon
	burst.Parent = self.root.Effects
	TweenService:Create(burst, TweenInfo.new(0.5), {
		Size = Vector3.new(S * 3, S * 3, S * 3),
		Transparency = 1,
	}):Play()
	Debris:AddItem(burst, 0.6)
end

function Render:damageNumber(x: number, y: number, enemySide: boolean, amount: number)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = self:worldPosition(x, y, enemySide, 0) + Vector3.new(0, S * 2, 0)
	anchor.Parent = self.root.Effects

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(3, 1.5)
	billboard.AlwaysOnTop = true
	billboard.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "-" .. math.floor(amount)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 128, 96)
	label.Parent = billboard

	TweenService:Create(anchor, TweenInfo.new(0.9), { Position = anchor.Position + Vector3.new(0, S * 2, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(0.9), { TextTransparency = 1 }):Play()
	Debris:AddItem(anchor, 1)
end

-- A nest that fires reveals its own cell. The puff exists so the defender
-- feels that cost the moment it happens (SPEC §10).
function Render:nestPuff(x: number, y: number, enemySide: boolean)
	local puff = Instance.new("Part")
	puff.Anchored = true
	puff.CanCollide = false
	puff.Shape = Enum.PartType.Ball
	puff.Size = Vector3.new(S * 0.6, S * 0.6, S * 0.6)
	puff.Position = self:worldPosition(x, y, enemySide, 0) + Vector3.new(0, S, 0)
	puff.Color = Color3.fromRGB(240, 236, 200)
	puff.Material = Enum.Material.Neon
	puff.Transparency = 0.2
	puff.Parent = self.root.Effects
	TweenService:Create(puff, TweenInfo.new(0.6), {
		Size = Vector3.new(S * 2, S * 2, S * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(puff, 0.7)
end

function Render:destroy()
	self.root:Destroy()
end

return Render
