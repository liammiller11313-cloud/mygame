--!nonstrict
--[[
	SurvivorService — survivor health and every rule that hangs off it.

	This is Left 4 Dead's health model, deliberately unsimplified:

	  * Permanent health is the only thing that lasts. Pills and adrenaline add a
	    white buffer that drains away, so a topped-up survivor is still a hurt
	    survivor on a clock.
	  * Going down is not dying. It is a debt the team pays in time, standing
	    still, while the horde keeps arriving.
	  * The third down kills you. That escalation is what turns "I'm at 20" from
	    a stat into a conversation, and it is the single most important rule here.

	Every number comes from GameConfig.Survivor. Nothing in this file invents a
	balance value, and nothing simplifies the incap ladder.

	PERFORMANCE: exactly one Heartbeat connection ticks every survivor. Decay,
	bleed, stamina, ledge timers, interaction holds, pin watchdogs and attribute
	publishing all ride in that single pass, and none of it allocates per frame.

	NETCODE: the HUD reads Attributes.Player.* and nothing else, so every field
	there is written here and kept true at all times. Discrete moments (a state
	flip, a hit landing) additionally go out as remotes.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local AudioConfig = require(Shared.Config.AudioConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)

local S = GameConfig.Survivor
local INTERACT_RANGE = GameConfig.Interaction.Range
local PICKUP_RANGE = GameConfig.Interaction.PickupRange
local PA = Attributes.Player
local STATE = Enums.SurvivorState

--[[
	A dead survivor's body is a defib target long after their Humanoid stops
	mattering, so it is tagged rather than looked up by class. Tags replicate, so
	the client's prompt code can find the same bodies without a remote.
]]
local BODY_TAG = "FL_SurvivorBody"

--[[ A rescue closet is any tagged model in the level. LevelService's tag table
     does not name one, so this is the tag the map builder must use. ]]
local CLOSET_TAG = "FL_RescueCloset"

-- Kinds of hold-to-complete interaction this service arbitrates.
local AMMO_CRATE_TAG = MapConfig.AmmoCrates.Tag

local INTERACT = table.freeze({
	Revive = "Revive",
	LedgePull = "LedgePull",
	HealAlly = "HealAlly",
	Defib = "Defib",
	Rescue = "Rescue",
	Resupply = "Resupply",
})

--[[ Stamina hysteresis: without it, a survivor who empties the bar stutters
     between sprint and walk speed every single frame. ]]
--[[ How much of the bar has to come back before sprint is granted again.
     0.25 was most of why movement sawtoothed: a survivor recovered a quarter of a
     tank, spent it in a second and a half, and did that all round. At 0.8 the
     cycle is roughly seven seconds of sprint bought back over three — see the
     simulated figures on GameConfig.Survivor's speeds. ]]
local SPRINT_RECOVER_FRACTION = 0.8

--[[ A survivor is judged to be sprinting when they actually outrun their own
     walk speed by this much. The server owns WalkSpeed, so this needs no extra
     remote — the movement itself is the intent. ]]
local SPRINT_DETECT_MARGIN = 1.5

--[[ Roblox kills a Humanoid at zero health, which would bypass the entire incap
     ladder. A downed survivor's Humanoid is therefore parked just above zero;
     the real number lives in the record. ]]
local DOWNED_HUMANOID_HEALTH = 1

-- Flow distance is only ever read by the Director at human timescales.
local FLOW_PUBLISH_INTERVAL = 0.25

-- Cheap anti-spam on the interaction remotes. Not balance; just rate limiting.
local INTERACT_REQUEST_INTERVAL = 0.1

local SurvivorService = {}

SurvivorService.stateChanged = Signal.new() -- (player, newState, oldState)
SurvivorService.damaged = Signal.new() -- (player, amount, ctx)
SurvivorService.died = Signal.new() -- (player, ctx)
SurvivorService.revived = Signal.new() -- (player, rescuer) — rescuer is nil for a scripted rescue

local records: { [Player]: any } = {}
local bodies: { [Model]: Player } = {} -- corpse model -> the player it belongs to
local awaitingRescue: { Player } = {} -- dead players queued for a closet, oldest first
--[[ Ping callouts. One key, one line of dialogue, and a cooldown so it cannot be
     held down to flood every client's subtitle queue. ]]
local PING_COOLDOWN = 1.6
local PING_MAX_RANGE = 700
local PING_SUBTITLE_SECONDS = 2.4
local PING_LINES = table.freeze({
	Location = "Over here!",
	Infected = "Contact!",
	Pickup = "Supplies here!",
})

local serviceTrove = Trove.new()

--[[ Squared distance without building an intermediate Vector3. Called for every
     survivor every frame, so it is worth the four lines. ]]
local function distanceSquared(a: Vector3, b: Vector3): number
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

local function playAt(definition, part: BasePart?)
	if not part then
		return
	end
	local audio = Registry.find("AudioService")
	if audio then
		audio:playOn(definition, part)
	end
end

--[[ Roblox inserts its own "Health" regeneration Script into every character.
     It would quietly heal a survivor who is supposed to be bleeding out. ]]
local function stripDefaultHealthScript(child: Instance)
	if child.Name == "Health" and child:IsA("Script") then
		child:Destroy()
	end
end

-- ─── record lifecycle ────────────────────────────────────────────────────────

function SurvivorService:_ensureRecord(player: Player)
	local record = records[player]
	if record then
		return record
	end

	record = {
		player = player,
		trove = Trove.new(),
		charTrove = Trove.new(),
		character = nil,
		humanoid = nil,
		root = nil,

		state = STATE.Spectating,
		health = 0,
		tempHealth = 0,
		tempDecay = S.PillDecayPerSecond,
		incapHealth = 0,
		incapCount = 0,
		blackAndWhite = false,

		adrenalineUntil = 0,
		stamina = S.MaxStamina,
		sprintLocked = false,
		crouching = false,
		--[[ Whether this player is asking to sprint. True by default: see
		     _computeWalkSpeed for why a silent client must keep sprinting. ]]
		sprinting = true,
		ledgeRemaining = 0,

		pinnedBy = nil,
		pinnedKind = "",

		interaction = nil, -- what this player is performing on someone else
		helper = nil, -- the player currently working on this one
		breathSound = nil,

		baseJumpPower = 50,
		baseJumpHeight = 7.2,
		appliedSpeed = -1,
		-- nil rather than false, so the first tick always publishes the gait.
		appliedSprint = nil,

		lastInteractRequest = 0,
		flowClock = 0,
		spawnCFrame = nil,

		-- Sentinels: the first publish must always write, whatever the value is.
		pub = {
			state = "",
			health = -1,
			temp = -1,
			incaps = -1,
			blackAndWhite = nil,
			progress = -1,
			pinned = nil,
			flow = -1,
		},
	}

	record.trove:add(record.charTrove)
	records[player] = record

	-- Every Attributes.Player field exists from the moment the player does; the
	-- HUD renders a teammate slot before that teammate has ever spawned.
	player:SetAttribute(PA.IsReady, false)
	player:SetAttribute(PA.FlowDistance, 0)
	record.pub.flow = 0
	self:_publish(record)
	self:_publishProgress(record, 0)

	record.trove:connect(player.CharacterAdded, function(character)
		self:_onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(function()
			self:_onCharacterAdded(player, player.Character)
		end)
	end

	return record
end

function SurvivorService:_destroyRecord(player: Player)
	local record = records[player]
	if not record then
		return
	end
	self:_cancelInteraction(record)
	self:_cancelHelp(record)
	record.trove:destroy()
	records[player] = nil

	local index = table.find(awaitingRescue, player)
	if index then
		table.remove(awaitingRescue, index)
	end
	for model, owner in bodies do
		if owner == player then
			bodies[model] = nil
			if model.Parent then
				CollectionService:RemoveTag(model, BODY_TAG)
			end
		end
	end
end

-- ─── derived values ──────────────────────────────────────────────────────────

--[[ Permanent plus white health. This is the number the player thinks of as
     "my health", and the only one the hurt threshold is measured against. ]]
function SurvivorService:_effective(record): number
	return record.health + record.tempHealth
end

--[[ Black and white clamps the ceiling rather than the current value: a survivor
     on their last life can be topped up, just never past halfway. ]]
function SurvivorService:_cap(record): number
	return record.blackAndWhite and S.BlackAndWhiteHealth or S.MaxHealth
end

function SurvivorService:_isUpright(record): boolean
	local state = record.state
	return state == STATE.Healthy or state == STATE.Hurt
end

function SurvivorService:_hasAdrenaline(record): boolean
	return os.clock() < record.adrenalineUntil
end

--[[
	Whether anybody on the team can still turn this around.

	Upright is the obvious half. PINNED is the subtle one, and it is why this is
	not simply "is anyone standing": a pinned survivor is not down, they are
	held — and a teammate who is only INCAPACITATED can still shoot the thing
	holding them, because a downed survivor keeps a pistol. Free them and the
	team has somebody on their feet again.

	Everything else needs somebody upright to get out of, and requestInteraction
	enforces exactly that: incapacitated needs a revive, ledge-hanging needs a
	pull-up, dead needs a defibrillator, and all three are interactions only an
	upright survivor may begin.

	So a team with nobody upright and nobody pinned has not almost lost. It HAS
	lost, and what remains is a hundred and fifty seconds of bleed-out with four
	people on the floor watching. RoundService reads this to end the round there
	instead.
]]
function SurvivorService:canTeamRecover(): boolean
	for _, record in records do
		if self:_isUpright(record) or record.state == STATE.Pinned then
			return true
		end
	end
	return false
end

-- ─── attribute publishing ────────────────────────────────────────────────────

--[[
	Attributes replicate on change, so every write costs bandwidth for every
	client. Values are quantised and compared before writing: temp health decaying
	at 0.55/s would otherwise produce a replication packet every single frame.
]]
function SurvivorService:_publish(record)
	local player = record.player
	local pub = record.pub

	if pub.state ~= record.state then
		pub.state = record.state
		player:SetAttribute(PA.State, record.state)
	end

	local health = math.floor(math.max(record.health, 0) * 10 + 0.5) / 10
	if pub.health ~= health then
		pub.health = health
		player:SetAttribute(PA.Health, health)
	end

	local temp = math.floor(math.max(record.tempHealth, 0) * 10 + 0.5) / 10
	if pub.temp ~= temp then
		pub.temp = temp
		player:SetAttribute(PA.TempHealth, temp)
	end

	if pub.incaps ~= record.incapCount then
		pub.incaps = record.incapCount
		player:SetAttribute(PA.IncapCount, record.incapCount)
	end

	if pub.blackAndWhite ~= record.blackAndWhite then
		pub.blackAndWhite = record.blackAndWhite
		player:SetAttribute(PA.IsBlackAndWhite, record.blackAndWhite)
	end

	local pinned = record.pinnedKind or ""
	if pub.pinned ~= pinned then
		pub.pinned = pinned
		player:SetAttribute(PA.PinnedBy, pinned)
	end
end

--[[ Progress lives on both parties: the downed survivor's ring and the rescuer's
     own hold bar are the same number, and the HUD should never have to guess. ]]
function SurvivorService:_publishProgress(record, alpha: number)
	local quantised = math.floor(math.clamp(alpha, 0, 1) * 100 + 0.5) / 100
	if record.pub.progress == quantised then
		return
	end
	record.pub.progress = quantised
	record.player:SetAttribute(PA.ReviveProgress, quantised)
end

-- ─── state machine ───────────────────────────────────────────────────────────

--[[
	The laboured breathing that runs the whole time a survivor is under the hurt
	threshold. AudioConfig documents this cue as looped, but every definition in
	that file is built by one constructor and arrives one-shot, so the loop is set
	here rather than by editing the frozen config.
]]
function SurvivorService:_setBreathing(record, on: boolean)
	local existing = record.breathSound
	if existing then
		record.breathSound = nil
		pcall(existing.Destroy, existing)
	end
	if not on or not record.root then
		return
	end
	local audio = Registry.find("AudioService")
	if not audio then
		return
	end
	local sound = audio:playOn(AudioConfig.Survivor.Breathing, record.root)
	if sound then
		sound.Looped = true
		record.breathSound = sound
	end
end

function SurvivorService:_setState(record, newState: string)
	local previous = record.state
	if previous == newState then
		return
	end
	record.state = newState

	--[[ A body that is not upright is not crouching. The client normally clears
	     this itself — releasing the key sends the release, and a menu opening
	     synthesises one — but a player who goes down or dies while still holding
	     it has nothing to release, and the clamp would follow them back up. ]]
	if record.crouching and not self:_isUpright(record) then
		record.crouching = false
		Attributes.set(record.player, Attributes.Player.IsCrouching, false)
	end

	self:_publish(record)
	self:_applyHumanoid(record)

	-- "Hurt" is meant to be heard, by teammates and by everything hunting them.
	if newState == STATE.Hurt then
		self:_setBreathing(record, true)
	elseif previous == STATE.Hurt then
		self:_setBreathing(record, false)
	end

	Remotes.Event.SurvivorStateChanged:FireAllClients({
		player = record.player,
		state = newState,
		previousState = previous,
	})
	self.stateChanged:fire(record.player, newState, previous)
end

--[[ Healthy or Hurt, decided purely by effective health. Downed, hanging, pinned
     and dead states are set explicitly and are never overridden from here. ]]
function SurvivorService:_refreshUprightState(record)
	if not self:_isUpright(record) then
		return
	end
	local hurt = self:_effective(record) < S.HurtThreshold
	self:_setState(record, hurt and STATE.Hurt or STATE.Healthy)
end

--[[
	The one place that decides how fast a survivor moves.

	Limping below the hurt threshold is the whole point of that threshold: it is
	audible, it is visible to teammates, and it is what makes a health item worth
	arguing over. Sprinting is gated on stamina rather than on a keybind, because
	the server owns WalkSpeed and the movement itself is the intent.
]]
function SurvivorService:_computeWalkSpeed(record): number
	local state = record.state
	if
		state == STATE.Incapacitated
		or state == STATE.Pinned
		or state == STATE.LedgeHanging
		or state == STATE.Dead
		or state == STATE.Spectating
	then
		return 0
	end

	local hurt = self:_effective(record) < S.HurtThreshold
	local speed = hurt and S.LimpWalkSpeed or S.NormalWalkSpeed

	-- A limping survivor cannot break into a run; adrenaline's temp health is the
	-- intended way back over the threshold, not an exception carved out here.
	--[[
		Sprint is now ASKED FOR rather than assumed.

		This granted SprintSpeed to anybody with stamina, so every survivor ran
		flat out for seventeen minutes and the bar emptied whether or not they
		wanted it spent. You could not move quietly, could not bank wind before a
		Charger lane, and could not tell why you had slowed down.

		`record.sprinting` defaults to TRUE so a client that never sends the remote
		— a phone, which has no room on the pad for a ninth button — behaves
		exactly as the whole game did before this line existed. Nobody loses a
		control they had; desktop and gamepad gain one.
	]]
	if not hurt and record.sprinting and not record.sprintLocked and record.stamina > 0 then
		speed = math.max(speed, S.SprintSpeed)
	end

	--[[ Crouch wins over sprint. You cannot sprint while crouched — that is the
	     trade the whole thing is built on — so this clamps rather than scales,
	     and it happens before adrenaline so a stimmed survivor still crouches
	     slowly. ]]
	if record.crouching then
		speed = math.min(speed, S.CrouchSpeed)
	end

	if self:_hasAdrenaline(record) then
		speed *= S.AdrenalineSpeedBonus
	end

	-- The weapon in hand is a movement stat in this game; the number lives in
	-- WeaponConfig and the server owns the property, so it is applied here.
	local inventory = Registry.find("InventoryService")
	if inventory then
		local _, definition = inventory:getActiveWeapon(record.player)
		if definition then
			speed *= definition.walkSpeedScale
		end
	end

	return speed
end

--[[ Pushes state onto the Humanoid: movement lockout, jump lockout, turn lockout
     while pinned, and the mirrored health value. ]]
function SurvivorService:_applyHumanoid(record)
	local humanoid = record.humanoid
	if not humanoid or humanoid.Parent == nil then
		return
	end

	local state = record.state
	local immobile = state ~= STATE.Healthy and state ~= STATE.Hurt

	-- This runs every frame for every survivor, so every write is guarded: an
	-- unchanged property assignment still costs a replication check.
	local autoRotate = state ~= STATE.Pinned
	if humanoid.AutoRotate ~= autoRotate then
		-- A pinned survivor cannot turn. Everything else that immobilises still
		-- lets you face where you are shooting from the floor.
		humanoid.AutoRotate = autoRotate
	end

	local jumpPower = immobile and 0 or record.baseJumpPower
	if humanoid.JumpPower ~= jumpPower then
		humanoid.JumpPower = jumpPower
	end
	local jumpHeight = immobile and 0 or record.baseJumpHeight
	if humanoid.JumpHeight ~= jumpHeight then
		humanoid.JumpHeight = jumpHeight
	end

	local speed = self:_computeWalkSpeed(record)
	if math.abs(speed - record.appliedSpeed) > 0.01 then
		record.appliedSpeed = speed
		humanoid.WalkSpeed = speed
	end

	--[[
		Whether that speed is a RUN, published for the footsteps.

		Derived from the same conditions _computeWalkSpeed uses rather than from
		the number it returned, because the number has already been through the
		weapon's walkSpeedScale and a heavy rifle at a sprint lands on the same
		figure as a light one at a walk. Asking the conditions is the only reading
		that stays right whatever is in somebody's hands.

		Written only on a CHANGE. Attributes.set is a bare SetAttribute and this
		runs on the humanoid tick, so an unguarded write would be a replicated
		property set several times a second per survivor for a value that changes
		a handful of times a minute. `appliedSprint` is the same trick
		appliedSpeed above it uses, with the same nil sentinel so the first tick
		always publishes.
	]]
	local sprinting = record.sprinting
		and not record.sprintLocked
		and not record.crouching
		and record.stamina > 0
		and self:_effective(record) >= S.HurtThreshold
		and speed > 0
	if record.appliedSprint ~= sprinting then
		record.appliedSprint = sprinting
		Attributes.set(record.player, Attributes.Player.IsSprinting, sprinting)
	end

	-- The Humanoid is a mirror, never the source of truth. It is kept above zero
	-- while downed so Roblox does not "helpfully" kill a survivor mid-revive.
	local mirrored
	if state == STATE.Dead then
		mirrored = 0
	elseif state == STATE.Incapacitated or state == STATE.LedgeHanging then
		mirrored = DOWNED_HUMANOID_HEALTH
	else
		mirrored = math.max(record.health, DOWNED_HUMANOID_HEALTH)
	end
	if math.abs(humanoid.Health - mirrored) > 0.05 then
		humanoid.Health = mirrored
	end
end

-- ─── character setup ─────────────────────────────────────────────────────────

function SurvivorService:_onCharacterAdded(player: Player, character: Model)
	local record = self:_ensureRecord(player)
	self:_setBreathing(record, false)
	record.charTrove:clean()
	record.character = character

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		warn(string.format("[SurvivorService] %s spawned without a Humanoid", player.Name))
		return
	end
	record.humanoid = humanoid
	record.root = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?

	--[[
		Placed HERE, the moment the root exists, and not further down.

		LoadCharacter drops the character at whatever SpawnLocation Roblox finds
		first — which on a map-swapping game is routinely nowhere near the map
		that is actually loaded. Physics starts immediately, so by the time the
		old code reached its PivotTo at the bottom of this function the character
		had been falling for two WaitForChild yields, and teleporting a body that
		already carries velocity into map geometry is exactly how a player ends up
		flung across the world.

		So: move it as early as possible, then zero the momentum it arrived with.
		Clearing the velocity is the half that actually stops the fling — without
		it the solver resolves the overlap by converting that accumulated fall
		speed into a very fast exit.
	]]
	local spawnAt = record.spawnCFrame
	if not spawnAt then
		-- No CFrame was staged for this spawn. Ask the level rather than leaving
		-- the character wherever Roblox put it, which is the case that strands a
		-- player in the void when a map has just been swapped underneath them.
		local level = Registry.find("LevelService")
		if level and typeof(level.getSurvivorSpawnCFrame) == "function" then
			local ok, cframe = pcall(function()
				return level:getSurvivorSpawnCFrame(#Players:GetPlayers())
			end)
			if ok and typeof(cframe) == "CFrame" then
				spawnAt = cframe
			end
		end
	end

	if spawnAt then
		character:PivotTo(spawnAt)
		record.spawnCFrame = nil
		local root = record.root
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end

	humanoid.MaxHealth = S.MaxHealth
	humanoid.BreakJointsOnDeath = false -- GoreService owns what a body does
	record.baseJumpPower = humanoid.JumpPower
	record.baseJumpHeight = humanoid.JumpHeight
	record.appliedSpeed = -1

	for _, child in character:GetChildren() do
		stripDefaultHealthScript(child)
	end
	record.charTrove:connect(character.ChildAdded, stripDefaultHealthScript)

	-- The collision group is registered by the bootstrap. If that has not run
	-- (or failed), assigning it throws — and a survivor with default collision is
	-- still a playable survivor, so this must not take the spawn down with it.
	local ok, err = pcall(RigUtil.setCollisionGroup, character, "Survivor")
	if not ok then
		warn(string.format("[SurvivorService] collision group not applied: %s", tostring(err)))
	end

	record.charTrove:connect(humanoid.Died, function()
		-- Anything that killed the Humanoid outside the damage funnel (the void,
		-- a stray script) still has to travel through the death path.
		if record.state ~= STATE.Dead then
			self:kill(
				player,
				Types.newDamageContext({
					damageType = Enums.DamageType.Environment,
					hitPosition = record.root and record.root.Position or Vector3.zero,
				})
			)
		end
	end)

	self:_applyHumanoid(record)
	self:_refreshUprightState(record)
	self:_publish(record)
end

-- ─── public API ──────────────────────────────────────────────────────────────

--[[ Spawns a survivor at full strength. A fresh spawn is a fresh life: the incap
     ledger resets, because dying already cost everything it was going to. ]]
function SurvivorService:spawnSurvivor(player: Player)
	local record = self:_ensureRecord(player)

	self:_cancelInteraction(record)
	self:_cancelHelp(record)
	self:_releaseBody(player)

	record.health = S.StartHealth
	record.tempHealth = 0
	record.tempDecay = S.PillDecayPerSecond
	record.incapHealth = 0
	record.incapCount = 0
	record.blackAndWhite = false
	record.adrenalineUntil = 0
	record.stamina = S.MaxStamina
	record.sprintLocked = false
	record.ledgeRemaining = 0
	record.pinnedBy = nil
	record.pinnedKind = ""

	local index = table.find(awaitingRescue, player)
	if index then
		table.remove(awaitingRescue, index)
	end

	-- Drop the old rig before announcing the new state, so nothing tries to push
	-- health back onto a character that is one line away from being replaced.
	record.charTrove:clean()
	record.character = nil
	record.humanoid = nil
	record.root = nil

	self:_setState(record, STATE.Healthy)
	self:_publish(record)
	self:_publishProgress(record, 0)
	player:LoadCharacter()
end

--[[ Where the next LoadCharacter should put this player. Set by whatever owns
     the level, since this service knows nothing about geometry. ]]
function SurvivorService:setSpawnCFrame(player: Player, cframe: CFrame)
	self:_ensureRecord(player).spawnCFrame = cframe
end

function SurvivorService:setReady(player: Player, ready: boolean)
	self:_ensureRecord(player)
	player:SetAttribute(PA.IsReady, ready == true)
end

function SurvivorService:getState(player: Player): string
	local record = records[player]
	return record and record.state or STATE.Spectating
end

function SurvivorService:isIncapacitated(player: Player): boolean
	local state = self:getState(player)
	-- Hanging is not a different problem from a teammate's point of view.
	return state == STATE.Incapacitated or state == STATE.LedgeHanging
end

function SurvivorService:isAlive(player: Player): boolean
	local state = self:getState(player)
	return state ~= STATE.Dead and state ~= STATE.Spectating
end

function SurvivorService:getEffectiveHealth(player: Player): number
	local record = records[player]
	return record and self:_effective(record) or 0
end

--[[ How much faster this survivor performs heals and revives. Adrenaline's real
     value is not the temp health, it is this. ]]
function SurvivorService:getUseSpeedMultiplier(player: Player): number
	local record = records[player]
	if record and self:_hasAdrenaline(record) then
		return S.AdrenalineUseSpeedBonus
	end
	return 1
end

--[[
	Takes a player out of the running round without taking them off the server.

	What the pause menu's LEAVE MATCH does. They stop being a survivor, their
	body goes, and they are a spectator until the next round spawns them again —
	which is exactly the state a player who joined mid-round is already in, so
	nothing downstream needs a new case for it.

	Deliberately NOT a death. A death is an outcome: it feeds the wipe check as a
	casualty, it is worth a callout, it leaves a body to defib and it counts
	against the team. Someone choosing to stop playing is none of those, and
	scoring it as one would let a player fake a team wipe by quitting.

	The wipe check still ends the round if this was the last one standing — but
	it ends it because the roster is empty, not because anybody was killed.
]]
function SurvivorService:leaveRound(player: Player): boolean
	local record = records[player]
	if not record or record.state == STATE.Spectating then
		return false
	end

	--[[ Any interaction in flight is cancelled first. A player who leaves halfway
	     through reviving a teammate must not leave a revive running against a
	     survivor who is no longer there to finish it. ]]
	self:_cancelInteraction(record)
	self:_cancelHelp(record)
	self:_setState(record, STATE.Spectating)

	--[[ The body goes rather than being left standing. A character with no
	     player behind it is a thing the horde will path to, shoot at and pile on
	     — an unattended lure that the team then has to fight around. ]]
	local character = player.Character
	if character then
		player.Character = nil
		character:Destroy()
	end
	return true
end

function SurvivorService:getAliveSurvivors(): { Player }
	local alive = {}
	for player, record in records do
		if record.state ~= STATE.Dead and record.state ~= STATE.Spectating then
			table.insert(alive, player)
		end
	end
	return alive
end

--[[ Characters of everyone still in the fight, downed included — the Director
     must not drop a horde on top of a survivor just because they are on the
     floor. ]]
function SurvivorService:getSurvivorCharacters(): { Model }
	local characters = {}
	for _, record in records do
		if record.state ~= STATE.Dead and record.state ~= STATE.Spectating then
			local character = record.character
			if character and character.Parent then
				table.insert(characters, character)
			end
		end
	end
	return characters
end

--[[ 0-1 read on how the team is doing, weighted by effective health. Downed and
     dead survivors contribute zero, which is exactly the signal the Director
     wants when it decides whether to leave a medkit in the next room. ]]
function SurvivorService:getTeamHealthFraction(): number
	local total, count = 0, 0
	for _, record in records do
		if record.state ~= STATE.Spectating then
			count += 1
			if record.state ~= STATE.Dead then
				total += math.clamp(self:_effective(record) / S.MaxHealth, 0, 1)
			end
		end
	end
	if count == 0 then
		return 1
	end
	return total / count
end

--[[
	The only way a survivor loses health.

	`amount` arrives already scaled by region and falloff from DamageService.
	Friendly fire is scaled HERE, once — see the guard flag — because the melee
	multiplier is zero and a zero must block the hit outright rather than deliver
	a damage-free flinch to a teammate.
]]
function SurvivorService:damage(player: Player, amount: number, ctx): any
	local record = records[player]
	if not record then
		return Types.blockedResult(0)
	end
	if record.state == STATE.Dead or record.state == STATE.Spectating then
		return Types.blockedResult(0)
	end

	ctx = ctx or Types.newDamageContext()
	amount = tonumber(amount) or 0
	if amount <= 0 then
		return Types.blockedResult(self:_effective(record))
	end

	--[[
		Friendly fire is scaled here and only here. `friendlyFireApplied` is the
		opt-out for a caller that already scaled: set it and this leaves the
		number alone. Note this function READS the flag and never writes it — one
		DamageContext is commonly shared by all ten pellets of a shotgun blast,
		and a flag written on pellet one would let pellets two through ten through
		at full strength.
	]]
	if ctx.isFriendlyFire and not ctx.friendlyFireApplied then
		local multiplier = ctx.damageType == Enums.DamageType.Melee and S.FriendlyFireMeleeMultiplier
			or S.FriendlyFireMultiplier
		-- Melee never touches a teammate. That is not a rounding decision: melee
		-- is the answer to a crowd, and it has to stay usable in a doorway.
		if multiplier <= 0 then
			return Types.blockedResult(self:_effective(record))
		end
		amount *= multiplier
	end

	--[[
		The SHIELD ability, and it is the only thing this file knows about
		abilities.

		After friendly fire is scaled and before anything is applied, because a
		shield should eat the number that was actually going to land rather than
		the one before the rules were applied to it. AbilityService returns the
		REMAINDER — a shield with ten points left against a forty-point swing
		takes ten and lets thirty through — so a hit that is fully absorbed comes
		back as zero and stops here.

		Asked through the Registry and guarded, so a server whose ability service
		failed to boot still takes damage normally rather than becoming
		invulnerable, which is the failure mode that would be least obvious and
		most damaging.
	]]
	local abilities = Registry.find("AbilityService")
	if abilities and typeof(abilities.absorb) == "function" then
		local ok, remaining = pcall(abilities.absorb, abilities, player, amount)
		if ok and typeof(remaining) == "number" then
			amount = remaining
		end
	end
	if amount <= 0 then
		return Types.blockedResult(self:_effective(record))
	end

	-- Being hit interrupts anything anyone is holding on you, or you on them.
	self:_breakInteractionsInvolving(player)

	local dealt, killed, overkill = 0, false, 0

	if record.state == STATE.Incapacitated or record.state == STATE.LedgeHanging then
		-- Down or hanging, the incap pool is the only health there is.
		dealt = math.min(amount, record.incapHealth)
		overkill = amount - dealt
		record.incapHealth -= dealt
		if record.incapHealth <= 0 then
			record.incapHealth = 0
			self:kill(player, ctx)
			killed = true
		end
	else
		local before = self:_effective(record)
		dealt = math.min(amount, before)
		overkill = amount - dealt

		-- White health is a real buffer and burns first, exactly like L4D.
		local fromTemp = math.min(record.tempHealth, amount)
		record.tempHealth -= fromTemp
		record.health = math.max(record.health - (amount - fromTemp), 0)

		if record.health <= 0 then
			self:incapacitate(player, ctx)
			killed = record.state == STATE.Dead
		else
			self:_refreshUprightState(record)
			self:_applyHumanoid(record)
		end
	end

	self:_publish(record)

	-- DamageTaken belongs to DamageService, which is the only way into this
	-- function and which resolves the source from the attacker's own root rather
	-- than by walking back up the shot line. Firing it here as well drew the
	-- damage arrow twice, at two different places, and doubled the screen blood.

	if not killed and dealt > 0 then
		playAt(AudioConfig.Survivor.Hurt, record.root)
	end

	self.damaged:fire(player, dealt, ctx)

	local remaining = record.state == STATE.Incapacitated and record.incapHealth or self:_effective(record)
	return {
		dealt = dealt,
		blocked = false,
		killed = killed,
		overkill = overkill,
		-- GoreService, via the damage funnel, decides what a survivor's body does.
		goreLevel = Enums.GoreLevel.None,
		severedPart = nil,
		remainingHealth = remaining,
	}
end

--[[
	Adds health. `temporary` puts it in the white buffer, which decays; permanent
	health does not. Total is capped, so a black-and-white survivor can be topped
	up to BlackAndWhiteHealth and no further no matter what they drink.
]]
function SurvivorService:heal(player: Player, amount: number, temporary: boolean)
	local record = records[player]
	if not record or amount <= 0 then
		return
	end
	-- Health only goes into someone who is on their feet. A downed survivor's
	-- number is the incap pool, and the only thing that changes it is a revive.
	if not self:_isUpright(record) then
		return
	end

	local room = math.max(self:_cap(record) - self:_effective(record), 0)
	local granted = math.min(amount, room)
	if granted <= 0 then
		return
	end

	if temporary then
		record.tempHealth += granted
	else
		record.health += granted
	end

	self:_refreshUprightState(record)
	self:_applyHumanoid(record)
	self:_publish(record)
end

--[[
	A medkit. Heals a percentage of what is MISSING, so it is worth most to the
	player who is worst off — the L4D rule that stops the healthiest survivor from
	hoarding the kit. It also wipes the incap ledger, which is the only way back
	from black and white.
]]
--[[
	Covers a survivor in bile for `seconds`.

	Deals no damage and never will. The threat a Boomer poses is that you cannot
	see and the horde is walking at you; a health bar ticking down alongside that
	reads as the real danger when it is not, and a player who takes damage from
	bile learns to fear the wrong half of it.

	Stacking EXTENDS rather than adds. Two Boomers bursting on the same survivor
	is already the worst thing that can happen to them, and summing the timers
	would take a bad moment and turn it into thirty seconds of nothing to do.

	The stamp is absolute server time so the client can render a smooth fade off
	one value, the same way the wave clock works.
]]
function SurvivorService:applyBile(player: Player, seconds: number): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") or not player.Parent then
		return false
	end
	if typeof(seconds) ~= "number" or seconds <= 0 then
		return false
	end
	-- A dead or spectating survivor cannot be biled: there is no screen to cover.
	local state = self:getState(player)
	if state == STATE.Dead or state == STATE.Spectating then
		return false
	end

	local now = workspace:GetServerTimeNow()
	local current = tonumber(Attributes.get(player, PA.BiledUntil, 0)) or 0
	Attributes.set(player, PA.BiledUntil, math.max(current, now + seconds))
	return true
end

--[[ True while a survivor is still covered. For anything that wants to know
     rather than to change it — the Director reads it as a team in trouble. ]]
function SurvivorService:isBiled(player: Player): boolean
	local until_ = tonumber(Attributes.get(player, PA.BiledUntil, 0)) or 0
	return until_ > workspace:GetServerTimeNow()
end

function SurvivorService:applyMedkitHeal(player: Player): boolean
	local record = records[player]
	if not record or not self:_isUpright(record) then
		return false
	end

	local cap = S.MaxHealth
	local missing = math.max(cap - record.health, 0)
	record.health = math.min(record.health + missing * S.MedkitHealPercent, cap)

	record.incapCount = 0
	record.blackAndWhite = false

	self:_refreshUprightState(record)
	self:_applyHumanoid(record)
	self:_publish(record)
	playAt(AudioConfig.Survivor.HealSelf, record.root)
	return true
end

--[[
	Pills or adrenaline. Pills are a big buffer on a slow clock; adrenaline is a
	smaller one on a fast clock that also makes you quicker at everything — which
	is what actually saves the run.
]]
function SurvivorService:applyPills(player: Player, itemId: string): boolean
	local record = records[player]
	if not record or not self:_isUpright(record) then
		return false
	end

	if itemId == Enums.PillItem.Adrenaline then
		record.adrenalineUntil = os.clock() + S.AdrenalineDuration
		-- The most recent item sets the drain rate for the whole buffer; two
		-- separate decay clocks on one bar is a HUD nobody can read.
		record.tempDecay = S.AdrenalineDecayPerSecond
		self:heal(player, S.AdrenalineHealth, true)
		record.stamina = S.MaxStamina
		record.sprintLocked = false
		Remotes.Event.ScreenEffect:FireClient(player, {
			effect = "Adrenaline",
			duration = S.AdrenalineDuration,
			intensity = 1,
		})
	elseif itemId == Enums.PillItem.PainPills then
		record.tempDecay = S.PillDecayPerSecond
		self:heal(player, S.PillHealth, true)
	else
		return false
	end

	playAt(AudioConfig.Survivor.PillsUse, record.root)
	return true
end

--[[
	Going down. The escalation lives here and nowhere else:
	  down 1  -> incapacitated
	  down 2  -> incapacitated, and you come back black and white
	  down 3  -> you do not come back
]]
function SurvivorService:incapacitate(player: Player, ctx)
	local record = records[player]
	if not record then
		return
	end
	if record.state == STATE.Incapacitated or record.state == STATE.Dead then
		return
	end

	ctx = ctx or Types.newDamageContext()

	if record.incapCount >= S.MaxIncapsBeforeDeath then
		self:kill(player, ctx)
		return
	end

	record.incapCount += 1
	if record.incapCount >= S.MaxIncapsBeforeDeath then
		-- Flagged now, felt on stand-up: from here a single down is fatal.
		record.blackAndWhite = true
	end

	record.health = 0
	record.tempHealth = 0
	record.incapHealth = S.IncapHealth
	record.ledgeRemaining = 0
	record.adrenalineUntil = 0

	self:_clearPinFields(record)
	self:_cancelInteraction(record)
	self:_cancelHelp(record)

	self:_setState(record, STATE.Incapacitated)
	self:_publish(record)

	local inventory = Registry.find("InventoryService")
	if inventory then
		inventory:setIncapacitated(player, true)
	end

	playAt(AudioConfig.Survivor.Incap, record.root)
end

--[[ Hanging off a ledge: a countdown, a slow drain, and a teammate who has to
     stop shooting to pull you up. Letting go spends one of your lives. ]]
function SurvivorService:ledgeHang(player: Player)
	local record = records[player]
	if not record or not self:_isUpright(record) then
		return
	end

	self:_clearPinFields(record)
	self:_cancelInteraction(record)
	self:_cancelHelp(record)

	record.ledgeRemaining = S.LedgeHangTime
	record.incapHealth = S.IncapHealth
	self:_setState(record, STATE.LedgeHanging)
	self:_publish(record)
end

--[[ Standing back up. The survivor comes up on TEMP health, so a revive buys
     the team a minute rather than a reset — that clock is the whole point. ]]
function SurvivorService:revive(player: Player, rescuer: Player?)
	local record = records[player]
	if not record then
		return
	end
	if record.state ~= STATE.Incapacitated and record.state ~= STATE.LedgeHanging then
		return
	end

	record.health = 0
	record.tempHealth = 0
	record.incapHealth = 0
	record.ledgeRemaining = 0
	-- Revive health drains at the standard white-health rate; it is a loan.
	record.tempDecay = S.PillDecayPerSecond
	self:_setState(record, STATE.Hurt)
	self:heal(player, S.ReviveHealth, true)

	local inventory = Registry.find("InventoryService")
	if inventory then
		inventory:setIncapacitated(player, false)
	end

	self:_cancelHelp(record)
	self:_publishProgress(record, 0)
	self:_refreshUprightState(record)
	self:_applyHumanoid(record)
	self:_publish(record)

	playAt(AudioConfig.Survivor.Revived, record.root)

	-- revive() is also called directly (a scripted rescue, a debug command), so
	-- the rescuer's own hold is tidied up here rather than only on completion.
	if rescuer then
		local helperRecord = records[rescuer]
		if helperRecord then
			self:_cancelInteraction(helperRecord)
		end
	end

	-- Fired last, once the record is fully consistent: a listener that reads
	-- state off this player must not see it halfway between down and standing.
	SurvivorService.revived:fire(player, rescuer)
end

--[[ Death. The body stays: it is a defib target, and a team that can see where
     their friend fell behaves differently from one that cannot. ]]
function SurvivorService:kill(player: Player, ctx)
	local record = records[player]
	if not record or record.state == STATE.Dead then
		return
	end
	ctx = ctx or Types.newDamageContext()

	record.health = 0
	record.tempHealth = 0
	record.incapHealth = 0
	record.ledgeRemaining = 0
	record.adrenalineUntil = 0

	self:_clearPinFields(record)
	self:_cancelInteraction(record)
	self:_cancelHelp(record)

	self:_setState(record, STATE.Dead)
	self:_publishProgress(record, 0)
	self:_publish(record)

	local character = record.character
	if character and character.Parent then
		bodies[character] = player
		CollectionService:AddTag(character, BODY_TAG)
	end

	if GameConfig.RespawnClosetsEnabled and not table.find(awaitingRescue, player) then
		table.insert(awaitingRescue, player)
	end

	playAt(AudioConfig.Survivor.Death, record.root)

	local killerName = ""
	if ctx.attacker then
		killerName = ctx.attacker.Name
	elseif ctx.attackerModel then
		killerName = ctx.attackerModel:GetAttribute(Attributes.Infected.Kind) or ctx.attackerModel.Name
	end
	Remotes.Event.KillFeed:FireAllClients({
		killer = killerName,
		victim = player.Name,
		weaponId = ctx.weaponId or "",
		headshot = ctx.region == Enums.HitRegion.Head,
	})

	self.died:fire(player, ctx)
end

--[[
	Pinned by a Hunter, Smoker or Charger. A pinned survivor cannot move or turn,
	and that is the entire threat — so the counter has to be reliable. The pin is
	released by clearPinned (shove, damage, the special dying) and, as a backstop,
	by the heartbeat the moment the pinning model stops being alive. A pin the
	team cannot answer is a bug, not difficulty.
]]
function SurvivorService:setPinned(player: Player, by: Model?, kind: string?)
	local record = records[player]
	if not record then
		return false
	end
	if by == nil then
		self:clearPinned(player)
		return true
	end
	if not self:_isUpright(record) then
		return false
	end

	record.pinnedBy = by
	record.pinnedKind = kind or by:GetAttribute(Attributes.Infected.Kind) or ""
	self:_cancelInteraction(record)
	self:_setState(record, STATE.Pinned)
	self:_publish(record)
	return true
end

--[[ Forgets the pin without touching state. Used by the paths that are about to
     set a state of their own, so the client never sees a one-frame flash of
     "standing" between being pinned and going down. ]]
function SurvivorService:_clearPinFields(record)
	record.pinnedBy = nil
	record.pinnedKind = ""
end

function SurvivorService:clearPinned(player: Player)
	local record = records[player]
	if not record or (record.pinnedBy == nil and record.pinnedKind == "") then
		return
	end

	self:_clearPinFields(record)
	if record.state == STATE.Pinned then
		local hurt = self:_effective(record) < S.HurtThreshold
		self:_setState(record, hurt and STATE.Hurt or STATE.Healthy)
	end
	self:_applyHumanoid(record)
	self:_publish(record)
end

function SurvivorService:getPinnedBy(player: Player): Model?
	local record = records[player]
	return record and record.pinnedBy or nil
end

--[[ Brings a dead survivor back on the spot, at DefibReviveHealth. A defib also
     clears the incap ledger — it is the second chance the item exists to sell. ]]
function SurvivorService:defibrillate(player: Player): boolean
	local record = records[player]
	if not record or record.state ~= STATE.Dead then
		return false
	end

	local cframe
	local body = record.character
	if body and body.Parent then
		cframe = body:GetPivot()
	end
	self:_releaseBody(player)

	record.incapCount = 0
	record.blackAndWhite = false
	self:_respawn(player, cframe, S.DefibReviveHealth)
	return true
end

--[[ Closet rescue. Everyone who died is queued in the order they fell; opening a
     closet brings back whoever has been waiting longest. ]]
function SurvivorService:rescueFromCloset(closet: Instance): Player?
	if not GameConfig.RespawnClosetsEnabled then
		return nil
	end
	local player = table.remove(awaitingRescue, 1)
	if not player or not records[player] then
		return nil
	end

	local cframe
	if closet:IsA("Model") then
		cframe = closet:GetPivot()
	elseif closet:IsA("BasePart") then
		cframe = closet.CFrame
	end

	self:_releaseBody(player)
	local record = records[player]
	record.incapCount = 0
	record.blackAndWhite = false
	self:_respawn(player, cframe, S.DefibReviveHealth)
	return player
end

function SurvivorService:getAwaitingRescue(): { Player }
	return table.clone(awaitingRescue)
end

-- ─── respawn / bodies ────────────────────────────────────────────────────────

function SurvivorService:_releaseBody(player: Player)
	for model, owner in bodies do
		if owner == player then
			bodies[model] = nil
			if model.Parent then
				CollectionService:RemoveTag(model, BODY_TAG)
			end
		end
	end
end

--[[ Rebuilds a character and puts the survivor back on their feet with permanent
     health. LoadCharacter yields, so this is never called from the heartbeat. ]]
function SurvivorService:_respawn(player: Player, cframe: CFrame?, health: number)
	local record = self:_ensureRecord(player)
	record.health = math.min(health, self:_cap(record))
	record.tempHealth = 0
	record.incapHealth = 0
	record.stamina = S.MaxStamina
	record.sprintLocked = false
	record.spawnCFrame = cframe

	local index = table.find(awaitingRescue, player)
	if index then
		table.remove(awaitingRescue, index)
	end

	record.charTrove:clean()
	record.character = nil
	record.humanoid = nil
	record.root = nil

	self:_setState(record, STATE.Healthy)
	self:_publish(record)
	task.spawn(function()
		player:LoadCharacter()
	end)
end

-- ─── interactions ────────────────────────────────────────────────────────────

local function resolvePlayerTarget(instance: Instance): Player?
	if instance:IsA("Player") then
		return instance
	end
	local model: Model? = nil
	if instance:IsA("Model") then
		model = instance
	elseif instance:IsA("BasePart") then
		model = RigUtil.getCharacterFromPart(instance)
	end
	if not model then
		return nil
	end
	return Players:GetPlayerFromCharacter(model) or bodies[model]
end

local function pivotOf(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		local ok, pivot = pcall(instance.GetPivot, instance)
		if ok then
			return pivot.Position
		end
	end
	return nil
end

--[[ Decides what holding the interact key on `target` actually means, given who
     is asking and what they are carrying. Returns nil when there is nothing to
     do, which is the normal case for the other handlers on this remote. ]]
function SurvivorService:_classify(record, target: Instance)
	local inventory = Registry.find("InventoryService")
	local heldHealthItem = inventory and inventory:getItem(record.player, Enums.Slot.Health) or nil

	local targetPlayer = resolvePlayerTarget(target)
	if targetPlayer and targetPlayer ~= record.player then
		local other = records[targetPlayer]
		if other then
			if other.state == STATE.Incapacitated then
				return INTERACT.Revive, targetPlayer, S.ReviveTime, "Revive"
			elseif other.state == STATE.LedgeHanging then
				return INTERACT.LedgePull, targetPlayer, S.LedgePullTime, "Pull Up"
			elseif other.state == STATE.Dead then
				if heldHealthItem == Enums.HealthItem.Defibrillator then
					return INTERACT.Defib, targetPlayer, S.DefibUseTime, "Revive"
				end
			elseif heldHealthItem == Enums.HealthItem.Medkit and other.health < S.MaxHealth then
				return INTERACT.HealAlly, targetPlayer, S.MedkitAllyUseTime, "Heal"
			end
		end
	end

	if
		GameConfig.RespawnClosetsEnabled
		and #awaitingRescue > 0
		and CollectionService:HasTag(target, CLOSET_TAG)
	then
		return INTERACT.Rescue, nil, S.ClosetRescueTime, "Rescue"
	end

	--[[ An ammo crate. Asked of the service rather than of the tag alone, because
	     a spent crate keeps its tag while it is on cooldown — the ghost is still
	     there, it just has nothing to give yet. ]]
	if CollectionService:HasTag(target, AMMO_CRATE_TAG) then
		local crates = Registry.find("AmmoCrateService")
		if crates and crates:isAvailable(target) then
			return INTERACT.Resupply, nil, MapConfig.AmmoCrates.UseSeconds, "Resupply"
		end
	end

	return nil
end

function SurvivorService:_beginInteract(player: Player, target: Instance)
	local record = records[player]
	if not record or not self:_isUpright(record) or not record.root then
		return
	end
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(game) then
		return
	end

	local now = os.clock()
	if now - record.lastInteractRequest < INTERACT_REQUEST_INTERVAL then
		return
	end
	record.lastInteractRequest = now

	-- Picking something up is instant and has its own, shorter range.
	if target:GetAttribute(Attributes.Pickup.Slot) ~= nil then
		local position = pivotOf(target)
		if position and distanceSquared(record.root.Position, position) <= PICKUP_RANGE * PICKUP_RANGE then
			local inventory = Registry.find("InventoryService")
			if inventory then
				inventory:pickup(player, target)
			end
		end
		return
	end

	local kind, targetPlayer, duration, verb = self:_classify(record, target)
	if not kind then
		return
	end

	local position = targetPlayer and records[targetPlayer].root and records[targetPlayer].root.Position
		or pivotOf(target)
	if not position or distanceSquared(record.root.Position, position) > INTERACT_RANGE * INTERACT_RANGE then
		return
	end

	-- Whatever this player was holding before, they are not holding it now.
	self:_cancelInteraction(record)

	-- Two rescuers on one downed survivor would each run their own clock and the
	-- second one to finish would revive somebody already on their feet. First
	-- hold wins.
	if targetPlayer then
		local other = records[targetPlayer]
		if other.helper and other.helper ~= player and records[other.helper] then
			return
		end
		other.helper = player
	end

	-- Adrenaline shortens the hold itself, so the client's prompt duration and
	-- the server's clock agree without sending progress over the wire.
	local scaled = duration / self:getUseSpeedMultiplier(player)
	record.interaction = {
		kind = kind,
		target = target,
		targetPlayer = targetPlayer,
		duration = math.max(scaled, 0.05),
		elapsed = 0,
	}

	Remotes.Event.InteractPromptChanged:FireClient(player, {
		visible = true,
		verb = verb,
		subject = targetPlayer and targetPlayer.Name or target.Name,
		duration = record.interaction.duration,
	})
end

function SurvivorService:_cancelInteraction(record)
	local interaction = record.interaction
	if not interaction then
		return
	end
	record.interaction = nil

	local targetPlayer = interaction.targetPlayer
	if targetPlayer then
		local other = records[targetPlayer]
		if other and other.helper == record.player then
			other.helper = nil
			self:_publishProgress(other, 0)
		end
	end

	self:_publishProgress(record, 0)
	Remotes.Event.InteractPromptChanged:FireClient(record.player, { visible = false })
end

--[[ Cancels whatever someone else is doing TO this survivor. ]]
function SurvivorService:_cancelHelp(record)
	local helper = record.helper
	record.helper = nil
	self:_publishProgress(record, 0)
	if helper then
		local helperRecord = records[helper]
		if
			helperRecord
			and helperRecord.interaction
			and helperRecord.interaction.targetPlayer == record.player
		then
			self:_cancelInteraction(helperRecord)
		end
	end
end

function SurvivorService:_breakInteractionsInvolving(player: Player)
	local record = records[player]
	if not record then
		return
	end
	self:_cancelInteraction(record)
	self:_cancelHelp(record)
end

function SurvivorService:_completeInteraction(record)
	local interaction = record.interaction
	if not interaction then
		return
	end
	local player = record.player
	local kind = interaction.kind
	local targetPlayer = interaction.targetPlayer
	local target = interaction.target
	self:_cancelInteraction(record)

	local inventory = Registry.find("InventoryService")

	if kind == INTERACT.Revive or kind == INTERACT.LedgePull then
		if targetPlayer then
			self:revive(targetPlayer, player)
		end
	elseif kind == INTERACT.HealAlly then
		if
			targetPlayer
			and inventory
			and inventory:consumeSlot(player, Enums.Slot.Health, Enums.HealthItem.Medkit)
		then
			self:applyMedkitHeal(targetPlayer)
		end
	elseif kind == INTERACT.Defib then
		if
			targetPlayer
			and inventory
			and inventory:consumeSlot(player, Enums.Slot.Health, Enums.HealthItem.Defibrillator)
		then
			-- LoadCharacter yields; the heartbeat must not.
			task.spawn(function()
				self:defibrillate(targetPlayer)
			end)
		end
	elseif kind == INTERACT.Rescue then
		task.spawn(function()
			self:rescueFromCloset(target)
		end)
	elseif kind == INTERACT.Resupply then
		local crates = Registry.find("AmmoCrateService")
		if crates and target then
			crates:consume(player, target)
		end
	end
end

--[[ Advances one hold. Every cancellation rule from the design lives here: too
     far apart, either party hurt (handled in damage()), the subject's state
     changing under you, or the target simply going away. ]]
function SurvivorService:_stepInteraction(record, dt: number)
	local interaction = record.interaction
	if not interaction then
		return
	end

	if not self:_isUpright(record) or not record.root then
		self:_cancelInteraction(record)
		return
	end

	local target = interaction.target
	if not target.Parent then
		self:_cancelInteraction(record)
		return
	end

	local position
	local targetPlayer = interaction.targetPlayer
	if targetPlayer then
		local other = records[targetPlayer]
		if not other or not other.root then
			self:_cancelInteraction(record)
			return
		end
		-- A revive that is no longer a revive (they died, or got up) is over.
		local stillValid = (interaction.kind == INTERACT.Revive and other.state == STATE.Incapacitated)
			or (interaction.kind == INTERACT.LedgePull and other.state == STATE.LedgeHanging)
			or (interaction.kind == INTERACT.Defib and other.state == STATE.Dead)
			or (interaction.kind == INTERACT.HealAlly and self:_isUpright(other))
		if not stillValid then
			self:_cancelInteraction(record)
			return
		end
		position = other.root.Position
	else
		position = pivotOf(target)
		if not position then
			self:_cancelInteraction(record)
			return
		end
	end

	if distanceSquared(record.root.Position, position) > INTERACT_RANGE * INTERACT_RANGE then
		self:_cancelInteraction(record)
		return
	end

	interaction.elapsed += dt
	local alpha = math.clamp(interaction.elapsed / interaction.duration, 0, 1)
	self:_publishProgress(record, alpha)
	if targetPlayer and records[targetPlayer] then
		self:_publishProgress(records[targetPlayer], alpha)
	end

	if alpha >= 1 then
		self:_completeInteraction(record)
	end
end

-- ─── the one loop ────────────────────────────────────────────────────────────

function SurvivorService:_stepRecord(record, dt: number, now: number)
	local state = record.state
	if state == STATE.Spectating or state == STATE.Dead then
		return
	end

	local player = record.player
	local humanoid = record.humanoid
	if not humanoid or humanoid.Parent == nil then
		return
	end

	-- A pin whose owner is gone is a softlock. Never let one survive a frame.
	local pinner = record.pinnedBy
	if pinner and (pinner.Parent == nil or not RigUtil.isAlive(pinner)) then
		self:clearPinned(player)
		state = record.state
	end

	if record.adrenalineUntil > 0 and now >= record.adrenalineUntil then
		record.adrenalineUntil = 0
		record.tempDecay = S.PillDecayPerSecond
	end

	-- White health always drains, in every state. It is a clock, not a resource.
	if record.tempHealth > 0 then
		record.tempHealth = math.max(record.tempHealth - record.tempDecay * dt, 0)
		if self:_isUpright(record) then
			self:_refreshUprightState(record)
		end
	end

	if state == STATE.Incapacitated then
		record.incapHealth -= S.IncapBleedPerSecond * dt
		if record.incapHealth <= 0 then
			record.incapHealth = 0
			self:kill(player, Types.newDamageContext({ damageType = Enums.DamageType.Environment }))
			return
		end
	elseif state == STATE.LedgeHanging then
		record.ledgeRemaining -= dt
		record.incapHealth -= S.LedgeHangDamagePerSecond * dt
		if record.ledgeRemaining <= 0 or record.incapHealth <= 0 then
			-- Letting go spends a life, and spends the last one for good.
			record.ledgeRemaining = 0
			self:incapacitate(player, Types.newDamageContext({ damageType = Enums.DamageType.Falling }))
			return
		end
	end

	-- Stamina. Sprinting is inferred from the survivor actually outrunning their
	-- walk speed, which keeps the whole system server-authoritative for free.
	local root = record.root
	local sprinting = false
	if root and self:_isUpright(record) and record.stamina > 0 then
		local velocity = root.AssemblyLinearVelocity
		local planar = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
		local walking = self:_effective(record) < S.HurtThreshold and S.LimpWalkSpeed or S.NormalWalkSpeed
		--[[
			The baseline has to carry every multiplier _computeWalkSpeed applied,
			or the test is comparing a real speed against an imaginary one.

			Adrenaline was the case that proved it. It multiplies the FINAL speed by
			1.25, so a stimmed survivor merely walking moved at 22.5 against a
			baseline of 18 + 1.5 — read as sprinting, drained to zero, set
			sprintLocked, and then could never recover, because walking still
			outran the baseline and the detector never went false. Adrenaline, the
			thing you take to move faster, deleted your sprint for its whole
			duration and left you slower than when you drank it.
		]]
		if self:_hasAdrenaline(record) then
			walking *= S.AdrenalineSpeedBonus
		end
		sprinting = planar > walking + SPRINT_DETECT_MARGIN
	end
	if sprinting then
		record.stamina = math.max(record.stamina - S.SprintStaminaDrain * dt, 0)
		if record.stamina <= 0 then
			record.sprintLocked = true
		end
	elseif record.stamina < S.MaxStamina then
		-- Downed and pinned survivors get their wind back too; standing up with
		-- an empty bar just means dying two seconds later.
		record.stamina = math.min(record.stamina + S.SprintStaminaRegen * dt, S.MaxStamina)
		if record.sprintLocked and record.stamina >= S.MaxStamina * SPRINT_RECOVER_FRACTION then
			record.sprintLocked = false
		end
	end

	self:_applyHumanoid(record)
	self:_stepInteraction(record, dt)

	-- Flow only ever feeds the Director, at human timescales.
	record.flowClock += dt
	if record.flowClock >= FLOW_PUBLISH_INTERVAL then
		record.flowClock = 0
		local level = Registry.find("LevelService")
		if level and root then
			local flow = level:getFlowDistance(root.Position)
			local quantised = math.floor(flow + 0.5)
			if record.pub.flow ~= quantised then
				record.pub.flow = quantised
				player:SetAttribute(PA.FlowDistance, quantised)
			end
		end
	end

	self:_publish(record)
end

function SurvivorService:_step(dt: number)
	local now = os.clock()
	for _, record in records do
		self:_stepRecord(record, dt, now)
	end
end

-- ─── lifecycle ───────────────────────────────────────────────────────────────

function SurvivorService:init()
	serviceTrove:connect(Players.PlayerAdded, function(player)
		self:_ensureRecord(player)
	end)
	serviceTrove:connect(Players.PlayerRemoving, function(player)
		self:_destroyRecord(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_ensureRecord(player)
	end
end

--[[
	The shortest gap between two accepted requests on one of the two state
	remotes below.

	Both of them end in a SetAttribute on a Player, which Roblox replicates to
	EVERY client. Neither has a natural rate limit — the "did it change" guard
	only stops a repeat, not an alternation — so a crafted client toggling one
	every frame makes the server broadcast a property change to the whole server
	at frame rate. A tenth of a second is far faster than any human toggles
	crouch and ends that entirely.
]]
local STATE_REMOTE_COOLDOWN = 0.1
local lastStateRequestAt: { [Player]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any

local function stateRequestAllowed(player: Player, key: string, cooldown: number): boolean
	local perPlayer = lastStateRequestAt[player]
	if not perPlayer then
		perPlayer = {}
		lastStateRequestAt[player] = perPlayer
	end
	local now = os.clock()
	if perPlayer[key] and now - perPlayer[key] < cooldown then
		return false
	end
	perPlayer[key] = now
	return true
end

function SurvivorService:start()
	--[[ The client asks; the server decides and publishes. Nothing here trusts
	     the request beyond "this player pressed crouch" — the speed clamp and the
	     attribute are both computed on this side. ]]
	serviceTrove:connect(Remotes.Event.SetCrouchState.OnServerEvent, function(player, wanted)
		--[[
			The PRESS is throttled. The RELEASE never is.

			That asymmetry is the whole point. Crouch rides the key's down/up
			edge, and a tap shorter than the cooldown would have its release
			swallowed — leaving the player stuck crouched at eight studs a second
			with no key held and no way to say so. Dropping a press costs a
			re-press; dropping a release costs the round.

			It still closes the spam: an alternation can only get its `false`
			through, so the attribute settles rather than broadcasting at frame
			rate.
		]]
		if wanted == true and not stateRequestAllowed(player, "crouch", STATE_REMOTE_COOLDOWN) then
			return
		end
		local record = records[player]
		if not record then
			return
		end
		local crouching = wanted == true and self:_isUpright(record)
		if record.crouching == crouching then
			return
		end
		record.crouching = crouching
		Attributes.set(player, Attributes.Player.IsCrouching, crouching)
	end)

	--[[ Sprint, asked for the same way. NOT throttled and NOT published as an
	     attribute: it changes nothing anybody else can see, it is read only by
	     _computeWalkSpeed on this side, and a dropped release here would pin a
	     player at sprint speed with no key held — the same failure the crouch
	     handler above refuses to allow. ]]
	serviceTrove:connect(Remotes.Event.SetSprintState.OnServerEvent, function(player, wanted)
		local record = records[player]
		if not record then
			return
		end
		record.sprinting = wanted == true
	end)

	--[[
		Personal difficulty.

		The client picks it in the options panel; the server is the only thing
		that acts on it, because a client-side "the infected hit me less" is a
		client telling the server how much damage it took. Coerced through
		SettingsConfig, so an unknown name lands on NORMAL rather than on an
		arbitrary multiplier — and every multiplier in that table is at most 1,
		which is what keeps this a comfort setting rather than a cheat.
	]]
	serviceTrove:connect(Remotes.Event.SetDifficulty.OnServerEvent, function(player, wanted)
		--[[ A second between changes. Nobody moves a settings row faster than
		     that, and this is the other remote that ends in a replicated
		     attribute write. ]]
		if not stateRequestAllowed(player, "difficulty", 1.0) then
			return
		end
		local choice = SettingsConfig.coerce("difficulty", wanted)
		if typeof(choice) ~= "string" then
			return
		end
		Attributes.set(player, Attributes.Player.Difficulty, choice)
	end)

	serviceTrove:connect(Remotes.Event.BeginInteract.OnServerEvent, function(player, target)
		-- Other systems (doors, level triggers) listen on this remote too; an
		-- unrecognised target is silently not ours.
		if typeof(target) == "Instance" then
			self:_beginInteract(player, target)
		end
	end)

	serviceTrove:connect(Remotes.Event.CancelInteract.OnServerEvent, function(player)
		local record = records[player]
		if record then
			self:_cancelInteraction(record)
		end
	end)

	--[[
		Pings. The client raycasts and classifies what it hit; we validate that it
		is plausible and turn it into a spoken callout everyone hears, which is how
		Left 4 Dead does it — "Pills here!" is a line of dialogue, not a marker
		floating in space. Rate-limited per player, because the alternative is one
		bound key that can spam every client's subtitle queue.
	]]
	serviceTrove:connect(Remotes.Event.PingLocation.OnServerEvent, function(player, payload)
		if typeof(payload) ~= "table" then
			return
		end
		local position = payload.position
		if typeof(position) ~= "Vector3" then
			return
		end
		-- Reject NaN and anything absurdly far away rather than trusting the ray.
		if position ~= position or position.Magnitude > 1e5 then
			return
		end

		local record = records[player]
		if not record or record.state == Enums.SurvivorState.Spectating then
			return
		end

		local now = os.clock()
		if now - (record.lastPingAt or 0) < PING_COOLDOWN then
			return
		end
		record.lastPingAt = now

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - position).Magnitude > PING_MAX_RANGE then
			return
		end

		local kind = if typeof(payload.kind) == "string" then payload.kind else "Location"
		local line = PING_LINES[kind] or PING_LINES.Location
		Remotes.Event.Subtitle:FireAllClients({
			speaker = player.DisplayName,
			text = line,
			duration = PING_SUBTITLE_SECONDS,
			position = position,
		})
	end)

	serviceTrove:add(RunService.Heartbeat:Connect(function(dt)
		self:_step(dt)
	end))
end

Registry.register("SurvivorService", SurvivorService)

return SurvivorService
