--!strict
-- UI/init.luau — build palette, resource readouts, targeting affordances,
-- and the end screen (SPEC §6, §10).
--
-- Everything here reads the fog-gated snapshot the server sends. The
-- opponent's Coin and Charge are never displayed because they are never
-- received (SPEC §4).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)

local Palette = require(script.Palette)
local HUD = require(script.HUD)
local EndScreen = require(script.EndScreen)

local UI = {}
UI.__index = UI

function UI.new(input: any, camera: any)
	local gui = Instance.new("ScreenGui")
	gui.Name = "IslandSiegeUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local self = setmetatable({
		gui = gui,
		input = input,
		camera = camera,
	}, UI)

	self.hud = HUD.new(gui, camera)
	self.palette = Palette.new(gui, input)
	self.endScreen = EndScreen.new(gui)
	return self
end

-- One snapshot in, whole UI updated. Called on every server push.
function UI:update(view: any)
	self.hud:update(view)
	self.palette:update(view)
	if view.phase == "ended" then
		self.endScreen:show(view)
	else
		self.endScreen:hide()
	end
end

function UI:toast(message: string, color: Color3?)
	self.hud:toast(message, color)
end

return UI
