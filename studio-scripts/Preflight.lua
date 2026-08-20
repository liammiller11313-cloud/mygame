--!nonstrict
--[[
	Preflight — is this place actually ready to press Play?

	Paste into the Roblox Studio COMMAND BAR and press Enter. It CHANGES
	NOTHING; it only reads and prints.

	── WHAT IT IS FOR ──────────────────────────────────────────────────────────
	Everything this game needs from the PLACE rather than from the code: assets
	in the right folders, the map tagged, the rigs rigged, the services enabled.
	Every one of these has already been the cause of a real bug in this project
	at least once, and each time the symptom was something that looked like a
	code failure:

	  * untagged flow nodes  -> the Director spawns the horde behind the team,
	                            and logs a warning nobody reads
	  * a rig with no Motor6D -> the body slides around rigid and no amount of
	                            animation configuration changes it
	  * API services off      -> every animation silently fails to load

	It does NOT check animation asset ids. That needs the network and its own
	rig tests, and it lives in CheckAnimations.lua next to this file. Run that
	one too.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local problems, warnings, notes = {}, {}, {}

local function fail(line: string)
	table.insert(problems, line)
end
local function warnAbout(line: string)
	table.insert(warnings, line)
end
local function note(line: string)
	table.insert(notes, line)
end

local function child(parent: Instance?, name: string): Instance?
	return if parent then parent:FindFirstChild(name) else nil
end

print("── Fading Light preflight ──")
print("")

-- ── 1. did Rojo sync ────────────────────────────────────────────────────────
-- Everything below assumes the code is in the place. If it is not, every other
-- check would report a content problem that is really a sync problem.
local shared = child(ReplicatedStorage, "Shared")
local server = child(ServerScriptService, "Server")
local scripts = child(StarterPlayer, "StarterPlayerScripts")
local client = child(scripts, "Client")

if not shared or not server or not client then
	print("  CODE           NOT SYNCED")
	print("")
	print("Rojo has not put the code into this place. Start the server and connect:")
	print("    ./scripts/dev.sh          (then Rojo > Connect in Studio)")
	print("Nothing else here is worth reading until that is done.")
	return
end
print("  code           synced")

--[[ Read straight from the synced config so this script cannot drift from the
     game. A hand-copied folder name here would be a second source of truth and
     would eventually disagree with the first. ]]
local okConfig, MapConfig = pcall(require, shared.Config.MapConfig)
if not okConfig then
	fail("could not read Shared.Config.MapConfig: " .. tostring(MapConfig))
	MapConfig = nil
end

-- ── 2. API services, which animations need ─────────────────────────────────
--[[ There is no property that reports this directly, so it is probed: a
     DataStore request throws a specific error when the setting is off. Wrapped
     because in a published place with it ON this is a real network call. ]]
local okApi = pcall(function()
	game:GetService("DataStoreService"):GetDataStore("FL_Preflight"):GetAsync("probe")
end)
if okApi then
	print("  API services   enabled")
else
	warnAbout(
		"Studio Access to API Services looks OFF. Animations will not load and profiles "
			.. "will not save. Game Settings > Security > Enable Studio Access to API Services."
	)
end

-- ── 3. assets ───────────────────────────────────────────────────────────────
local assets = child(ReplicatedStorage, "Assets")
if not assets then
	warnAbout(
		"No ReplicatedStorage.Assets folder. The game builds greybox stand-ins for every "
			.. "weapon and every infected, so it RUNS — it just looks like boxes. "
			.. "studio-scripts/OrganizeAssets.lua sorts supplied models into place."
	)
else
	for _, name in { "Weapons", "Viewmodels", "Infected" } do
		local folder = child(assets, name)
		local count = if folder then #folder:GetChildren() else 0
		if count == 0 then
			note(string.format("Assets.%s is empty — those fall back to greybox models", name))
		else
			print(string.format("  Assets.%-9s %d model(s)", name, count))
		end
	end
end

-- ── 4. the map's own folders ────────────────────────────────────────────────
--[[ Matched the way MedkitService and the crate lookup do it, and not the
     obvious way: RECURSIVELY, because the map loads into Workspace.CurrentMap
     and the folder lives inside it, and case- and space-insensitively, because
     both services deliberately accept "Medkits", "medkits" and "Med Kits". A
     FindFirstChild here would have reported a missing folder for a place that
     has one, which is worse than not checking at all. ]]
local function findMapFolder(name: string): Instance?
	local wanted = string.lower(string.gsub(name, "%s+", ""))
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("Folder") or descendant:IsA("Model") then
			if string.lower(string.gsub(descendant.Name, "%s+", "")) == wanted then
				return descendant
			end
		end
	end
	return nil
end

if MapConfig then
	for label, spec in { medkits = MapConfig.Medkits, ammo = MapConfig.AmmoCrates } :: { [string]: any } do
		local name = spec and spec.FolderName
		if typeof(name) == "string" then
			local folder = findMapFolder(name)
			local count = if folder then #folder:GetChildren() else 0
			if count == 0 then
				warnAbout(
					string.format(
						'no folder called "%s" anywhere in Workspace with anything in it — there will be no %s '
							.. "in the round, and picking one up is most of why a side room is worth opening",
						name,
						label
					)
				)
			else
				print(string.format("  %-14s %d in %s", label, count, folder:GetFullName()))
			end
		end
	end
end

-- ── 5. map tags ─────────────────────────────────────────────────────────────
--[[ These are what the level system runs on. Untagged is not fatal — every one
     has a fallback — but the fallbacks are all "spawn by raw distance", which
     is the difference between a designed level and a shooting gallery. ]]
local TAGS: { { tag: string, need: number, why: string } } = {
	{
		tag = "FL_SurvivorSpawn",
		need = 1,
		why = "the team spawns wherever the fallback picks instead of where a round should start",
	},
	{
		tag = "FL_SpawnNode",
		need = 6,
		why = "the Director samples rings around the players instead of using places you chose",
	},
	{
		tag = "FL_FlowNode",
		need = 6,
		why = "nothing knows what is AHEAD of the team, so the horde arrives from behind as often as in front",
	},
	{ tag = "FL_ItemSpawn", need = 1, why = "pickups scatter instead of stocking the route" },
	{ tag = "FL_SafeRoom", need = 1, why = "no start or end room" },
}

print("")
for _, entry in TAGS do
	local tagged = CollectionService:GetTagged(entry.tag)
	local live = 0
	for _, instance in tagged do
		if instance:IsDescendantOf(Workspace) then
			live += 1
		end
	end
	if live < entry.need then
		warnAbout(
			string.format("%s: %d tagged, wants at least %d — %s", entry.tag, live, entry.need, entry.why)
		)
	else
		print(string.format("  %-18s %d", entry.tag, live))
	end
end

-- ── 6. rigs ─────────────────────────────────────────────────────────────────
--[[ The check that has caught the most. A supplied model with no Motor6D is
     animated by nothing — not by a clip, and not by the procedural fallback,
     which stands down for any body with tracks playing. It slides around rigid
     and looks exactly like an animation bug. ]]
local infectedAssets = child(assets, "Infected")
if infectedAssets then
	print("")
	for _, kind in infectedAssets:GetChildren() do
		local model = if kind:IsA("Model") then kind else kind:FindFirstChildOfClass("Model")
		if not model then
			continue
		end
		local motors, parts = 0, 0
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("Motor6D") then
				motors += 1
			elseif descendant:IsA("BasePart") then
				parts += 1
			end
		end
		local rig = if model:FindFirstChild("UpperTorso", true) then "R15" else "R6"
		if motors == 0 and parts > 1 then
			fail(
				string.format(
					"the %s rig has %d parts and NO Motor6D joints — nothing can animate it and "
						.. "nothing can dismember it. Open it in Studio and check the limbs are "
						.. "JOINED to the torso with Motor6D rather than welded.",
					kind.Name,
					parts
				)
			)
		else
			print(string.format("  rig %-12s %s, %d joints, %d parts", kind.Name, rig, motors, parts))
		end
	end
end

-- ── 7. lighting the game will overwrite ─────────────────────────────────────
--[[ Not a problem, a surprise: AtmosphereService drives Lighting from wave one
     and ends the round in the dark. An editor set up bright reads as the game
     ignoring it. ]]
if Lighting.ClockTime < 16 then
	note(
		string.format(
			"Lighting.ClockTime is %.1f in the editor; the game sets it from AtmosphereService "
				.. "at round start and ramps toward dark. ResetEditorLighting.lua puts the "
				.. "editor back if it looks wrong between runs.",
			Lighting.ClockTime
		)
	)
end

-- ── report ──────────────────────────────────────────────────────────────────
print("")
if #problems > 0 then
	warn(string.format("[Preflight] %d PROBLEM(S) — these break something:", #problems))
	for _, line in problems do
		warn("    " .. line)
	end
end
if #warnings > 0 then
	warn(string.format("[Preflight] %d thing(s) the game will work around:", #warnings))
	for _, line in warnings do
		warn("    " .. line)
	end
end
if #notes > 0 then
	print(string.format("[Preflight] %d note(s):", #notes))
	for _, line in notes do
		print("    " .. line)
	end
end

if #problems == 0 and #warnings == 0 then
	print("[Preflight] nothing to fix. Run CheckAnimations.lua as well — animation ids")
	print("            need the network and are not covered here.")
else
	print("")
	print("[Preflight] a warning is playable; a PROBLEM is not. Fix problems first.")
	print("            Then run CheckAnimations.lua for the animation half.")
end
