--!strict
-- `lune run sim` — a quick smoke run of the harness: one match per pairing
-- with a full timeline, printed as a readable summary. Use `lune run sweep`
-- for the real round robin.

local Config = require("../src/shared/config")
local Harness = require("../sim/harness")

local archetypes = Harness.loadArchetypes()

print("Island Siege — sim smoke run")
print("config " .. require("../sim/metrics").configHash(Config))
print("")

for ai = 1, #archetypes do
	for bi = ai, #archetypes do
		local a, b = archetypes[ai], archetypes[bi]
		local log = Harness.runMatch(Config, 1234, { a, b }, { timeline = true, sampleInterval = 60 })
		local firstFound = log.firstRealBaseFound[1] and string.format("%.0fs", log.firstRealBaseFound[1]) or "never"
		print(
			string.format(
				"%-10s vs %-10s  winner=%-10s %5.0fs  %-8s firstBase=%-6s shots=%d/%d birds=%d/%d decoyKills=%d",
				a.name,
				b.name,
				log.winner == 0 and "draw" or log.agents[log.winner],
				log.duration,
				log.endReason,
				firstFound,
				log.shotsFired[1],
				log.shotsFired[2],
				log.birdsFlown[1],
				log.birdsFlown[2],
				log.decoyKills
			)
		)
	end
end
