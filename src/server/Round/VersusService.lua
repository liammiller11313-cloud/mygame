--!nonstrict
--[[
	VersusService — half the server plays the horde.

	The mode is one match of two halves. Each half is a full seventeen-minute
	round on RoundService's clock: one side holds out against the same fifteen
	waves the other side is about to face, and then the teams swap and do it
	again. Nothing here owns a wave, a timer or a spawn budget — RoundService
	owns the clock in both modes and the Director still owns what arrives inside
	each wave. This file owns exactly three things: who is on which side, what an
	infected player's body is, and what the halves were worth.

	── SCORE IS PROGRESS, NOT KILLS ────────────────────────────────────────────
	Waves cleared, seconds survived, and survivors still standing at the end.
	Scoring the infected side by kills would make it a different game to play
	(hunt the weakest player) than it is to defend against, and the two halves
	would stop being comparable. Measuring both sides against the same seven
	waves is the entire reason the mode is fair, and ScorePerSurvivorAlive is
	what stops the survivor half degenerating into four people playing solo.

	── AN INFECTED PLAYER IS TWO OBJECTS ───────────────────────────────────────
	This is the important structural decision in the file, so it is worth being
	explicit about why.

	The player never drives the infected rig directly, because a Model that is a
	Player's Character answers Players:GetPlayerFromCharacter, and DamageService,
	MeleeService, GoreService and RigUtil all decide "survivor or infected?" with
	exactly that question. Handing a player the Hunter rig would make survivors'
	bullets route into SurvivorService:damage for a player with no survivor
	record — a Hunter nobody can kill.

	So an infected player gets a GHOST: an invisible, unshootable
	(CanQuery = false) rig in the Debris collision group, which is the player's
	Character and therefore drives itself with Roblox's own control and camera
	code at no networking cost. The infected body is a normal InfectedService
	spawn that nothing owns but this file, anchored and pinned to the ghost's
	CFrame every frame. Survivors shoot the body and it takes damage exactly like
	an AI one; the player steers the ghost and sees through it.

	── THE ABILITY IS THEIRS, THE ABILITY CODE IS NOT ──────────────────────────
	Specials/Hunter, Jockey, Charger and Tank already contain the pounce, the
	ride, the charge and the swing, tuned and tested. Reimplementing any of that
	here would give the mode a second, worse Hunter. Instead the module is taken
	off InfectedService's record while the player is walking around — no module,
	no AI, no ability firing itself — and put back for a couple of seconds when
	the player presses jump. The module's own stalk phase then commits the moment
	its conditions are met, exactly as it does for the AI.

	Two observable edges drive the whole hand-off, because the modules expose
	only onSpawn/onUpdate/onDeath and nothing else:

	  committed : humanoid.WalkSpeed drops to 0. All four modules root the body
	              at the instant they commit (beginCrouch, beginGather,
	              beginWindUp, the Tank's swing and rock).
	  finished  : brain:isPaused() goes false. All four hand the body back
	              through a resumeBrain() at the end of every phase.

	Both edges are inferences, and they are inferences because the split between
	"decide to use the ability" and "execute the ability" lives inside one
	unexported stepStalk per module. The clean version of this file is fifteen
	lines shorter and needs one exported `tryAbility(model, brain): boolean` on
	each of the four modules.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)

-- Not a service: a plain placement module, required directly the same way
-- DirectorService requires it and InfectedService requires InfectedBrain.
local SpawnPlacement = require(script.Parent.Parent.Director.SpawnPlacement)

local VERSUS = GameModeConfig.Versus
local SPAWNING = DirectorConfig.Spawning

--[[ The two persistent teams. Enums.Team names the ROLE a side is currently
     playing, which swaps at half time; these name the side itself, which does
     not, and they are what the scores are keyed by. ]]
local SIDE_A = "A"
local SIDE_B = "B"

--[[ Tags and attributes on a ghost model, so an infected client can draw its
     teammates and their intended spawn spots without this service streaming
     positions over a remote every frame. The ghost model is a replicated
     Instance; its position IS the intended spawn spot. ]]
local GHOST_TAG = "FL_VersusGhost"
local GHOST_OWNER_ATTRIBUTE = "FL_GhostOwner" -- number, UserId
local GHOST_KIND_ATTRIBUTE = "FL_GhostKind" -- string, last requested kind or ""
local GHOST_READY_ATTRIBUTE = "FL_GhostReadyAt" -- number, server time it may materialise

--[[ Written on a player-controlled infected body so outlines, the kill feed and
     the HUD can tell a played Hunter from a Director one. Not in
     Shared/Net/Attributes yet; see the report. ]]
local CONTROLLER_ATTRIBUTE = "FL_Controller" -- number, UserId of the player driving it

--[[ A ghost moves at twice a survivor's sprint. Derived rather than invented:
     the point of the ghost is to cross ground the survivors have to walk, and
     tying it to the survivor's own top speed keeps that true if the survivor
     numbers ever move. ]]
local GHOST_SPEED = GameConfig.Survivor.SprintSpeed * 2
local GHOST_JUMP_POWER = 90

--[[ How far off the floor a ghost floats. High enough to see over cover and
     pick a rooftop, low enough that the drop to the ground is still the spot
     you were looking at. ]]
local GHOST_HOVER = 7

--[[ Ghost and body geometry. The ghost is what collides with the level, so it
     is sized from the body's own bounding box: a Tank must not be able to walk
     its ghost through a doorway the Tank itself cannot fit through. ]]
local GHOST_MIN_WIDTH = 2
local GHOST_ROOT_HEIGHT = 2
local GHOST_HEAD_SIZE = Vector3.new(1, 1, 1)
local GHOST_HEALTH = 1000 -- never damaged; a number only so the Humanoid is alive

--[[ How long an armed ability waits for its own module to commit. A Hunter that
     is out of pounce range and a Tank that is out of reach both simply do
     nothing, and the player has to be given movement back rather than left
     standing in a wind-up that will never fire. ]]
local ABILITY_ARM_WINDOW = 2.0

--[[ Backstop only. If a module ever commits and never hands the body back, the
     player would be a spectator inside their own zombie forever. ]]
local ABILITY_MAX_DURATION = 30

-- Anti-spam on the two client entry points. Not balance; rate limiting.
local REQUEST_INTERVAL = 0.25
local OPTIONS_INTERVAL = 0.5

--[[ 4Hz for everything that is not the CFrame pin: readiness deadlines, role
     reconciliation, spawn-option broadcasts. All of it is deadline comparisons
     against a server clock the client is already counting down from. ]]
local TICK_INTERVAL = 0.25

-- How far up and down the ground search looks under a hovering ghost.
local GROUND_SEARCH_HEIGHT = 80
local SIGHT_COS = math.cos(math.rad(SPAWNING.SightCheckFovDegrees * 0.5))

local VersusService = {}

--[[ (player: Player, role: string, side: string) — fired on every assignment
     and every swap, alongside the VersusTeamChanged remote. ]]
--[[ (scores: {[string]: number}, half: number) — a half was scored. ]]
--[[ (scores: {[string]: number}, winner: string?) — both halves are done. ]]

local serviceTrove = Trove.new()

--[[ Who won the half that just finished, by player. Written once in _scoreHalf
     and read by the payout services; see wonLastRound. Weak-keyed so a player
     who leaves during the scoreboard does not pin their Player instance. ]]
local lastRoundWon: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- ── match state ─────────────────────────────────────────────────────────────
local active = false -- a versus match is being managed
local wanted = false -- startVersus was asked for and is waiting on players
local half = 0 -- 0 before the first half, then 1 or 2
local converted = false -- the running round has had its infected side taken out
local halfStartedAt = 0 -- absolute server time this half's round opened
local scores: { [string]: number } = { [SIDE_A] = 0, [SIDE_B] = 0 }
local wavesCredited = 0
local generation = 0 -- invalidates a pending half-start from an older match

--[[ side -> the role it is playing this half. Everything else reads through
     this, so a swap is two writes. ]]
local roleOf: { [string]: string } = {
	[SIDE_A] = Enums.Team.Survivor,
	[SIDE_B] = Enums.Team.Infected,
}

-- ── per-player state ────────────────────────────────────────────────────────
local slots: { [Player]: any } = {}
local order: { Player } = {} -- join order; the Tank token walks it
local tankCursor = 1

local slowAccumulator = 0
local random = Random.new()

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[VersusService] " .. message)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

--[[ A CFrame with the yaw of `look` and none of its pitch or roll. Used every
     time the ghost and the body copy each other: a body that came out of a
     pounce is tilted, and tipping a Humanoid's root over tips the camera with
     it and leaves the balance controller fighting the write. ]]
local function uprightAt(position: Vector3, look: Vector3): CFrame
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, position + flat.Unit)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Sides
-- ════════════════════════════════════════════════════════════════════════════

local function countSide(side: string): number
	local total = 0
	for _, slot in slots do
		if slot.side == side then
			total += 1
		end
	end
	return total
end

local function roleFor(player: Player): string
	local slot = slots[player]
	if not slot then
		return Enums.Team.Survivor
	end
	return roleOf[slot.side]
end

local function announce(player: Player, slot: any)
	local role = roleOf[slot.side]
	Remotes.Event.VersusTeamChanged:FireAllClients({
		player = player,
		team = role,
		side = slot.side,
		kind = slot.kind,
		model = slot.body,
	})
end

--[[
	Puts a player on a side.

	The tie-break is deliberate rather than arbitrary: with the sides level, a
	joiner goes to whichever one is currently playing infected. Dropping somebody
	into a survivor team that is four minutes into wave 4 with no weapon and no
	idea where the team is, is a worse first thirty seconds than dropping them
	into a respawn queue that was going to hand them a Hunter anyway.
]]
local function assign(player: Player): any
	local existing = slots[player]
	if existing then
		return existing
	end

	local countA, countB = countSide(SIDE_A), countSide(SIDE_B)
	local side: string
	if countA < countB then
		side = SIDE_A
	elseif countB < countA then
		side = SIDE_B
	elseif roleOf[SIDE_A] == Enums.Team.Infected then
		side = SIDE_A
	else
		side = SIDE_B
	end

	local slot = {
		player = player,
		side = side,

		ghost = nil :: Model?,
		ghostRoot = nil :: BasePart?,
		ghostHumanoid = nil :: Humanoid?,
		ghostTrove = nil :: any,

		body = nil :: Model?,
		bodyRoot = nil :: BasePart?,
		bodyHumanoid = nil :: Humanoid?,
		brain = nil :: any,
		special = nil :: any, -- the module taken off InfectedService's record
		silent = nil :: any, -- that module's onDeath and nothing else
		record = nil :: any,
		kind = nil :: string?,
		pinOffset = 0,
		pinUp = Vector3.zero,

		armedAt = 0,
		committedAt = 0,
		readyAt = 0,
		spawning = false, -- a materialise request is resolving
		spawningSurvivor = false, -- a LoadCharacter is in flight

		lastRequestAt = 0,
		lastOptionsAt = 0,
	}

	slots[player] = slot
	table.insert(order, player)
	announce(player, slot)
	return slot
end

--[[ Never leave a side empty. A one-sided versus round is a Classic round with
     half the players watching, and the swap that would fix it is nine minutes
     away. ]]
local function rebalance()
	if #order < 2 then
		return
	end
	local countA, countB = countSide(SIDE_A), countSide(SIDE_B)
	if countA > 0 and countB > 0 then
		return
	end

	local empty = if countA == 0 then SIDE_A else SIDE_B
	local full = if empty == SIDE_A then SIDE_B else SIDE_A

	-- The most recently added player moves: whoever has been on the full side
	-- longest keeps the half they have been playing.
	for index = #order, 1, -1 do
		local player = order[index]
		local slot = slots[player]
		if slot and slot.side == full then
			slot.side = empty
			announce(player, slot)
			return
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Leaving SurvivorService behind
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Takes a player out of SurvivorService entirely for the half they spend
	infected.

	SurvivorService keys everything off player.Character, and an infected
	player's Character is a ghost. Left with a live record, its CharacterAdded
	hook gives that ghost a survivor's 100 max health, puts it in the Survivor
	collision group, zeroes its WalkSpeed (a Spectating survivor does not move)
	and registers its body as a defibrillator target. Worse, the player keeps
	counting as a survivor in getAliveSurvivors — the Director would spawn at
	them, and a team wipe would never be a team wipe.

	There is no public "this player is not a survivor right now", so the record
	is rebuilt — which publishes FL_State = Spectating, so the HUD stops drawing
	them as a living teammate — and then dropped. Both calls are guarded: if
	SurvivorService ever renames them, the ghost still works, it is just wearing
	a survivor's properties, and reassertGhost() puts those back every tick.
]]
local function detachFromSurvivors(player: Player)
	local survivors = Registry.find("SurvivorService")
	if not survivors then
		return
	end

	local character = player.Character
	player.Character = nil
	if character and character.Parent then
		character:Destroy()
	end

	if typeof(survivors._destroyRecord) ~= "function" or typeof(survivors._ensureRecord) ~= "function" then
		warnOnce(
			"nodetach",
			"SurvivorService exposes no _destroyRecord/_ensureRecord; infected players stay in the "
				.. "survivor roster and will be counted as living teammates"
		)
		return
	end

	survivors:_destroyRecord(player)
	survivors:_ensureRecord(player)
	survivors:_destroyRecord(player)
end

--[[
	Puts the ghost back if something else spawned a survivor over the top of it.

	RoundService's breather restock respawns every player whose survivor state is
	Dead or Spectating, and an infected player reads as Spectating from the
	outside, so every breather hands them a survivor rig and takes their ghost
	away. The bootstrap's PlayerAdded does the same to a joiner. Neither of those
	files can be edited from here, so the intruder is destroyed and the ghost is
	handed back within a tick. See the report: the real fix is one team check in
	RoundService:_restock.
]]
local function repairGhostCharacter(slot: any)
	local player = slot.player
	local ghost = slot.ghost
	if not ghost or not ghost.Parent or not player.Parent then
		return
	end
	if player.Character == ghost then
		return
	end

	detachFromSurvivors(player)
	player.Character = ghost
end

-- ════════════════════════════════════════════════════════════════════════════
--  The ghost
-- ════════════════════════════════════════════════════════════════════════════

--[[ Both ghost parts are invisible AND CanQuery = false. Invisible alone is not
     enough: a bullet that stops on something nobody can see is the single most
     infuriating bug a shooter can have, and BallisticsService raycasts against
     the world, not against a whitelist. ]]
local function buildGhostPart(name: string, size: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Transparency = 1
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function buildGhost(player: Player, width: number): Model
	local model = Instance.new("Model")
	model.Name = string.format("VersusGhost_%s", player.Name)

	local root = buildGhostPart("HumanoidRootPart", Vector3.new(width, GHOST_ROOT_HEIGHT, width))
	-- The one part that DOES collide, so the ghost walks the level the body will
	-- have to walk. The Debris collision group already means "collides with the
	-- world and with nothing alive", which is exactly a ghost.
	root.CanCollide = true
	root.Parent = model

	local head = buildGhostPart("Head", GHOST_HEAD_SIZE)
	head.CanCollide = false
	head.Massless = true
	head.CFrame = root.CFrame * CFrame.new(0, GHOST_ROOT_HEIGHT * 0.5 + 0.5, 0)
	head.Parent = model

	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = head
	weld.C0 = CFrame.new(0, GHOST_ROOT_HEIGHT * 0.5 + 0.5, 0)
	weld.Parent = root

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = GHOST_HEALTH
	humanoid.Health = GHOST_HEALTH
	humanoid.WalkSpeed = GHOST_SPEED
	humanoid.UseJumpPower = true
	humanoid.JumpPower = GHOST_JUMP_POWER
	humanoid.HipHeight = GHOST_HOVER
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayDistance = 0
	humanoid.NameDisplayDistance = 0
	humanoid.Parent = model

	model.PrimaryPart = root
	pcall(RigUtil.setCollisionGroup, model, "Debris")

	model:SetAttribute(GHOST_OWNER_ATTRIBUTE, player.UserId)
	model:SetAttribute(GHOST_KIND_ATTRIBUTE, "")
	model:SetAttribute(GHOST_READY_ATTRIBUTE, 0)
	CollectionService:AddTag(model, GHOST_TAG)

	return model
end

--[[
	Where a fresh ghost opens its eyes.

	The Director's own placement rules, because a ghost that materialises out of
	thin air ten studs behind the team has already lost the round for its side —
	and because reusing find() means the ghost starts somewhere the body would
	actually have been allowed to spawn.
]]
local function ghostStartCFrame(): CFrame
	local survivors = Registry.find("SurvivorService")
	local characters = if survivors then survivors:getSurvivorCharacters() else {}

	if #characters > 0 then
		local position = SpawnPlacement.find(characters, nil)
		if position then
			return CFrame.new(position + Vector3.new(0, GHOST_HOVER, 0))
		end
	end

	local level = Registry.find("LevelService")
	if level and typeof(level.getSpawnNodes) == "function" then
		local ok, nodes = pcall(level.getSpawnNodes, level)
		if ok and typeof(nodes) == "table" and #nodes > 0 then
			local node = nodes[random:NextInteger(1, #nodes)]
			return node.CFrame + Vector3.new(0, GHOST_HOVER, 0)
		end
	end

	-- Last resort: above the first survivor, which is at least inside the level.
	for _, character in characters do
		local root = RigUtil.getRoot(character)
		if root then
			return CFrame.new(root.Position + Vector3.new(0, GHOST_HOVER + 12, 0))
		end
	end
	return CFrame.new(0, GHOST_HOVER + 8, 0)
end

--[[ Jump is the ability button, and it is the only input this service needs.
     Humanoid.Jump replicates from the owning client for free, so an infected
     player needs no new remote and no client module to pounce. ]]
local function connectAbilityInput(slot: any, humanoid: Humanoid)
	slot.ghostTrove:connect(humanoid.Jumping, function(activeJump: boolean)
		if activeJump then
			VersusService:_requestAbility(slot)
		end
	end)
	-- A hovering Humanoid is in Freefall and will not raise Jumping, but the
	-- control script still writes the property, so this is the path that
	-- actually fires while the ghost is in the air.
	slot.ghostTrove:connect(humanoid:GetPropertyChangedSignal("Jump"), function()
		if humanoid.Jump then
			VersusService:_requestAbility(slot)
		end
	end)
end

--[[ Puts the player back in the sky with a countdown to their next body.
     `delay` is the floor: InfectedGhostTime at the start of a half, and the
     respawn penalty after a death. ]]
function VersusService:_beginGhost(slot: any, delay: number)
	local player = slot.player
	if not player.Parent then
		return
	end

	self:_releaseBody(slot, true)

	if not slot.ghost or not slot.ghost.Parent then
		if slot.ghostTrove then
			slot.ghostTrove:destroy()
		end
		slot.ghostTrove = Trove.new()

		local ghost = buildGhost(player, GHOST_MIN_WIDTH)
		ghost:PivotTo(ghostStartCFrame())
		ghost.Parent = Workspace
		slot.ghostTrove:add(ghost)

		slot.ghost = ghost
		slot.ghostRoot = ghost.PrimaryPart
		slot.ghostHumanoid = ghost:FindFirstChildOfClass("Humanoid")

		detachFromSurvivors(player)
		player.Character = ghost

		if slot.ghostHumanoid then
			connectAbilityInput(slot, slot.ghostHumanoid)
		end
	else
		-- Reused after a death: back to flying shape, wherever they were.
		self:_shapeGhost(slot, nil)
	end

	slot.readyAt = serverNow() + math.max(delay, 0)
	slot.kind = nil
	if slot.ghost then
		slot.ghost:SetAttribute(GHOST_KIND_ATTRIBUTE, "")
		slot.ghost:SetAttribute(GHOST_READY_ATTRIBUTE, slot.readyAt)
	end

	self:_sendSpawnOptions(slot, true)
	announce(player, slot)
end

--[[
	Ghost shape follows the body it is about to become, or none at all.

	`definition` nil means flying: hovering, fast, and the size of nothing in
	particular. With a definition the ghost stands on the floor and takes the
	body's own footprint, because from that moment it is the thing the level
	collides with and a Tank has to be Tank-sized to be stopped by a Tank-sized
	gap.
]]
function VersusService:_shapeGhost(slot: any, definition: any)
	local root, humanoid = slot.ghostRoot, slot.ghostHumanoid
	if not root or not humanoid or not root.Parent then
		return
	end

	if definition then
		local width = math.max(GHOST_MIN_WIDTH * definition.scale, GHOST_MIN_WIDTH)
		root.Size = Vector3.new(width, GHOST_ROOT_HEIGHT, width)
		humanoid.HipHeight = 0
		humanoid.WalkSpeed = definition.runSpeed
		humanoid.JumpPower = definition.jumpPower
	else
		root.Size = Vector3.new(GHOST_MIN_WIDTH, GHOST_ROOT_HEIGHT, GHOST_MIN_WIDTH)
		humanoid.HipHeight = GHOST_HOVER
		humanoid.WalkSpeed = GHOST_SPEED
		humanoid.JumpPower = GHOST_JUMP_POWER
	end
end

--[[ A shove has to answer a played special exactly the way it answers an AI one.
     InfectedService:stagger reaches the paused brain and freezes the BODY, which
     an infected player would never feel, because their movement comes from the
     ghost — so the ghost is what gets frozen. ]]
local function brainStaggered(slot: any): boolean
	local brain = slot.brain
	return brain ~= nil and typeof(brain.isStaggered) == "function" and brain:isStaggered() == true
end

--[[
	Puts back everything a neighbour may have overwritten on the ghost.

	LevelService calls SurvivorService:setSpawnCFrame on PlayerAdded and on every
	placeSurvivors, and that rebuilds the survivor record this file just dropped
	— which re-runs _onCharacterAdded against the ghost. Rather than fight that
	race, the properties that matter are re-asserted here on the slow tick. Each
	one is a guarded compare, four ghosts at 4Hz; a write that changes nothing
	still costs a replication check.
]]
function VersusService:_reassertGhost(slot: any)
	local humanoid = slot.ghostHumanoid
	local root = slot.ghostRoot
	if not humanoid or not root or not root.Parent then
		return
	end

	local definition = if slot.kind then InfectedConfig.get(slot.kind) else nil
	local speed = if definition then definition.runSpeed else GHOST_SPEED
	local jump = if definition then definition.jumpPower else GHOST_JUMP_POWER
	local hip = if definition then 0 else GHOST_HOVER
	if brainStaggered(slot) then
		speed = 0
	end

	-- Zero speed is also the tell that SurvivorService has published a Spectating
	-- survivor's movement lockout onto the ghost. Everything else here is the
	-- same repair.
	if slot.committedAt == 0 and humanoid.WalkSpeed ~= speed then
		humanoid.WalkSpeed = speed
	end
	if humanoid.JumpPower ~= jump then
		humanoid.JumpPower = jump
	end
	if humanoid.HipHeight ~= hip then
		humanoid.HipHeight = hip
	end
	if humanoid.MaxHealth ~= GHOST_HEALTH then
		humanoid.MaxHealth = GHOST_HEALTH
	end
	if humanoid.Health < GHOST_HEALTH then
		humanoid.Health = GHOST_HEALTH
	end
	if root.CollisionGroup ~= "Debris" then
		pcall(RigUtil.setCollisionGroup, slot.ghost, "Debris")
	end
	if root.CanQuery then
		root.CanQuery = false
	end
end

--[[
	Puts the body's own WalkSpeed back after a stagger.

	The brain restores it when a stumble expires — but only from update(), and a
	paused brain never gets there, so a shoved player-infected would sit at zero
	forever. That matters twice over: it is also the value _stepAbility watches
	for, and a body already at zero would read as an ability committing on the
	very frame it was armed.
]]
function VersusService:_reassertBody(slot: any)
	local humanoid = slot.bodyHumanoid
	if not humanoid or not humanoid.Parent then
		return
	end
	if slot.armedAt ~= 0 or slot.committedAt ~= 0 or brainStaggered(slot) then
		return
	end
	local definition = if slot.kind then InfectedConfig.get(slot.kind) else nil
	if definition and humanoid.WalkSpeed ~= definition.runSpeed then
		humanoid.WalkSpeed = definition.runSpeed
	end
end

--[[ Tears the ghost down. Called when a player goes back to the survivor side,
     leaves, or the match ends. ]]
function VersusService:_destroyGhost(slot: any)
	self:_releaseBody(slot, true)

	if slot.ghostTrove then
		slot.ghostTrove:destroy()
		slot.ghostTrove = nil
	end
	if slot.ghost and slot.ghost.Parent then
		slot.ghost:Destroy()
	end
	if slot.player.Character == slot.ghost then
		slot.player.Character = nil
	end

	slot.ghost = nil
	slot.ghostRoot = nil
	slot.ghostHumanoid = nil
	slot.kind = nil
	slot.armedAt = 0
	slot.committedAt = 0
end

-- ════════════════════════════════════════════════════════════════════════════
--  Availability
-- ════════════════════════════════════════════════════════════════════════════

--[[ Whoever currently holds the Tank. TankIsRotated: it passes between infected
     players in turn rather than being picked, so one player cannot spend the
     whole half as the only thing the survivors are afraid of. ]]
local function tankHolder(): Player?
	local infectedPlayers: { Player } = {}
	for _, player in order do
		local slot = slots[player]
		if slot and roleOf[slot.side] == Enums.Team.Infected then
			table.insert(infectedPlayers, player)
		end
	end
	if #infectedPlayers == 0 then
		return nil
	end
	if tankCursor > #infectedPlayers then
		tankCursor = 1
	end
	return infectedPlayers[tankCursor]
end

--[[ The token moves on every materialisation by its holder, whether or not they
     took the Tank. Advancing only on a Tank spawn would let the holder sit on it
     by never picking it, and nobody else could ever be one. ]]
local function passTankToken()
	tankCursor += 1
	local count = 0
	for _, player in order do
		local slot = slots[player]
		if slot and roleOf[slot.side] == Enums.Team.Infected then
			count += 1
		end
	end
	if count == 0 or tankCursor > count then
		tankCursor = 1
	end
end

--[[ How many player-driven bodies of this kind are alive. The AI's own copies
     are counted separately, through InfectedConfig.maxAlive, so a Director Tank
     and a played Tank cannot both exist. ]]
local function playedAlive(kind: string): number
	local total = 0
	for _, slot in slots do
		if slot.kind == kind and slot.body and slot.body.Parent then
			total += 1
		end
	end
	return total
end

function VersusService:getAvailableKinds(player: Player): { string }
	local kinds: { string } = {}
	local slot = slots[player]
	if not slot or roleOf[slot.side] ~= Enums.Team.Infected then
		return kinds
	end

	local infected = Registry.find("InfectedService")
	local holder = tankHolder()

	for _, kind in VERSUS.InfectedPlayableKinds do
		local definition = InfectedConfig.get(kind)
		if not definition then
			continue
		end
		-- The Tank is not picked, it is handed out.
		if kind == Enums.Infected.Tank and VERSUS.TankIsRotated and holder ~= player then
			continue
		end
		if playedAlive(kind) >= VERSUS.InfectedMaxSameKindAlive then
			continue
		end
		-- The roster's own ceiling, so a kind the Director already filled is
		-- never offered and then refused by InfectedService:spawn.
		if infected and infected:getCount(kind) >= definition.maxAlive then
			continue
		end
		table.insert(kinds, kind)
	end

	return kinds
end

--[[ Shorter during the finale: the last wave is where the infected side has to
     be able to keep arriving, or the finale stops being a finale and becomes a
     victory lap. ]]
local function respawnDelay(): number
	local round = Registry.find("RoundService")
	if round and typeof(round.getWaveIndex) == "function" then
		if round:getWaveIndex() >= GameModeConfig.getWaveCount() then
			return VERSUS.InfectedRespawnTimeFinale
		end
	end
	return VERSUS.InfectedRespawnTime
end

--[[ The class picker's whole payload: what may be spawned, when, and where the
     rest of the team is planning to come from. The ghost positions are what
     turns four people spawning at random into an ambush. ]]
function VersusService:_sendSpawnOptions(slot: any, force: boolean?)
	local now = os.clock()
	if not force and now - slot.lastOptionsAt < OPTIONS_INTERVAL then
		return
	end
	slot.lastOptionsAt = now

	local player = slot.player
	if not player.Parent or roleFor(player) ~= Enums.Team.Infected then
		return
	end

	local teammates = {}
	for _, other in order do
		local otherSlot = slots[other]
		if other == player or not otherSlot then
			continue
		end
		if roleOf[otherSlot.side] ~= Enums.Team.Infected then
			continue
		end
		local root = otherSlot.ghostRoot
		table.insert(teammates, {
			userId = other.UserId,
			name = other.DisplayName,
			position = if root and root.Parent then root.Position else nil,
			kind = otherSlot.kind,
			embodied = otherSlot.body ~= nil,
			readyAt = otherSlot.readyAt,
		})
	end

	Remotes.Event.InfectedSpawnOptions:FireClient(player, {
		kinds = self:getAvailableKinds(player),
		respawnAt = slot.readyAt,
		ghostTag = GHOST_TAG,
		teammates = teammates,
	})
end

local function broadcastSpawnOptions()
	for _, player in order do
		local slot = slots[player]
		if slot and roleOf[slot.side] == Enums.Team.Infected and not slot.body then
			VersusService:_sendSpawnOptions(slot)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Materialising
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Is this a legal place for a body to appear?

	The same two rules SpawnPlacement enforces and for the same reason: appearing
	inside somebody's field of view is the one thing that makes a spawn feel like
	a cheat rather than an ambush. The flow window is deliberately NOT applied —
	the player chose this spot with their own eyes, and a rule about how far
	ahead of the team the AI should spawn has nothing to say about that.
]]
local function isLegalSpawn(ground: Vector3): boolean
	local survivors = Registry.find("SurvivorService")
	if not survivors then
		return true
	end
	local characters = survivors:getSurvivorCharacters()
	if #characters == 0 then
		return true
	end

	local ignore = table.clone(characters)
	local infectedFolder = Workspace:FindFirstChild("Infected")
	if infectedFolder then
		table.insert(ignore, infectedFolder)
	end

	local eyeHeight = Vector3.new(0, SPAWNING.SpawnGroundClearance, 0)
	local minimum = SPAWNING.MinDistanceFromSurvivor * SPAWNING.MinDistanceFromSurvivor

	for _, character in characters do
		local root = RigUtil.getRoot(character)
		if not root then
			continue
		end
		local delta = ground - root.Position
		if delta:Dot(delta) < minimum then
			return false
		end

		if SPAWNING.RequireOutOfSight then
			local head = character:FindFirstChild("Head")
			local eyePart = if head and head:IsA("BasePart") then head else root
			local toBody = (ground + eyeHeight) - eyePart.Position
			local distance = toBody.Magnitude
			if distance > 1e-3 and toBody.Unit:Dot(eyePart.CFrame.LookVector) >= SIGHT_COS then
				if RaycastUtil.hasLineOfSight(eyePart.Position, ground + eyeHeight, ignore) then
					return false
				end
			end
		end
	end

	return true
end

--[[ The ground under the ghost, which is the spot the player picked. Falls back
     to a Director-found point when that spot is illegal, because refusing the
     spawn outright would leave a dead player staring at a button that does
     nothing and no way to find out why.

     `kind` is passed through to the fallback and that is not optional. Without
     it SpawnPlacement reserves room for the LARGEST body in the game, which is
     the Metallic at seventeen studs — so a player asking to be a Jockey was
     asking the map for a hole a quarter taller than a Tank, and on any map that
     had none, the button did exactly the nothing this comment promises it
     would not. ]]
local function resolveSpawnPosition(slot: any, kind: string): Vector3?
	local root = slot.ghostRoot
	if root and root.Parent then
		local ignore = { slot.ghost }
		local infectedFolder = Workspace:FindFirstChild("Infected")
		if infectedFolder then
			table.insert(ignore, infectedFolder)
		end
		local ground = RaycastUtil.groundAt(root.Position, GROUND_SEARCH_HEIGHT, ignore)
		if ground and isLegalSpawn(ground) then
			return ground
		end
	end

	local survivors = Registry.find("SurvivorService")
	local characters = if survivors then survivors:getSurvivorCharacters() else {}
	if #characters == 0 then
		return if root and root.Parent then root.Position else nil
	end
	local position = SpawnPlacement.find(characters, { kind = kind })
	return position
end

--[[
	Hands the body to the player.

	The special module is taken OFF InfectedService's record and kept here. That
	is the whole player-control switch: no module means no target scan, no
	approach and no ability firing itself, and the paused brain means no pathing.
	What is left is a rig that goes exactly where the ghost goes.
]]
function VersusService:_takeControl(slot: any, model: Model, kind: string)
	local infected = Registry.find("InfectedService")
	local definition = InfectedConfig.get(kind)
	local root = RigUtil.getRoot(model)
	if not infected or not definition or not root then
		return false
	end

	slot.body = model
	slot.bodyRoot = root
	slot.bodyHumanoid = model:FindFirstChildOfClass("Humanoid")
	slot.kind = kind
	slot.armedAt = 0
	slot.committedAt = 0

	slot.brain = infected:getBrain(model)
	if slot.brain then
		slot.brain:pause()
	else
		warnOnce(
			"nobrain",
			"InfectedService:getBrain returned nil for a freshly spawned body; the common AI cannot "
				.. "be stood down and will fight the player for the controls"
		)
	end

	local records = infected._records
	slot.record = if records then records[model] else nil
	if slot.record then
		slot.special = slot.record.special
		--[[ A stub with onDeath and no onUpdate, rather than nothing at all.
		     InfectedService skips a special with no onUpdate, which is the whole
		     point — but it still runs onDeath, and those handlers are load
		     bearing: the Hunter's frees a pinned survivor, and the Tank's is the
		     only thing that clears FL_TankActive and stops the Tank music. ]]
		slot.silent = if slot.special then { onDeath = slot.special.onDeath } else nil
		slot.record.special = slot.silent
	else
		warnOnce(
			"norecord",
			"InfectedService keeps no reachable record for a spawned model, so the special module "
				.. "cannot be detached — played specials will fire their ability on the AI's terms "
				.. "instead of on the player's input"
		)
	end

	-- Anchored, because the body is driven by a CFrame write every frame and an
	-- unanchored rig spends that frame arguing with the solver. Every path that
	-- hands the body to its own module, or to gore, unanchors first.
	root.Anchored = true
	model:SetAttribute(CONTROLLER_ATTRIBUTE, slot.player.UserId)

	self:_shapeGhost(slot, definition)

	-- Measured, not assumed: the ghost's root sits at a known height above the
	-- floor and the rig's does not, and that gap is different for every kind
	-- once RigUtil.scaleRig has been applied.
	local boxCFrame, boxSize = model:GetBoundingBox()
	local rootHeight = root.Position.Y - (boxCFrame.Position.Y - boxSize.Y * 0.5)
	slot.pinOffset = rootHeight - GHOST_ROOT_HEIGHT * 0.5
	-- Built once and reused by the per-frame pin, which is the only allocation
	-- that loop would otherwise make.
	slot.pinUp = Vector3.new(0, slot.pinOffset, 0)

	if slot.ghost then
		slot.ghost:SetAttribute(GHOST_KIND_ATTRIBUTE, kind)
	end
	return true
end

--[[ Gives the body back: to its own module for an ability, or to gore for a
     death. `destroyBody` is for a swap or a disconnect, where nobody is left to
     own the rig at all. ]]
function VersusService:_releaseBody(slot: any, destroyBody: boolean?)
	local model = slot.body
	if not model then
		return
	end

	self:_disarm(slot, true)

	if slot.record then
		-- The whole module back, not the stub: whatever owns this rig next is
		-- entitled to the AI it was built with.
		slot.record.special = slot.special
	end
	slot.record = nil
	slot.special = nil
	slot.silent = nil

	local root = slot.bodyRoot
	if root and root.Parent then
		root.Anchored = false
	end
	if model.Parent then
		model:SetAttribute(CONTROLLER_ATTRIBUTE, nil)
	end

	if destroyBody and model.Parent then
		local infected = Registry.find("InfectedService")
		if infected and infected:isTracked(model) then
			infected:despawn(model)
		else
			model:Destroy()
		end
	end

	slot.body = nil
	slot.bodyRoot = nil
	slot.bodyHumanoid = nil
	slot.brain = nil
	slot.armedAt = 0
	slot.committedAt = 0
end

--[[
	The one client entry point that creates something, so every field of it is
	the server's decision.

	The client sends a kind and nothing else. The position is the ghost's own
	server-side position, which is why there is no position to validate and no
	way to lie about one.
]]
function VersusService:requestSpawnAs(player: Player, kind: string): boolean
	local slot = slots[player]
	if not slot or roleOf[slot.side] ~= Enums.Team.Infected then
		return false
	end
	if typeof(kind) ~= "string" then
		return false
	end
	-- Spawn twice: they already have a body.
	if slot.body or slot.spawning then
		return false
	end
	-- Spawn early: the ghost window and the respawn penalty are the same clock.
	if serverNow() < slot.readyAt then
		return false
	end
	if not slot.ghost or not slot.ghost.Parent then
		return false
	end

	local round = Registry.find("RoundService")
	if round and typeof(round.isRunning) == "function" and not round:isRunning() then
		return false
	end

	-- Spawn as something unavailable: the same list the picker was sent, rebuilt
	-- now rather than trusted from then.
	if table.find(self:getAvailableKinds(player), kind) == nil then
		self:_sendSpawnOptions(slot, true)
		return false
	end

	local infected = Registry.find("InfectedService")
	if not infected then
		return false
	end

	slot.spawning = true
	local position = resolveSpawnPosition(slot, kind)
	if not position then
		slot.spawning = false
		return false
	end

	local model = infected:spawn(kind, position)
	slot.spawning = false
	if not model then
		-- Refused by the roster ceiling between the check and the spawn. The
		-- picker is resent so the player sees what is actually left.
		self:_sendSpawnOptions(slot, true)
		return false
	end

	if not self:_takeControl(slot, model, kind) then
		infected:despawn(model)
		return false
	end

	-- The ghost teleports to the body rather than the body to the ghost: the
	-- body is standing on validated ground and the ghost may have been floating
	-- seven studs above a rooftop.
	local ghostRoot = slot.ghostRoot
	local bodyRoot = slot.bodyRoot
	if ghostRoot and bodyRoot then
		ghostRoot.CFrame = uprightAt(bodyRoot.Position - slot.pinUp, bodyRoot.CFrame.LookVector)
		ghostRoot.AssemblyLinearVelocity = Vector3.zero
	end

	--[[
		Only the HOLDER's spawn moves the token.

		The rule this implements is written above passTankToken and was not what
		the code did: it advanced on any infected player's materialisation, so
		with four on the team the cursor ran four times as fast as intended. A
		player would be handed the Tank and lose it a second later because a
		teammate respawned as a Hunter — the token spent its whole life being
		shuffled by people who could not have used it, and whether you ever got a
		Tank came down to how often your teammates happened to die.

		Evaluated after the spawn, which is safe: tankHolder() reads tankCursor
		and the infected roster, and this player materialising changed neither.
	]]
	if VERSUS.TankIsRotated and tankHolder() == player then
		passTankToken()
	end

	local audio = Registry.find("AudioService")
	if audio then
		audio:playForPlayer(player, AudioConfig.UI.MenuConfirm)
	end

	announce(player, slot)
	broadcastSpawnOptions()
	return true
end

-- ════════════════════════════════════════════════════════════════════════════
--  The ability
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Arms the special.

	Handing the module back is the whole mechanism. Its stalk phase then makes
	exactly the decision it makes for an AI — is there a target, is it in range,
	is there a line to it — and commits or does not. What the player controls is
	WHEN that question gets asked, which is the difference between a Hunter that
	pounces because you chose the moment and one that pounces because it walked
	into range.
]]
function VersusService:_requestAbility(slot: any)
	if not slot.body or not slot.record or not slot.special then
		return
	end
	if slot.armedAt ~= 0 or slot.committedAt ~= 0 then
		return
	end
	-- A shoved special does not get to pounce. That is what the shove is for.
	if brainStaggered(slot) then
		return
	end

	-- Written now rather than left to the slow tick: WalkSpeed IS the commit
	-- signal, and arming on a frame where it still reads zero from a stumble
	-- would fire the ability before the player had a target.
	local humanoid = slot.bodyHumanoid
	local definition = if slot.kind then InfectedConfig.get(slot.kind) else nil
	if humanoid and definition and humanoid.WalkSpeed ~= definition.runSpeed then
		humanoid.WalkSpeed = definition.runSpeed
	end

	slot.armedAt = os.clock()
	slot.record.special = slot.special
end

--[[ The module has rooted the body: it is committing. From here the module owns
     the physics, so the body comes off its anchor and the server takes the
     ghost off the player's machine — the camera has to ride the pounce, and a
     client that keeps steering mid-charge would fight it. ]]
function VersusService:_commit(slot: any)
	slot.committedAt = os.clock()

	local root = slot.bodyRoot
	if root and root.Parent then
		root.Anchored = false
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end

	local ghostRoot = slot.ghostRoot
	if ghostRoot and ghostRoot.Parent then
		pcall(function()
			ghostRoot:SetNetworkOwner(nil)
		end)
	end
end

--[[ Gives the controls back. `releasing` is a hand-off that is about to bury or
     destroy the rig, so nothing is re-anchored on the way out — a corpse has to
     be free to fall. ]]
function VersusService:_disarm(slot: any, releasing: boolean?)
	if slot.armedAt == 0 and slot.committedAt == 0 then
		return
	end

	slot.armedAt = 0
	slot.committedAt = 0

	if slot.record then
		slot.record.special = slot.silent
	end
	if slot.brain and typeof(slot.brain.isPaused) == "function" and not slot.brain:isPaused() then
		slot.brain:pause()
	end

	local ghostRoot = slot.ghostRoot
	if ghostRoot and ghostRoot.Parent then
		local player = slot.player
		pcall(function()
			ghostRoot:SetNetworkOwner(player)
		end)
	end

	if releasing then
		return
	end

	local root = slot.bodyRoot
	local humanoid = slot.bodyHumanoid
	local definition = if slot.kind then InfectedConfig.get(slot.kind) else nil
	if root and root.Parent then
		-- The ghost follows the body out of the ability rather than the other
		-- way round: the pounce ended where it ended, and snapping the player
		-- back to where they jumped from would undo it.
		if ghostRoot and ghostRoot.Parent then
			ghostRoot.CFrame = uprightAt(root.Position - slot.pinUp, root.CFrame.LookVector)
			ghostRoot.AssemblyLinearVelocity = Vector3.zero
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.Anchored = true
	end
	if humanoid and definition and humanoid.WalkSpeed ~= definition.runSpeed then
		humanoid.WalkSpeed = definition.runSpeed
	end
end

--[[
	One armed body, one frame.

	Two observable edges and nothing else, because Specials/* export three
	functions and none of them is "are you busy". WalkSpeed hitting zero is every
	module's commit; the brain coming off pause is every module's hand-back.
]]
function VersusService:_stepAbility(slot: any)
	local humanoid = slot.bodyHumanoid
	if not humanoid or not humanoid.Parent then
		return
	end
	local now = os.clock()

	if slot.committedAt == 0 then
		-- Shoved out of the wind-up before it started.
		if brainStaggered(slot) then
			self:_disarm(slot)
			return
		end
		if humanoid.WalkSpeed <= 0.01 then
			self:_commit(slot)
			return
		end
		if now - slot.armedAt >= ABILITY_ARM_WINDOW then
			-- Nothing in reach. Give the player their feet back rather than
			-- leaving them armed and pouncing at whatever wanders past.
			self:_disarm(slot)
		end
		return
	end

	local finished = slot.brain == nil
		or typeof(slot.brain.isPaused) ~= "function"
		or not slot.brain:isPaused()
	if finished or now - slot.committedAt >= ABILITY_MAX_DURATION then
		self:_disarm(slot)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Scoring
-- ════════════════════════════════════════════════════════════════════════════

local function survivingSide(): string
	return if roleOf[SIDE_A] == Enums.Team.Survivor then SIDE_A else SIDE_B
end

local function addScore(side: string, amount: number)
	if amount <= 0 then
		return
	end
	scores[side] = (scores[side] or 0) + amount
end

--[[ A breather starting means the wave before it was cleared, which is the
     event the score is actually about: not "the survivors are alive" but "the
     survivors got through wave N". The last wave has no breather and is credited by
     the victory that ends the half. ]]
local function creditWave(index: number)
	if index <= wavesCredited then
		return
	end
	wavesCredited = index
	addScore(survivingSide(), VERSUS.ScorePerWaveCleared)
end

function VersusService:_scoreHalf(outcome: string)
	local side = survivingSide()

	if outcome == Enums.RoundState.Victory then
		creditWave(GameModeConfig.getWaveCount())
	end

	-- Timed from this service's own stamp rather than RoundService:getElapsed().
	-- endRound publishes the outcome BEFORE it fires roundEnded, and getElapsed
	-- returns zero the moment the round stops running — a wipe at sixteen
	-- minutes would score the same as one at ten seconds.
	local elapsed = math.clamp(serverNow() - halfStartedAt, 0, GameModeConfig.Classic.TotalDuration)
	addScore(side, math.floor(elapsed) * VERSUS.ScorePerSecondSurvived)

	--[[ On their FEET, not merely not-dead. A team that finishes with two people
	     bleeding out on the floor did not protect each other, and this is the
	     line of the config that is supposed to make protecting each other pay. ]]
	local survivors = Registry.find("SurvivorService")
	if survivors then
		local standing = 0
		for _, player in survivors:getAliveSurvivors() do
			if not survivors:isIncapacitated(player) then
				standing += 1
			end
		end
		addScore(side, standing * VERSUS.ScorePerSurvivorAlive)
	end

	--[[
		Who actually won this half, recorded BEFORE anything swaps.

		RoundService's outcome describes the SURVIVOR half and nothing else. In
		Versus that is half the server: a survivor Victory is an infected defeat,
		and every service that read the outcome directly paid the infected half
		for losing. EconomyService's VictoryBonus is 5.5x its DefeatBonus, so a
		team that failed to stop anybody banked the winning purse — and the XP
		table hands out its single largest award, Victory, on the same test.

		Captured here rather than derived later because `swapTeams` runs a few
		lines after this and reverses every role in the match. Anything asking
		"which team was this player on" after that point gets the answer for the
		half they are about to play, not the one they were just paid for.
	]]
	local survivorsWon = outcome == Enums.RoundState.Victory
	table.clear(lastRoundWon)
	for _, player in order do
		lastRoundWon[player] = if roleFor(player) == Enums.Team.Infected
			then not survivorsWon
			else survivorsWon
	end
end

--[[
	Whether this player won the round that just ended, or nil when Versus has no
	opinion — no match running, or somebody who was not in one.

	Every round-end payout goes through this rather than testing the outcome
	itself. nil means "use the outcome", which is the right answer for Classic
	and for a player who joined while the scoreboard was up.

	ORDERING: this is written by _scoreHalf, which runs from this service's own
	roundEnded handler. Callers must therefore be connected to roundEnded AFTER
	this service — which they are, because a signal fires in connection order and
	connection order is the MODULES list in init.server.lua, where both payout
	services sit below Round/VersusService. That comment says so too.
]]
function VersusService:wonLastRound(player: Player): boolean?
	if not active then
		return nil
	end
	return lastRoundWon[player]
end

function VersusService:getScores(): { [string]: number }
	return { [SIDE_A] = scores[SIDE_A] or 0, [SIDE_B] = scores[SIDE_B] or 0 }
end

-- ════════════════════════════════════════════════════════════════════════════
--  Halves
-- ════════════════════════════════════════════════════════════════════════════

--[[ Makes the world agree with roleOf. Idempotent and cheap, so it is also what
     handles a joiner arriving in the middle of a wave and a leaver forcing a
     rebalance — there is one path into being infected and one path out. ]]
function VersusService:_applyRoles()
	local round = Registry.find("RoundService")
	--[[ Running AND Versus, for the same reason _slowStep tests both: `active`
	     outlives a match by design, so any path that can hand out a ghost has to
	     check the mode or it hands one out in a Classic round. ]]
	local running = round ~= nil
		and typeof(round.isRunning) == "function"
		and round:isRunning()
		and typeof(round.getMode) == "function"
		and round:getMode() == GameModeConfig.Modes.Versus
	local survivors = Registry.find("SurvivorService")

	for _, player in order do
		local slot = slots[player]
		if not slot or not player.Parent then
			continue
		end

		if roleOf[slot.side] == Enums.Team.Infected then
			--[[
				Only while a round is actually running.

				swapTeams runs at HALF TIME, from _onRoundEnded, and _publishRoundState
				has already set the round state to its outcome by then — so this branch
				fired with the round over and took the characters off the four players
				who had just finished as survivors, for the whole 30-second scoreboard.

				They then sat behind a spawn picker that is invisible and live: it draws
				at DisplayOrder 41, under the results screen at 80, but the results
				scrim is a Frame and a Frame does not block input in Roblox. Every click
				played a confirm sound the server refused, and the gamepad focus was
				stolen off the Continue button. Worse, the ghost built here is never
				torn down, so the incoming infected half entered the next half with its
				ghost timer already spent and could materialise at t=0 on a team that
				had only just been spawned together.
			]]
			if running and (not slot.ghost or not slot.ghost.Parent) then
				self:_beginGhost(slot, VERSUS.InfectedGhostTime)
			end
			continue
		end

		local wasInfected = slot.ghost ~= nil or slot.body ~= nil
		if wasInfected then
			self:_destroyGhost(slot)
			announce(player, slot)
		end

		-- Only mid-round. Between halves everybody is characterless on purpose
		-- and RoundService's next startRound spawns the whole server at once.
		local needsBody = running and player.Character == nil
		if survivors and needsBody and not slot.spawningSurvivor then
			slot.spawningSurvivor = true
			-- LoadCharacter yields; neither loop that reaches here may.
			task.spawn(function()
				survivors:spawnSurvivor(player)
				slot.spawningSurvivor = false
			end)
		end
	end
end

function VersusService:swapTeams()
	roleOf[SIDE_A], roleOf[SIDE_B] = roleOf[SIDE_B], roleOf[SIDE_A]
	tankCursor = 1
	wavesCredited = 0

	for _, player in order do
		local slot = slots[player]
		if slot then
			self:_destroyGhost(slot)
			announce(player, slot)
		end
	end

	self:_applyRoles()
end

--[[ Everyone is a survivor between rounds. RoundService's startRound spawns the
     whole server as one, and the infected half is taken back out the moment the
     round is actually running — see _convert. ]]
function VersusService:_beginHalf()
	converted = false
	wavesCredited = 0

	local round = Registry.find("RoundService")
	if not round then
		warnOnce("noround", "RoundService is not registered; Versus has no wave clock to ride")
		return
	end
	round:startRound(GameModeConfig.Modes.Versus)
	self:_convert(round)
end

--[[
	Takes the infected half back out of the survivor team, once per round.

	This is an EDGE, not a call, because it is not always this service that
	starts a round: RoundService brings the next one back by itself after the
	scoreboard, and MatchmakingService will when it exists. Whoever starts it,
	the half is counted and the infected side becomes ghosts here.
]]
function VersusService:_convert(round: any)
	if converted or not active or not round then
		return
	end
	if typeof(round.isRunning) ~= "function" or not round:isRunning() then
		return
	end
	if typeof(round.getMode) == "function" and round:getMode() ~= GameModeConfig.Modes.Versus then
		return
	end

	converted = true
	if half < VERSUS.Halves then
		half += 1
	else
		half = 1
	end
	wavesCredited = 0

	-- RoundService publishes the absolute stamp the round ends at, so the start
	-- is exact rather than "whenever this tick noticed".
	local endsAt = Attributes.get(Workspace, Attributes.Game.RoundEndsAt, 0)
	halfStartedAt = if endsAt > 0 then endsAt - GameModeConfig.Classic.TotalDuration else serverNow()

	self:_applyRoles()
end

function VersusService:_onRoundEnded(outcome: string)
	if not active or half == 0 then
		return
	end

	self:_scoreHalf(outcome)

	for _, player in order do
		local slot = slots[player]
		if slot then
			self:_destroyGhost(slot)
		end
	end

	if half >= VERSUS.Halves then
		local final = self:getScores()
		local winner: string? = nil
		if final[SIDE_A] > final[SIDE_B] then
			winner = SIDE_A
		elseif final[SIDE_B] > final[SIDE_A] then
			winner = SIDE_B
		end

		-- A fresh match on the same server, sides kept, halves and scores reset.
		half = 0
		scores[SIDE_A] = 0
		scores[SIDE_B] = 0
		converted = false
		return
	end

	-- Swap now rather than at the next round start: the scoreboard between
	-- halves is when a player wants to see which side they are about to be on.
	if VERSUS.SwapBetweenHalves then
		self:swapTeams()
	end
	converted = false

	-- A backstop, not the normal path. RoundService restarts on its own after
	-- the scoreboard, but it stands down entirely once MatchmakingService is
	-- registered, and a versus match must not stall at half time because the
	-- matchmaker had nothing to say. startRound ignores a second caller, so
	-- whichever of the three gets there first is the one that counts.
	generation += 1
	local mine = generation
	task.delay(GameModeConfig.Matchmaking.PostRoundDuration, function()
		if mine == generation and active and not converted then
			self:_beginHalf()
		end
	end)
end

-- ════════════════════════════════════════════════════════════════════════════
--  The one loop
-- ════════════════════════════════════════════════════════════════════════════

--[[ The only per-frame work in the file: one CFrame write per player-driven
     body, and only while it is being driven. A committed ability is the module's
     physics and is not touched. ]]
function VersusService:_pin()
	for _, player in order do
		local slot = slots[player]
		if not slot or not slot.body then
			continue
		end

		local root = slot.bodyRoot
		local ghostRoot = slot.ghostRoot
		if not root or not root.Parent or not ghostRoot or not ghostRoot.Parent then
			continue
		end

		if slot.committedAt ~= 0 then
			-- The module owns the body; the ghost rides along so the camera sees
			-- the pounce from inside it.
			ghostRoot.CFrame = uprightAt(root.Position - slot.pinUp, root.CFrame.LookVector)
			ghostRoot.AssemblyLinearVelocity = Vector3.zero
		else
			root.CFrame = ghostRoot.CFrame + slot.pinUp
		end

		if slot.armedAt ~= 0 then
			self:_stepAbility(slot)
		end
	end
end

--[[ Everything that is a deadline rather than a position. 4Hz: the client
     already counts its own respawn down from an absolute stamp, so asking sixty
     times a second buys nothing but traffic. ]]
function VersusService:_slowStep()
	local round = Registry.find("RoundService")
	--[[
		RUNNING **AND VERSUS**. The mode half of that test was missing, and it let
		this service poison every round that came after a match.

		`active` is deliberately never cleared when a match ends — the comment in
		_onRoundEnded says so, "a fresh match on the same server, sides kept" — and
		stopVersus, the only thing that would clear it, has exactly one caller
		(destroy) which is itself never called. That is fine as long as nothing
		acts on `active` outside a Versus round. This did: with `running` derived
		from isRunning() alone, the next CLASSIC round on the same server found
		active true and roleOf still mapping one side to Infected, and handed half
		the lobby a ghost. requestSpawnAs has no mode guard either, so those
		players could then materialise Tanks into a co-op round.

		Guarding here rather than clearing `active` keeps the documented behaviour
		— the sides survive to the next match — and costs one comparison at 5Hz.
	]]
	local running = round ~= nil
		and typeof(round.isRunning) == "function"
		and round:isRunning()
		and typeof(round.getMode) == "function"
		and round:getMode() == GameModeConfig.Modes.Versus

	if wanted and not active then
		if #Players:GetPlayers() >= VERSUS.MinPlayersToStart then
			self:startVersus()
		end
		return
	end
	if not active then
		return
	end

	if running then
		self:_convert(round)
	elseif converted then
		converted = false
	end

	for _, player in order do
		local slot = slots[player]
		if not slot then
			continue
		end
		if roleOf[slot.side] ~= Enums.Team.Infected then
			continue
		end

		-- A body that stopped being tracked was taken out from under us — a
		-- round reset, or the Director clearing the board.
		if slot.body and not slot.body.Parent then
			self:_releaseBody(slot)
			self:_beginGhost(slot, respawnDelay())
			continue
		end

		if not slot.ghost or not slot.ghost.Parent then
			if running then
				self:_beginGhost(slot, VERSUS.InfectedGhostTime)
			end
			continue
		end

		repairGhostCharacter(slot)
		self:_reassertGhost(slot)

		if slot.body then
			self:_reassertBody(slot)
		else
			slot.ghost:SetAttribute(GHOST_READY_ATTRIBUTE, slot.readyAt)
			self:_sendSpawnOptions(slot)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Public surface
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Splits the server and starts the first half.

	Below MinPlayersToStart the intent is remembered rather than refused: a
	four-player mode that silently does nothing when the fourth player is ten
	seconds away is indistinguishable from a broken button.
]]
function VersusService:startVersus(): boolean
	if active then
		return true
	end

	for _, player in Players:GetPlayers() do
		assign(player)
	end
	rebalance()

	if #Players:GetPlayers() < VERSUS.MinPlayersToStart then
		wanted = true
		warnOnce(
			"waiting",
			string.format(
				"Versus needs %d players (GameModeConfig.Versus.MinPlayersToStart); waiting",
				VERSUS.MinPlayersToStart
			)
		)
		return false
	end

	active = true
	wanted = false
	half = 0
	converted = false
	wavesCredited = 0
	generation += 1
	scores[SIDE_A] = 0
	scores[SIDE_B] = 0

	for _, player in order do
		local slot = slots[player]
		if slot then
			announce(player, slot)
		end
	end

	self:_beginHalf()
	return true
end

--[[
	Takes responsibility for a join-in-progress player.

	MatchmakingService calls this instead of spawning them, because which half a
	joiner lands on is not a decision it can make — and it treats "did not throw"
	as "handled", so this must always leave the player with a body or a ghost,
	never in between. Below MinPlayersToStart there is no split yet, so they join
	as a survivor and are sorted when the match actually starts.
]]
function VersusService:assignTeam(player: Player): boolean
	assign(player)
	rebalance()

	if active then
		self:_applyRoles()
		broadcastSpawnOptions()
		return true
	end

	local survivors = Registry.find("SurvivorService")
	if survivors then
		task.spawn(function()
			survivors:spawnSurvivor(player)
		end)
	end
	return true
end

--[[ The role a player is playing right now — Enums.Team. The side they belong
     to, which does not change at half time, is getSide. ]]
function VersusService:getTeam(player: Player): string
	return roleFor(player)
end

function VersusService:getSide(player: Player): string?
	local slot = slots[player]
	return slot and slot.side or nil
end

function VersusService:isActive(): boolean
	return active
end

function VersusService:getHalf(): number
	return half
end

--[[ The body a player is driving, for anything that needs to draw or name it. ]]
function VersusService:getControlledModel(player: Player): Model?
	local slot = slots[player]
	return slot and slot.body or nil
end

function VersusService:getControllingPlayer(model: Model): Player?
	for player, slot in slots do
		if slot.body == model then
			return player
		end
	end
	return nil
end

--[[ Stops managing the mode and puts everybody back on their feet. ]]
function VersusService:stopVersus()
	active = false
	wanted = false
	half = 0
	converted = false
	generation += 1

	local survivors = Registry.find("SurvivorService")
	for _, player in order do
		local slot = slots[player]
		if not slot then
			continue
		end
		-- Only the infected half needs putting back. Respawning a survivor who
		-- was mid-fight would hand them a full health bar for free.
		local wasInfected = slot.ghost ~= nil or slot.body ~= nil
		self:_destroyGhost(slot)
		if wasInfected and survivors and player.Parent then
			task.spawn(function()
				survivors:spawnSurvivor(player)
			end)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Boot
-- ════════════════════════════════════════════════════════════════════════════

function VersusService:_onPlayerAdded(player: Player)
	if not active and not wanted then
		return
	end
	assign(player)
	rebalance()
	if active then
		self:_applyRoles()
		broadcastSpawnOptions()
	end
end

function VersusService:_onPlayerRemoving(player: Player)
	local slot = slots[player]
	if slot then
		self:_destroyGhost(slot)
		slots[player] = nil
	end
	local index = table.find(order, player)
	if index then
		table.remove(order, index)
	end

	if not active then
		return
	end
	rebalance()
	self:_applyRoles()
	broadcastSpawnOptions()
end

function VersusService:init()
	roleOf[SIDE_A] = Enums.Team.Survivor
	roleOf[SIDE_B] = Enums.Team.Infected
end

function VersusService:start()
	serviceTrove:connect(Remotes.Event.RequestInfectedSpawn.OnServerEvent, function(player, kind)
		local slot = slots[player]
		if not slot then
			return
		end
		-- Rate limited before anything else: requestSpawnAs ends in a raycast
		-- and a rig build, and a client is free to send this at packet rate.
		local now = os.clock()
		if now - slot.lastRequestAt < REQUEST_INTERVAL then
			return
		end
		slot.lastRequestAt = now
		self:requestSpawnAs(player, kind)
	end)

	serviceTrove:connect(Players.PlayerAdded, function(player)
		self:_onPlayerAdded(player)
	end)
	serviceTrove:connect(Players.PlayerRemoving, function(player)
		self:_onPlayerRemoving(player)
	end)

	local round = Registry.find("RoundService")
	if round then
		if round.phaseChanged then
			serviceTrove:add(round.phaseChanged:connect(function(isBreather: boolean, index: number)
				if active and isBreather then
					creditWave(index)
					broadcastSpawnOptions()
				end
			end))
		end
		if round.roundEnded then
			serviceTrove:add(round.roundEnded:connect(function(outcome: string)
				self:_onRoundEnded(outcome)
			end))
		end
	else
		warnOnce(
			"noroundsignals",
			"RoundService was not registered at start(); Versus cannot score waves or halves and "
				.. "will never swap teams"
		)
	end

	local infected = Registry.find("InfectedService")
	if infected and infected.died then
		serviceTrove:add(infected.died:connect(function(model: Model)
			local player = self:getControllingPlayer(model)
			if not player then
				return
			end
			local slot = slots[player]
			if not slot then
				return
			end
			-- Released, never destroyed: the corpse belongs to GoreService from
			-- this moment, and it has to be unanchored to fall.
			self:_releaseBody(slot)
			self:_beginGhost(slot, respawnDelay())
			broadcastSpawnOptions()
		end))
	end

	-- THE loop. One connection: a CFrame write per driven body every frame, and
	-- every deadline in the mode at 4Hz.
	serviceTrove:connect(RunService.Heartbeat, function(delta)
		if active then
			self:_pin()
		end

		slowAccumulator += delta
		if slowAccumulator < TICK_INTERVAL then
			return
		end
		slowAccumulator = 0
		self:_slowStep()
	end)
end

function VersusService:destroy()
	self:stopVersus()
	serviceTrove:destroy()
end

Registry.register("VersusService", VersusService)

return VersusService
