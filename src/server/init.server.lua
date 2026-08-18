--!strict
--[[
	Fading Light — server bootstrap.

	Load order matters exactly once, here, and then never again. This script
	builds the remote manifest, registers the collision groups, loads every
	service module, and runs the two-phase lifecycle. After that every
	cross-service call goes through Registry.get at call time, so nothing cares
	who loaded first.

	Every module and every lifecycle call is isolated with xpcall and reported
	with a traceback. During development something in this list is always
	half-written, and one broken system taking the whole server down turns a
	thirty-second fix into a restart loop. A loud, named failure that leaves the
	rest of the game standing is worth far more than a clean stack trace nobody
	can act on because they cannot get in-game to reproduce it.
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(Shared.Util.Registry)
-- Requiring Remotes is what creates ReplicatedStorage.FadingLightNet. It has to
-- happen before any client gets far enough to WaitForChild it, so it is first.
local Remotes = require(Shared.Net.Remotes)

local BAR = string.rep("=", 72)

-- Read by RigUtil.makeDebris and by every service that reparents a body, so the
-- names here are a contract, not a preference.
local COLLISION_GROUPS = { "Survivor", "Infected", "Debris", "Gib" }

--[[
	Pairs that must NOT use the Roblox default of "collides with everything".
	Anything absent stays collidable, which is why no pair involving Default
	appears: all four groups are meant to collide with the level itself.
]]
local COLLISION_RULES: { { any } } = {
	-- The single most important line in this file. A 46-strong horde that
	-- collides with itself wedges solid in the first doorway it reaches and
	-- never arrives; the players hear a horde they never fight. Turning this off
	-- lets bodies flow around corners and pile through gaps the way they do in
	-- Left 4 Dead.
	{ "Infected", "Infected", false },
	{ "Infected", "Survivor", true },
	-- Survivors DO block each other. That is not an oversight — it is the reason
	-- Shove exists, and it is what makes a doorway a decision.
	{ "Survivor", "Survivor", true },

	-- Corpses, severed limbs and gibs are scenery with physics. They must never
	-- push a survivor off a ledge, plug a doorway, or knock a Common off course.
	{ "Debris", "Survivor", false },
	{ "Debris", "Infected", false },
	{ "Debris", "Debris", false },
	{ "Debris", "Gib", false },
	{ "Gib", "Survivor", false },
	{ "Gib", "Infected", false },
	{ "Gib", "Gib", false },
}

--[[
	Every server service, in a readable dependency-ish order.

	The Registry means this order cannot break anything — nothing resolves
	another service until it is called. It is ordered for humans, and because the
	init/start passes run in this same order, which gives assets and the level a
	chance to exist before the Director starts asking about them.
]]
local MODULES = {
	"Audio/AudioService",
	"Assets/PlaceholderFactory",
	"Level/LevelService",
	"Survivors/SurvivorService",
	"Survivors/InventoryService",
	"Combat/GoreService",
	"Combat/DamageService",
	"Combat/BallisticsService",
	"Combat/MeleeService",
	"Infected/InfectedService",
	"Director/ItemPlacer",
	"Director/DirectorService",
}

-- Modules slower than this get called out by name in the banner. Boot cost that
-- nobody can see is boot cost nobody fixes.
local SLOW_MODULE_MS = 8

-- RequestInitialState is identical for every caller, so one shared snapshot
-- serves a whole team joining at once and a client spamming the remote costs
-- nothing but a table read.
local STATE_CACHE_TIME = 0.25

type LoadedModule = {
	path: string,
	names: { string },
	service: any,
}

local loaded: { LoadedModule } = {}

local function report(phase: string, subject: string, err: any)
	warn(
		string.format(
			"\n%s\n[Fading Light] %s FAILED — %s\n%s\n%s",
			BAR,
			phase,
			subject,
			tostring(err),
			BAR
		)
	)
end

--[[ xpcall with a traceback, because a bare pcall message points at the line
     that threw and never at the call that led there. ]]
local function protect<A...>(fn: (A...) -> ...any, ...: A...): (boolean, any)
	return xpcall(fn, function(message: any)
		return debug.traceback(tostring(message), 2)
	end, ...)
end

local function setupCollisionGroups()
	local existing: { [string]: boolean } = {}
	local ok, groups = protect(function()
		return PhysicsService:GetRegisteredCollisionGroups()
	end)
	if ok and typeof(groups) == "table" then
		for _, group in groups do
			existing[group.name] = true
		end
	end

	for _, name in COLLISION_GROUPS do
		if existing[name] then
			continue
		end
		-- RegisterCollisionGroup throws when the group already exists, which it
		-- does on every Studio re-run against a place file that kept them.
		local registered, err = protect(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
		if not registered then
			report("collision group", name, err)
		end
	end

	for _, rule in COLLISION_RULES do
		local applied, err = protect(function()
			PhysicsService:CollisionGroupSetCollidable(rule[1], rule[2], rule[3])
		end)
		if not applied then
			report("collision rule", string.format("%s <-> %s", tostring(rule[1]), tostring(rule[2])), err)
		end
	end
end

--[[
	Seeds the global attributes so a client that joins before any service has
	written one reads a sane value instead of nil. Only ever fills a blank: the
	service that owns a field still owns it.
]]
local function seedGameAttributes()
	local defaults: { [string]: any } = {
		[Attributes.Game.RoundState] = Enums.RoundState.Lobby,
		[Attributes.Game.PacingState] = Enums.PacingState.Relax,
		[Attributes.Game.TeamIntensity] = 0,
		[Attributes.Game.AliveSurvivors] = 0,
		[Attributes.Game.InfectedAlive] = 0,
		[Attributes.Game.TankActive] = false,
		[Attributes.Game.ObjectiveText] = "",
	}
	for name, value in defaults do
		if Workspace:GetAttribute(name) == nil then
			Workspace:SetAttribute(name, value)
		end
	end
end

local function resolveModule(path: string): ModuleScript?
	local instance: Instance? = script
	for segment in string.gmatch(path, "[^/]+") do
		if not instance then
			return nil
		end
		instance = instance:FindFirstChild(segment)
	end
	if instance and instance:IsA("ModuleScript") then
		return instance
	end
	return nil
end

local function registeredNameSet(): { [string]: boolean }
	local set = {}
	for _, name in Registry.getRegisteredNames() do
		set[name] = true
	end
	return set
end

--[[ Loads one module and records which Registry names it claimed, so a module
     that forgets to register itself is caught here rather than three systems
     later as a confusing Registry.get error. ]]
local function loadModule(path: string): number
	local moduleScript = resolveModule(path)
	if not moduleScript then
		report("module load", path, "no ModuleScript at ServerScriptService.Server." .. path)
		return 0
	end

	local before = registeredNameSet()
	local started = os.clock()
	local ok, result = protect(require, moduleScript)
	local elapsed = (os.clock() - started) * 1000

	if not ok then
		report("module load", path, result)
		return elapsed
	end

	local claimed = {}
	for _, name in Registry.getRegisteredNames() do
		if not before[name] then
			table.insert(claimed, name)
		end
	end
	if #claimed == 0 then
		warn(
			string.format(
				"[Fading Light] %s loaded but registered nothing. Every service module must end with "
					.. 'Registry.register("Name", Service).',
				path
			)
		)
	end

	table.insert(loaded, { path = path, names = claimed, service = result })
	return elapsed
end

--[[ Runs one lifecycle phase across every loaded service, in load order. ]]
local function runPhase(phase: string): (number, number)
	local ran, failed = 0, 0
	for _, entry in loaded do
		local service = entry.service
		if typeof(service) ~= "table" then
			continue
		end
		local method = service[phase]
		if typeof(method) ~= "function" then
			continue
		end

		local ok, err = protect(method, service)
		if ok then
			ran += 1
		else
			failed += 1
			report(phase .. "()", entry.path, err)
		end
	end
	return ran, failed
end

-- ── initial state handshake ─────────────────────────────────────────────────
-- Installed before any module loads. The remote instances exist from the moment
-- Remotes was required at the top of this file, so a client that gets there
-- first must find a callback attached rather than an invoke that throws.

local cachedState: { [string]: any }? = nil
local cachedAt = 0
local reportedStateFailure = false

--[[ Difficulty has no attribute in the contract, so it is read from the Director
     when that service offers a getter and falls back to the config default. ]]
local function currentDifficulty(): string
	local director = Registry.find("DirectorService")
	if director and typeof(director.getDifficulty) == "function" then
		local ok, name = protect(director.getDifficulty, director)
		if ok and typeof(name) == "string" and name ~= "" then
			return name
		end
	end
	return DirectorConfig.DefaultDifficulty
end

--[[
	Everything a joining client needs to draw a HUD before the first event
	arrives. Built entirely from attributes rather than by calling into services:
	attribute reads cannot yield and cannot throw, which is exactly the property
	a RemoteFunction callback needs.
]]
local function buildInitialState(): { [string]: any }
	local roster = {}
	for _, player in Players:GetPlayers() do
		table.insert(roster, {
			userId = player.UserId,
			name = player.Name,
			displayName = player.DisplayName,
			state = Attributes.get(player, Attributes.Player.State, Enums.SurvivorState.Spectating),
			health = Attributes.get(player, Attributes.Player.Health, 0),
			tempHealth = Attributes.get(player, Attributes.Player.TempHealth, 0),
			incapCount = Attributes.get(player, Attributes.Player.IncapCount, 0),
			isBlackAndWhite = Attributes.get(player, Attributes.Player.IsBlackAndWhite, false),
			flowDistance = Attributes.get(player, Attributes.Player.FlowDistance, 0),
		})
	end

	return {
		roundState = Attributes.get(Workspace, Attributes.Game.RoundState, Enums.RoundState.Lobby),
		pacingState = Attributes.get(Workspace, Attributes.Game.PacingState, Enums.PacingState.Relax),
		teamIntensity = Attributes.get(Workspace, Attributes.Game.TeamIntensity, 0),
		objective = Attributes.get(Workspace, Attributes.Game.ObjectiveText, ""),
		difficulty = currentDifficulty(),
		maxSurvivors = GameConfig.MaxSurvivors,
		serverTime = Workspace:GetServerTimeNow(),
		survivors = roster,
	}
end

--[[
	A RemoteFunction is the one place a client can make the server do work on the
	server's own thread. This callback therefore never yields, never trusts an
	argument (it takes none), and can only ever cost a cached table read inside
	the throttle window. If the build ever throws, the client still gets a
	well-formed lobby payload rather than an error that surfaces as a broken HUD.
]]
Remotes.Function.RequestInitialState.OnServerInvoke = function(_player: Player)
	local now = os.clock()
	if cachedState and now - cachedAt < STATE_CACHE_TIME then
		return cachedState
	end

	local ok, payload = protect(buildInitialState)
	if not ok then
		-- Reported once: a client is free to invoke this as fast as it likes, and
		-- a repeating failure must not become the client's warn throttle.
		if not reportedStateFailure then
			reportedStateFailure = true
			report("RequestInitialState", "buildInitialState", payload)
		end
		local fallback = {
			roundState = Enums.RoundState.Lobby,
			pacingState = Enums.PacingState.Relax,
			teamIntensity = 0,
			objective = "",
			difficulty = DirectorConfig.DefaultDifficulty,
			maxSurvivors = GameConfig.MaxSurvivors,
			serverTime = Workspace:GetServerTimeNow(),
			survivors = {},
		}
		cachedState = fallback
		cachedAt = now
		return fallback
	end

	cachedState = payload
	cachedAt = now
	return payload
end

-- ── boot ────────────────────────────────────────────────────────────────────

local bootStarted = os.clock()

-- The project file sets this, but a place file that lost the property would
-- otherwise spawn a default Roblox character next to every survivor we make.
Players.CharacterAutoLoads = false

seedGameAttributes()

local collisionStarted = os.clock()
setupCollisionGroups()
local collisionMs = (os.clock() - collisionStarted) * 1000

local loadStarted = os.clock()
local slowModules: { string } = {}
for _, path in MODULES do
	local elapsed = loadModule(path)
	if elapsed >= SLOW_MODULE_MS then
		table.insert(slowModules, string.format("%s %.0fms", path, elapsed))
	end
end
local loadMs = (os.clock() - loadStarted) * 1000

local initStarted = os.clock()
local initRan, initFailed = runPhase("init")
local initMs = (os.clock() - initStarted) * 1000

local startStarted = os.clock()
local startRan, startFailed = runPhase("start")
local startMs = (os.clock() - startStarted) * 1000

print(BAR)
print("  Fading Light — server")
print(string.format("  collision groups                       %7.1f ms", collisionMs))
print(string.format("  modules    %2d/%2d loaded                 %7.1f ms", #loaded, #MODULES, loadMs))
print(string.format("  init       %2d ran, %d failed             %7.1f ms", initRan, initFailed, initMs))
print(string.format("  start      %2d ran, %d failed             %7.1f ms", startRan, startFailed, startMs))
print(string.format("  total                                  %7.1f ms", (os.clock() - bootStarted) * 1000))
if #slowModules > 0 then
	print("  slow       " .. table.concat(slowModules, ", "))
end
print("  registry   " .. table.concat(Registry.getRegisteredNames(), ", "))
print(BAR)

-- ── survivor spawning ───────────────────────────────────────────────────────

local handledPlayers: { [Player]: boolean } = {}

local function onPlayerAdded(player: Player)
	if handledPlayers[player] then
		return
	end
	handledPlayers[player] = true

	local survivors = Registry.find("SurvivorService")
	if not survivors then
		warn(
			string.format(
				"[Fading Light] SurvivorService is not registered, so %s has no character. "
					.. "Fix the load failure above.",
				player.Name
			)
		)
		return
	end

	local ok, err = protect(survivors.spawnSurvivor, survivors, player)
	if not ok then
		report("spawnSurvivor", player.Name, err)
	end
end

local function onPlayerRemoving(player: Player)
	handledPlayers[player] = nil

	-- Optional hook. SurvivorService owns survivor lifetime and is expected to
	-- watch PlayerRemoving itself; this only calls a method if that service
	-- chose to declare one, so the bootstrap never forces API onto a neighbour.
	local survivors = Registry.find("SurvivorService")
	if survivors and typeof(survivors.onPlayerRemoving) == "function" then
		local ok, err = protect(survivors.onPlayerRemoving, survivors, player)
		if not ok then
			report("onPlayerRemoving", player.Name, err)
		end
	end
end

-- Connect before sweeping the existing list: the reverse order can miss a player
-- who joins in between, and the dedupe set makes the overlap harmless.
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
