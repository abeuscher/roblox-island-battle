--!strict
-- turtle — heavy nest coverage early, minimal offense, wins on attrition.
-- The control case for the anti-air lever: if turtle dominates, nests are
-- overtuned and nobody can find anything.
local Common = require("./common")

return Common.make({
	name = "turtle",
	openingBuild = { "nest", "nest", "grove" },
	buildOrder = {
		{ kind = "nest", cap = 8, band = "mid" },
		{ kind = "grove", cap = 4, band = "inland" },
		{ kind = "perch", cap = 1, band = "shore" },
		{ kind = "catapult", cap = 2, band = "shore" },
	},
	killOnSight = true,
	coverageBeforeKill = 0,
	suppressNests = false,
	bombardGroves = false,
	blindFire = false,
	birdChargeReserve = 0,
	laneRepeatAfter = 90,
	scoutUntilCoverage = 0.55,
	minLaneValue = 120,
	coinFloor = 0,
})
