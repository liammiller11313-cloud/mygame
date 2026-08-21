--!nonstrict
--[[
	AddClips — gives infected models their own animation clips.

	Paste into the Roblox Studio COMMAND BAR and press Enter.

	Fill in CLIPS and TARGET below, then run. It reports what it would do and
	changes nothing until you set APPLY = true. Repairs sit inside a
	ChangeHistoryService waypoint, so it is all one Ctrl+Z.

	── WHY YOU WOULD ──────────────────────────────────────────────────────────
	Every infected animates from one of two places, and the game prefers the
	first:

	  1. Clips the MODEL carries. A rig knows its own proportions, so if it
	     brought a walk, that walk wins.
	  2. AnimationConfig — this game's built-in set, complete for R6 and R15.

	Both are correct and neither is a fault. But a folder of thirty-five Commons
	where some carry clips and some do not looks, in play, exactly like the
	built-in set being applied at random. The boot log names which models are on
	which source; this is how you move one from the second list to the first.

	── WHAT IT BUILDS ─────────────────────────────────────────────────────────
	    Model
	      FL_Animations        <- Folder
	        walk               <- Folder, named for the ROLE
	          walk             <- Animation, AnimationId set
	        idle
	          idle

	That is the exact shape PlaceholderFactory harvests and InfectedAnimator
	reads. You can build it by hand; this is the same thing without the clicking.

	── ROLES ──────────────────────────────────────────────────────────────────
	    idle   standing still            walk   moving
	    run    moving fast               attack the swing
	    death  dying                     jump   leaving the ground
	    fall   airborne                  climb  on a ladder

	Nothing is required. A role you leave out falls back to the built-in clip for
	that role alone, so supplying only a walk is a perfectly good thing to do.
	Walk and run may be the same id — the game scales playback to the body's real
	speed, so one gait covers both.

	── OWNERSHIP, WHICH IS THE USUAL REASON A CLIP DOES NOTHING ───────────────
	Roblox only plays an animation owned by the place's creator or by Roblox
	itself. An id uploaded from another account loads, reports itself as playing,
	and moves nothing. If a clip you add here does not play, run
	studio-scripts/CheckAnimations.lua — it fetches each id and says which ones
	are refused.
]]

-- ────────────────────────────────────────────────────────────────────────────
local APPLY = false -- set to true to actually write the clips

--[[
	Where the clips come from. Use ONE of these two.

	COPY_FROM is almost always the answer. Name a model that already animates the
	way you want — one of the ones the boot log did NOT list as falling back — and
	its ids are read off it and written to the targets. You never have to find an
	id, type an id, or know what an id looks like.

	    local COPY_FROM = "Common/14"     -- a model under Assets.Infected
	    local COPY_FROM = "selection"     -- or select it and use the other target

	Leave it as "" to type ids in CLIPS instead, which is what you want when the
	animation is one you made in the Animation Editor and published: its id is on
	its page under Creations, and the number in that page's URL is the id.
]]
local COPY_FROM = ""

--[[ Role -> animation id. Ignored entirely when COPY_FROM is set. Numbers or
     full rbxassetid:// strings both work; delete a line to leave that role on
     the built-in clip. ]]
local CLIPS = {
	idle = 0,
	walk = 0,
	run = 0,
	death = 0,
	jump = 0,
	fall = 0,
}

--[[ Which models to write to. Either:
       "selection"                  — whatever is selected in the Explorer
       "Common"                     — every model in Assets.Infected.Common
       { "Common", "Hunter" }       — those folders
       { "Common/19", "Common/22" } — specific variants, as the boot log names them ]]
local TARGET = "selection"

--[[ Replace clips a model already has? Off by default: a rig that shipped its
     own walk knows its proportions better than a set applied in bulk does. ]]
local OVERWRITE = false
-- ────────────────────────────────────────────────────────────────────────────

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local ANIMATION_FOLDER = "FL_Animations"

local KNOWN_ROLES = {
	idle = true,
	walk = true,
	run = true,
	attack = true,
	death = true,
	jump = true,
	fall = true,
	climb = true,
}

--[[ Accepts a bare number or a full asset string, and returns the string form
     Roblox wants. A bare 0 means "not filled in" rather than "asset zero". ]]
local function assetId(value): string?
	if typeof(value) == "number" then
		return if value > 0 then "rbxassetid://" .. tostring(math.floor(value)) else nil
	end
	if typeof(value) == "string" and value ~= "" then
		local digits = string.match(value, "(%d+)")
		return if digits and tonumber(digits) > 0 then "rbxassetid://" .. digits else nil
	end
	return nil
end

local function infectedFolders(): { Instance }
	local found = {}
	for _, root in { ReplicatedStorage, ServerStorage } do
		local assets = root:FindFirstChild("Assets")
		local infected = assets and assets:FindFirstChild("Infected")
		if infected then
			table.insert(found, infected)
		end
	end
	return found
end

local function modelsUnder(entry: Instance): { Model }
	if entry:IsA("Model") then
		return { entry }
	end
	local models = {}
	for _, child in entry:GetChildren() do
		if child:IsA("Model") then
			table.insert(models, child)
		end
	end
	return models
end

local function resolveTargets(): ({ Model }, string)
	if TARGET == "selection" then
		local models = {}
		for _, item in Selection:Get() do
			if item:IsA("Model") then
				table.insert(models, item)
			end
		end
		return models, "the Explorer selection"
	end

	local wanted = if typeof(TARGET) == "table" then TARGET else { TARGET }
	local models = {}
	for _, spec in wanted do
		local kind, variant = string.match(spec, "^(.-)/(.+)$")
		kind = kind or spec

		local matched = false
		for _, infected in infectedFolders() do
			local folder = infected:FindFirstChild(kind)
			if not folder then
				continue
			end
			for _, model in modelsUnder(folder) do
				if not variant or model.Name == variant then
					table.insert(models, model)
					matched = true
				end
			end
		end
		if not matched then
			warn(string.format("[AddClips] found nothing for %q", spec))
		end
	end
	return models, "Assets.Infected"
end

--[[
	Reads every clip off one model, as role -> id.

	Looks in FL_Animations first — that is where a prepared rig keeps them — and
	then anywhere else in the model, which is where a rig that still has its
	original Animate script keeps them. Both are just "an Animation whose parent
	is named for the role", which is the same rule the game's own harvester uses.
]]
local function readClipsFrom(model: Model): ({ [string]: string }, number)
	local found: { [string]: string } = {}
	local count = 0

	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("Animation") or descendant.AnimationId == "" then
			continue
		end
		local parent = descendant.Parent
		local role = if parent and parent ~= model then string.lower(parent.Name) else "idle"
		--[[ First one wins per role. A model with two idles has them for variety,
		     and picking one is what the game does per body anyway. ]]
		if KNOWN_ROLES[role] and not found[role] then
			found[role] = descendant.AnimationId
			count += 1
		end
	end

	return found, count
end

--[[ Writes one role into the model's clip folder. Returns "added", "kept" for a
     role that was already there with OVERWRITE off, or nil if nothing changed. ]]
local function writeClip(model: Model, role: string, id: string): string?
	local store = model:FindFirstChild(ANIMATION_FOLDER)
	if not store then
		if not APPLY then
			return "added"
		end
		store = Instance.new("Folder")
		store.Name = ANIMATION_FOLDER
		store.Parent = model
	end

	local bucket = store:FindFirstChild(role)
	local existing = bucket and bucket:FindFirstChildOfClass("Animation")
	if existing and not OVERWRITE then
		return "kept"
	end

	if not APPLY then
		return "added"
	end

	if not bucket then
		bucket = Instance.new("Folder")
		bucket.Name = role
		bucket.Parent = store
	end
	if existing then
		existing:Destroy()
	end

	local animation = Instance.new("Animation")
	animation.Name = role
	animation.AnimationId = id
	animation.Parent = bucket
	return "added"
end

-- ────────────────────────────────────────────────────────────────────────────

local roles = {}
local sourceLabel = "the CLIPS table"

if COPY_FROM ~= "" then
	--[[ resolveTargets already knows how to turn "Common/14" or "selection" into
	     models, so the source is found the same way the targets are. ]]
	local saved = TARGET
	TARGET = COPY_FROM
	local sources = resolveTargets()
	TARGET = saved

	if #sources == 0 then
		warn(string.format("[AddClips] COPY_FROM found no model for %q", tostring(COPY_FROM)))
	else
		local source = sources[1]
		local found, count = readClipsFrom(source)
		roles = found
		sourceLabel = string.format("%s (%d clip(s))", source.Name, count)
		if count == 0 then
			warn(
				string.format(
					"[AddClips] %q carries no animation ids of its own — it is one of the "
						.. "models animating from the built-in set, so there is nothing to "
						.. "copy FROM. Pick one the boot log did not list.",
					source.Name
				)
			)
		end
	end
else
	for role, value in CLIPS do
		if not KNOWN_ROLES[role] then
			warn(string.format("[AddClips] %q is not a role this game plays — ignored", role))
			continue
		end
		local id = assetId(value)
		if id then
			roles[role] = id
		end
	end
end

local ordered = {}
for role in roles do
	table.insert(ordered, role)
end
table.sort(ordered)

print(
	"── AddClips ──────────────────────────────────────────────────────────"
)
if #ordered == 0 then
	print("No clips to write.")
	print("  Either set COPY_FROM to a model that already animates the way you want,")
	print("  or put animation ids in the CLIPS table. Both are at the top of this script.")
	return
end

local targets, where = resolveTargets()
print(
	if APPLY
		then "APPLY MODE — writing clips. Ctrl+Z undoes all of it."
		else "REPORT ONLY — nothing is being changed."
)
print(string.format("  clips from %s", sourceLabel))
print(string.format("  %d role(s): %s", #ordered, table.concat(ordered, ", ")))
print(string.format("  %d model(s) from %s", #targets, where))

if #targets == 0 then
	print("Nothing to write to. Select some models, or set TARGET to a kind name.")
	return
end

local recording = if APPLY then ChangeHistoryService:TryBeginRecording("AddClips") else nil

local added, kept = 0, 0
for _, model in targets do
	local wrote = {}
	for _, role in ordered do
		local result = writeClip(model, role, roles[role])
		if result == "added" then
			added += 1
			table.insert(wrote, role)
		elseif result == "kept" then
			kept += 1
		end
	end
	print(
		string.format(
			"  %-28s %s",
			model.Name,
			if #wrote > 0 then table.concat(wrote, ", ") else "nothing to do — already has these"
		)
	)
end

print(
	"──────────────────────────────────────────────────────────────────────"
)
print(
	string.format(
		"%s %d clip(s)%s.",
		if APPLY then "Wrote" else "Would write",
		added,
		if kept > 0
			then string.format(", left %d already on the model alone (set OVERWRITE = true to replace)", kept)
			else ""
	)
)
if APPLY then
	print("Play-test, then check the boot log: these models should no longer be listed")
	print("as animating from the built-in clips.")
else
	print("Set APPLY = true at the top and run it again.")
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
