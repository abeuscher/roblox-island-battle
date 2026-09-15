--!strict
-- trickster — multiple decoys, minimal real defense, wins by wasting the
-- opponent's fire. The readout on decoy ROI (SPEC §11.3): if trickster is
-- unbeatable, DECOY_FAKE_KILL_FEEDBACK plus decoy cost is too strong.
local Common = require("./common")

return Common.make({
	name = "trickster",
	openingBuild = { "decoy_base", "decoy_base", "grove", "decoy_base" },
	buildOrder = {
		{ kind = "decoy_base", cap = 5, band = "any" },
		{ kind = "grove", cap = 3, band = "inland" },
		{ kind = "perch", cap = 1, band = "shore" },
		{ kind = "catapult", cap = 3, band = "shore" },
		{ kind = "nest", cap = 1, band = "mid" },
	},
	killOnSight = true,
	coverageBeforeKill = 0,
	suppressNests = false,
	bombardGroves = false,
	blindFire = false,
	birdChargeReserve = 0,
	laneRepeatAfter = 120,
	scoutUntilCoverage = 0.55,
	minLaneValue = 120,
	coinFloor = 0,
})
