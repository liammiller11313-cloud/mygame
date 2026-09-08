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

	The banner at the end exists for the same reason. A developer pressing Play
	needs one screen that answers: did everything load, what broke, how long did
	it take, is the game using my models or grey boxes, and does a joining player
	land in the menu or in a round. Every one of those has been a bug that took
	twenty minutes to notice.
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local WeaponConfig = require(Shared.Config.WeaponConfig)
-- Requiring Remotes is what creates ReplicatedStorage.FadingLightNet. It has to
-- happen before any client gets far enough to WaitForChild it, so it is first.
local Remotes = require(Shared.Net.Remotes)

local BAR = string.rep("=", 72)
local RULE = "  " .. string.rep("-", 68)

-- Read by RigUtil.makeDebris and by every service that reparents a body, so the
-- names here are a contract, not a preference.
local COLLISION_GROUPS = { "Survivor", "Infected", "Debris", "Gib", "TurretSeat" }

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

	--[[
		The turret's gunner seat, which only a survivor may touch.

		A Roblox Seat seats ANY Humanoid that touches it, and the thing most likely
		to walk over a turret's seat is a zombie attacking the turret. One would
		sit down in the gun and stop being part of the fight.

		The Turret module ejects anything that is not a survivor, so this is not
		the only guard — but an eject is a repair and this is a prevention: a body
		that never generates the touch never has to be thrown back out, and cannot
		stutter in and out of the seat while it is standing on it.

		Debris and gibs too. A severed arm landing on the seat is not a gunner.
	]]
	{ "TurretSeat", "Infected", false },
	{ "TurretSeat", "Debris", false },
	{ "TurretSeat", "Gib", false },
	{ "TurretSeat", "TurretSeat", false },
}

--[[
	Every server service, in a readable dependency-ish order.

	The Registry means this order cannot break anything — nothing resolves
	another service until it is called. It is ordered for humans, and because the
	init/start passes run in this same order.

	The round lifecycle goes first. Matchmaking decides whether this server is a
	lobby or a round and where a joining player lands; RoundService owns the wave
	clock that the Director, the atmosphere and the whole HUD read off. Putting
	them at the top says which way the dependencies point, even though the
	Registry means nothing enforces it.

	Atmosphere goes last because it is downstream of everything: it interpolates
	the light level from how far through the round RoundService says we are, so
	it has nothing to say until there is a round to be far through.
]]
local MODULES = {
	--[[ Maps first, and "first" means first to START rather than first to have a
     world. MapService:init only adopts stray models and prints an inventory;
     the live map is built by its start(), which is the first call of the start
     phase — so nothing below this line can read the world during load or during
     init, whatever order it sits in. What the position actually buys is that
     when the world DOES appear, it appears before any other start() runs. ]]
	"Level/MapService",
	"Round/MapVoteService",
	"Round/RoundService",
	--[[ After RoundService, whose roundEnded signal it subscribes to and whose
	     phase attributes decide whether buying is open. Before the services that
	     read the requisition switches — they read them off Workspace at the
	     moment they matter, so only the CLEAR has to have happened first. ]]
	"Round/RequisitionService",
	"Round/VersusService",
	"Round/MatchmakingService",
	-- After it: LobbyService asks MatchmakingService for the browser rows rather
	-- than keeping a second copy of the joinability rule.
	"Round/LobbyService",
	--[[ After RoundService, whose clock it holds, and it reaches the Director and
	     InfectedService by registry name at call time rather than at load, so it
	     does not need to be below either. ]]
	"Round/PauseService",

	"Audio/AudioService",
	"Assets/PlaceholderFactory",
	-- Populates ReplicatedStorage.Assets.Ammo, and only where it is empty: a
	-- hand-made casing or magazine always wins over a generated one.
	"Assets/AmmoFactory",
	"Level/LevelService",
	"Level/AmmoCrateService",
	--[[ After LevelService, whose restock the vault reward calls, and after
	     MapService, whose loaded map it searches for props. It arms itself off
	     the round-state attribute rather than being driven by anything here. ]]
	"Level/PuzzleService",
	--[[ After MapService for the same reason the puzzle is: it scans the loaded
	     map. Before InfectedService, whose brains ask it what is in their way —
	     ordering only for tidiness there, since the lookup is by registry name at
	     call time rather than at load. ]]
	"Level/BarricadeService",
	--[[ Before anything that reads what a player owns. ProfileService is the only
	     thing in the game that persists, and a purchase or a spawn that happened
	     before it finished loading would be made against an empty profile. ]]
	"Economy/ProfileService",
	--[[ AFTER Round/VersusService, and that is load-bearing rather than tidy.

	     Both of these pay on RoundService.roundEnded, and in Versus what a player
	     is owed depends on which team they were on — which VersusService records
	     in its own roundEnded handler, before it swaps the roles for the next
	     half. Signal handlers fire in connection order and connection order is
	     this list, so Versus writes the answer before either of these reads it.
	     Move either one above Versus and half the server gets paid for losing.
	     See VersusService.wonLastRound. ]]
	"Economy/EconomyService",
	-- Reads what ProfileService loaded and what StatsService counted; registers
	-- before either is asked for anything, and only listens once started.
	"Economy/ProgressionService",
	--[[ After ProfileService but beholden to none of it: pass ownership is asked
	     of Roblox and cached in memory, never written to a profile. ]]
	"Economy/PassService",
	--[[ After ProfileService, whose redeemed set is what makes a code exclusive. ]]
	"Economy/CodeService",
	--[[ After ProfileService, whose ability set and slot list it reads and writes,
	     and after ProgressionService for tidiness rather than need. Abilities are
	     bought with Dollars through ProfileService's own spend, so this does not
	     go near EconomyService. ]]
	"Abilities/AbilityService",
	"Survivors/LoadoutService",
	"Survivors/SurvivorService",
	"Survivors/InventoryService",
	-- Both listen to InventoryService's signals, so they load after it. MapItemService
	-- owns the spawn points; CarryVisualService owns what ends up on a back.
	"Level/MapItemService",
	--[[ After SurvivorService, whose state it reads and whose ledgeHang it calls,
	     and after MapService, whose map it measures. ]]
	"Level/LedgeService",
	"Survivors/CarryVisualService",
	"Combat/GoreService",
	"Combat/DamageService",
	"Combat/BallisticsService",
	--[[ Read by BallisticsService when a pogo weapon's shot lands. Guarded there,
	     so a missing PogoService costs the launch and never the shot. ]]
	"Combat/PogoService",
	"Combat/MeleeService",
	"Combat/ProjectileService",
	"Infected/InfectedService",
	"Director/ItemPlacer",
	-- Rolled before the Director asks it anything.
	"Director/DirectorTemperament",
	"Director/DirectorService",
	-- Stats listens to signals the combat services own, so it loads after them.
	"Round/StatsService",
	"Level/AtmosphereService",
	--[[ Last of the level services, and after every system it borrows: the sky it
	     asks for a grade, the Director it asks for a horde, ItemPlacer for a drop,
	     RoundService for the clock and its voice. It reaches all of them by
	     registry name at call time, so this ordering is for tidiness rather than
	     need — but a director that loaded first would spend the first round warning
	     about services that were about to exist. ]]
	"Events/RandomEventDirector",
}

-- Matchmaking is the one module the bootstrap itself changes behaviour around,
-- so its path is named rather than spelled out at the two call sites.
local MATCHMAKING_PATH = "Round/MatchmakingService"

-- Modules slower than this get called out by name in the banner. Boot cost that
-- nobody can see is boot cost nobody fixes.
local SLOW_MODULE_MS = 8

-- RequestInitialState is identical for every caller, so one shared snapshot
-- serves a whole team joining at once and a client spamming the remote costs
-- nothing but a table read.
local STATE_CACHE_TIME = 0.25

-- The folder PlaceholderFactory looks in, surveyed here before it runs so the
-- banner reports what the USER supplied rather than what the factory then
-- published alongside it.
local ASSETS_FOLDER = "Assets"

--[[ FL_WavePhase between rounds. RoundService and WaveController each declare
     this string set privately ("Prep" | "Active" | "Breather" | "Over", per
     Attributes.Game.WavePhase); there is no shared enum to borrow, and adding
     one is not this file's call. "Over" is what the client tests for to decide
     the wave block is not worth drawing. ]]
local IDLE_WAVE_PHASE = "Over"

type LoadedModule = {
	path: string,
	names: { string },
	service: any,
}

local loaded: { LoadedModule } = {}

-- Path -> the phase that broke it. A service whose module threw, or whose init
-- or start threw, is not safe to hand players to no matter what it managed to
-- register on the way down, and the banner has to name it.
local failures: { [string]: string } = {}
local failureOrder: { string } = {}

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

local function noteFailure(path: string, phase: string)
	if not failures[path] then
		table.insert(failureOrder, path)
	end
	-- The first failure is the interesting one: a module that failed to load
	-- cannot then fail init, so a later phase overwriting it would only ever
	-- report the symptom.
	failures[path] = failures[path] or phase
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

	The round fields matter more here than the older ones. WaveController divides
	by a phase duration and renders a countdown off FL_WaveEndsAt on its very
	first frame; nil there is an arithmetic error in a RenderStepped loop, which
	is a black HUD rather than a warning. Zeroed stamps with the phase set to
	"Over" read as "there is no round yet", which is exactly true at this point.
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

		[Attributes.Game.Mode] = GameModeConfig.DefaultMode,
		[Attributes.Game.WaveIndex] = 0,
		[Attributes.Game.WavePhase] = IDLE_WAVE_PHASE,
		[Attributes.Game.WaveEndsAt] = 0,
		[Attributes.Game.RoundEndsAt] = 0,
		[Attributes.Game.Difficulty] = DirectorConfig.DefaultDifficulty,
	}
	for name, value in defaults do
		if Workspace:GetAttribute(name) == nil then
			Workspace:SetAttribute(name, value)
		end
	end
end

-- ── asset survey ────────────────────────────────────────────────────────────
-- Run BEFORE any module loads. PlaceholderFactory publishes some of its own
-- grey-box output into ReplicatedStorage.Assets, so counting after it has run
-- would report the factory's work back to the user as their own models.

--[[ How many models the user supplied under a category for the first of `names`
     that exists: a Model or a Tool is one, a Folder of variants is however many
     it holds. Both storage roots and the name priority order mirror what
     PlaceholderFactory itself looks for.

     THIS RUNS BEFORE THE FACTORY DOES, which is the thing to remember when the
     two lines disagree. It is a survey of what is in the folders, taken before
     any module has loaded, so that a place whose factory failed outright still
     gets an honest answer. The factory's own line reports what the game ENDED UP
     with, which is the more useful number when both exist. ]]
local function suppliedModels(category: string, names: { string }): number
	for _, name in names do
		for _, root in { ReplicatedStorage, ServerStorage } do
			local assets = root:FindFirstChild(ASSETS_FOLDER)
			local folder = assets and assets:FindFirstChild(category)
			local entry = folder and folder:FindFirstChild(name)
			if entry then
				--[[ A Tool counts. PlaceholderFactory accepts "a Model or a TOOL"
				     because Roblox hands you a weapon as a Tool and that is what
				     most supplied props are; counting only Models here is what
				     made this line disagree with the factory's four lines above
				     it about whether an asset exists. ]]
				if entry:IsA("Model") or entry:IsA("Tool") then
					return 1
				end
				if entry:IsA("Folder") then
					local count = 0
					for _, child in entry:GetChildren() do
						if child:IsA("Model") or child:IsA("Tool") then
							count += 1
						end
					end
					if count > 0 then
						return count
					end
				end
			end
		end
	end
	return 0
end

--[[ One banner line answering "is this my game or a grey box?". Somebody who
     has just dropped a folder of models into the place has no other way to find
     out whether the names matched, and a silhouette test at runtime is a slow,
     confusing way to learn that a folder is called "Weapon". ]]
local function surveyAssets(): string
	local weapons, viewmodels, weaponTotal = 0, 0, 0
	for weaponId, definition in WeaponConfig.all() do
		weaponTotal += 1
		-- modelName first: the asset folder is named for the real gun, and the
		-- enum id is only a fallback for anyone who named theirs in code style.
		local names = { definition.modelName, weaponId }
		if suppliedModels("Weapons", names) > 0 then
			weapons += 1
		end
		--[[ A first-person model falls back to the WORLD model — see the
		     "ONE MODEL, THREE PLACES" note in PlaceholderFactory. Counting only
		     literal Viewmodels entries reported 15 of 37 while the factory,
		     four lines earlier in the same log, reported 37 of 37. Both numbers
		     were true and the pair of them was useless. ]]
		if suppliedModels("Viewmodels", names) > 0 or suppliedModels("Weapons", names) > 0 then
			viewmodels += 1
		end
	end

	local kinds, kindTotal, variants = 0, 0, 0
	for kind in InfectedConfig.all() do
		kindTotal += 1
		local found = suppliedModels("Infected", { kind })
		if found > 0 then
			kinds += 1
			variants += found
		end
	end

	if weapons + viewmodels + kinds == 0 then
		return "GREY-BOX — nothing under Assets/; every rig, gun and viewmodel is procedural"
	end

	local label = if weapons == weaponTotal
			and viewmodels == weaponTotal
			and kinds == kindTotal
		then "YOUR MODELS"
		else "PARTIAL — the rest is grey-boxed"
	return string.format(
		"%s · infected %d/%d kinds (%d rigs) · weapons %d/%d · viewmodels %d/%d",
		label,
		kinds,
		kindTotal,
		variants,
		weapons,
		weaponTotal,
		viewmodels,
		weaponTotal
	)
end

-- ── module loading ──────────────────────────────────────────────────────────

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
		noteFailure(path, "missing")
		return 0
	end

	local before = registeredNameSet()
	local started = os.clock()
	local ok, result = protect(require, moduleScript)
	local elapsed = (os.clock() - started) * 1000

	if not ok then
		report("module load", path, result)
		noteFailure(path, "load")
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
		--[[ A module whose earlier phase threw has nothing to start. This ran
		     start() on half-built objects, which is how one broken init became a
		     second, less legible error in a later phase — and this file already
		     knows the shape of that problem: matchmakingService() refuses to hand
		     a player to a service whose start() failed, for exactly this reason.
		     The banner has already reported it; running more of it adds noise,
		     not recovery. ]]
		if failures[entry.path] then
			continue
		end
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
			noteFailure(entry.path, phase)
		end
	end
	return ran, failed
end

--[[ MatchmakingService, but only when it is actually fit to receive a player.
     Registered-but-broken is the dangerous case: a service whose start() threw
     never connected its RequestMode listener, so a player handed to it would sit
     in a menu whose only button does nothing. That is worse than no menu. ]]
local function matchmakingService(): any?
	if failures[MATCHMAKING_PATH] then
		return nil
	end
	return Registry.find("MatchmakingService")
end

-- ── initial state handshake ─────────────────────────────────────────────────
-- Installed before any module loads. The remote instances exist from the moment
-- Remotes was required at the top of this file, so a client that gets there
-- first must find a callback attached rather than an invoke that throws.

local cachedState: { [string]: any }? = nil
local cachedAt = 0
local reportedStateFailure = false

--[[
	The difficulty in force, mirrored into its attribute on the way past.

	DirectorService owns the value and is the only thing that can change it, but
	it publishes no attribute for it — and Attributes.Game.Difficulty exists in
	the contract with no writer. This is the one place that already asks, so it
	is the cheapest honest place to keep the attribute current: a client reading
	FL_Difficulty then sees what the damage code is using rather than the boot
	default. Never a loop; the payload cache already bounds how often it runs.
]]
local function currentDifficulty(): string
	local published = Attributes.get(Workspace, Attributes.Game.Difficulty, DirectorConfig.DefaultDifficulty)

	local director = Registry.find("DirectorService")
	if director and typeof(director.getDifficulty) == "function" then
		local ok, name = protect(director.getDifficulty, director)
		if ok and typeof(name) == "string" and name ~= "" then
			if name ~= published then
				Workspace:SetAttribute(Attributes.Game.Difficulty, name)
			end
			return name
		end
	end
	return published
end

--[[ The lobby has no attribute: MatchmakingService owns it in memory and pushes
     LobbyStateChanged when it moves. Somebody who joins between two broadcasts
     would otherwise get a main menu insisting the server is an empty lobby while
     a round is running, so the snapshot carries it. Optional and protected — the
     menu already handles this table being absent. ]]
local function lobbySnapshot(): { [string]: any }?
	local matchmaking = matchmakingService()
	if not matchmaking or typeof(matchmaking.getLobbyState) ~= "function" then
		return nil
	end
	local ok, state = protect(matchmaking.getLobbyState, matchmaking)
	if ok and typeof(state) == "table" then
		return state
	end
	return nil
end

--[[
	Everything a joining client needs to draw a HUD before the first event
	arrives. Built from attributes rather than by calling into services:
	attribute reads cannot yield and cannot throw, which is exactly the property
	a RemoteFunction callback needs.

	The two *EndsAt fields are absolute server-time stamps, and `serverTime` is
	sampled in the same breath, so a client can correct for its own clock offset
	once and then render every countdown locally with no further traffic.
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
		mode = Attributes.get(Workspace, Attributes.Game.Mode, GameModeConfig.DefaultMode),
		waveIndex = Attributes.get(Workspace, Attributes.Game.WaveIndex, 0),
		wavePhase = Attributes.get(Workspace, Attributes.Game.WavePhase, IDLE_WAVE_PHASE),
		waveEndsAt = Attributes.get(Workspace, Attributes.Game.WaveEndsAt, 0),
		roundEndsAt = Attributes.get(Workspace, Attributes.Game.RoundEndsAt, 0),
		difficulty = currentDifficulty(),
		maxSurvivors = GameConfig.MaxSurvivors,
		serverTime = Workspace:GetServerTimeNow(),
		survivors = roster,
		lobby = lobbySnapshot(),
	}
end

--[[
	A RemoteFunction is the one place a client can make the server do work on the
	server's own thread. This callback therefore never yields, never trusts an
	argument (it takes none), and can only ever cost a cached table read inside
	the throttle window. If the build ever throws, the client still gets a
	well-formed lobby payload rather than an error that surfaces as a broken HUD.
]]
Remotes.Function.RequestInitialState.OnServerInvoke = function(player: Player)
	--[[ This is also the "my client has booted" signal, and the only one there
	     is: the client invokes it once, at the end of its own two-phase boot.
	     SurvivorService holds a joining character still until it arrives — see
	     the clientReady note there for the console fall-through this fixes.

	     Before the cache check, deliberately. The cached-state early return is
	     about not rebuilding a payload; it must not swallow the fact that a
	     different player has just finished loading. ]]
	local survivors = Registry.find("SurvivorService")
	if survivors and typeof(survivors.markClientReady) == "function" then
		local ok, err = protect(survivors.markClientReady, survivors, player)
		if not ok then
			report("markClientReady", tostring(player), err)
		end
	end

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
			mode = GameModeConfig.DefaultMode,
			waveIndex = 0,
			wavePhase = IDLE_WAVE_PHASE,
			waveEndsAt = 0,
			roundEndsAt = 0,
			difficulty = DirectorConfig.DefaultDifficulty,
			maxSurvivors = GameConfig.MaxSurvivors,
			serverTime = Workspace:GetServerTimeNow(),
			survivors = {},
			-- No `lobby`: if the snapshot build threw, the matchmaking getter is
			-- the likeliest culprit. The menu already draws itself without one.
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

local assetSummary = surveyAssets()

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

-- Decided once, here, so the banner and the join handler can never disagree
-- about where a player is going to end up.
local matchmakingReady = matchmakingService() ~= nil

-- The line that explains why nobody spawned. Without matchmaking this bootstrap
-- is the thing putting players into the world, and that is a fallback rather
-- than the design, so it says so in capitals.
local joiningSummary = if matchmakingReady
	then "players land in the MAIN MENU, MatchmakingService spawns them"
	else "NO MATCHMAKING — spawning every player straight into the map (degraded)"

--[[ One column layout for the whole banner. Fixed widths so the timings line up
     under each other: a boot cost that has doubled has to be visible by shape,
     without reading the numbers. ]]
local function line(label: string, detail: string, milliseconds: number?)
	if milliseconds then
		print(string.format("  %-11s %-42s %7.1f ms", label, detail, milliseconds))
	else
		print(string.format("  %-11s %s", label, detail))
	end
end

print(BAR)
print(
	string.format(
		"  FADING LIGHT — build %s — server up in %.0f ms",
		tostring(GameConfig.BuildStamp),
		(os.clock() - bootStarted) * 1000
	)
)
print(RULE)
line("collision", string.format("%d groups, %d rules", #COLLISION_GROUPS, #COLLISION_RULES), collisionMs)
line("modules", string.format("%d of %d loaded", #loaded, #MODULES), loadMs)
line("init", string.format("%d ran, %d failed", initRan, initFailed), initMs)
line("start", string.format("%d ran, %d failed", startRan, startFailed), startMs)
line("assets", assetSummary)
line("joining", joiningSummary)
if #slowModules > 0 then
	line("slow", table.concat(slowModules, ", "))
end
line("registry", table.concat(Registry.getRegisteredNames(), ", "))

if #failureOrder > 0 then
	print(RULE)
	print(string.format("  %d MODULE(S) BROKEN — tracebacks are above:", #failureOrder))
	for _, path in failureOrder do
		print(string.format("    %-34s failed at %s", path, failures[path]))
	end
end
print(BAR)

-- ── where a joining player goes ─────────────────────────────────────────────

local handledPlayers: { [Player]: boolean } = {}
local warnedNoMatchmaking = false

--[[
	With a main menu in front of the game, spawning a player the moment they
	connect is wrong: it drops them into whatever wave this server happens to be
	on, with no say in it and no idea what they joined. MatchmakingService owns
	that decision — it holds them in the menu, and spawns them itself when they
	pick a mode, when the lobby countdown fires, or when they take a
	join-in-progress slot.

	The direct spawn survives as the fallback for exactly one case: matchmaking
	is not there, or came up broken. A developer whose Round/ folder is mid-
	rewrite still gets a character and a gun instead of an empty grey screen,
	which is the difference between one broken system and a broken game.
]]
local function onPlayerAdded(player: Player)
	if handledPlayers[player] then
		return
	end
	handledPlayers[player] = true

	local matchmaking = matchmakingService()
	if matchmaking then
		--[[ Optional hook, in the same spirit as onPlayerRemoving below.
		     MatchmakingService watches PlayerAdded itself, so this only calls a
		     method if that service chose to declare one and the bootstrap never
		     forces API onto a neighbour. Either branch ends the same way: no
		     spawn from here, because the menu is the player's first screen. ]]
		if typeof(matchmaking.onPlayerAdded) == "function" then
			local ok, err = protect(matchmaking.onPlayerAdded, matchmaking, player)
			if not ok then
				report("MatchmakingService:onPlayerAdded", player.Name, err)
			end
		end
		return
	end

	local survivors = Registry.find("SurvivorService")
	if not survivors then
		warn(
			string.format(
				"[Fading Light] neither MatchmakingService nor SurvivorService is usable, so %s has "
					.. "no menu and no character. Fix the load failures above.",
				player.Name
			)
		)
		return
	end

	if not warnedNoMatchmaking then
		warnedNoMatchmaking = true
		warn(
			"[Fading Light] MatchmakingService is unavailable — every player is being spawned straight "
				.. "into the map with no menu and no mode choice. This is the degraded path."
		)
	end

	local ok, err = protect(survivors.spawnSurvivor, survivors, player)
	if not ok then
		report("spawnSurvivor", player.Name, err)
	end
end

local function onPlayerRemoving(player: Player)
	handledPlayers[player] = nil

	-- Optional hooks. Both services own their own player lifetime and are
	-- expected to watch PlayerRemoving themselves; this only calls a method if
	-- one of them chose to declare it, so the bootstrap never forces API onto a
	-- neighbour.
	for _, name in { "SurvivorService", "MatchmakingService" } do
		local service = Registry.find(name)
		if service and typeof(service.onPlayerRemoving) == "function" then
			local ok, err = protect(service.onPlayerRemoving, service, player)
			if not ok then
				report(name .. ":onPlayerRemoving", player.Name, err)
			end
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
