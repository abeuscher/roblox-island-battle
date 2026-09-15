--!strict
-- HUD.luau — resources, phase clock, base counter, cooldown indicators.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)

local HUD = {}
HUD.__index = HUD

local function label(parent: Instance, size: UDim2, position: UDim2, text: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Size = size
	l.Position = position
	l.BackgroundTransparency = 1
	l.Text = text
	l.Font = Enum.Font.GothamBold
	l.TextScaled = true
	l.TextColor3 = Color3.fromRGB(240, 240, 240)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

function HUD.new(gui: ScreenGui, camera: any)
	local frame = Instance.new("Frame")
	frame.Name = "HUD"
	frame.Size = UDim2.new(1, 0, 0, 56)
	frame.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local self = setmetatable({
		gui = gui,
		camera = camera,
		frame = frame,
		coin = label(frame, UDim2.new(0, 160, 1, -16), UDim2.new(0, 16, 0, 8), "Coin 0"),
		charge = label(frame, UDim2.new(0, 200, 1, -16), UDim2.new(0, 184, 0, 8), "Charge 0/0"),
		bases = label(frame, UDim2.new(0, 160, 1, -16), UDim2.new(0, 396, 0, 8), "Bases 3"),
		kills = label(frame, UDim2.new(0, 200, 1, -16), UDim2.new(0, 560, 0, 8), "Enemy bases down 0"),
		clock = label(frame, UDim2.new(0, 220, 1, -16), UDim2.new(1, -236, 0, 8), ""),
	}, HUD)

	-- Intel-view toggle, mirrored by the Tab key.
	local toggle = Instance.new("TextButton")
	toggle.Size = UDim2.new(0, 150, 0, 34)
	toggle.Position = UDim2.new(1, -166, 0, 64)
	toggle.BackgroundColor3 = Color3.fromRGB(40, 60, 96)
	toggle.BorderSizePixel = 0
	toggle.Text = "Intel view (Tab)"
	toggle.Font = Enum.Font.GothamBold
	toggle.TextScaled = true
	toggle.TextColor3 = Color3.new(1, 1, 1)
	toggle.Parent = gui
	toggle.Activated:Connect(function()
		local side = camera:toggle()
		toggle.Text = side == "enemy" and "Your island (Tab)" or "Intel view (Tab)"
	end)
	self.toggle = toggle

	return self
end

function HUD:update(view: any)
	self.coin.Text = string.format("Coin %d", view.coin or 0)
	self.charge.Text = string.format("Charge %d/%d", view.charge or 0, Config.CHARGE_CAP)
	self.bases.Text = string.format("Your bases %d", view.basesAlive or 0)
	-- This is the BELIEVED count: a destroyed decoy advances it exactly as
	-- a real base does (SPEC §5). The truth is never sent to this client.
	self.kills.Text = string.format("Enemy bases down %d/%d", view.baseKills or 0, Config.BASES_PER_PLAYER)

	if view.phase == "setup" then
		self.clock.Text = string.format("SETUP  %ds", math.max(0, math.ceil(view.setupRemaining or 0)))
		self.clock.TextColor3 = Color3.fromRGB(255, 208, 96)
	elseif view.phase == "combat" then
		local remaining = math.max(0, Config.MATCH_TIMEOUT - (view.time or 0))
		self.clock.Text = string.format("%d:%02d", math.floor(remaining / 60), math.floor(remaining % 60))
		self.clock.TextColor3 = Color3.fromRGB(240, 240, 240)
	else
		self.clock.Text = ""
	end
end

function HUD:toast(message: string, color: Color3?)
	local toast = Instance.new("TextLabel")
	toast.Size = UDim2.new(0, 420, 0, 44)
	toast.Position = UDim2.new(0.5, -210, 0, 96)
	toast.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	toast.BackgroundTransparency = 0.2
	toast.BorderSizePixel = 0
	toast.Text = message
	toast.Font = Enum.Font.GothamBold
	toast.TextScaled = true
	toast.TextColor3 = color or Color3.new(1, 1, 1)
	toast.Parent = self.gui
	TweenService:Create(toast, TweenInfo.new(2.2), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
	Debris:AddItem(toast, 2.4)
end

return HUD
