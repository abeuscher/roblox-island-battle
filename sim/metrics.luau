--!strict
-- metrics.luau — aggregation for the balance sweep (SPEC §11.3).
--
-- NOTE ON PRIVILEGE: this module and the harness are OBSERVERS, not
-- players. They read true MatchState to compute metrics such as
-- "time to first REAL base found", which no agent could ever know. Agents
-- get only Rules.viewFor. Keep that line sharp — every function here takes
-- the true state and is called from the harness loop, never from an agent.

local Metrics = {}

function Metrics.percentile(sorted: { number }, p: number): number
	if #sorted == 0 then
		return 0
	end
	local idx = math.max(1, math.min(#sorted, math.ceil(p * #sorted)))
	return sorted[idx]
end

function Metrics.mean(values: { number }): number
	if #values == 0 then
		return 0
	end
	local sum = 0
	for _, v in values do
		sum += v
	end
	return sum / #values
end

function Metrics.median(values: { number }): number
	local copy = table.clone(values)
	table.sort(copy)
	return Metrics.percentile(copy, 0.5)
end

-- A match length distribution is bimodal if a large share of matches sit in
-- both a fast and a slow cluster with a sparse middle. A 2-or-25-minute
-- result signals a dominant line that the mean conceals (SPEC §11.3).
function Metrics.bimodality(durations: { number }): number
	if #durations < 8 then
		return 0
	end
	local sorted = table.clone(durations)
	table.sort(sorted)
	local lo, hi = sorted[1], sorted[#sorted]
	if hi - lo < 1e-6 then
		return 0
	end
	local bins = 10
	local counts = table.create(bins, 0)
	for _, v in sorted do
		local b = math.min(bins, math.floor((v - lo) / (hi - lo) * bins) + 1)
		counts[b] += 1
	end
	-- Ratio of the emptiest interior bin to the average bin: near zero
	-- means a real gap between two clusters.
	local avg = #sorted / bins
	local minInterior = math.huge
	for b = 3, bins - 2 do
		minInterior = math.min(minInterior, counts[b])
	end
	if minInterior == math.huge then
		return 0
	end
	return 1 - (minInterior / math.max(avg, 1e-9))
end

-- Deterministic hash over the tuning constants that the sweep moves, so a
-- CSV row can be traced back to the exact config that produced it.
function Metrics.configHash(config: any): string
	local parts = {}
	local keys = {}
	for k, v in config do
		if type(v) == "number" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	for _, k in keys do
		table.insert(parts, k .. "=" .. tostring(config[k]))
	end
	for _, id in { "base", "decoy_base", "grove", "catapult", "perch", "nest" } do
		local w = config.WEAPONS[id]
		table.insert(
			parts,
			string.format(
				"%s:%d/%d/%g/%g/%g/%g/%g",
				id,
				w.coin_cost,
				w.charge_cost,
				w.cooldown,
				w.range,
				w.damage,
				w.hp,
				w.reveal_size
			)
		)
	end
	local blob = table.concat(parts, ";")
	-- FNV-1a, 32-bit, in double-safe arithmetic.
	local hash = 2166136261
	for i = 1, #blob do
		hash = bit32.bxor(hash, string.byte(blob, i))
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x", hash)
end

----------------------------------------------------------------------------
-- Aggregation over a set of match logs
----------------------------------------------------------------------------

export type Aggregate = {
	matches: number,
	winRate: { [string]: number },
	durations: { number },
	timeToFirstBase: { number },
	comebacks: number,
	comebackEligible: number,
	decoyKills: number,
	decoySpend: number,
	fireAbsorbedByDecoys: number,
	purchases: { [string]: number },
	coverageAt: { [number]: { number } },
	weaponKills: { [string]: number },
	timeouts: number,
	draws: number,
}

function Metrics.newAggregate(): Aggregate
	return {
		matches = 0,
		winRate = {},
		durations = {},
		timeToFirstBase = {},
		comebacks = 0,
		comebackEligible = 0,
		decoyKills = 0,
		decoySpend = 0,
		fireAbsorbedByDecoys = 0,
		purchases = {},
		coverageAt = {},
		weaponKills = {},
		timeouts = 0,
		draws = 0,
	}
end

function Metrics.absorb(agg: Aggregate, log: any)
	agg.matches += 1
	table.insert(agg.durations, log.duration)
	if log.endReason == "timeout" then
		agg.timeouts += 1
	end
	if log.winner == 0 then
		agg.draws += 1
	else
		local name = log.agents[log.winner]
		agg.winRate[name] = (agg.winRate[name] or 0) + 1
	end
	-- Keyed by seat, and a seat that never found a real base simply has no
	-- entry — it must not be averaged in as a zero.
	for _, t in log.firstRealBaseFound do
		table.insert(agg.timeToFirstBase, t)
	end
	if log.comebackEligible then
		agg.comebackEligible += 1
		if log.comeback then
			agg.comebacks += 1
		end
	end
	agg.decoyKills += log.decoyKills
	agg.decoySpend += log.decoySpend
	agg.fireAbsorbedByDecoys += log.fireAbsorbedByDecoys
	for kind, n in log.purchases do
		agg.purchases[kind] = (agg.purchases[kind] or 0) + n
	end
	for kind, n in log.weaponKills do
		agg.weaponKills[kind] = (agg.weaponKills[kind] or 0) + n
	end
	for _, sample in log.coverage do
		local bucket = agg.coverageAt[sample.t] or {}
		table.insert(bucket, sample.p1)
		table.insert(bucket, sample.p2)
		agg.coverageAt[sample.t] = bucket
	end
end

return Metrics
