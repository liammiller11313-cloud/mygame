--!nonstrict
--[[
	Support — what every random event module needs and none of them should own.

	Two jobs: finding the objects a map offers an event, and the handful of
	services an event reaches for. Both are here rather than in each module
	because eight copies of "walk the map looking for a folder called Lights" is
	eight chances for one of them to fold a plural differently from the others.

	── THE MAP OFFERS, THE EVENT ASKS ──────────────────────────────────────────
	A map keeps what events need under one folder:

	    <Map>/Events/Lights
	    <Map>/Events/EmergencyLights
	    <Map>/Events/SupplyDrops

	Found by NAME, matched through MapConfig.folderMatches so case, spacing,
	punctuation and a trailing plural are all folded away — the same contract the
	medkits, the ammo crates, the vault props and the barricades already use. A
	map without one of these folders is not broken; the events that need it are
	simply never offered there, which is the whole point of the split.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventConfig = require(Shared.Config.EventConfig)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)

local FOLDERS = EventConfig.MapFolders

local Support = {}

--[[ One warning per problem per server, not one per round. These are authoring
     mistakes: the same folder is wrong every round until somebody fixes it, and
     seventeen copies of the message is how a log stops being read. ]]
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[RandomEvents] " .. message)
end

--[[ A named folder anywhere under `root`. Descendants rather than children
     because a designer's own organisation is theirs and the folder might be
     three deep. ]]
local function findFolder(root: Instance?, wanted: string): Instance?
	if not root then
		return nil
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Folder") or descendant:IsA("Model") then
			if MapConfig.folderMatches(descendant.Name, wanted) then
				return descendant
			end
		end
	end
	return nil
end

--[[ The live map, or nil. Every lookup below starts here, and nil is the honest
     answer during a swap rather than something to wait for. ]]
function Support.mapRoot(): Instance?
	local maps = Registry.find("MapService")
	return if maps then maps:getCurrentRoot() else nil
end

function Support.mapId(): string
	local maps = Registry.find("MapService")
	return if maps then maps:getCurrentId() else ""
end

--[[ The map's Events folder, which everything else hangs off. Looked up fresh
     rather than cached for the reason MapService's own header gives: the live
     map is destroyed on an unload, and a cached instance across rounds is a
     reference to something that no longer exists. ]]
function Support.eventsFolder(): Instance?
	return findFolder(Support.mapRoot(), FOLDERS.Root)
end

--[[ Every light of a kind the map offers, or an empty list. Lights rather than
     parts: a designer points this at fixtures, and what a blackout turns off is
     the Light objects inside them — taking the PARTS away would delete the lamp
     posts along with the light. ]]
function Support.lights(kind: string): { Light }
	local events = Support.eventsFolder()
	local folder = findFolder(events, kind)
	local out: { Light } = {}
	if not folder then
		return out
	end
	local parts = 0
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("Light") then
			table.insert(out, descendant)
		elseif descendant:IsA("BasePart") then
			parts += 1
		end
	end

	--[[
		A folder of bare parts is the silent failure this event has.

		Only a Light can be switched — that is why the parts themselves are not
		collected, and why a designer who fills this folder with glowing NEON
		bricks gets a blackout that announces itself and turns nothing off. There
		is nothing to detect that at runtime except this, so it is said once, by
		name, where somebody can act on it.
	]]
	if #out == 0 and parts > 0 then
		warnOnce(
			"nolights:" .. kind,
			string.format(
				"the map's Events/%s folder has %d part(s) in it and no Light objects, "
					.. "so a blackout there would turn nothing off. Put a PointLight, "
					.. "SpotLight or SurfaceLight in each fixture.",
				kind,
				parts
			)
		)
	end
	return out
end

--[[ Every part a supply drop may land on. Parts rather than attachments so a
     designer can see where it will be from across the map. ]]
function Support.dropPoints(): { BasePart }
	local events = Support.eventsFolder()
	local folder = findFolder(events, FOLDERS.SupplyDrops)
	local out: { BasePart } = {}
	if not folder then
		return out
	end
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(out, descendant)
		end
	end
	return out
end

--[[ The sky. Every weather event drives it and none of them writes to Lighting:
     see AtmosphereService.setWeather, where a grade is a request that eases in
     and out rather than a value that has to be put back. ]]
function Support.setWeather(grade: string?)
	local atmosphere = Registry.find("AtmosphereService")
	if atmosphere and typeof(atmosphere.setWeather) == "function" then
		atmosphere:setWeather(grade)
	end
end

--[[ A sound, played for everybody, at a point or on a part. Silently does
     nothing without an AudioService, because a missing announcement must never
     be the thing that stops an event running. ]]
function Support.play(key: string, where: any)
	local audio = Registry.find("AudioService")
	if audio then
		audio:play("Event", key, where)
	end
end

--[[ The game's own voice, through the one service that owns it. RoundService is
     the sole producer of Subtitle — its header says so — and an event with
     something to say asks rather than firing the remote itself. ]]
function Support.say(speaker: string, text: string, duration: number?)
	local round = Registry.find("RoundService")
	if round and typeof(round.announce) == "function" then
		round:announce(speaker, text, duration)
	end
end

--[[ Roughly where the team is, for anything that has to happen NEAR them rather
     than at a fixed point. Nil when nobody is up, which is a real answer: an
     event that needs a team has no business running without one. ]]
function Support.teamCentre(): Vector3?
	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getSurvivorCharacters) ~= "function" then
		return nil
	end
	local total, count = Vector3.zero, 0
	for _, character in survivors:getSurvivorCharacters() do
		local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			total += root.Position
			count += 1
		end
	end
	return if count > 0 then total / count else nil
end

return Support
