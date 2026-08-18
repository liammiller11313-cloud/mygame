--[[
	RemoveStuds — paste this into the Roblox Studio COMMAND BAR and press Enter.

	Finds the model named "Clinton" and smooths every surface on every part inside
	it, so nothing renders with the old stud / inlet / weld bumps.

	It changes the six SurfaceType properties only. Geometry, position, size,
	material, colour and anything else are left exactly as they are.

	Undo works: the whole pass is one undo step (Ctrl+Z).
]]

local MODEL_NAME = "Clinton"

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

-- Prefer whatever you have selected, so this also works on a copy or on a model
-- sitting in ReplicatedStorage rather than Workspace.
local function findTarget()
	for _, selected in Selection:Get() do
		if selected:IsA("Model") and selected.Name == MODEL_NAME then
			return selected, "selection"
		end
	end
	for _, selected in Selection:Get() do
		local found = selected:FindFirstChild(MODEL_NAME, true)
		if found and found:IsA("Model") then
			return found, "inside selection"
		end
	end
	for _, container in { workspace, game:GetService("ReplicatedStorage"), game:GetService("ServerStorage") } do
		local found = container:FindFirstChild(MODEL_NAME, true)
		if found and found:IsA("Model") then
			return found, container.Name
		end
	end
	return nil, nil
end

local target, whereFound = findTarget()

if not target then
	warn(string.format('[RemoveStuds] No Model named "%s" found. Select it and run this again.', MODEL_NAME))
	return
end

local recording = ChangeHistoryService:TryBeginRecording("RemoveStuds")

local SURFACES =
	{ "TopSurface", "BottomSurface", "LeftSurface", "RightSurface", "FrontSurface", "BackSurface" }
local SMOOTH = Enum.SurfaceType.Smooth

local partsScanned, partsChanged, surfacesChanged = 0, 0, 0

for _, descendant in target:GetDescendants() do
	if descendant:IsA("BasePart") then
		partsScanned += 1
		local touchedThisPart = false
		for _, surfaceName in SURFACES do
			if (descendant :: any)[surfaceName] ~= SMOOTH then
				(descendant :: any)[surfaceName] = SMOOTH
				surfacesChanged += 1
				touchedThisPart = true
			end
		end
		if touchedThisPart then
			partsChanged += 1
		end
	end
end

-- The model itself may be a part-less container, but check it anyway.
if target:IsA("BasePart") then
	partsScanned += 1
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

print(
	string.format(
		'[RemoveStuds] "%s" (found in %s): scanned %d part%s, smoothed %d surface%s across %d part%s.%s',
		MODEL_NAME,
		whereFound,
		partsScanned,
		partsScanned == 1 and "" or "s",
		surfacesChanged,
		surfacesChanged == 1 and "" or "s",
		partsChanged,
		partsChanged == 1 and "" or "s",
		surfacesChanged == 0 and " Nothing was studded already." or " Ctrl+Z to undo."
	)
)
