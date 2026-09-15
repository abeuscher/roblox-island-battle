--!strict
-- weapons.luau — roster data access + weapon resolution. Pure Luau.
--
-- Weapons are data (config.WEAPONS), not bespoke code. Resolution has
-- exactly two projectile branches — "coconut" (ballistic, reveals a line +
-- impact circle) and "bird" (lane flyer, live reveal, interceptable) — so a
-- v2 weapon is a config entry plus, at most, one new branch here.

-- Dual-target module loading: under Rojo/Roblox `script` exists and modules
-- are instances; under Lune `script` is nil and modules are files. Keeping
-- this shim here is what lets the identical pure core run in both places
-- with no build step (see DECISIONS.md).
local function import(name: string): any
	if script ~= nil then
		return require((script :: any).Parent[name])
	end
	return require("./" .. name)
end

local Grid = import("grid")
local State = import("state")
local Fog = import("fog")

local Weapons = {}

----------------------------------------------------------------------------
-- Stats with Bloons-style tiers
----------------------------------------------------------------------------

-- Effective stat for a weapon at a tier. Tier overrides apply cumulatively
-- (tier 2 on top of tier 1). Returns nil for stats the weapon doesn't have.
function Weapons.getStat(config: any, weaponId: string, tier: number, stat: string): any
	local def = config.WEAPONS[weaponId]
	assert(def, "unknown weapon: " .. tostring(weaponId))
	local value = (def :: any)[stat]
	for i = 1, math.min(tier, #def.upgrades) do
		local override = def.upgrades[i].overrides[stat]
		if override ~= nil then
			value = override
		end
	end
	return value
end

function Weapons.def(config: any, weaponId: string)
	return config.WEAPONS[weaponId]
end

----------------------------------------------------------------------------
-- Firing (validation happens in rules.validateCommand; these just resolve)
----------------------------------------------------------------------------

-- Lob a coconut at defender-local cell (tx, ty).
function Weapons.fireCatapult(
	state: State.MatchState,
	player: State.Player,
	struct: State.Structure,
	tx: number,
	ty: number,
	events: { State.Event }
)
	local config = state.config
	local vx, vy = Grid.toEnemyFrame(config, struct.x, struct.y)
	local dx, dy = tx - vx, ty - vy
	local dist = math.sqrt(dx * dx + dy * dy)
	if dist < 0.001 then
		dist = 0.001
	end

	struct.cooldownRemaining = Weapons.getStat(config, struct.kind, struct.tier, "cooldown")
	player.stats.shotsFired += 1

	local proj: State.Projectile = {
		id = state.nextProjId,
		kind = "coconut",
		owner = player.index,
		x = vx,
		y = vy,
		spawnX = vx,
		spawnY = vy,
		targetX = tx,
		targetY = ty,
		dirX = dx / dist,
		dirY = dy / dist,
		laneY = nil,
		speed = Weapons.getStat(config, struct.kind, struct.tier, "projectile_speed"),
		hp = math.huge, -- not interceptable
		damage = Weapons.getStat(config, struct.kind, struct.tier, "damage"),
		splash = Weapons.getStat(config, struct.kind, struct.tier, "splash"),
		revealSize = Weapons.getStat(config, struct.kind, struct.tier, "reveal_size"),
		lastRevealX = nil,
		sourceStructId = struct.id,
	}
	state.nextProjId += 1
	state.projectiles[proj.id] = proj

	table.insert(events, {
		type = "shot_fired",
		visibleTo = player.index,
		weapon = struct.kind,
		structId = struct.id,
		targetX = tx,
		targetY = ty,
	})
end

-- Launch a spotter bird down lane y = laneY (defender-local), flying -x.
function Weapons.launchBird(
	state: State.MatchState,
	player: State.Player,
	struct: State.Structure,
	laneY: number,
	events: { State.Event }
)
	local config = state.config
	local vx, vy = Grid.toEnemyFrame(config, struct.x, struct.y)

	struct.cooldownRemaining = Weapons.getStat(config, struct.kind, struct.tier, "cooldown")
	player.stats.birdsFlown += 1

	local hpBonus = Weapons.getStat(config, struct.kind, struct.tier, "bird_hp_bonus") or 0

	local proj: State.Projectile = {
		id = state.nextProjId,
		kind = "bird",
		owner = player.index,
		x = vx,
		y = vy,
		targetX = nil,
		targetY = nil,
		dirX = nil,
		dirY = nil,
		laneY = laneY,
		speed = config.BIRD_SPEED,
		hp = config.BIRD_HP + hpBonus,
		damage = 0,
		splash = 0,
		-- Lane width is the perch's own tier-aware reveal_size, not a
		-- global: §5 lists reveal size among the stats an upgrade may
		-- modify, and intel that improves with investment is the only
		-- mechanism in the roster that can make discovery scale with the
		-- length of a match (see DECISIONS.md §3.3).
		revealSize = Weapons.getStat(config, struct.kind, struct.tier, "reveal_size"),
		lastRevealX = nil, -- set when the bird crosses onto the island
		sourceStructId = struct.id,
	}
	state.nextProjId += 1
	state.projectiles[proj.id] = proj

	table.insert(events, {
		type = "bird_launched",
		visibleTo = player.index,
		structId = struct.id,
		laneY = laneY,
	})
end

----------------------------------------------------------------------------
-- Damage / destruction
----------------------------------------------------------------------------

local function destroyStructure(
	state: State.MatchState,
	defender: State.Player,
	s: State.Structure,
	attackerIndex: number?,
	events: { State.Event }
)
	local config = state.config
	local def = config.WEAPONS[s.kind]
	s.alive = false
	s.hp = 0
	defender.stats.structuresLost += 1

	for _, cell in Grid.footprintCells(s.x, s.y, def.footprint) do
		local key = Grid.key(cell[1], cell[2])
		defender.occ[key] = nil
		-- Rubble persists on the ground and plots as rubble when revealed
		-- (open decision #3 — resolved in DECISIONS.md: rubble is permanent).
		defender.island.rubble[key] = true
	end

	if s.kind == "base" then
		defender.basesAlive -= 1
	end

	table.insert(events, {
		type = "structure_destroyed",
		visibleTo = defender.index,
		structId = s.id,
		kind = s.kind,
		x = s.x,
		y = s.y,
	})

	if attackerIndex then
		local attacker = state.players[attackerIndex]
		Fog.plotDestruction(state, attackerIndex, s, def.footprint)
		if s.kind == "base" then
			attacker.stats.realBaseKills += 1
			attacker.stats.believedBaseKills += 1
			table.insert(events, {
				type = "base_destroyed_feedback",
				visibleTo = attackerIndex,
				x = s.x,
				y = s.y,
				footprint = def.footprint,
			})
		elseif s.kind == "decoy_base" and config.DECOY_FAKE_KILL_FEEDBACK then
			-- Identical feedback to a real kill. The kill counter shown to
			-- the attacker is believedBaseKills; the real counter never
			-- leaves the server (SPEC §5).
			attacker.stats.believedBaseKills += 1
			attacker.stats.timesFooledByDecoy += 1
			table.insert(events, {
				type = "base_destroyed_feedback",
				visibleTo = attackerIndex,
				x = s.x,
				y = s.y,
				footprint = def.footprint,
			})
		end
	end
end

-- Apply damage to whatever structure occupies (x, y) on the defender.
function Weapons.damageCell(
	state: State.MatchState,
	defenderIndex: number,
	x: number,
	y: number,
	damage: number,
	attackerIndex: number?,
	events: { State.Event }
)
	local defender = state.players[defenderIndex]
	local s = State.structureAt(defender, x, y)
	if s and s.alive and damage > 0 then
		s.hp -= damage
		table.insert(events, {
			type = "structure_damaged",
			visibleTo = defender.index,
			structId = s.id,
			kind = s.kind,
			hp = math.max(0, s.hp),
			damage = damage,
			x = s.x,
			y = s.y,
		})
		if s.hp <= 0 then
			destroyStructure(state, defender, s, attackerIndex, events)
		end
	end
end

----------------------------------------------------------------------------
-- Projectile advance
----------------------------------------------------------------------------

local function resolveCoconutImpact(state: State.MatchState, proj: State.Projectile, events: { State.Event })
	local config = state.config
	local defenderIndex = 3 - proj.owner
	local tx, ty = proj.targetX :: number, proj.targetY :: number

	table.insert(events, {
		type = "impact",
		visibleTo = "all",
		defender = defenderIndex,
		x = tx,
		y = ty,
	})

	-- 1. Damage first, so the reveal below plots the post-impact truth
	--    (a destroyed structure reveals as rubble — SPEC §7).
	if proj.splash > 0 then
		local seen: { [number]: boolean } = {}
		for _, cell in Grid.cellsInRadius(tx, ty, proj.splash) do
			local s = State.structureAt(state.players[defenderIndex], cell[1], cell[2])
			if s and not seen[s.id] then
				seen[s.id] = true
				Weapons.damageCell(state, defenderIndex, cell[1], cell[2], proj.damage, proj.owner, events)
			end
		end
	else
		Weapons.damageCell(state, defenderIndex, tx, ty, proj.damage, proj.owner, events)
	end

	-- 2. Flight-line reveal plus the impact circle. The line runs from the
	--    ORIGINAL launch point; Fog.reveal drops the cells that are off the
	--    enemy island.
	--
	--    FLIGHT_LINE_REVEAL_WIDTH is a real knob: 0 disables flight-line
	--    recon entirely, 1 is the spec's single-cell trace, and higher
	--    values thicken it. It matters more than it looks — flight lines
	--    are a second, independent source of intel alongside bird lanes,
	--    and narrowing only one of them just moves discovery to the other
	--    (DECISIONS.md §3.7).
	local config = state.config
	local lineWidth = config.FLIGHT_LINE_REVEAL_WIDTH
	local cells = {}
	if lineWidth > 0 then
		local spread = math.floor((lineWidth - 1) / 2)
		for _, cell in Grid.lineCells(math.floor(proj.spawnX or proj.x), math.floor(proj.spawnY or proj.y), tx, ty) do
			for offset = -spread, lineWidth - 1 - spread do
				table.insert(cells, { cell[1], cell[2] + offset })
			end
		end
	end
	for _, cell in Grid.cellsInRadius(tx, ty, proj.revealSize) do
		table.insert(cells, cell)
	end
	Fog.reveal(state, proj.owner, cells, events)
end

-- Reveal the bird's lane between two x frontiers (exclusive .. inclusive).
local function revealLaneSegment(
	state: State.MatchState,
	proj: State.Projectile,
	fromX: number,
	toX: number,
	events: { State.Event }
)
	local w = proj.revealSize
	local halfLo = math.floor((w - 1) / 2) -- lane covers laneY-halfLo .. laneY+halfHi
	local halfHi = w - 1 - halfLo
	local laneY = proj.laneY :: number
	local cells = {}
	for x = math.floor(toX), math.floor(fromX) do
		for y = laneY - halfLo, laneY + halfHi do
			table.insert(cells, { x, y })
		end
	end
	if #cells > 0 then
		Fog.reveal(state, proj.owner, cells, events)
	end
end

function Weapons.advanceProjectiles(state: State.MatchState, dt: number, events: { State.Event })
	local config = state.config
	local d = config.ISLAND_DIAMETER
	local toRemove = {}

	for id, proj in state.projectiles do
		if proj.kind == "coconut" then
			local remaining = Grid.dist(proj.x, proj.y, proj.targetX :: number, proj.targetY :: number)
			local step = proj.speed * dt
			if step >= remaining then
				resolveCoconutImpact(state, proj, events)
				table.insert(toRemove, id)
			else
				proj.x += (proj.dirX :: number) * step
				proj.y += (proj.dirY :: number) * step
			end
		elseif proj.kind == "bird" then
			local defender = state.players[3 - proj.owner]
			local laneY = proj.laneY :: number

			-- Move: fly toward the lane entry point (d + 1, laneY) while over
			-- the channel, then straight down the lane in -x.
			local step = proj.speed * dt
			if proj.x > d + 1 then
				local ex, ey = d + 1, laneY
				local ddist = Grid.dist(proj.x, proj.y, ex, ey)
				if step >= ddist then
					proj.x, proj.y = ex, ey
				else
					proj.x += (ex - proj.x) / ddist * step
					proj.y += (ey - proj.y) / ddist * step
				end
			else
				proj.y = laneY
				proj.x -= step
			end

			-- Live lane reveal while over the island.
			if proj.x <= d then
				local frontier = proj.lastRevealX or d
				if proj.x < frontier then
					revealLaneSegment(state, proj, frontier, math.max(proj.x, 1), events)
					proj.lastRevealX = math.max(proj.x, 1)
				end
			end

			-- Anti-air: every completed enemy nest in radius applies DPS.
			-- A firing nest reveals its own cell to the bird's owner.
			for _, s in defender.structures do
				if s.alive and s.kind == "nest" and s.buildRemaining <= 0 then
					local radius = Weapons.getStat(config, "nest", s.tier, "range")
					if Grid.dist(s.x, s.y, proj.x, proj.y) <= radius then
						local dps = Weapons.getStat(config, "nest", s.tier, "damage")
						proj.hp -= dps * dt
						if not s.revealedNest then
							s.revealedNest = true
							Fog.reveal(state, proj.owner, { { s.x, s.y } }, events)
							table.insert(events, {
								type = "nest_fired",
								visibleTo = "all",
								defender = defender.index,
								x = s.x,
								y = s.y,
							})
						end
					end
				end
			end

			if proj.hp <= 0 then
				-- Shot down: the reveal stops here (SPEC §5, self-playtest d).
				state.players[proj.owner].stats.birdsLost += 1
				table.insert(events, {
					type = "bird_down",
					visibleTo = "all",
					owner = proj.owner,
					laneY = laneY,
					x = proj.x,
					y = proj.y,
				})
				table.insert(toRemove, id)
			elseif proj.x <= d and proj.x < 1 then
				-- Exited the far side.
				table.insert(events, {
					type = "bird_exit",
					visibleTo = proj.owner,
					x = proj.x,
					y = proj.y,
				})
				table.insert(toRemove, id)
			end
		end
	end

	for _, id in toRemove do
		state.projectiles[id] = nil
	end
end

return Weapons
