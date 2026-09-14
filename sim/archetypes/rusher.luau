--!strict
-- rusher — catapults first, bombards blind, accepts poor economy.
-- The control case for blind saturation: if rusher wins without scouting,
-- firing is too cheap and fog has stopped mattering (SPEC §4).
local Common = require("./common")

return Common.make({
	name = "rusher",
	openingBuild = { "catapult", "catapult", "catapult" },
	buildOrder = {
		{ kind = "catapult", cap = 6, band = "shore" },
		{ kind = "grove", cap = 2, band = "inland" },
		{ kind = "perch", cap = 1, band = "shore" },
		{ kind = "nest", cap = 1, band = "mid" },
	},
	killOnSight = true,
	coverageBeforeKill = 0,
	suppressNests = true,
	bombardGroves = true,
	blindFire = true,
	birdChargeReserve = 0,
	laneRepeatAfter = 120,
	scoutUntilCoverage = 0.45,
	minLaneValue = 120,
	coinFloor = 0,
})
