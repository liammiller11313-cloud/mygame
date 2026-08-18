--[[
	OrganizeAssets — paste into the Roblox Studio COMMAND BAR and press Enter.

	Builds ReplicatedStorage.Assets and moves your models into the layout the game
	loads from. You do not need to drag anything by hand.

	It produces:

	    ReplicatedStorage/Assets/
	        Infected/
	            Common/    <- every common variant, Male and Female flattened together
	            Hunter/    <- one folder per special, each holding its rig(s)
	            Jockey/
	            Rusher/
	            Tank/
	            Witch/     <- "WitchZombie" is renamed to "Witch" here
	        Weapons/       <- every gun model (third-person / world)
	        Viewmodels/    <- a copy of each gun for first-person
	    ServerStorage/
	        AnimationSource/   <- "CI Anim", the animation reference rig

	Each infected kind is a FOLDER holding one or more rigs, so the spawner can pick
	a random variant per zombie. That is why a horde of your 13 commons will read as
	a crowd instead of a clone army.

	Safe to run twice — it skips anything already moved. One undo step (Ctrl+Z).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- Source folder name in Workspace -> what we do with it.
local SPECIAL_RENAMES = { WitchZombie = "Witch" }

local recording = ChangeHistoryService:TryBeginRecording("OrganizeAssets")

local function folder(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local new = Instance.new("Folder")
	new.Name = name
	new.Parent = parent
	return new
end

local assets = folder(ReplicatedStorage, "Assets")
local infectedRoot = folder(assets, "Infected")
local weaponsRoot = folder(assets, "Weapons")
local viewmodelsRoot = folder(assets, "Viewmodels")

local moved, skipped, notes = 0, 0, {}

local function note(text)
	table.insert(notes, text)
end

-- A rig is a Model with a Humanoid. Some rigs name their Humanoid something else
-- (your Rusher calls it "Zombie"), so never look it up by name.
local function isRig(instance)
	return instance:IsA("Model") and instance:FindFirstChildOfClass("Humanoid") ~= nil
end

---------------------------------------------------------------- common infected
local commonSource = workspace:FindFirstChild("Common Infected")
if commonSource then
	local commonDest = folder(infectedRoot, "Common")
	-- GetDescendants so the Male/ and Female/ subfolders flatten automatically.
	for _, descendant in commonSource:GetDescendants() do
		if isRig(descendant) then
			if descendant.Name == "CI Anim" then
				local animRoot = folder(ServerStorage, "AnimationSource")
				descendant.Parent = animRoot
				note('moved "CI Anim" -> ServerStorage.AnimationSource (animation reference rig)')
			else
				descendant.Parent = commonDest
				moved += 1
			end
		end
	end
	note(string.format("Common/ now holds %d variant rig(s)", #commonDest:GetChildren()))
else
	note('[!] Workspace."Common Infected" not found')
end

--------------------------------------------------------------- special infected
local specialSource = workspace:FindFirstChild("Special Infected")
if specialSource then
	for _, child in specialSource:GetChildren() do
		if isRig(child) then
			local kind = SPECIAL_RENAMES[child.Name] or child.Name
			local dest = folder(infectedRoot, kind)
			if SPECIAL_RENAMES[child.Name] then
				note(string.format('renamed "%s" -> "%s"', child.Name, kind))
			end
			child.Parent = dest
			moved += 1
		end
	end
else
	note('[!] Workspace."Special Infected" not found')
end

------------------------------------------------------------------------- guns
local gunSource = workspace:FindFirstChild("Gun Models")
if gunSource then
	for _, child in gunSource:GetChildren() do
		if child:IsA("Model") then
			-- Viewmodel copy first, while the original is still in place.
			if not viewmodelsRoot:FindFirstChild(child.Name) then
				local copy = child:Clone()
				copy.Parent = viewmodelsRoot
			end
			child.Parent = weaponsRoot
			moved += 1
		end
	end
	note(string.format("Weapons/ holds %d gun(s), Viewmodels/ mirrored", #weaponsRoot:GetChildren()))
else
	note('[!] Workspace."Gun Models" not found')
end

------------------------------------------------------------------- leftover check
for _, name in { "Common Infected", "Special Infected", "Gun Models" } do
	local leftover = workspace:FindFirstChild(name)
	if leftover then
		local remaining = #leftover:GetDescendants()
		if remaining == 0 then
			leftover:Destroy()
			note(string.format('removed now-empty Workspace."%s"', name))
		else
			note(
				string.format(
					'Workspace."%s" still has %d object(s) left — check them by hand',
					name,
					remaining
				)
			)
		end
	end
end

local warnFolder = workspace:FindFirstChild("READ THE SCRIPT FIRST!!!")
if warnFolder then
	note('[!] Workspace has a folder named "READ THE SCRIPT FIRST!!!" — that is free-model')
	note("    packaging. Open it, read it, then delete it. Left untouched by this script.")
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

print("\n============ ORGANIZE ASSETS ============")
print(string.format("moved %d model(s), skipped %d", moved, skipped))
for _, text in notes do
	print("  " .. text)
end
print("\nResulting layout:")
local function dump(instance, indent)
	for _, child in instance:GetChildren() do
		print(string.rep("  ", indent) .. child.Name .. (child:IsA("Folder") and "/" or ""))
		if child:IsA("Folder") and indent < 3 then
			dump(child, indent + 1)
		end
	end
end
print("ReplicatedStorage.Assets/")
dump(assets, 1)
print("=========================================\n")
