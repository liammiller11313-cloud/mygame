--!strict
--[[
	Fading Light — client bootstrap.

	Mirrors the server's: require every controller (which registers it), run
	every init(), then every start(), each call isolated so one broken system
	cannot take the whole client down. On the client that isolation matters more
	than it does on the server — a client that fails to boot shows the player a
	black screen with no HUD and no camera, and they cannot read the output
	window to find out why. A loud, named failure that leaves the rest of the
	game playable is worth far more than a clean stack trace nobody will see.

	After the two phases, RequestInitialState is invoked once, with a timeout,
	and handed to every controller that exposes `onInitialState(payload)`. That
	handshake exists because attributes only fire their changed signal on the
	next write: a player joining mid-round has to be able to read the round
	state, the roster and the objective as they are RIGHT NOW rather than wait
	for something to move.

	The controller list below is the one in docs/ARCHITECTURE.md. A module that
	does not exist yet is reported once and skipped — during development
	something in this list is always half-written, and the rest of the client
	still has to run.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)

-- Assigned in the boot section below, not here: requiring it can fail, and the
-- failure has to be reported through `report` rather than thrown at module
-- scope. Declared up here so requestInitialState closes over the local.
local Remotes: any = nil

local BAR = string.rep("=", 72)

--[[
	Every client controller, in a readable order.

	Registry lookups happen at call time, so this order cannot break anything.
	It is ordered for humans and because the init/start passes run in it: input
	and camera first because everything else reacts to them, presentation after
	the systems that drive it.

	MainMenuController is last on purpose. Its start() opens the menu, and opening
	the menu switches off the HUD, the crosshair, the interact prompts and the
	input controller — so every controller it reaches for has to have built its
	ScreenGui already, or the menu opens over a HUD that is still visible.
]]
local CONTROLLERS = {
	--[[ First, and it has to be: it draws black over everything at
	     DisplayOrder.Splash while the rest of the client boots behind it, so the
	     player never sees a half-built menu assembling itself. Nothing else
	     depends on it and it depends on nothing. ]]
	"UI/SplashController",
	"Input/InputController",
	"Effects/CameraController",
	"Weapon/WeaponController",
	"Weapon/ViewmodelController",
	"Effects/ImpactController",
	"Effects/GoreController",
	--[[ The map is pitch dark by the finale and the atmosphere ramp was pointed at
	     nothing until this existed. See GameConfig.Flashlight. ]]
	"Effects/FlashlightController",
	"Effects/OutlineController",
	-- The horde's walk cycle. Client-side because a continuous gait replicated
	-- from the server would be a quarter of a million property writes a second.
	"Effects/InfectedPoseController",
	--[[ Before the HUD, and that is only tidiness — it draws on its own ScreenGui
	     under everything by DisplayOrder, not by boot order. ]]
	"UI/Dread",
	"UI/HudController",
	"UI/WaveController",
	-- After WaveController, whose block height it asks for to sit underneath it.
	"UI/EventController",
	--[[ After WaveController, because it draws under that block and measures its
	     bottom edge to know where to start. It used to say WaveController sets a
	     "resting inset" in start() that a later module has to overwrite; no such
	     thing exists any more — TopStack replaced the inset with a claim, and the
	     boss bar takes a slot in it rather than pushing a number past somebody
	     else's. The ORDER still matters, for the plainer reason that TopStack
	     measures the wave block and the wave block has to be built. ]]
	"UI/BossBarController",
	"UI/CrosshairController",
	"UI/HitmarkerController",
	"UI/PromptController",
	"UI/SubtitleController",
	"UI/OverlayController",
	"UI/InfectedController",
	"UI/MapVoteController",
	-- After the HUD, because it lays itself out around where the hotbar already is.
	"UI/TouchController",
	--[[ Order does not matter to it: it reads AudioConfig and asks Roblox, and
	     touches nothing else in the game. It is here so it sits with the audio
	     it is about. ]]
	"Audio/SoundCheck",
	"Audio/MusicController",
	-- Reads Attributes.Player.IsSprinting, which SurvivorService publishes.
	"Audio/FootstepController",
	--[[ Before the menu, because the menu's SETTINGS entry opens this and its
	     start() applies every stored preference — a sensitivity restored from the
	     last server should be in force before the first frame of play, not after
	     somebody opens the panel. ]]
	"UI/SettingsController",
	--[[ The economy, in dependency order. ProfileController is the store the other
	     two read; both of them look it up at start(), so it has to have connected
	     its remotes first or the first sync lands in nothing. ]]
	"UI/ProfileController",
	--[[ Before ShopController, which reads it to draw the PASSES tab. Holds no
	     profile state: Robux ownership is Roblox's record, not ours. ]]
	"UI/PassController",
	--[[ Its own panel off the menu's nav row. Decides nothing — CodeService owns
	     the window and the one-per-account rule. ]]
	"UI/CodesController",
	-- Beside ProfileController and for the same reason: a mirror of server state
	-- that several screens read, loaded before any of them.
	"UI/ProgressionController",
	--[[ After ProgressionController, whose Scrip mirror it reads to decide what
	     the player can afford. A panel like the shop, on the same layer, and
	     never open at the same time as one. ]]
	"UI/RequisitionController",
	--[[ The permanent abilities. The panel goes with the other menu screens; the
	     HUD cards and the effects are separate modules because they are separate
	     jobs — one draws two cards and asks the server, the other draws what the
	     server says happened. ]]
	"UI/AbilityPanelController",
	"UI/AbilityController",
	"Effects/AbilityEffects",
	"UI/ShopController",
	"UI/LoadoutController",
	--[[ A panel like those two, and reachable from the pause menu the same way
	     CAREER is. Reads nothing but Player attributes, so it has no service to
	     wait for and its position here is only about the menus that open it. ]]
	"UI/BackpackController",
	-- A panel like the shop and the loadout screen, opened from the same nav row,
	-- so it loads with them and before the menu that opens it.
	"UI/CareerController",
	--[[ Beside the career panel it borrows its whole vocabulary from: the tag on
	     a leaderboard row IS a pass callsign, drawn in a pass accent. ]]
	"UI/LeaderboardController",
	-- The PLAY flow: quick play, private lobbies, and the server browser. Loaded
	-- with the other panels and before the menu that opens it.
	"UI/PlayController",
	-- Reads ProgressionController the same way; draws over the results card
	-- rather than inside it, so neither has to wait for the other.
	"UI/AwardController",
	--[[ Reads the same mirror, on the HUD rather than over the results: level
	     and today's orders while they are being earned. After
	     ProgressionController for the same reason every other reader is. ]]
	"UI/OrdersController",
	--[[ The vault keypad and its document reader. After PromptController, which
	     is what opens both — a world interaction rather than a keybind, so this
	     has no binding of its own. ]]
	"UI/VaultController",
	--[[ The generator panel, and the arrow to the room the generators open.

	     Both after VaultController: the panel asks it to put a refusal on the
	     counter card that VaultController owns, and the arrow sits beside that
	     card in the same left column. Both after PromptController for the same
	     reason the keypad is — a world interaction opens them, not a keybind. ]]
	"UI/GeneratorController",
	"UI/WaypointController",
	--[[ The bar over a deployed turret, and the trigger while you are sitting in
	     one. After InputController, which it asks whether the fire button is
	     down — by registry name at tick time rather than at load, so the ordering
	     is tidiness rather than need. ]]
	"UI/TurretController",
	--[[ Following a teammate once you are dead. After InputController, whose Fire
	     and Aim signals it cycles on, and after TopStack's other claimants so the
	     card it draws lands under them rather than over the clock. ]]
	"UI/SpectateController",
	--[[ After the screens it can open, and after the HUD whose corner it shares. ]]
	--[[ Before MainMenuController, which attaches it in its own build(). Order
	     is belt and braces — every controller is required before any init() runs
	     — but a module found by Registry should be listed before the one that
	     looks for it, or the next person has to prove the bootstrap for
	     themselves. ]]
	"UI/MenuBackdrop",
	"UI/PauseController",
	"UI/MainMenuController",
}

-- How long to wait for a controller module to replicate before giving up on it.
-- StarterPlayerScripts arrives in one piece, so anything past this is missing.
local MODULE_WAIT = 5

--[[ RequestInitialState is a RemoteFunction and RemoteFunctions block forever
     if the server never answers. Nothing in the payload is required to play, so
     the client boots without it rather than hanging on a black screen. ]]
local STATE_TIMEOUT = 8

type Loaded = {
	path: string,
	module: any,
}

local loaded: { Loaded } = {}

-- Path -> the phase that broke it, in the order they broke. The counts in the
-- banner say something is missing; only the names say which screen is gone, and
-- a player looking at a HUD with no ammo counter cannot scroll back through
-- fourteen tracebacks to work it out.
local failures: { [string]: string } = {}
local failureOrder: { string } = {}

local function noteFailure(path: string, phase: string)
	if not failures[path] then
		table.insert(failureOrder, path)
	end
	-- Keep the first: a controller that failed to require cannot then fail init,
	-- so a later phase overwriting it would only ever report the symptom.
	failures[path] = failures[path] or phase
end

local function report(phase: string, subject: string, err: any)
	warn(
		string.format(
			"\n%s\n[Fading Light client] %s FAILED — %s\n%s\n%s",
			BAR,
			phase,
			subject,
			tostring(err),
			BAR
		)
	)
end

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

--[[ Walks a "Folder/Module" path from this script. WaitForChild rather than
     direct indexing so a slow replication reads as a wait, not as a nil error. ]]
local function resolve(path: string): ModuleScript?
	local node: Instance = script
	for segment in string.gmatch(path, "[^/]+") do
		local child = node:WaitForChild(segment, MODULE_WAIT)
		if not child then
			return nil
		end
		node = child
	end
	if not node:IsA("ModuleScript") then
		return nil
	end
	return node
end

local function loadController(path: string)
	local moduleScript = resolve(path)
	if not moduleScript then
		report("require", path, "no ModuleScript at that path (not written yet?)")
		noteFailure(path, "missing")
		return
	end

	local ok, result = xpcall(require, traceback, moduleScript :: any)
	if not ok then
		report("require", path, result)
		noteFailure(path, "require")
		return
	end
	if typeof(result) ~= "table" then
		report("require", path, "module did not return a table")
		noteFailure(path, "require")
		return
	end
	table.insert(loaded, { path = path, module = result })
end

local function runPhase(phase: string): (number, number)
	local ran, failed = 0, 0
	for _, entry in loaded do
		--[[ Same rule the server bootstrap keeps: a controller whose earlier
		     phase threw has nothing to start, and starting it half-built turns
		     one legible failure into two. The banner has already named it. ]]
		if failures[entry.path] then
			continue
		end
		local method = entry.module[phase]
		if typeof(method) == "function" then
			local ok, err = xpcall(method, traceback, entry.module)
			if ok then
				ran += 1
			else
				failed += 1
				report(phase, entry.path, err)
				noteFailure(entry.path, phase)
			end
		end
	end
	return ran, failed
end

--[[
	The one blocking call in the boot, wrapped so it cannot be the reason the
	client never finishes starting. Returns nil on timeout or error; every
	consumer of onInitialState must already handle never being called.
]]
local function requestInitialState(): any
	local finished = false
	local payload: any = nil

	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.Function.RequestInitialState:InvokeServer()
		end)
		finished = true
		if ok then
			payload = result
		else
			report("RequestInitialState", "InvokeServer", result)
		end
	end)

	local deadline = os.clock() + STATE_TIMEOUT
	while not finished and os.clock() < deadline do
		task.wait()
	end

	if not finished then
		warn("[Fading Light client] RequestInitialState timed out; booting without the initial snapshot")
	end
	return payload
end

--[[
	── TELLING THE SERVER WHICH MAP THIS CLIENT CAN SEE ────────────────────────

	MapLoading's "Ready" is fired the instant the clone is parented ON THE
	SERVER. A map is a large model that then has to cross the wire to four
	clients, and until it arrives, a body placed on it is a body standing in
	nothing. SurvivorService holds a character still until this says otherwise —
	see the hold's note there for the fall it prevents.

	── IT WAITS FOR THE MODEL, NOT FOR THE MESSAGE ─────────────────────────────
	Answering the moment the remote arrives would confirm nothing: the event is
	small and overtakes the map it is announcing. So this waits for a child of
	Workspace.CurrentMap actually named for that map, which is the one fact worth
	reporting — the model exists here.

	── AND IT GIVES UP ─────────────────────────────────────────────────────────
	A map that never arrives must not freeze somebody out of the round. The
	server has its own timeout under the hold; this one exists so a client that
	waited too long still says something, and says it about the right map.
]]
--[[ Shared with the server's hold, which is derived from it. See
     MapConfig.Handshake for why the order of the two matters. ]]
local MAP_WAIT_TIMEOUT = MapConfig.Handshake.ClientWait
local MAP_POLL = 0.15
--[[ Consecutive polls with the part count unmoved that mean replication has
     stopped. The count is the primary test; this is the fallback for the case
     where it can never be reached — a part destroyed by a round that started
     while the map was still arriving, say — so that a map which HAS finished
     coming across is not held against a target that moved. ]]
local MAP_STABLE_POLLS = 6

local mapWatch = 0

--[[ BaseParts under the live map, on THIS machine. The one number that answers
     "can I see the floor yet". ]]
local function localParts(map: Instance): number
	local count = 0
	for _, descendant in map:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

--[[
	── WHAT THIS USED TO CONFIRM, AND WHY IT WAS THE BUG ───────────────────────

	It waited for `CurrentMap` to contain a child named for the map, and then
	said "ready". A Model replicates to a client as an INSTANCE first and fills
	in afterwards — so that child appears within a frame or two of the event,
	while the thing it is named after is still an empty shell with no floor in
	it.

	The server took that at its word. The hold on a joining body checks whether
	the client has the map before it anchors anything at all, so a client that
	confirmed early was not merely released early — it was never held. The body
	was placed on a floor the server could see and the client could not, and on
	the client it fell through where the floor had not arrived: standing outside
	the world on their own screen, in the map on everybody else's, and being
	attacked the whole time because the server was right about where they were.

	Three attempts at this fixed the wrong halves — which SpawnLocations to use,
	who owns the physics, and which map generation a confirmation belongs to.
	All three were real and none of them touched this line, because the
	handshake was not failing. It was succeeding, about the wrong question.

	So now it counts. The server publishes how many BaseParts the live map has —
	see Attributes.Game.MapParts — and this waits until it has that many, which
	is the smallest fact that actually means "there is a map here".
]]
local function confirmMap(mapId: string)
	mapWatch += 1
	local ticket = mapWatch
	task.spawn(function()
		local deadline = os.clock() + MAP_WAIT_TIMEOUT
		local seen, stable = -1, 0
		while os.clock() < deadline do
			--[[ Superseded. Another map started loading while this one was still
			     being waited for, and confirming the old id now would be worse
			     than saying nothing — the server would release a body onto a map
			     this client has not begun to receive. ]]
			if ticket ~= mapWatch then
				return
			end
			local folder = Workspace:FindFirstChild(MapConfig.LiveFolder)
			local map = folder and folder:FindFirstChild(mapId)
			if map then
				local expected = tonumber(Workspace:GetAttribute(Attributes.Game.MapParts)) or 0
				local have = localParts(map)
				if expected > 0 and have >= expected then
					break
				end
				--[[ Still arriving, or arrived and short of a target that moved.
				     Only counted once something is actually here, so an empty
				     shell can never be mistaken for a finished one. ]]
				if have > 0 and have == seen then
					stable += 1
					if stable >= MAP_STABLE_POLLS then
						break
					end
				else
					seen, stable = have, 0
				end
			end
			task.wait(MAP_POLL)
		end
		if ticket == mapWatch then
			Remotes.Event.MapReady:FireServer(mapId)
		end
	end)
end

local function watchMapLoading()
	Remotes.Event.MapLoading.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or payload.phase ~= "Ready" then
			return
		end
		local mapId = payload.mapId
		if typeof(mapId) == "string" and mapId ~= "" then
			confirmMap(mapId)
		end
	end)

	--[[ And once for whatever is already loaded, because a client that joins a
	     server mid-round never sees the event that announced its map. ]]
	local current = Workspace:GetAttribute(Attributes.Game.CurrentMap)
	if typeof(current) == "string" and current ~= "" then
		confirmMap(current)
	end
end

local function seed(payload: any)
	for _, entry in loaded do
		local method = entry.module.onInitialState
		if typeof(method) == "function" then
			local ok, err = xpcall(method, traceback, entry.module, payload)
			if not ok then
				report("onInitialState", entry.path, err)
			end
		end
	end
end

-- ── boot ────────────────────────────────────────────────────────────────────

local started = os.clock()

--[[
	Requiring Remotes on the client WAITS for the server's manifest to replicate,
	so this is also the "is the server actually up" check, and it has to succeed
	before any controller connects to a remote in start().

	It is isolated because a failure here is not one controller's problem: every
	controller requires Remotes, so letting it throw once per controller would
	cost a twenty-second wait each time and bury the one message that matters.
]]
local remotesOk, remotesResult = xpcall(require, traceback, Shared.Net.Remotes :: any)
if not remotesOk then
	report("require", "Shared/Net/Remotes", remotesResult)
	error("[Fading Light client] the network manifest never replicated; the client cannot start", 0)
end
Remotes = remotesResult

for _, path in CONTROLLERS do
	loadController(path)
end
local loadMs = (os.clock() - started) * 1000

local initRan, initFailed = runPhase("init")
local startRan, startFailed = runPhase("start")

local bootMs = (os.clock() - started) * 1000

print(BAR)
print(
	string.format(
		"[Fading Light] client up in %.0fms — %d/%d controllers loaded (%.0fms), "
			.. "init %d ok / %d failed, start %d ok / %d failed\nregistered: %s",
		bootMs,
		#loaded,
		#CONTROLLERS,
		loadMs,
		initRan,
		initFailed,
		startRan,
		startFailed,
		table.concat(Registry.getRegisteredNames(), ", ")
	)
)
if #failureOrder > 0 then
	print(string.format("%d CONTROLLER(S) BROKEN — tracebacks are above:", #failureOrder))
	for _, path in failureOrder do
		print(string.format("  %-34s failed at %s", path, failures[path]))
	end
end
print(BAR)

--[[ Seeded after start() so a controller's remote listeners are already up: the
     snapshot is a starting point, not a substitute for the events that follow. ]]
--[[ Before the snapshot, so a client that joins mid-round starts waiting for
     its map at the earliest possible moment rather than after a blocking call
     that can take a second to answer. ]]
watchMapLoading()

seed(requestInitialState())
