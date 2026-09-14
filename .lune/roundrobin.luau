--!strict
-- `lune run roundrobin [matchesPerPair] [--bot]`
--
-- The M1.5 deliverable: a full archetype round robin from the terminal
-- producing a win-rate matrix, a time-to-first-base distribution, the
-- secondary metrics from SPEC §11.3, and a pathology pass over the logs.
-- Pass --bot to include the shipping bot's three difficulty presets as
-- additional entrants, which is how the bot gets measured rather than
-- vibed.

local fs = require("@lune/fs")

local Config = require("../src/shared/config")
local Harness = require("../sim/harness")
local Metrics = require("../sim/metrics")
local Rubric = require("../sim/rubric")
local BotBrain = require("../src/shared/botbrain")

local args = {}
for _, a in require("@lune/process").args do
	if a ~= "--" then
		table.insert(args, a)
	end
end

local matchesPerPair = tonumber(args[1]) or 40
local includeBot = false
for _, a in args do
	if a == "--bot" then
		includeBot = true
	end
end

local archetypes = Harness.loadArchetypes()
if includeBot then
	for _, preset in { "beachcomber", "skirmish", "siege" } do
		table.insert(archetypes, BotBrain.asAgent(preset))
	end
end

print(string.format("Round robin: %d archetypes, %d matches per pairing", #archetypes, matchesPerPair))
print("config " .. Metrics.configHash(Config))

local started = os.time()
local results = Harness.roundRobin(Config, archetypes, matchesPerPair, {
	baseSeed = 4242,
	keepLogs = true,
	matchOptions = { timeline = true, sampleInterval = 30 },
})
local elapsed = os.time() - started
local agg = results.overall

print(string.format("\n%d matches in %ds\n", agg.matches, elapsed))

-- Win-rate matrix
print("=== win rate matrix (row beats column) ===")
local header = string.rep(" ", 13)
for _, b in archetypes do
	header ..= string.format("%-12s", b.name)
end
print(header)
for _, a in archetypes do
	local line = string.format("%-13s", a.name)
	for _, b in archetypes do
		local rate = results.winRateMatrix[a.name][b.name]
		line ..= string.format("%-12s", rate and string.format("%.2f", rate) or "-")
	end
	print(line)
end

print("\n=== win rate vs the field (gate: no archetype above 0.60) ===")
local field = Harness.fieldWinRates(results, archetypes)
local names = {}
for name in field do
	table.insert(names, name)
end
table.sort(names, function(a, b)
	return field[a] > field[b]
end)
for _, name in names do
	print(string.format("  %-13s %.3f %s", name, field[name], field[name] > 0.60 and "  <-- DOMINANT" or ""))
end

-- Time to first real base
local firstBase = table.clone(agg.timeToFirstBase)
table.sort(firstBase)
local durations = table.clone(agg.durations)
table.sort(durations)
local medianDuration = Metrics.percentile(durations, 0.5)

print("\n=== time to first REAL base found (the primary metric) ===")
if #firstBase == 0 then
	print("  never found in any match")
else
	for _, p in { 0.10, 0.25, 0.50, 0.75, 0.90 } do
		print(string.format("  p%-3d %6.1fs", p * 100, Metrics.percentile(firstBase, p)))
	end
	local fraction = medianDuration > 0 and Metrics.percentile(firstBase, 0.5) / medianDuration or 0
	print(string.format(
		"  median is %.0f%% into the median match (target window 25-45%%) %s",
		fraction * 100,
		(fraction >= 0.25 and fraction <= 0.45) and "OK" or "<-- OUT OF WINDOW"
	))
end

print("\n=== match length distribution (not just the mean) ===")
for _, p in { 0.10, 0.25, 0.50, 0.75, 0.90 } do
	print(string.format("  p%-3d %6.1fs", p * 100, Metrics.percentile(durations, p)))
end
print(string.format("  mean %6.1fs   bimodality %.2f   timeouts %.1f%%   draws %d",
	Metrics.mean(agg.durations), Metrics.bimodality(agg.durations),
	agg.matches > 0 and agg.timeouts / agg.matches * 100 or 0, agg.draws))

print("\n=== secondary metrics ===")
print(string.format("  comeback rate        %.3f  (%d of %d eligible)",
	agg.comebackEligible > 0 and agg.comebacks / agg.comebackEligible or 0, agg.comebacks, agg.comebackEligible))
print(string.format("  decoy ROI            %.2f  (coin of fire absorbed per coin of decoy; <1.0 means decoys are a trap)",
	agg.decoySpend > 0 and agg.fireAbsorbedByDecoys / agg.decoySpend or 0))

local totalPurchases = 0
for _, n in agg.purchases do
	totalPurchases += n
end
print("  per-weapon purchase share:")
for _, id in Config.PURCHASABLE do
	local n = agg.purchases[id] or 0
	print(string.format("    %-12s %5.1f%%  (%d)  %s", id, totalPurchases > 0 and n / totalPurchases * 100 or 0, n,
		(totalPurchases > 0 and n / totalPurchases < 0.02) and "<-- never bought, miscosted" or ""))
end

print("\n=== reveal coverage curve (mean cells revealed per player) ===")
local times = {}
for t in agg.coverageAt do
	table.insert(times, t)
end
table.sort(times)
for _, t in times do
	if t <= 300 then
		print(string.format("  t=%3ds  %6.0f cells", t, Metrics.mean(agg.coverageAt[t])))
	end
end

-- Pathology pass
print("\n=== pathology pass (SPEC 11.4) ===")
local counts, flagged = Rubric.summarize(results.logs, Config)
if next(counts) == nil then
	print("  no structural pathologies flagged")
else
	for kind, n in counts do
		print(string.format("  %-20s %d matches (%.1f%%)", kind, n, n / agg.matches * 100))
	end
end

if not fs.isDir("sim/out") then
	fs.writeDir("sim/out")
end
-- Only the flagged matches are written out: the point of the rubric is to
-- hand a reader the matches worth reading, not all of them.
local jsonl = {}
for _, entry in flagged do
	local kinds = {}
	for _, f in entry.findings do
		table.insert(kinds, string.format('{"kind":"%s","detail":"%s"}', f.kind, f.detail))
	end
	table.insert(jsonl, string.format(
		'{"seed":%d,"agents":["%s","%s"],"winner":%d,"duration":%.1f,"endReason":"%s","findings":[%s]}',
		entry.log.seed, entry.log.agents[1], entry.log.agents[2], entry.log.winner,
		entry.log.duration, entry.log.endReason, table.concat(kinds, ",")
	))
end
fs.writeFile("sim/out/flagged.jsonl", table.concat(jsonl, "\n") .. "\n")
print(string.format("\nwrote sim/out/flagged.jsonl (%d flagged matches)", #flagged))
