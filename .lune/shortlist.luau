--!strict
-- `lune run shortlist [grid]` — reads every sweep CSV in sim/out and ranks
-- configurations, best first.
--
-- This is the M1.5 deliverable "a shortlist of surviving configs". When
-- configurations survive every gate it lists those. When none do — which is
-- the current state, and a finding in its own right (DECISIONS.md §3) — it
-- ranks by how many gates each one fails and how far it misses, so the
-- shortlist still says something useful instead of printing nothing.
--
-- Per SPEC §11.5 this narrows and does not decide. Roughly five surviving
-- configurations are meant to go to human playtesting; nothing here picks
-- one.

local fs = require("@lune/fs")
local process = require("@lune/process")

local args = {}
for _, a in process.args do
	if a ~= "--" then
		table.insert(args, a)
	end
end
local wanted = args[1]

local function splitCsvLine(line: string): { string }
	-- Handles the one quoted column (failures), which may contain commas.
	local fields = {}
	local current = ""
	local inQuotes = false
	for i = 1, #line do
		local c = string.sub(line, i, i)
		if c == '"' then
			inQuotes = not inQuotes
		elseif c == "," and not inQuotes then
			table.insert(fields, current)
			current = ""
		else
			current ..= c
		end
	end
	table.insert(fields, current)
	return fields
end

type Row = { grid: string, dims: { string }, values: { [string]: string } }

local rows: { Row } = {}
if not fs.isDir("sim/out") then
	print("no sim/out directory — run a sweep first")
	return
end

for _, name in fs.readDir("sim/out") do
	local grid = string.match(name, "^sweep_([%a]+)_%d+%.csv$")
	if grid and (not wanted or grid == wanted) then
		local lines = string.split(fs.readFile("sim/out/" .. name), "\n")
		local header = splitCsvLine(lines[1])
		-- Every column before config_hash is a swept dimension.
		local dims = {}
		for _, column in header do
			if column == "config_hash" then
				break
			end
			table.insert(dims, column)
		end
		for i = 2, #lines do
			if lines[i] ~= "" then
				local fields = splitCsvLine(lines[i])
				local values = {}
				for j, column in header do
					values[column] = fields[j]
				end
				table.insert(rows, { grid = grid, dims = dims, values = values })
			end
		end
	end
end

if #rows == 0 then
	print("no sweep results found in sim/out")
	return
end

local function num(row: Row, key: string): number
	return tonumber(row.values[key]) or 0
end

local function failureCount(row: Row): number
	local failures = row.values.failures or ""
	if failures == "" then
		return 0
	end
	local n = 1
	for _ in string.gmatch(failures, ";") do
		n += 1
	end
	return n
end

-- Ranked by gates failed, then by distance from the two targets the spec
-- is most specific about: the first-base window (§11.3) and match length
-- (§1). Both are normalized so neither dominates the other by units.
local function score(row: Row): number
	local fraction = num(row, "first_base_fraction")
	local duration = num(row, "median_duration_s")
	local fractionMiss = math.max(0, 0.25 - fraction) + math.max(0, fraction - 0.45)
	local durationMiss = math.max(0, 480 - duration) / 480 + math.max(0, duration - 720) / 720
	return failureCount(row) * 10 + fractionMiss * 4 + durationMiss
end

table.sort(rows, function(a, b)
	return score(a) < score(b)
end)

local survivors = {}
for _, row in rows do
	if row.values.survives == "yes" then
		table.insert(survivors, row)
	end
end

print(string.format("%d configurations across %s\n", #rows, wanted and ("grid " .. wanted) or "all grids"))

if #survivors > 0 then
	print(string.format("=== %d configurations survive every gate ===", #survivors))
else
	print("=== no configuration survives every gate ===")
	print("Ranked by gates failed, then by distance from the §11.3 first-base")
	print("window and the §1 match-length window.\n")
end

for i = 1, math.min(10, #rows) do
	local row = rows[i]
	local settings = {}
	for _, dim in row.dims do
		table.insert(settings, dim .. "=" .. row.values[dim])
	end
	print(string.format("%2d. [%s] %s", i, row.grid, table.concat(settings, "  ")))
	print(string.format(
		"    first base %5.1fs (%4.1f%% of match, target 25-45%%)   match %5.0fs (target 480-720s)   p10 %4.0fs  p90 %4.0fs",
		num(row, "median_first_base_s"),
		num(row, "first_base_fraction") * 100,
		num(row, "median_duration_s"),
		num(row, "p10_duration_s"),
		num(row, "p90_duration_s")
	))
	print(string.format(
		"    top archetype %.2f (%s, gate 0.60)   comebacks %.2f   timeouts %.0f%%   decoy ROI %.2f",
		num(row, "max_field_win_rate"),
		row.values.dominant_archetype,
		num(row, "comeback_rate"),
		num(row, "timeout_rate") * 100,
		num(row, "decoy_roi")
	))
	if row.values.failures ~= "" then
		print(string.format("    misses: %s", row.values.failures))
	end
	print("")
end

print("SPEC §11.5: the sweep narrows, it does not decide. These go to human")
print("playtesting; none of them is a shipping config.")
