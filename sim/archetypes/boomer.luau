--!strict
-- boomer — groves first, no offense until income compounds, then mass buys.
-- The control case for the economy: if boomer runs away with the round
-- robin, grove income or grove cost is mispriced (SPEC §11.5 second sweep).
local Common = require("./common")

return Common.make({
	name = "boomer",
	openingBuild = { "grove", "grove", "grove", "grove" },
	buildOrder = {
		{ kind = "grove", cap = 7, band = "inland" },
		{ kind = "nest", cap = 2, band = "mid" },
		{ kind = "perch", cap = 2, band = "shore" },
		{ kind = "catapult", cap = 5, band = "shore" },
	},
	killOnSight = true,
	coverageBeforeKill = 0,
	suppressNests = true,
	bombardGroves = true,
	blindFire = false,
	birdChargeReserve = 0,
	-- Holds coin back early so the grove engine keeps compounding.
	scoutUntilCoverage = 0.6,
	minLaneValue = 120,
	coinFloor = 12,
	laneRepeatAfter = 100,
})
