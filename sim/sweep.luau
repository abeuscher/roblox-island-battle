--!strict
-- sweep.luau — archetype round robin across a parameter grid (SPEC §11.5).
--
-- The sweep NARROWS; it does not decide. Its output is the region of
-- parameter space where time-to-first-real-base lands in the target window,
-- no archetype beats the field by more than 60%, and comebacks still
-- happen. Roughly five surviving configurations then go to human
-- playtesting. Nothing here picks a shipping config on its own.

local Config = require("../src/shared/config")
local Harness = require("./harness")
local Metrics = require("./metrics")

local Sweep = {}

-- First sweep, in the priority order SPEC §11.5 asks for: the anti-air
-- lever first (it is the strongest lever in the game, §7), then the rate
-- at which found bases actually die.
Sweep.FIRST = {
	{ key = "WEAPONS.nest.damage", label = "NEST_DPS", values = { 10, 16, 24 } },
	{ key = "WEAPONS.nest.range", label = "NEST_RADIUS", values = { 6, 8, 10 } },
	{ key = "BIRD_HP", values = { 12, 20, 32 }, label = "BIRD_HP" },
	{ key = "WEAPONS.catapult.cooldown", label = "CATAPULT_COOLDOWN", values = { 6, 9 } },
}

-- Second sweep: the economy (SPEC §11.5). Run after the AA region is known.
Sweep.SECOND = {
	{ key = "COIN_BASE_RATE", label = "COIN_BASE_RATE", values = { 1, 2 } },
	{ key = "CHARGE_REGEN_SECONDS", label = "CHARGE_REGEN_SECONDS", values = { 4, 6, 8 } },
	{ key = "WEAPONS.grove.coin_cost", label = "GROVE_COST", values = { 8, 10, 14 } },
}

-- Third sweep — NOT in the spec, added because the first sweep said the
-- spec's priority order is wrong for this build. SPEC §7 predicts anti-air
-- is the strongest lever; across all 54 cells of the first grid, moving
-- NEST_DPS 10 -> 24, NEST_RADIUS 6 -> 10 and BIRD_HP 12 -> 32 changed
-- median time-to-first-base by under two seconds.
--
-- The reason is a timing one the spec's math does not model: the opening
-- loadout buys a perch, so the first bird flies at t ~ 0, before any nest
-- has been built. Anti-air cannot contest the flight that actually finds
-- the bases, so its numbers are close to inert.
--
-- What does move discovery is how much one pass reveals (BIRD_LANE_WIDTH)
-- and how often a pass can be afforded (perch charge cost). What moves
-- match length is base HP and the Charge regen that paces all firing.
-- See DECISIONS.md.
Sweep.PACING = {
	{ key = "BIRD_LANE_WIDTH", label = "BIRD_LANE_WIDTH", values = { 3, 5, 8 } },
	{ key = "WEAPONS.base.hp", label = "BASE_HP", values = { 40, 90, 140 } },
	{ key = "CHARGE_REGEN_SECONDS", label = "CHARGE_REGEN_SECONDS", values = { 5, 7, 9 } },
	{ key = "WEAPONS.perch.charge_cost", label = "PERCH_CHARGE", values = { 2, 3 } },
}

-- Expands a dimension list into every combination, in a stable order.
function Sweep.expand(dimensions: { any }): { { [string]: any } }
	local combos = { {} }
	for _, dim in dimensions do
		local next_ = {}
		for _, combo in combos do
			for _, value in dim.values do
				local copy = table.clone(combo)
				copy[dim.key] = value
				table.insert(next_, copy)
			end
		end
		combos = next_
	end
	return combos
end

export type Verdict = {
	overrides: { [string]: any },
	configHash: string,
	matches: number,
	medianFirstBase: number,
	firstBaseFraction: number, -- as a share of median match length
	medianDuration: number,
	p10Duration: number,
	p90Duration: number,
	bimodality: number,
	timeoutRate: number,
	maxFieldWinRate: number,
	worstArchetype: string,
	comebackRate: number,
	decoyRoi: number,
	purchaseShare: { [string]: number },
	survives: boolean,
	failures: { string },
}

-- The acceptance gates from SPEC §11.3 and §11.5.
Sweep.GATES = {
	-- Time to first real base, as a fraction of median match length.
	firstBaseMin = 0.25,
	firstBaseMax = 0.45,
	-- No archetype may beat the field by more than this.
	maxFieldWinRate = 0.60,
	-- Comeback rate must be non-trivial.
	minComebackRate = 0.10,
	-- Matches that run to the hard cap are stalls, not games.
	maxTimeoutRate = 0.25,
	-- Target match length window, in combat seconds (SPEC §1: 8–12 min).
	durationMin = 8 * 60,
	durationMax = 12 * 60,
}

function Sweep.evaluate(overrides: { [string]: any }, archetypes: { any }, matchesPerPair: number, baseSeed: number): Verdict
	local config = Config.withOverrides(overrides)
	local results = Harness.roundRobin(config, archetypes, matchesPerPair, { baseSeed = baseSeed })
	local agg = results.overall
	local field = Harness.fieldWinRates(results, archetypes)

	local durations = table.clone(agg.durations)
	table.sort(durations)
	local firstBase = table.clone(agg.timeToFirstBase)
	table.sort(firstBase)

	local medianDuration = Metrics.percentile(durations, 0.5)
	local medianFirstBase = Metrics.percentile(firstBase, 0.5)
	local fraction = medianDuration > 0 and medianFirstBase / medianDuration or 0

	local maxWinRate, worst = 0, ""
	for name, rate in field do
		if rate > maxWinRate then
			maxWinRate, worst = rate, name
		end
	end

	local comebackRate = agg.comebackEligible > 0 and agg.comebacks / agg.comebackEligible or 0
	local decoyRoi = agg.decoySpend > 0 and agg.fireAbsorbedByDecoys / agg.decoySpend or 0

	local totalPurchases = 0
	for _, n in agg.purchases do
		totalPurchases += n
	end
	local share = {}
	for _, id in Config.PURCHASABLE do
		share[id] = totalPurchases > 0 and (agg.purchases[id] or 0) / totalPurchases or 0
	end

	local failures = {}
	if fraction < Sweep.GATES.firstBaseMin then
		table.insert(failures, "first-base too early (fog decorative)")
	elseif fraction > Sweep.GATES.firstBaseMax then
		table.insert(failures, "first-base too late (matches stall)")
	end
	if maxWinRate > Sweep.GATES.maxFieldWinRate then
		table.insert(failures, "dominant archetype " .. worst)
	end
	if comebackRate < Sweep.GATES.minComebackRate then
		table.insert(failures, "no comebacks (snowball)")
	end
	if agg.matches > 0 and agg.timeouts / agg.matches > Sweep.GATES.maxTimeoutRate then
		table.insert(failures, "too many hard-cap timeouts")
	end
	if medianDuration < Sweep.GATES.durationMin then
		table.insert(failures, "matches too short")
	elseif medianDuration > Sweep.GATES.durationMax then
		table.insert(failures, "matches too long")
	end
	for _, id in Config.PURCHASABLE do
		if share[id] < 0.02 then
			table.insert(failures, "never bought: " .. id)
		end
	end

	return {
		overrides = overrides,
		configHash = Metrics.configHash(config),
		matches = agg.matches,
		medianFirstBase = medianFirstBase,
		firstBaseFraction = fraction,
		medianDuration = medianDuration,
		p10Duration = Metrics.percentile(durations, 0.10),
		p90Duration = Metrics.percentile(durations, 0.90),
		bimodality = Metrics.bimodality(agg.durations),
		timeoutRate = agg.matches > 0 and agg.timeouts / agg.matches or 0,
		maxFieldWinRate = maxWinRate,
		worstArchetype = worst,
		comebackRate = comebackRate,
		decoyRoi = decoyRoi,
		purchaseShare = share,
		survives = #failures == 0,
		failures = failures,
	}
end

function Sweep.csvHeader(dimensions: { any }): string
	local cols = {}
	for _, dim in dimensions do
		table.insert(cols, dim.label)
	end
	for _, c in {
		"config_hash",
		"matches",
		"median_first_base_s",
		"first_base_fraction",
		"median_duration_s",
		"p10_duration_s",
		"p90_duration_s",
		"bimodality",
		"timeout_rate",
		"max_field_win_rate",
		"dominant_archetype",
		"comeback_rate",
		"decoy_roi",
		"share_decoy",
		"share_grove",
		"share_catapult",
		"share_perch",
		"share_nest",
		"survives",
		"failures",
	} do
		table.insert(cols, c)
	end
	return table.concat(cols, ",")
end

function Sweep.csvRow(dimensions: { any }, verdict: Verdict): string
	local cols = {}
	for _, dim in dimensions do
		table.insert(cols, tostring(verdict.overrides[dim.key]))
	end
	for _, v in {
		verdict.configHash,
		tostring(verdict.matches),
		string.format("%.1f", verdict.medianFirstBase),
		string.format("%.3f", verdict.firstBaseFraction),
		string.format("%.1f", verdict.medianDuration),
		string.format("%.1f", verdict.p10Duration),
		string.format("%.1f", verdict.p90Duration),
		string.format("%.3f", verdict.bimodality),
		string.format("%.3f", verdict.timeoutRate),
		string.format("%.3f", verdict.maxFieldWinRate),
		verdict.worstArchetype,
		string.format("%.3f", verdict.comebackRate),
		string.format("%.2f", verdict.decoyRoi),
		string.format("%.3f", verdict.purchaseShare.decoy_base),
		string.format("%.3f", verdict.purchaseShare.grove),
		string.format("%.3f", verdict.purchaseShare.catapult),
		string.format("%.3f", verdict.purchaseShare.perch),
		string.format("%.3f", verdict.purchaseShare.nest),
		verdict.survives and "yes" or "no",
		'"' .. table.concat(verdict.failures, "; ") .. '"',
	} do
		table.insert(cols, v)
	end
	return table.concat(cols, ",")
end

-- Fourth grid — the controlled test of the §3.1 hypothesis in DECISIONS.md.
-- SETUP_ALLOWS_RECON is swept as a dimension, not assumed, so the run
-- yields a like-for-like comparison of the spec's opening against one where
-- the first bird has to be paid for out of combat income.
Sweep.RECON = {
	{ key = "SETUP_ALLOWS_RECON", label = "SETUP_RECON", values = { true, false } },
	{ key = "WEAPONS.base.hp", label = "BASE_HP", values = { 90, 140, 200 } },
	{ key = "CHARGE_REGEN_SECONDS", label = "CHARGE_REGEN_SECONDS", values = { 7, 9, 11 } },
	{ key = "BIRD_LANE_WIDTH", label = "BIRD_LANE_WIDTH", values = { 5, 8 } },
}

-- Fifth grid — the last experiment M1.5 has left to run.
--
-- Sweeps two, three and four all found the same wall: time-to-first-real-
-- base sits at roughly 30-50s no matter which lever moves, so lengthening
-- a match only makes discovery a *smaller* fraction of it and the §11.3
-- window moves further out of reach. The cause is that one bird pass is
-- decisive whenever it happens.
--
-- So this grid sweeps what a pass is WORTH at tier 0, now that lane width
-- is a tier-aware perch stat. A narrow opening lane that upgrades wider is
-- the only mechanism in the roster that makes intel scale with the length
-- of the match rather than arriving all at once in the first minute.
Sweep.INTEL = {
	{ key = "WEAPONS.perch.reveal_size", label = "LANE_TIER0", values = { 3, 5, 8 } },
	{ key = "WEAPONS.perch.cooldown", label = "PERCH_COOLDOWN", values = { 14, 20 } },
	{ key = "WEAPONS.base.hp", label = "BASE_HP", values = { 90, 140 } },
	{ key = "CHARGE_REGEN_SECONDS", label = "CHARGE_REGEN_SECONDS", values = { 7, 9, 11 } },
}

-- Sixth grid — the narrow end of the intel lever.
--
-- Grid five showed the direction is right but the magnitude is not: a
-- tier-0 lane of 3 moves time-to-first-base from ~40s to ~59s and lifts
-- decoy ROI from 0.73 to 0.80, yet the §11.3 ratio still lands near 10%
-- because longer matches grow faster than discovery does.
--
-- Reaching 25% of a 580s match needs first base near 145s, so this grid
-- asks the obvious next question: how narrow does the opening lane have to
-- be before recon stops being one decisive look and becomes a search that
-- takes minutes? A width of 1 is a bird that reveals only its exact flight
-- line, which is the same reveal rule every projectile already follows.
Sweep.NARROW = {
	{ key = "WEAPONS.perch.reveal_size", label = "LANE_TIER0", values = { 1, 2, 3 } },
	{ key = "WEAPONS.base.hp", label = "BASE_HP", values = { 140, 200 } },
	{ key = "CHARGE_REGEN_SECONDS", label = "CHARGE_REGEN_SECONDS", values = { 9, 11 } },
}

return Sweep
