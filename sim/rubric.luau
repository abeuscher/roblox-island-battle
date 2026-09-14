--!strict
-- rubric.luau — pathology detection over match logs (SPEC §11.4).
--
-- The spec asks for a model pass over the logs. A model is not reachable
-- from a headless Lune run, so this module does the mechanical half: it
-- flags the specific failure SHAPES the spec names, and the harness writes
-- the flagged matches to sim/out/*.jsonl so a model (or a human) can read
-- the ones that matter instead of all of them. See DECISIONS.md.
--
-- Deliberately NOT scored: anything resembling "is this fun". Per the spec,
-- treat balance and fairness as reliable and direct enjoyment scores as
-- near-noise. Everything below is a structural defect, not a taste call.

local Rubric = {}

export type Finding = {
	kind: string,
	detail: string,
}

-- A stretch of match time in which neither player did anything that could
-- change the outcome: no shots, no builds, no reveals.
local function deadAir(log: any, threshold: number): Finding?
	if #log.timeline < 2 then
		return nil
	end
	local longest, lastAction = 0, log.timeline[1].t
	for _, entry in log.timeline do
		local gap = entry.t - lastAction
		if gap > longest then
			longest = gap
		end
		lastAction = entry.t
	end
	local tailGap = log.duration - lastAction
	if tailGap > longest then
		longest = tailGap
	end
	if longest >= threshold then
		return {
			kind = "dead_air",
			detail = string.format("%.0fs with no consequential action", longest),
		}
	end
	return nil
end

-- The loser spent the end of the match doing things that could not have
-- affected the result: no fire, no scouting, only building.
local function futileEndgame(log: any): Finding?
	if log.winner == 0 or #log.timeline == 0 then
		return nil
	end
	local loser = 3 - log.winner
	local lateWindow = log.duration * 0.75
	local consequential, total = 0, 0
	for _, entry in log.timeline do
		if entry.player == loser and entry.t >= lateWindow then
			total += 1
			if entry.action == "fire" or entry.action == "launch_bird" then
				consequential += 1
			end
		end
	end
	if total >= 4 and consequential == 0 then
		return {
			kind = "futile_endgame",
			detail = string.format("loser's last %d actions had no bearing on the outcome", total),
		}
	end
	return nil
end

-- The match was effectively decided by setup placement: one side lost
-- bases before it had a meaningful chance to act.
local function decidedInSetup(log: any): Finding?
	if log.winner == 0 or #log.coverage == 0 then
		return nil
	end
	local first = log.coverage[1]
	if first.bases1 <= 1 or first.bases2 <= 1 then
		return {
			kind = "decided_in_setup",
			detail = "a player was down to one base within the first sample window",
		}
	end
	return nil
end

-- A weapon appears in the logs but never affects an outcome.
local function inertWeapon(log: any, config: any): { Finding }
	local findings = {}
	for _, id in config.PURCHASABLE do
		local bought = log.purchases[id] or 0
		if bought > 0 then
			local killed = log.weaponKills[id] or 0
			if id == "nest" and log.birdsLost[1] + log.birdsLost[2] == 0 and bought >= 2 then
				table.insert(findings, {
					kind = "inert_weapon",
					detail = string.format("%d nests bought, no bird ever downed", bought),
				})
			elseif id == "decoy_base" and killed == 0 and bought >= 2 then
				table.insert(findings, {
					kind = "inert_weapon",
					detail = string.format("%d decoys bought, none ever drew fire", bought),
				})
			end
		end
	end
	return findings
end

function Rubric.inspect(log: any, config: any): { Finding }
	local findings = {}
	local checks = {
		deadAir(log, 90),
		futileEndgame(log),
		decidedInSetup(log),
	}
	for _, finding in checks do
		if finding then
			table.insert(findings, finding)
		end
	end
	for _, finding in inertWeapon(log, config) do
		table.insert(findings, finding)
	end
	return findings
end

-- Aggregates findings across a batch of logs into counts by kind.
function Rubric.summarize(logs: { any }, config: any): ({ [string]: number }, { any })
	local counts = {}
	local flagged = {}
	for _, log in logs do
		local findings = Rubric.inspect(log, config)
		if #findings > 0 then
			table.insert(flagged, { log = log, findings = findings })
			for _, finding in findings do
				counts[finding.kind] = (counts[finding.kind] or 0) + 1
			end
		end
	end
	return counts, flagged
end

return Rubric
