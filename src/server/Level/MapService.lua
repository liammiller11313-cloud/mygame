--!nonstrict
--[[
	MapService — loading, unloading and swapping maps.

	The whole design goal here is that the swap between rounds is FAST, because
	it happens while eight people are staring at a scoreboard waiting for it.
	Three things make it fast:

	  1. MAPS LIVE IN ServerStorage, ASSEMBLED. Nothing is built at swap time; the
	     replacement already exists as a finished model. Loading is one reparent.

	  2. THE LIVE MAP IS A CLONE, NEVER THE ORIGINAL. Unloading destroys the
	     clone rather than trying to put a mutated map back — a map that has been
	     shot at, set on fire and had its crates emptied is not something you want
	     to reuse, and repairing it would cost more than rebuilding it.

	  3. THE CLONE IS PREPARED IN ADVANCE. `prewarm` clones the next map into
	     ServerStorage while the previous round is still running, so the swap
	     itself is a reparent of an already-cloned model. That turns a visible
	     hitch into an imperceptible one.

	Everything that reads the map — LevelService's flow spline, the Director's
	spawn nodes, the ammo crates — rebuilds from tags after `mapChanged` fires.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local MapService = {}

MapService.mapChanged = Signal.new() -- (mapId: string, root: Model)

local serviceTrove = Trove.new()
local currentId = ""
local currentRoot: Model? = nil
local prewarmed: { [string]: Model } = {}

local PREWARM_FOLDER = "FL_Prewarm"

--[[
	A map's own sky and its own music.

	Both are things a level author naturally drops INSIDE their map model, and
	both do absolutely nothing there:

	  * Roblox only renders a Sky parented to Lighting. One sitting in a Model in
	    Workspace is inert — no error, no warning, no sky. It is the single most
	    confusing thing about authoring a map, because everything looks right in
	    the explorer.
	  * A Sound plays, but a Sound in Workspace is not a descendant of
	    SoundService, and the master volume slider is a SoundGroup that adopts
	    SoundService's descendants. Music left in the map would ignore the volume
	    setting entirely — including when it is set to zero.

	So both are lifted out on load and put where the engine expects them, and
	both are put back exactly as they were on unload.

	── HOW ONE IS RECOGNISED ───────────────────────────────────────────────────
	A DIRECT child of the map model, and nothing deeper. That is not a shortcut,
	it is the distinction itself: a Sound attached to a part is positional
	ambience that belongs to that part and must stay there, and a Sound hanging
	off the model root is 2D by definition — it is already global, so it can only
	have been authored as the map's own track. Same for a Sky, which has nowhere
	else meaningful to be.

	No naming convention, deliberately. "CrossroadsSky" and "Crossroads Music"
	are perfectly good names and so is anything else somebody picks; a rule that
	depended on the words would fail silently the first time it did not.
]]
local AMBIENCE_STASH = "FL_DisplacedSky"

--[[ What we put into Lighting and SoundService, so unload can take it back out
     again. The map clone is destroyed wholesale, and these two are no longer
     inside it by then — without holding them they would simply leak. ]]
local installedSky: Sky? = nil
local installedMusic: Sound? = nil

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[MapService] " .. message)
end

local function storage(): Folder
	local existing = ServerStorage:FindFirstChild(MapConfig.StorageFolder)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = MapConfig.StorageFolder
	created.Parent = ServerStorage
	return created
end

local function prewarmFolder(): Folder
	local existing = ServerStorage:FindFirstChild(PREWARM_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = PREWARM_FOLDER
	created.Parent = ServerStorage
	return created
end

local function liveFolder(): Folder
	local existing = Workspace:FindFirstChild(MapConfig.LiveFolder)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = MapConfig.LiveFolder
	created.Parent = Workspace
	return created
end

--[[
	Everything in a supplied map that must not come into the world with it.

	The same argument PlaceholderFactory makes about rigs, for the same reason: a
	map downloaded from the Toolbox is somebody else's code, and a Script inside
	it runs on OUR server with full permissions the moment it is parented. It does
	not have to be malicious to be a problem — the Zombieville build shipped with
	a `GM.Script` whose first line waits forever on a child that does not exist,
	which is a thread hung for the life of the server.

	Deliberately NARROWER than the rig rule. That one also strips Sounds, because
	forty-six rigs each carrying a looping moan blows the voice budget on its own;
	a map's sounds are authored ambience and are left alone. What goes is
	behaviour that either endangers the server or competes with a system this game
	already owns:

	  * every kind of script — the security case, and the hang above
	  * ProximityPrompt and ClickDetector — the game has its own interact system,
	    and a second one on the same geometry is a prompt the player can press
	    that nothing is listening to
]]
local MAP_STRIPPED = { "LuaSourceContainer", "ProximityPrompt", "ClickDetector" }

local function sanitise(root: Instance, mapId: string)
	local removed = 0
	local names: { string } = {}

	for _, descendant in root:GetDescendants() do
		for _, className in MAP_STRIPPED do
			if descendant:IsA(className) then
				if #names < 6 then
					--[[ ClassName as well as path. The first run reported
					     "PackageLink, TextureConfiguration", which reads as though
					     it removed something it should not have, and the line gave
					     no way to tell whether those were genuinely scripts or a
					     class that inherits from one. The class name answers that
					     without another playtest. ]]
					table.insert(
						names,
						string.format("%s (%s)", descendant:GetFullName(), descendant.ClassName)
					)
				end
				descendant:Destroy()
				removed += 1
				break
			end
		end
	end

	--[[ Printed rather than silent. Somebody who put a script in their map on
	     purpose should find out from the game rather than from it not working,
	     and the names are what turn "something was removed" into "that one". ]]
	if removed > 0 then
		print(
			string.format(
				"[MapService] stripped %d script/prompt instance(s) from %s: %s%s",
				removed,
				mapId,
				table.concat(names, ", "),
				if removed > #names then string.format(" (+%d more)", removed - #names) else ""
			)
		)
	end
end

--[[
	Finds a map's source model.

	Also looks in Workspace.Maps, because that is where a level designer
	naturally leaves one while building it. A map found there is MOVED into
	ServerStorage rather than copied: leaving the original in Workspace would
	mean the world contains two of every map, which is both a rendering cost and
	a very confusing thing to debug.
]]
local function findSource(mapId: string): Model?
	local store = storage()
	local direct = store:FindFirstChild(mapId)
	if direct and direct:IsA("Model") then
		return direct
	end

	local workspaceMaps = Workspace:FindFirstChild(MapConfig.StorageFolder)
	if workspaceMaps then
		local stray = workspaceMaps:FindFirstChild(mapId)
		if stray and stray:IsA("Model") then
			stray.Parent = store
			print(
				string.format(
					"[MapService] moved map %q out of Workspace.Maps into ServerStorage.Maps",
					mapId
				)
			)
			return stray
		end
	end

	return nil
end

--[[ Clones a map ahead of time so the swap itself is a reparent. Safe to call
     repeatedly; a map already prepared is left alone. ]]
function MapService:prewarm(mapId: string): boolean
	if mapId == "" or prewarmed[mapId] then
		return prewarmed[mapId] ~= nil
	end
	local source = findSource(mapId)
	if not source then
		return false
	end
	local clone = source:Clone()
	clone.Name = mapId
	clone.Parent = prewarmFolder()
	prewarmed[mapId] = clone
	return true
end

function MapService:getCurrentId(): string
	return currentId
end

function MapService:getCurrentRoot(): Model?
	return currentRoot
end

--[[ Every map id that actually has a model behind it. The vote only ever offers
     these, so a roster entry with no model can never win and strand a round. ]]
function MapService:getAvailableIds(): { string }
	local available = {}
	for _, id in MapConfig.ids() do
		if findSource(id) then
			table.insert(available, id)
		end
	end
	return available
end

--[[ Where a sky that was already in Lighting waits out the round. Parked rather
     than destroyed: it is the place's own sky, not ours, and a map that borrows
     the view has to give it back. ]]
local function skyStash(): Folder
	local existing = ServerStorage:FindFirstChild(AMBIENCE_STASH)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = AMBIENCE_STASH
	folder.Parent = ServerStorage
	return folder
end

--[[ Lifts a map's sky and music out of the model and into the services that can
     actually use them. See the note on AMBIENCE_STASH for why either has to
     move at all. ]]
local function installAmbience(clone: Model, definition: any)
	for _, child in clone:GetChildren() do
		if child:IsA("Sky") and not installedSky then
			--[[ Anything already up there steps aside first. Two Skies in Lighting
			     is not a blend, it is a coin toss — and the one that wins is not
			     the map's. ]]
			for _, existing in Lighting:GetChildren() do
				if existing:IsA("Sky") then
					existing.Parent = skyStash()
				end
			end
			child.Parent = Lighting
			installedSky = child
		elseif child:IsA("Sound") and not installedMusic then
			--[[ Looped without asking. A background track that plays once and
			     stops leaves the rest of a seventeen-minute round in silence,
			     which is never what a map's music was for. ]]
			child.Looped = true

			--[[ And scaled, when the map asks for it. Volume used to be left
			     exactly as authored on the argument that the mix was the author's
			     decision — which is right in isolation and wrong in a round: a
			     track written on its own has never been heard under a horde, a
			     Tank and thirty gunshots. MapConfig.musicVolume is where that gets
			     reconciled, as a SCALE, so the author's own choices survive it and
			     a map that does not ask is untouched. ]]
			local scale = definition and definition.musicVolume
			if typeof(scale) == "number" and scale >= 0 then
				child.Volume *= scale
			end

			child.Parent = SoundService
			child:Play()
			installedMusic = child
		end
	end
end

--[[ Puts the view and the mixer back the way they were. Called before the map
     clone is destroyed, though the order does not matter: neither instance is
     inside the clone any more, which is exactly why this has to exist. ]]
local function removeAmbience()
	if installedSky then
		installedSky:Destroy()
		installedSky = nil
	end
	if installedMusic then
		installedMusic:Destroy()
		installedMusic = nil
	end
	local stash = ServerStorage:FindFirstChild(AMBIENCE_STASH)
	if stash then
		for _, sky in stash:GetChildren() do
			sky.Parent = Lighting
		end
	end
end

function MapService:unload()
	--[[ Before the early return, not after. A map can install a sky and then fail
	     to leave a currentRoot behind — and a game running the last map's sky over
	     no map at all is a bug that survives every subsequent round. ]]
	removeAmbience()

	if not currentRoot then
		currentId = ""
		return
	end

	Workspace:SetAttribute(Attributes.Game.MapPhase, "Unload")
	Remotes.Event.MapLoading:FireAllClients({ mapId = currentId, phase = "Unload" })

	--[[ Destroy rather than reparent back. A played map has burned crates, blood
	     decals, broken props and a hundred gore parts welded into it; putting
	     that back in storage would poison every future round with it. ]]
	currentRoot:Destroy()
	currentRoot = nil
	currentId = ""
end

--[[
	Swaps to a map. Returns false and changes nothing when the map has no model,
	which is what stops a bad vote from leaving the game with no world at all.
]]
function MapService:load(mapId: string): boolean
	local source = findSource(mapId)
	if not source then
		warnOnce(
			"nomap:" .. mapId,
			string.format("no model named %q in ServerStorage.%s", mapId, MapConfig.StorageFolder)
		)
		return false
	end

	self:unload()

	Workspace:SetAttribute(Attributes.Game.MapPhase, "Load")
	Remotes.Event.MapLoading:FireAllClients({ mapId = mapId, phase = "Load" })

	-- Prepared in advance if prewarm ran; cloned now if it did not.
	local clone = prewarmed[mapId]
	if clone and clone.Parent then
		prewarmed[mapId] = nil
	else
		clone = source:Clone()
	end
	clone.Name = mapId
	--[[ Before it is parented, not after. A Script runs the instant it enters the
	     world, so stripping afterwards is a race this would sometimes lose. ]]
	sanitise(clone, mapId)
	clone.Parent = liveFolder()
	--[[ After parenting, so the sky and the music are lifted out of a model that
	     is already live rather than out of one still being assembled. ]]
	--[[ The definition rides along so the map's own mix preferences — currently
	     just musicVolume — are applied at the moment its Sound is adopted, rather
	     than needing a second pass that would have to find it again. ]]
	installAmbience(clone, MapConfig.get(mapId))

	currentRoot = clone
	currentId = mapId

	Workspace:SetAttribute(Attributes.Game.CurrentMap, mapId)
	Workspace:SetAttribute(Attributes.Game.MapPhase, "Ready")
	Remotes.Event.MapLoading:FireAllClients({ mapId = mapId, phase = "Ready" })

	--[[ Everything downstream rebuilds from tags rather than being told what
	     changed: the flow spline, the spawn nodes, the item spots and the ammo
	     crates all rediscover themselves. That is what lets a hand-built map drop
	     in with no code changes. ]]
	MapService.mapChanged:fire(mapId, clone)

	local level = Registry.find("LevelService")
	if level and typeof(level.rebuild) == "function" then
		level:rebuild()
	end

	return true
end

--[[ Loads a map only if it is not already the live one. Used at round start,
     where re-loading the same map would throw away a perfectly good world and
     cost a visible hitch for nothing. ]]
function MapService:ensure(mapId: string): boolean
	if currentId == mapId and currentRoot and currentRoot.Parent then
		return true
	end
	return self:load(mapId)
end

function MapService:init()
	-- Adopt anything a designer left in Workspace before the game ever ran, so a
	-- freshly opened place with a map sitting in the world still plays.
	local live = liveFolder()
	if #live:GetChildren() == 0 then
		local workspaceMaps = Workspace:FindFirstChild(MapConfig.StorageFolder)
		if workspaceMaps then
			for _, child in workspaceMaps:GetChildren() do
				if child:IsA("Model") and MapConfig.get(child.Name) then
					child.Parent = storage()
				end
			end
		end
	end

	local available = self:getAvailableIds()
	if #available == 0 then
		warnOnce(
			"empty",
			string.format(
				"no maps found. Put your map models in ServerStorage.%s, named to match "
					.. "MapConfig.Maps (%s).",
				MapConfig.StorageFolder,
				table.concat(MapConfig.ids(), ", ")
			)
		)
	else
		print(
			string.format("[MapService] %d map(s) available: %s", #available, table.concat(available, ", "))
		)
	end
end

--[[
	Puts a world up as soon as the server is running, before any round exists.

	Without this the place is empty until the first round starts, which is fine
	for a full server (everybody is looking at the menu) and awful for a developer
	pressing Play alone and finding a void. The map vote still runs and still
	swaps this out — loading the default here only guarantees there is always
	SOMETHING to swap from.
]]
function MapService:start()
	if currentRoot and currentRoot.Parent then
		return
	end

	local available = self:getAvailableIds()
	if #available == 0 then
		return
	end

	local first = if table.find(available, MapConfig.DefaultMap) then MapConfig.DefaultMap else available[1]
	self:load(first)
end

function MapService:destroy()
	serviceTrove:destroy()
	for _, clone in prewarmed do
		clone:Destroy()
	end
	table.clear(prewarmed)
end

Registry.register("MapService", MapService)

return MapService
