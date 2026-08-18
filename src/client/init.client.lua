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

local Shared = ReplicatedStorage:WaitForChild("Shared")
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
]]
local CONTROLLERS = {
	"Input/InputController",
	"Effects/CameraController",
	"Weapon/WeaponController",
	"Weapon/ViewmodelController",
	"Effects/ImpactController",
	"Effects/GoreController",
	"Effects/OutlineController",
	"UI/HudController",
	"UI/CrosshairController",
	"UI/HitmarkerController",
	"UI/PromptController",
	"UI/SubtitleController",
	"UI/OverlayController",
	"Audio/MusicController",
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
		return
	end

	local ok, result = xpcall(require, traceback, moduleScript :: any)
	if not ok then
		report("require", path, result)
		return
	end
	if typeof(result) ~= "table" then
		report("require", path, "module did not return a table")
		return
	end
	table.insert(loaded, { path = path, module = result })
end

local function runPhase(phase: string): (number, number)
	local ran, failed = 0, 0
	for _, entry in loaded do
		local method = entry.module[phase]
		if typeof(method) == "function" then
			local ok, err = xpcall(method, traceback, entry.module)
			if ok then
				ran += 1
			else
				failed += 1
				report(phase, entry.path, err)
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
	controller requires Remotes, so letting it throw fourteen more times would
	cost fourteen more twenty-second waits and bury the one message that matters.
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

print(
	string.format(
		"%s\n[Fading Light] client up in %.0fms — %d/%d controllers loaded (%.0fms), "
			.. "init %d ok / %d failed, start %d ok / %d failed\n"
			.. "registered: %s\n%s",
		BAR,
		bootMs,
		#loaded,
		#CONTROLLERS,
		loadMs,
		initRan,
		initFailed,
		startRan,
		startFailed,
		table.concat(Registry.getRegisteredNames(), ", "),
		BAR
	)
)

--[[ Seeded after start() so a controller's remote listeners are already up: the
     snapshot is a starting point, not a substitute for the events that follow. ]]
seed(requestInitialState())
