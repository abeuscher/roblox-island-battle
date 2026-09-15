--!strict
-- lib.luau — tiny test toolkit shared by the Lune specs.

local Lib = {}

function Lib.eq(actual: any, expected: any, msg: string?)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
	end
end

function Lib.ok(value: any, msg: string?)
	if not value then
		error((msg or "expected truthy") .. " (got " .. tostring(value) .. ")", 2)
	end
end

function Lib.near(actual: number, expected: number, tol: number, msg: string?)
	if math.abs(actual - expected) > tol then
		error(string.format("%s: expected ~%s (±%s), got %s", msg or "near", expected, tol, actual), 2)
	end
end

-- Deterministic deep serialization for purity comparisons.
function Lib.serialize(value: any): string
	local t = type(value)
	if t ~= "table" then
		return tostring(value)
	end
	local keys = {}
	for k in value do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, tostring(k) .. "=" .. Lib.serialize(value[k]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

function Lib.findEvent(events: { any }, eventType: string): any?
	for _, e in events do
		if e.type == eventType then
			return e
		end
	end
	return nil
end

function Lib.countEvents(events: { any }, eventType: string): number
	local n = 0
	for _, e in events do
		if e.type == eventType then
			n += 1
		end
	end
	return n
end

return Lib
