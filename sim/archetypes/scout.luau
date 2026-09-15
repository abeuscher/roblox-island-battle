--!strict
-- scout — perch-heavy, wants full coverage before committing kill fire.
-- The direct readout on time-to-first-base (SPEC §11.3): scout's results
-- are what the anti-air sweep is really measuring.
local Common = require("./common")

return Common.make({
	name = "scout",
	openingBuild = { "perch", "grove", "grove" },
	buildOrder = {
		{ kind = "perch", cap = 3, band = "shore" },
		{ kind = "grove", cap = 4, band = "inland" },
		{ kind = "catapult", cap = 4, band = "shore" },
		{ kind = "nest", cap = 2, band = "mid" },
	},
	killOnSight = true,
	-- Holds fire until a third of the enemy board is plotted.
	coverageBeforeKill = 0.33,
	suppressNests = true,
	bombardGroves = false,
	blindFire = false,
	-- Always keeps a bird's worth of charge banked.
	birdChargeReserve = 2,
	laneRepeatAfter = 150,
	scoutUntilCoverage = 0.9,
	minLaneValue = 60,
	coinFloor = 0,
})
