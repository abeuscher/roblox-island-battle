--!strict
-- Client entry point.
--
-- The client is a VIEWER and a REQUESTER. It holds only its own island plus
-- its belief map, both of which arrive from the server already fog-gated
-- (SPEC §8). It predicts visuals; it never computes damage, reveal, or
-- resource change, and it has no code path that could render an enemy
-- structure the server has not revealed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.config)

local Render = require(script.Render)
local Camera = require(script.Camera)
local Input = require(script.Input)
local UI = require(script.UI)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local SnapshotRemote = Remotes:WaitForChild("Snapshot") :: RemoteEvent
local EventsRemote = Remotes:WaitForChild("Events") :: RemoteEvent

-- The client's whole model of the match. Deltas merge into this; nothing
-- is ever inferred about cells the server has not sent.
local view: any = nil

local render = Render.new(Workspace)
local camera = Camera.new()
local input = Input.new(camera, function()
	return view
end)
local ui = UI.new(input, camera)
input:bind()

local function applyFull(payload: any)
	view = payload.view
	render:buildOwnIsland(view.island)
	render:buildHaze()
	render:syncOwnStructures(view.structures, nil)
	render:applyPlots(view.belief)
	render:syncProjectiles(view.myProjectiles or {}, view.incomingProjectiles or {})
	ui:update(view)
end

local function applyDelta(payload: any)
	if not view then
		return
	end
	view.time = payload.time
	view.phase = payload.phase
	view.setupRemaining = payload.setupRemaining
	view.coin = payload.coin
	view.charge = payload.charge
	view.basesAlive = payload.basesAlive
	view.baseKills = payload.baseKills
	view.stats = payload.stats or view.stats

	if payload.removed then
		for _, id in payload.removed do
			view.structures[id] = nil
		end
	end
	if payload.structures then
		for id, s in payload.structures do
			view.structures[id] = s
		end
	end
	if payload.structures or payload.removed then
		render:syncOwnStructures(payload.structures or {}, payload.removed)
	end

	if payload.plots then
		for key, plot in payload.plots do
			view.belief[key] = plot
		end
		render:applyPlots(payload.plots)
	end

	view.myProjectiles = payload.myProjectiles or {}
	view.incomingProjectiles = payload.incomingProjectiles or {}
	render:syncProjectiles(view.myProjectiles, view.incomingProjectiles)
	ui:update(view)
end

-- Projectile-only pushes arrive between snapshots, so motion stays smooth
-- without the server rebuilding a whole view at frame rate.
local function applyProjectiles(payload: any)
	if not view then
		return
	end
	view.myProjectiles = payload.myProjectiles or {}
	view.incomingProjectiles = payload.incomingProjectiles or {}
	render:syncProjectiles(view.myProjectiles, view.incomingProjectiles)
end

SnapshotRemote.OnClientEvent:Connect(function(payload)
	if payload.kind == "full" then
		applyFull(payload)
	elseif payload.kind == "projectiles" then
		applyProjectiles(payload)
	else
		applyDelta(payload)
	end
end)

-- Feedback (SPEC §10). Every one of these is a reaction to a server event;
-- none of them reveals anything the snapshot has not already revealed.
EventsRemote.OnClientEvent:Connect(function(events)
	for _, e in events do
		if e.type == "impact" then
			local onEnemy = view ~= nil and e.defender ~= view.playerIndex
			render:impact(e.x, e.y, onEnemy)
		elseif e.type == "structure_damaged" then
			-- Only ever fired for the structure's owner, so this is ours.
			render:damageNumber(e.x, e.y, false, e.damage or 0)
			if e.kind == "base" then
				camera:shake(2.5)
			end
		elseif e.type == "nest_fired" then
			local onEnemy = view ~= nil and e.defender ~= view.playerIndex
			render:nestPuff(e.x, e.y, onEnemy)
		elseif e.type == "reveal" then
			render:peelLane(e.cells)
		elseif e.type == "base_destroyed_feedback" then
			-- Identical feedback whether the kill was real or a decoy. The
			-- client cannot tell, because the server does not say.
			ui:toast("Base destroyed!", Color3.fromRGB(120, 220, 140))
		elseif e.type == "bird_down" then
			if view and e.owner == view.playerIndex then
				ui:toast("Bird shot down", Color3.fromRGB(240, 160, 96))
			end
		elseif e.type == "command_rejected" then
			ui:toast(tostring(e.reason), Color3.fromRGB(240, 120, 120))
		elseif e.type == "combat_started" then
			ui:toast("Combat!", Color3.fromRGB(255, 208, 96))
		elseif e.type == "match_ended" then
			if view then
				view.winner = e.winner
				view.phase = "ended"
				ui:update(view)
			end
		end
	end
end)
