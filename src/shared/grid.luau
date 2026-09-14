--!strict
-- grid.luau — island generation, cell math, line-of-flight.
-- Pure Luau: no Roblox APIs, deterministic for a given seed.
--
-- Coordinate convention (important — used everywhere):
-- Each player's island lives in its OWN local grid, x and y in [1..D].
-- x = D is that island's shore facing the channel; x = 1 is the inland edge.
-- y runs along the shoreline. The two islands face each other, so the
-- horizontal separation between my cell (sx) and an enemy cell (tx) is
--   (D - sx) + CHANNEL_WIDTH + (D - tx)
-- This keeps the rules perfectly symmetric with no mirroring anywhere.

local Grid = {}

----------------------------------------------------------------------------
-- Deterministic RNG (own LCG so Lune, Roblox, and the sweep all agree)
----------------------------------------------------------------------------

export type Rng = {
	state: number,
	next: (self: Rng) -> number, -- float in [0, 1)
	nextInt: (self: Rng, lo: number, hi: number) -> number, -- inclusive
}

local RngMt = {}
RngMt.__index = RngMt

function RngMt.next(self: Rng): number
	-- Numerical Recipes LCG, kept inside the 2^53 double-exact range.
	self.state = (self.state * 1664525 + 1013904223) % 4294967296
	return self.state / 4294967296
end

function RngMt.nextInt(self: Rng, lo: number, hi: number): number
	return lo + math.floor(RngMt.next(self) * (hi - lo + 1))
end

function Grid.makeRng(seed: number): Rng
	local self = setmetatable({ state = math.floor(seed) % 4294967296 }, RngMt)
	-- burn a few values so nearby seeds diverge quickly
	self:next()
	self:next()
	return (self :: any) :: Rng
end

----------------------------------------------------------------------------
-- Cell keys
----------------------------------------------------------------------------

function Grid.key(x: number, y: number): string
	return x .. "," .. y
end

function Grid.parseKey(key: string): (number, number)
	local cx, cy = string.match(key, "^(-?%d+),(-?%d+)$")
	assert(cx and cy, "bad cell key: " .. tostring(key))
	return tonumber(cx) :: number, tonumber(cy) :: number
end

----------------------------------------------------------------------------
-- Island generation
----------------------------------------------------------------------------

export type Island = {
	diameter: number,
	-- set of unbuildable obstacle cells, keyed "x,y"
	obstacles: { [string]: boolean },
	-- persistent rubble left by destroyed structures, keyed "x,y" (starts empty)
	rubble: { [string]: boolean },
	buildableCount: number,
}

-- A cell is on the island if it falls inside the inscribed circle.
function Grid.inIsland(diameter: number, x: number, y: number): boolean
	if x < 1 or y < 1 or x > diameter or y > diameter then
		return false
	end
	local c = (diameter + 1) / 2
	local r = diameter / 2
	local dx, dy = x - c, y - c
	return dx * dx + dy * dy <= r * r
end

-- Both islands are generated from the same shared seed and use the IDENTICAL
-- layout in local coordinates, which makes them mirror-fair by construction
-- (buildable counts match exactly, not just ±2). See DECISIONS.md.
function Grid.generateIsland(config: any, seed: number): Island
	local d = config.ISLAND_DIAMETER
	local rng = Grid.makeRng(seed)
	local obstacleCount = rng:nextInt(config.OBSTACLE_MIN, config.OBSTACLE_MAX)

	local landCells = {}
	for x = 1, d do
		for y = 1, d do
			if Grid.inIsland(d, x, y) then
				table.insert(landCells, { x, y })
			end
		end
	end

	local obstacles: { [string]: boolean } = {}
	local placed = 0
	local guard = 0
	while placed < obstacleCount and guard < 10000 do
		guard += 1
		local cell = landCells[rng:nextInt(1, #landCells)]
		local k = Grid.key(cell[1], cell[2])
		if not obstacles[k] then
			obstacles[k] = true
			placed += 1
		end
	end

	return {
		diameter = d,
		obstacles = obstacles,
		rubble = {},
		buildableCount = #landCells - placed,
	}
end

-- True if (x, y) is a legal ground cell: on the island and not an obstacle.
function Grid.isBuildableGround(island: Island, x: number, y: number): boolean
	return Grid.inIsland(island.diameter, x, y) and not island.obstacles[Grid.key(x, y)]
end

-- Cells covered by a structure whose anchor (top-left) is (x, y).
function Grid.footprintCells(x: number, y: number, footprint: number): { { number } }
	local cells = {}
	for dx = 0, footprint - 1 do
		for dy = 0, footprint - 1 do
			table.insert(cells, { x + dx, y + dy })
		end
	end
	return cells
end

----------------------------------------------------------------------------
-- Cross-channel geometry
----------------------------------------------------------------------------

-- Distance from my cell (sx, sy) to an enemy cell (tx, ty), both in their
-- own island-local coordinates (see header). Used for weapon range checks.
function Grid.attackDistance(config: any, sx: number, sy: number, tx: number, ty: number): number
	local d = config.ISLAND_DIAMETER
	local dxh = (d - sx) + config.CHANNEL_WIDTH + (d - tx)
	local dy = sy - ty
	return math.sqrt(dxh * dxh + dy * dy)
end

-- Maps my cell into the ENEMY island's local frame as a "virtual" position
-- beyond their shore (x > D means out over the channel toward me). Used to
-- trace projectile flight lines across the enemy island.
function Grid.toEnemyFrame(config: any, sx: number, sy: number): (number, number)
	local d = config.ISLAND_DIAMETER
	return d + config.CHANNEL_WIDTH + (d - sx), sy
end

----------------------------------------------------------------------------
-- Lines and areas
----------------------------------------------------------------------------

-- Integer Bresenham line from (x0, y0) to (x1, y1), inclusive.
function Grid.lineCells(x0: number, y0: number, x1: number, y1: number): { { number } }
	local cells = {}
	local dx = math.abs(x1 - x0)
	local dy = math.abs(y1 - y0)
	local sx = x0 < x1 and 1 or -1
	local sy = y0 < y1 and 1 or -1
	local err = dx - dy
	local x, y = x0, y0
	while true do
		table.insert(cells, { x, y })
		if x == x1 and y == y1 then
			break
		end
		local e2 = 2 * err
		if e2 > -dy then
			err -= dy
			x += sx
		end
		if e2 < dx then
			err += dx
			y += sy
		end
	end
	return cells
end

-- All integer cells within radius r of (cx, cy) (Euclidean, center-to-center).
function Grid.cellsInRadius(cx: number, cy: number, r: number): { { number } }
	local cells = {}
	local ir = math.ceil(r)
	for x = math.floor(cx) - ir, math.floor(cx) + ir do
		for y = math.floor(cy) - ir, math.floor(cy) + ir do
			local dx, dy = x - cx, y - cy
			if dx * dx + dy * dy <= r * r then
				table.insert(cells, { x, y })
			end
		end
	end
	return cells
end

function Grid.dist(x0: number, y0: number, x1: number, y1: number): number
	local dx, dy = x1 - x0, y1 - y0
	return math.sqrt(dx * dx + dy * dy)
end

return Grid
