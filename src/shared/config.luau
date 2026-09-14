--!strict
-- config.luau — ALL tuning constants for Island Siege.
-- Every number the game uses lives here. Nothing numeric is hardcoded elsewhere.
-- Pure data: zero Roblox API calls. Safe under Lune.
--
-- The balance-critical levers (see SPEC §7) are marked [AA-LEVER]:
-- anti-air coverage is the single strongest balance knob in the game.
-- Tune NEST_DPS, NEST_RADIUS and BIRD_HP first, everything else second.

export type UpgradeTier = {
	coin_cost: number,
	-- Stat overrides applied on top of the base weapon entry (tier 2 is
	-- applied on top of tier 1). Only stats listed here change; an upgrade
	-- never grants a new role (SPEC §5).
	overrides: { [string]: number },
}

export type WeaponDef = {
	id: string,
	display_name: string,
	role: string, -- "win" | "deception" | "income" | "kill" | "find" | "blind"
	coin_cost: number,
	charge_cost: number,
	cooldown: number,
	range: number, -- 0 = not a ranged weapon / unlimited where noted
	damage: number,
	splash: number, -- impact splash radius in cells (0 = the impact cell only)
	reveal_shape: string, -- "none" | "circle" | "lane"
	reveal_size: number, -- circle radius, or lane width, in cells
	reveal_duration: number, -- 0 = plots are permanent-but-stale (SPEC §7)
	projectile_speed: number, -- cells per second; 0 = instant / none
	interceptable: boolean, -- can anti-air shoot it down
	hp: number,
	footprint: number, -- N means NxN cells
	max_hp_building_factor: number, -- fraction of HP while under construction
	upgrades: { UpgradeTier },
}

local Config = {}

----------------------------------------------------------------------------
-- Playfield (SPEC §3)
----------------------------------------------------------------------------
Config.STUDS_PER_CELL = 4 -- world-space conversion; logic is all in cells
Config.ISLAND_DIAMETER = 36 -- valid range 30–50
Config.CHANNEL_WIDTH = 15 -- cells of open water between the two shores
Config.BASE_FOOTPRINT = 3 -- bases and decoys occupy 3x3
Config.OBSTACLE_MIN = 8 -- seeded random unbuildable cells, blocks nothing else
Config.OBSTACLE_MAX = 14

----------------------------------------------------------------------------
-- Economy (SPEC §4)
----------------------------------------------------------------------------
Config.COIN_BASE_RATE = 1 -- coin per income tick, before groves
Config.COIN_TICK_SECONDS = 2 -- income tick length
Config.GROVE_INCOME = 1 -- extra coin per surviving completed grove per tick
Config.CHARGE_REGEN_SECONDS = 6 -- flat: +1 charge every N seconds
Config.CHARGE_CAP = 6
Config.STARTING_COIN = 40 -- spent during setup on the opening loadout
Config.STARTING_CHARGE = 2 -- opening charge so the first minute isn't dead

----------------------------------------------------------------------------
-- Match flow (SPEC §6)
----------------------------------------------------------------------------
Config.SETUP_SECONDS = 75
Config.MATCH_TIMEOUT = 900 -- 15 min hard cap, then tiebreak
Config.DISCONNECT_GRACE = 30
Config.BUILD_SECONDS = 4 -- construction time; inert + half HP while building
Config.BASES_PER_PLAYER = 3

----------------------------------------------------------------------------
-- Fog & recon (SPEC §7)
----------------------------------------------------------------------------
Config.FLIGHT_LINE_REVEAL_WIDTH = 1 -- every projectile reveals its flight line
Config.DECOY_FAKE_KILL_FEEDBACK = true -- decoy death sends "Base destroyed!"

-- May a recon structure (role "find") be bought during setup?
--
-- true reproduces the spec's opening exactly: a perch is a normal opening
-- buy, so the first bird flies at t ~ 0. The first sweep showed that makes
-- anti-air almost inert, because the flight that finds the bases happens
-- before any nest can exist (see DECISIONS.md §3.1).
--
-- false delays the first flight until a perch has been paid for and built
-- out of combat income, which is what gives anti-air something to contest.
-- Swept as a dimension rather than assumed either way.
Config.SETUP_ALLOWS_RECON = true

----------------------------------------------------------------------------
-- Birds (the "find" leg — [AA-LEVER])
----------------------------------------------------------------------------
Config.BIRD_HP = 20 -- [AA-LEVER] one center nest (dps 10) kills in 2 s
Config.BIRD_SPEED = 6 -- cells/second; a 36-cell pass takes 6 s
-- Base live reveal lane width (~28% of the island per pass at tier 0).
-- The authoritative value at runtime is the perch's `reveal_size`, which is
-- tier-aware; this is the tier-0 value it is set from, and a test asserts
-- the two stay in step.
Config.BIRD_LANE_WIDTH = 8

----------------------------------------------------------------------------
-- Bot (SPEC §9)
----------------------------------------------------------------------------
Config.BOT_DECISION_SECONDS = 3 -- default; presets override below
-- Presets: { decision_seconds, coin_multiplier, reprobe_decoys_after (0 = fooled forever) }
Config.BOT_PRESETS = {
	beachcomber = { decision_seconds = 5, coin_multiplier = 0.8, reprobe_after = 0 },
	skirmish = { decision_seconds = 3, coin_multiplier = 1.0, reprobe_after = 0 },
	siege = { decision_seconds = 2, coin_multiplier = 1.25, reprobe_after = 90 },
}

----------------------------------------------------------------------------
-- Simulation harness (SPEC §11)
----------------------------------------------------------------------------
Config.SIM_AGENT_ACTION_INTERVAL = 2.5 -- max one agent command per N sim-seconds
Config.SIM_MATCHES_PER_PAIR = 200
Config.SIM_DT = 0.25 -- headless step size
-- How long an agent with nothing worth doing waits before being offered a
-- decision again. Not a game rule: purely a harness throughput knob.
Config.SIM_IDLE_RECHECK = 1.0

----------------------------------------------------------------------------
-- Weapon / structure roster (SPEC §5). IDs are canonical snake_case.
----------------------------------------------------------------------------
Config.WEAPONS = {
	base = {
		id = "base",
		display_name = "Base",
		role = "win",
		coin_cost = 0, -- 3 pre-placed during setup, never purchasable
		charge_cost = 0,
		cooldown = 0,
		range = 0,
		damage = 0,
		splash = 0,
		reveal_shape = "none",
		reveal_size = 0,
		reveal_duration = 0,
		projectile_speed = 0,
		interceptable = false,
		hp = 40, -- 5 catapult hits at default damage
		footprint = 3,
		max_hp_building_factor = 0.5,
		upgrades = {},
	} :: WeaponDef,

	decoy_base = {
		id = "decoy_base",
		display_name = "Decoy Base",
		role = "deception",
		coin_cost = 8,
		charge_cost = 0,
		cooldown = 0,
		range = 0,
		damage = 0,
		splash = 0,
		reveal_shape = "none",
		reveal_size = 0,
		reveal_duration = 0,
		projectile_speed = 0,
		interceptable = false,
		hp = 1, -- any hit destroys it
		footprint = 3,
		max_hp_building_factor = 0.5,
		upgrades = {},
	} :: WeaponDef,

	grove = {
		id = "grove",
		display_name = "Grove",
		role = "income",
		coin_cost = 10,
		charge_cost = 0,
		cooldown = 0,
		range = 0,
		damage = 0,
		splash = 0,
		reveal_shape = "none",
		reveal_size = 0,
		reveal_duration = 0,
		projectile_speed = 0,
		interceptable = false,
		hp = 6,
		footprint = 1,
		max_hp_building_factor = 0.5,
		upgrades = {
			-- Income tiers stay in-role: more coin, nothing else.
			{ coin_cost = 15, overrides = { income = 2 } },
			{ coin_cost = 25, overrides = { income = 3, hp = 9 } },
		},
	} :: WeaponDef,

	catapult = {
		id = "catapult",
		display_name = "Coconut Catapult",
		role = "kill",
		coin_cost = 12,
		charge_cost = 1,
		cooldown = 6, -- CATAPULT_COOLDOWN
		-- Range 50 across the channel metric (see grid.attackDistance):
		-- an inland catapult (x=1) reaches exactly the enemy shoreline;
		-- a shore catapult reaches the enemy inland edge straight across but
		-- cannot cover the whole enemy island (corners are ~53 away). This
		-- preserves the shore-risk/inland-safety tension of SPEC §3.
		range = 50,
		damage = 8, -- CATAPULT_DAMAGE
		splash = 0, -- impact cell only; 3x3 bases make this land
		reveal_shape = "circle",
		reveal_size = 3, -- ~28 cells per impact (<3% of the island)
		reveal_duration = 0,
		projectile_speed = 12, -- lobbed; ~2–4 s of flight
		interceptable = false,
		hp = 5,
		footprint = 1,
		max_hp_building_factor = 0.5,
		upgrades = {
			{ coin_cost = 10, overrides = { cooldown = 4.5 } },
			{ coin_cost = 18, overrides = { damage = 11 } },
		},
	} :: WeaponDef,

	perch = {
		id = "perch",
		display_name = "Bird Perch",
		role = "find",
		coin_cost = 14,
		charge_cost = 2,
		cooldown = 20, -- PERCH_COOLDOWN
		range = 0, -- lane choice is unrestricted; travel time still applies
		damage = 0,
		splash = 0,
		reveal_shape = "lane",
		reveal_size = 8, -- BIRD_LANE_WIDTH mirror (kept equal in tests)
		reveal_duration = 0,
		projectile_speed = 6, -- BIRD_SPEED mirror (kept equal in tests)
		interceptable = true,
		hp = 6,
		footprint = 1,
		max_hp_building_factor = 0.5,
		upgrades = {
			-- Both tiers stay in the "find" role: a faster, wider, tougher
			-- search, never a weapon. An upgraded perch is still a scout.
			{ coin_cost = 12, overrides = { cooldown = 14, reveal_size = 10 } },
			{ coin_cost = 20, overrides = { bird_hp_bonus = 10, reveal_size = 12 } },
		},
	} :: WeaponDef,

	nest = {
		id = "nest",
		display_name = "Slingshot Nest",
		role = "blind",
		coin_cost = 16,
		charge_cost = 0,
		cooldown = 0, -- continuous DPS, no per-shot cooldown
		range = 6, -- NEST_RADIUS [AA-LEVER]
		damage = 10, -- NEST_DPS (per second) [AA-LEVER]
		splash = 0,
		reveal_shape = "none",
		reveal_size = 0,
		reveal_duration = 0,
		projectile_speed = 0,
		interceptable = false,
		hp = 8,
		footprint = 1,
		max_hp_building_factor = 0.5,
		upgrades = {
			{ coin_cost = 12, overrides = { range = 7.5 } },
			{ coin_cost = 20, overrides = { damage = 14 } },
		},
	} :: WeaponDef,
}

-- Structure ids a player may purchase mid-match (everything but `base`).
Config.PURCHASABLE = { "decoy_base", "grove", "catapult", "perch", "nest" }

----------------------------------------------------------------------------
-- Overrides (used by the sweep, tests, and difficulty presets)
----------------------------------------------------------------------------

local function deepCopy(t: any): any
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in t do
		out[k] = deepCopy(v)
	end
	return out
end

-- Returns a deep copy of the config with a flat override table applied.
-- Top-level keys override Config fields; keys of the form
-- "WEAPONS.catapult.cooldown" reach into the roster.
function Config.withOverrides(overrides: { [string]: any })
	local copy = deepCopy(Config)
	copy.withOverrides = Config.withOverrides
	for key, value in overrides do
		local node: any = copy
		local parts = {}
		for part in string.gmatch(key, "[^%.]+") do
			table.insert(parts, part)
		end
		for i = 1, #parts - 1 do
			node = node[parts[i]]
			assert(node ~= nil, "bad override path: " .. key)
		end
		node[parts[#parts]] = value
	end
	return copy
end

return Config
