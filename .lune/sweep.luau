--!strict
-- `lune run sweep [-- which shard shards matchesPerPair]`
--   which          "first" (anti-air lever, default) or "second" (economy)
--   shard/shards   1-based shard index and total, so the grid can be run
--                  across several processes and the CSVs concatenated
--   matchesPerPair matches per archetype pairing (default from config)
--
-- Writes sim/out/sweep_<which>_<shard>.csv.

local process = require("@lune/process")
local fs = require("@lune/fs")

local Config = require("../src/shared/config")
local Harness = require("../sim/harness")
local Sweep = require("../sim/sweep")

-- Lune forwards the `--` separator itself when the command line uses one,
-- so drop it before reading positional arguments.
local args = {}
for _, a in process.args do
	if a ~= "--" then
		table.insert(args, a)
	end
end

local which = args[1] or "first"
local shard = tonumber(args[2]) or 1
local shards = tonumber(args[3]) or 1
local matchesPerPair = tonumber(args[4]) or Config.SIM_MATCHES_PER_PAIR

local GRIDS = { first = Sweep.FIRST, second = Sweep.SECOND, pacing = Sweep.PACING }
local dimensions = GRIDS[which] or Sweep.FIRST
local combos = Sweep.expand(dimensions)
local archetypes = Harness.loadArchetypes()

if not fs.isDir("sim/out") then
	fs.writeDir("sim/out")
end

local path = string.format("sim/out/sweep_%s_%d.csv", which, shard)
local lines = { Sweep.csvHeader(dimensions) }
local survivors = {}

-- Rewritten after every grid cell so a long sweep can be watched (and
-- salvaged) while it runs, rather than only at the end.
local function flush()
	fs.writeFile(path, table.concat(lines, "\n") .. "\n")
end
flush()

for i, overrides in combos do
	if (i - 1) % shards + 1 == shard then
		local started = os.time()
		local verdict = Sweep.evaluate(overrides, archetypes, matchesPerPair, 1000 + i * 97)
		table.insert(lines, Sweep.csvRow(dimensions, verdict))
		flush()
		if verdict.survives then
			table.insert(survivors, verdict)
		end
		local desc = {}
		for _, dim in dimensions do
			table.insert(desc, dim.label .. "=" .. tostring(overrides[dim.key]))
		end
		print(
			string.format(
				"[%d/%d] %-72s firstBase=%5.0fs (%.0f%% of match) median=%4.0fs win=%.2f(%s) comeback=%.2f %s  %ds",
				i,
				#combos,
				table.concat(desc, " "),
				verdict.medianFirstBase,
				verdict.firstBaseFraction * 100,
				verdict.medianDuration,
				verdict.maxFieldWinRate,
				verdict.worstArchetype,
				verdict.comebackRate,
				verdict.survives and "SURVIVES" or ("x " .. table.concat(verdict.failures, "; ")),
				os.time() - started
			)
		)
	end
end

flush()
print(string.format("\nwrote %s (%d rows, %d surviving)", path, #lines - 1, #survivors))
