--!strict
-- EndScreen.luau — result, stats, rematch, leave (SPEC §6).
--
-- "Times you were fooled by a decoy" is the one number the server withholds
-- until the match is over: showing it live would defeat the deception it
-- describes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RequestRemote = Remotes:WaitForChild("Request") :: RemoteEvent

local EndScreen = {}
EndScreen.__index = EndScreen

function EndScreen.new(gui: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "EndScreen"
	frame.Size = UDim2.new(0, 460, 0, 360)
	frame.Position = UDim2.new(0.5, -230, 0.5, -180)
	frame.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -24, 0, 64)
	title.Position = UDim2.new(0, 12, 0, 12)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.Parent = frame

	local stats = Instance.new("TextLabel")
	stats.Size = UDim2.new(1, -24, 0, 200)
	stats.Position = UDim2.new(0, 12, 0, 84)
	stats.BackgroundTransparency = 1
	stats.Font = Enum.Font.Gotham
	stats.TextSize = 18
	stats.TextXAlignment = Enum.TextXAlignment.Left
	stats.TextYAlignment = Enum.TextYAlignment.Top
	stats.TextColor3 = Color3.fromRGB(220, 220, 224)
	stats.Parent = frame

	local rematch = Instance.new("TextButton")
	rematch.Size = UDim2.new(0, 200, 0, 44)
	rematch.Position = UDim2.new(0, 16, 1, -60)
	rematch.BackgroundColor3 = Color3.fromRGB(40, 96, 60)
	rematch.BorderSizePixel = 0
	rematch.Text = "Rematch (new island)"
	rematch.Font = Enum.Font.GothamBold
	rematch.TextScaled = true
	rematch.TextColor3 = Color3.new(1, 1, 1)
	rematch.Parent = frame
	rematch.Activated:Connect(function()
		RequestRemote:FireServer({ type = "rematch" })
	end)

	local leave = Instance.new("TextButton")
	leave.Size = UDim2.new(0, 200, 0, 44)
	leave.Position = UDim2.new(1, -216, 1, -60)
	leave.BackgroundColor3 = Color3.fromRGB(80, 40, 44)
	leave.BorderSizePixel = 0
	leave.Text = "Leave"
	leave.Font = Enum.Font.GothamBold
	leave.TextScaled = true
	leave.TextColor3 = Color3.new(1, 1, 1)
	leave.Parent = frame
	leave.Activated:Connect(function()
		-- A real deployment teleports back to a lobby place here; with no
		-- lobby to return to, leaving the match means leaving the server.
		local Players = game:GetService("Players")
		Players.LocalPlayer:Kick("Left the match")
	end)

	return setmetatable({ frame = frame, title = title, stats = stats }, EndScreen)
end

function EndScreen:show(view: any)
	self.frame.Visible = true
	local won = view.winner == view.playerIndex
	local draw = view.winner == 0
	self.title.Text = draw and "DRAW" or (won and "VICTORY" or "DEFEAT")
	self.title.TextColor3 = draw and Color3.fromRGB(220, 220, 120)
		or (won and Color3.fromRGB(120, 220, 140) or Color3.fromRGB(220, 120, 120))

	local s = view.stats or {}
	local lines = {
		string.format("Duration              %d:%02d", math.floor((view.time or 0) / 60), math.floor((view.time or 0) % 60)),
		string.format("Shots fired           %d", s.shotsFired or 0),
		string.format("Birds flown / lost    %d / %d", s.birdsFlown or 0, s.birdsLost or 0),
		string.format("Cells revealed        %d", s.cellsRevealed or 0),
		string.format("Structures lost       %d", s.structuresLost or 0),
		string.format("Coin earned / spent   %d / %d", s.coinEarned or 0, s.coinSpent or 0),
		"",
		string.format("Times you were fooled by a decoy   %d", view.timesFooledByDecoy or 0),
	}
	self.stats.Text = table.concat(lines, "\n")
end

function EndScreen:hide()
	self.frame.Visible = false
end

return EndScreen
