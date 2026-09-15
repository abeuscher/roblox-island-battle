--!strict
-- syntax_spec.luau — compile every Luau file in the project.
--
-- src/server and src/client can never be *run* outside Roblox, so nothing
-- else in this suite would catch a typo in them until someone opened
-- Studio. Compiling them here closes that gap: `lune run test` fails on a
-- syntax error anywhere in the project, not just in the parts that are
-- headlessly runnable.

local T = require("./lib")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function collect(dir: string, out: { string })
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			collect(path, out)
		elseif string.match(name, "%.luau$") then
			table.insert(out, path)
		end
	end
	return out
end

return {
	["every Luau file in the project compiles"] = function()
		local files = {}
		for _, dir in { "src", "sim", "tests", ".lune" } do
			if fs.isDir(dir) then
				collect(dir, files)
			end
		end
		T.ok(#files > 20, "found the project's files (got " .. #files .. ")")
		for _, path in files do
			local ok, err = pcall(function()
				luau.load(fs.readFile(path), { debugName = path })
			end)
			T.ok(ok, path .. " failed to compile: " .. tostring(err))
		end
	end,
}
