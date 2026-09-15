--!strict
-- `lune run test` — runs every tests/*_spec.luau against src/shared.
-- No Roblox, no Studio: this is the only verification loop an agent has.

local fs = require("@lune/fs")
local process = require("@lune/process")

local specs = {}
for _, name in fs.readDir("tests") do
	if string.match(name, "_spec%.luau$") then
		table.insert(specs, name)
	end
end
table.sort(specs)

local passed, failed = 0, 0
local failures: { string } = {}

for _, name in specs do
	local moduleName = string.gsub(name, "%.luau$", "")
	local suite = require("../tests/" .. moduleName)
	local caseNames = {}
	for caseName in suite do
		table.insert(caseNames, caseName)
	end
	table.sort(caseNames)

	print(string.format("\n%s", moduleName))
	for _, caseName in caseNames do
		local ok, err = pcall(suite[caseName])
		if ok then
			passed += 1
			print(string.format("  PASS  %s", caseName))
		else
			failed += 1
			print(string.format("  FAIL  %s", caseName))
			print(string.format("        %s", tostring(err)))
			table.insert(failures, moduleName .. " :: " .. caseName)
		end
	end
end

print(string.format("\n%d passed, %d failed, %d total", passed, failed, passed + failed))
if failed > 0 then
	for _, f in failures do
		print("  failed: " .. f)
	end
	process.exit(1)
end
