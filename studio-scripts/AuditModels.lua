--[[
	AuditModels — paste into the Roblox Studio COMMAND BAR and press Enter.

	Reports exactly what is inside your Common Infected / Special Infected / Gun
	Models folders: rig type (R6 vs R15), whether the joints needed for
	dismemberment exist, and — importantly — every Script, LocalScript and
	ModuleScript it finds.

	That last part matters. Free models routinely ship with scripts named after
	random usernames, and on Roblox that is the classic shape of a backdoor: a
	script that quietly grants someone else run access to your game. The Hunter
	model has a stack of objects with names like that. This tells you what class
	each one actually is so you can decide what to keep. It CHANGES NOTHING — it
	only prints.
]]

local FOLDERS = { "Common Infected", "Special Infected", "Gun Models" }
local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local R15_MARKERS = { "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperLeg" }
local R6_MARKERS = { "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local function has(model, names)
	for _, name in names do
		if not model:FindFirstChild(name) then
			return false
		end
	end
	return true
end

local function rigTypeOf(model)
	if has(model, R15_MARKERS) then
		return "R15"
	elseif has(model, R6_MARKERS) then
		return "R6"
	end
	return "UNKNOWN"
end

local function countClass(model, className)
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA(className) then
			n += 1
		end
	end
	return n
end

print("\n================ FADING LIGHT — MODEL AUDIT ================")

local suspicious = {}
local totalScripts = 0

for _, folderName in FOLDERS do
	local folder = workspace:FindFirstChild(folderName)
	if not folder then
		print(string.format("\n[!] Workspace.%s not found — skipping", folderName))
		continue
	end

	print(string.format("\n--- %s ---", folderName))

	for _, child in folder:GetDescendants() do
		if not child:IsA("Model") then
			continue
		end
		-- Only report models that are actually rigs or gun models, not sub-parts.
		local humanoid = child:FindFirstChildOfClass("Humanoid")
		local isGun = folderName == "Gun Models" and child.Parent == folder
		if not humanoid and not isGun then
			continue
		end

		local scripts = countClass(child, "LuaSourceContainer")
		totalScripts += scripts

		if humanoid then
			local motors = countClass(child, "Motor6D")
			local welds = countClass(child, "Weld") + countClass(child, "ManualWeld")
			local anims = countClass(child, "Animation")
			local sounds = countClass(child, "Sound")
			print(
				string.format(
					"  %-28s %s  parts:%-3d motor6d:%-3d weld:%-3d anim:%-2d sound:%-2d scripts:%d%s%s",
					child:GetFullName():gsub("^Workspace%." .. folderName .. "%.", ""),
					rigTypeOf(child),
					countClass(child, "BasePart"),
					motors,
					welds,
					anims,
					sounds,
					scripts,
					motors == 0 and "   << NO MOTOR6D: cannot be dismembered" or "",
					humanoid.Name ~= "Humanoid" and ("   << Humanoid is named '" .. humanoid.Name .. "'")
						or ""
				)
			)
		else
			print(
				string.format(
					"  %-28s parts:%-3d scripts:%-2d  handle:%s  muzzle-attachment:%s",
					child.Name,
					countClass(child, "BasePart"),
					scripts,
					child:FindFirstChild("Handle") and "yes" or "NO",
					countClass(child, "Attachment") > 0 and "some" or "NO"
				)
			)
		end

		-- Collect every script for the security pass below.
		for _, d in child:GetDescendants() do
			if SCRIPT_CLASSES[d.ClassName] then
				table.insert(suspicious, d)
			end
		end
	end
end

print("\n--- SCRIPTS FOUND (review every one of these) ---")
if #suspicious == 0 then
	print("  none — clean")
else
	for _, s in suspicious do
		local source = ""
		local ok, text = pcall(function()
			return s.Source
		end)
		if ok and text then
			local flagged = {}
			for _, pattern in
				{ "require%s*%(%s*%d", "HttpGet", "GetObjects", "loadstring", "getfenv", "Backdoor" }
			do
				if text:match(pattern) then
					table.insert(flagged, pattern)
				end
			end
			source = #flagged > 0 and ("   <<< FLAGGED: " .. table.concat(flagged, ", ")) or ""
		end
		print(string.format("  [%s] %s%s", s.ClassName, s:GetFullName(), source))
	end
end

print(string.format("\nTotal scripts across all models: %d", totalScripts))
print("Anything FLAGGED above, or any script you did not write, should be deleted.")
print("===========================================================\n")
