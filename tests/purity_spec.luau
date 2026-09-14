--!strict
-- purity_spec.luau — the two hard guarantees of the rules core:
-- (1) it touches zero Roblox APIs, (2) Rules.step never mutates its input.

local T = require("./lib")
local Rules = require("../src/shared/rules")
local Config = require("../src/shared/config")
local Helpers = require("./helpers")

local fs = require("@lune/fs")

-- Roblox globals/APIs that must never appear in src/shared. Patterns are
-- matched against a sentinel-padded copy of the source with comments
-- stripped; `%f[%w]` guards keep `Economy.tick(...)` from matching the
-- Roblox global `tick(`.
local FORBIDDEN = {
	"Instance%s*%.%s*new",
	"%f[%w]game%s*[%.:]",
	"%f[%w]workspace%s*[%.:]",
	"%f[%w]task%s*%.",
	"%f[%w]Vector3%f[%W]",
	"%f[%w]CFrame%f[%W]",
	"%f[%w]Color3%f[%W]",
	"%f[%w]RunService%f[%W]",
	"%f[%w]ReplicatedStorage%f[%W]",
	"%f[%w]BillboardGui%f[%W]",
	"%f[%w]RemoteEvent%f[%W]",
	"[^%.%w_]wait%s*%(",
	"[^%.%w_]tick%s*%(",
	"%f[%w]os%s*%.%s*clock",
	"%f[%w]DateTime%f[%W]",
}

return {
	["src/shared contains no Roblox API calls"] = function()
		for _, name in fs.readDir("src/shared") do
			local source = fs.readFile("src/shared/" .. name)
			-- Strip comments so the spec references in them don't trip it.
			local code = " " .. string.gsub(source, "%-%-[^\n]*", "") .. " "
			for _, pattern in FORBIDDEN do
				local hit = string.find(code, pattern)
				T.ok(hit == nil, "src/shared/" .. name .. " references a Roblox API: " .. pattern)
			end
		end
	end,

	["the only Roblox global src/shared names is the import shim's `script`"] = function()
		-- The dual-target shim (see any shared module header) is the single
		-- sanctioned mention of a Roblox global, and it only ever tests for
		-- nil — it never calls into an API.
		for _, name in fs.readDir("src/shared") do
			local source = fs.readFile("src/shared/" .. name)
			local code = string.gsub(source, "%-%-[^\n]*", "")
			for _ in string.gmatch(code, "%f[%w]script%f[%W]") do
				-- every mention must be inside the shim's two known lines
			end
			local mentions = 0
			for _ in string.gmatch(code, "%f[%w]script%f[%W]") do
				mentions += 1
			end
			local shimLines = 0
			for line in string.gmatch(code, "[^\n]+") do
				if string.find(line, "script ~= nil") or string.find(line, "%(script :: any%)%.Parent") then
					shimLines += 1
				end
			end
			T.eq(mentions, shimLines, "src/shared/" .. name .. " mentions `script` outside the import shim")
		end
	end,

	["src/shared only requires its own siblings"] = function()
		for _, name in fs.readDir("src/shared") do
			local source = fs.readFile("src/shared/" .. name)
			for path in string.gmatch(source, 'require%("([^"]+)"%)') do
				T.ok(
					not string.find(path, "%.%."),
					"src/shared/" .. name .. " reaches outside shared: " .. path
				)
			end
		end
	end,

	["Rules.step does not mutate its input state"] = function()
		local state = Helpers.startCombat(Config, 42)
		state.players[1].coin = 500
		local before = T.serialize(state)
		local commands = {
			{ player = 1, type = "place", kind = "catapult", x = 33, y = 18 },
			{ player = 2, type = "place", kind = "grove", x = 14, y = 14 },
		}
		local nextState = Rules.step(state, commands, 1.0)
		T.eq(T.serialize(state), before, "input state untouched")
		T.ok(T.serialize(nextState) ~= before, "returned state did change")
		T.eq(nextState.time, state.time + 1.0)
	end,

	["Rules.step is deterministic for identical inputs"] = function()
		local a = Helpers.startCombat(Config, 4242)
		local b = Helpers.startCombat(Config, 4242)
		T.eq(T.serialize(a), T.serialize(b), "identical seeds produce identical matches")
		for i = 1, 40 do
			local cmds = {}
			if i == 5 then
				cmds = { { player = 1, type = "place", kind = "perch", x = 30, y = 18 } }
			end
			a = (Rules.step(a, cmds, 0.25))
			b = (Rules.step(b, cmds, 0.25))
		end
		T.eq(T.serialize(a), T.serialize(b), "same command stream, same end state")
	end,

	["stepMut and step agree on outcomes"] = function()
		local pure = Helpers.startCombat(Config, 77)
		local mut = Helpers.startCombat(Config, 77)
		for i = 1, 30 do
			local cmds = {}
			if i == 3 then
				cmds = { { player = 2, type = "place", kind = "nest", x = 18, y = 18 } }
			end
			pure = (Rules.step(pure, cmds, 0.5))
			Rules.stepMut(mut, cmds, 0.5)
		end
		T.eq(T.serialize(pure), T.serialize(mut), "pure and mutating steps agree")
	end,
}
