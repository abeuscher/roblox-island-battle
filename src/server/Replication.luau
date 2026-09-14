--!strict
-- Replication.luau — fog-gated state push, per player (SPEC §8).
--
-- THE RULE: a client must never receive a payload containing unrevealed
-- enemy data, even in a field it does not render. Hiding enemy models with
-- Transparency or a fog overlay is not fog of war — the positions can be
-- read out of the client's workspace in seconds.
--
-- So every outbound payload here is built from Rules.viewFor, which
-- contains the player's own island plus their stale belief map and nothing
-- else, and from Rules.filterEventsFor, which drops events addressed to
-- the opponent. The full MatchState never leaves this module's caller.
--
-- Shape of the wire protocol:
--   full   — on join, phase change, and rematch. The whole view.
--   delta  — every push tick: resources, changed own structures, NEW belief
--            plots only, and the projectiles this player may see.
-- Deltas exist for bandwidth, not secrecy: both are built from the view.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared.rules)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local SnapshotRemote = Remotes:WaitForChild("Snapshot") :: RemoteEvent
local EventsRemote = Remotes:WaitForChild("Events") :: RemoteEvent

local Replication = {}
Replication.__index = Replication

function Replication.new()
	return setmetatable({
		-- Per player: what we have already sent, so deltas stay small.
		sentPlots = {} :: { [number]: { [string]: number } },
		sentStructures = {} :: { [number]: { [number]: string } },
	}, Replication)
end

local function structureSignature(s: any): string
	return string.format("%d|%.1f|%d|%.2f", s.tier, s.hp, s.alive and 1 or 0, s.buildRemaining)
end

-- Sends the complete view. Used on join, phase change, and rematch.
function Replication:pushFull(state: any, playerIndex: number, player: Player?)
	if not player then
		return
	end
	local view = Rules.viewFor(state, playerIndex)

	local plots = {}
	for key, plot in view.belief do
		plots[key] = plot
	end
	self.sentPlots[playerIndex] = {}
	for key, plot in view.belief do
		self.sentPlots[playerIndex][key] = plot.t
	end

	self.sentStructures[playerIndex] = {}
	for id, s in view.structures do
		self.sentStructures[playerIndex][id] = structureSignature(s)
	end

	SnapshotRemote:FireClient(player, {
		kind = "full",
		view = view,
	})
end

-- Sends only what changed since the last push for this player.
function Replication:pushDelta(state: any, playerIndex: number, player: Player?)
	if not player then
		return
	end
	local view = Rules.viewFor(state, playerIndex)
	local sentPlots = self.sentPlots[playerIndex]
	local sentStructures = self.sentStructures[playerIndex]
	if not sentPlots or not sentStructures then
		return self:pushFull(state, playerIndex, player)
	end

	-- New or re-revealed plots only. A plot whose timestamp is unchanged is
	-- the same stale record the client already holds (SPEC §7).
	local plots = nil
	for key, plot in view.belief do
		if sentPlots[key] ~= plot.t then
			plots = plots or {}
			plots[key] = plot
			sentPlots[key] = plot.t
		end
	end

	local structures = nil
	for id, s in view.structures do
		local signature = structureSignature(s)
		if sentStructures[id] ~= signature then
			structures = structures or {}
			structures[id] = s
			sentStructures[id] = signature
		end
	end
	local removed = nil
	for id in sentStructures do
		if view.structures[id] == nil then
			removed = removed or {}
			table.insert(removed, id)
			sentStructures[id] = nil
		end
	end

	SnapshotRemote:FireClient(player, {
		kind = "delta",
		time = view.time,
		phase = view.phase,
		setupRemaining = view.setupRemaining,
		coin = view.coin,
		charge = view.charge,
		basesAlive = view.basesAlive,
		baseKills = view.baseKills,
		plots = plots,
		structures = structures,
		removed = removed,
		-- Only this player's own projectiles plus enemy ones already over
		-- their island — both come straight from the fog-gated view.
		myProjectiles = view.myProjectiles,
		incomingProjectiles = view.incomingProjectiles,
		stats = view.stats,
	})
end

-- Forwards only the events this player is entitled to see.
function Replication:pushEvents(events: { any }, playerIndex: number, player: Player?)
	if not player then
		return
	end
	local visible = Rules.filterEventsFor(events, playerIndex)
	if #visible > 0 then
		EventsRemote:FireClient(player, visible)
	end
end

function Replication:reset(playerIndex: number)
	self.sentPlots[playerIndex] = nil
	self.sentStructures[playerIndex] = nil
end

return Replication
