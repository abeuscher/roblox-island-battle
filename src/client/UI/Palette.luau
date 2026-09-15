--!strict
-- Palette.luau — the build palette and the weapon tray.
--
-- The palette is generated from config.PURCHASABLE, so adding a v2 weapon
-- is a config entry and nothing here changes (SPEC §5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)
local Weapons = require(Shared.weapons)

local Palette = {}
Palette.__index = Palette

local GLYPH = {
	base = "🥥",
	decoy_base = "🥥",
	grove = "🌴",
	catapult = "🥥",
	perch = "🐦",
	nest = "🎯",
}

local function button(parent: Instance, position: UDim2, size: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = Color3.fromRGB(30, 38, 52)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextScaled = true
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Parent = parent
	return b
end

function Palette.new(gui: ScreenGui, input: any)
	local frame = Instance.new("Frame")
	frame.Name = "Palette"
	frame.Size = UDim2.new(0, 132, 0, 104 + #Config.PURCHASABLE * 52)
	frame.Position = UDim2.new(0, 12, 0, 72)
	frame.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local self = setmetatable({
		gui = gui,
		input = input,
		frame = frame,
		buttons = {} :: { [string]: TextButton },
		trayFrame = nil :: Frame?,
		trayButtons = {} :: { [number]: TextButton },
	}, Palette)

	-- Setup-phase base placement is its own affordance: bases are free,
	-- pre-placed, and never purchasable (SPEC §5).
	self.baseButton = button(frame, UDim2.new(0, 8, 0, 8), UDim2.new(1, -16, 0, 44))
	self.baseButton.Text = "Place Base"
	self.baseButton.BackgroundColor3 = Color3.fromRGB(92, 64, 44)
	self.baseButton.Activated:Connect(function()
		input:setMode("build", "base")
	end)

	for i, id in Config.PURCHASABLE do
		local def = Config.WEAPONS[id]
		local b = button(frame, UDim2.new(0, 8, 0, 60 + (i - 1) * 52), UDim2.new(1, -16, 0, 44))
		b.Name = id
		b.Text = string.format("%s %s\n%d", GLYPH[id] or "", def.display_name, def.coin_cost)
		b.Activated:Connect(function()
			input:setMode("build", id)
		end)
		self.buttons[id] = b
	end

	-- Bulldoze and upgrade are modes rather than palette entries: both act
	-- on a structure already on the board, picked by clicking it.
	local bulldoze = button(frame, UDim2.new(0, 8, 0, 60 + #Config.PURCHASABLE * 52), UDim2.new(0.5, -10, 0, 36))
	bulldoze.Text = "Bulldoze"
	bulldoze.BackgroundColor3 = Color3.fromRGB(72, 40, 40)
	bulldoze.Activated:Connect(function()
		input:setMode("bulldoze", nil)
	end)

	local upgrade = button(frame, UDim2.new(0.5, 2, 0, 60 + #Config.PURCHASABLE * 52), UDim2.new(0.5, -10, 0, 36))
	upgrade.Text = "Upgrade"
	upgrade.BackgroundColor3 = Color3.fromRGB(40, 60, 84)
	upgrade.Activated:Connect(function()
		input:setMode("upgrade", nil)
	end)

	-- Weapon tray: one entry per built weapon, showing its cooldown and
	-- putting the player straight into targeting when clicked.
	local tray = Instance.new("Frame")
	tray.Name = "Tray"
	tray.Size = UDim2.new(1, -300, 0, 62)
	tray.Position = UDim2.new(0, 156, 1, -74)
	tray.BackgroundTransparency = 1
	tray.Parent = gui
	self.trayFrame = tray

	return self
end

function Palette:update(view: any)
	self.baseButton.Visible = view.phase == "setup" and (view.basesPlaced or 0) < Config.BASES_PER_PLAYER
	if self.baseButton.Visible then
		self.baseButton.Text = string.format("Place Base (%d left)", Config.BASES_PER_PLAYER - (view.basesPlaced or 0))
	end

	for id, b in self.buttons do
		local def = Config.WEAPONS[id]
		local affordable = (view.coin or 0) >= def.coin_cost
		b.BackgroundColor3 = affordable and Color3.fromRGB(30, 38, 52) or Color3.fromRGB(46, 30, 30)
		b.TextTransparency = affordable and 0 or 0.4
	end

	self:updateTray(view)
end

-- Rebuilds the tray from the player's own structures. Only weapons that
-- can actually be used get an entry.
function Palette:updateTray(view: any)
	for _, b in self.trayButtons do
		b:Destroy()
	end
	self.trayButtons = {}
	if view.phase ~= "combat" then
		return
	end

	local usable = {}
	for id, s in view.structures or {} do
		local def = Config.WEAPONS[s.kind]
		if def and (def.role == "kill" or def.role == "find") and s.buildRemaining <= 0 then
			table.insert(usable, s)
		end
	end
	table.sort(usable, function(a, b)
		return a.id < b.id
	end)

	for i, s in usable do
		local def = Config.WEAPONS[s.kind]
		local b = button(self.trayFrame :: Instance, UDim2.new(0, (i - 1) * 96, 0, 0), UDim2.new(0, 88, 0, 56))
		local ready = s.cooldownRemaining <= 0 and (view.charge or 0) >= def.charge_cost
		b.Text = ready and string.format("%s\nready", GLYPH[s.kind] or s.kind)
			or string.format("%s\n%.0fs", GLYPH[s.kind] or s.kind, s.cooldownRemaining)
		b.BackgroundColor3 = ready and Color3.fromRGB(40, 72, 48) or Color3.fromRGB(44, 44, 52)
		b.Activated:Connect(function()
			if not ready then
				return
			end
			-- A catapult picks a cell; a perch picks a lane. The server
			-- validates both regardless of what the client believes.
			self.input:setMode(def.role == "kill" and "target" or "lane", s.id)
		end)
		table.insert(self.trayButtons, b)
	end
end

return Palette
