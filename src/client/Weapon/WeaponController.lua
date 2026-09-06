--!nonstrict
--[[
	WeaponController — the fire loop, and every millisecond of latency it hides.

	The server decides what was hit. This file decides what the trigger FEELS
	like, and it does not wait for permission to do that: the frame the mouse
	goes down, the muzzle flashes, the tracer draws, the camera kicks, the shell
	ejects and the ammo counter drops. The packet leaves afterwards. A gun that
	waits a round trip before it reacts is a gun nobody wants to hold, no matter
	how correct its damage is.

	── WHAT MAY BE PREDICTED, AND WHAT MAY NOT ─────────────────────────────────
	Predicted here: muzzle flash, tracer, recoil, shake, fire sound, the ammo
	count, and the reload clock. Every one of those is presentation the server
	will agree with or quietly correct.

	Never predicted: a hit, a damage number, a kill, a state change. Those arrive
	as HitConfirmed / GoreEvent and belong to the controllers that own them. A
	predicted hitmarker that the server disagrees with is worse than no hitmarker
	at all, because it teaches the player to trust something that lies.

	── THE SHARED CONE ─────────────────────────────────────────────────────────
	Read Shared/Util/ShotPattern.lua's header, then BallisticsService's. One
	integer seed goes out with the shot; both machines feed it to Random.new()
	and get the same pellet directions. That is the only reason the tracers drawn
	here land where the server's pellets resolved.

	The seed is half the contract. The other half is the CONE ANGLE, which is not
	sent — the server recomputes it. So the bloom model below is a deliberate,
	line-for-line mirror of BallisticsService's:

	    base   = isAiming and spreadAim or spreadHip
	    base  += spreadMoving          while actually moving
	    cone   = min(base + bloom, max(spreadMax, base))
	    bloom += bloomPerShot          after the shot
	    bloom -= bloomRecovery * dt    continuously

	If those two drift apart, the same seed produces different directions and the
	whole deterministic-pattern guarantee is worth nothing. Change one, change
	both. It is also what CrosshairController reads, so the gap between the ticks
	is the literal cone the shot will use.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	One Heartbeat connection drives held-auto fire, the reload clock and ammo
	reconciliation for the whole controller. Bloom is not stepped per frame at
	all: it is a closed-form decay evaluated when someone asks. Predicted tracers
	are capped at the same three the server replicates, so a shotgun blast is
	three raycasts, not ten.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RequisitionConfig = require(Shared.Config.RequisitionConfig)
local ShotPattern = require(Shared.Util.ShotPattern)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local LA = Attributes.Loadout
local PA = Attributes.Player
local STATE = Enums.SurvivorState

--[[ Reload timings, with the FIELD DRILL requisition applied if the team bought
     one. These are the client's PREDICTION of a clock the server also runs —
     see the matching pair in InventoryService — so both sides read the multiplier
     from RequisitionConfig rather than each deciding what a drill is worth. Get
     that wrong and the magazine appears at a different moment on each machine,
     which the player experiences as a shot the server refused after the reload
     visibly finished. ]]
local function reloadTimeFor(definition: any): number
	return definition.reloadTime * RequisitionConfig.reloadScale(Workspace)
end

local function shellTimeFor(definition: any): number
	return definition.reloadPerShell * RequisitionConfig.reloadScale(Workspace)
end

--[[ Mirrors BallisticsService's own movement test exactly, including the
     velocity fallback for a survivor who is being carried or shoved. ]]
local MOVE_INTENT_EPSILON = 0.1
local MOVING_SPEED_SQUARED = 9

--[[ The server draws three tracers per trigger pull and no more, because ten
     from one shotgun read as one cone of light anyway. Index 1 is ShotPattern's
     guaranteed centre pellet, so the shot always draws where the crosshair was. ]]
local MAX_PREDICTED_TRACERS = 3

--[[ The server is behind us by a round trip while we are firing, so a HIGHER
     server ammo count is normally just latency, not disagreement. We only
     believe an upward correction once the trigger has been quiet this long. A
     lower count is believed immediately: the server never gives ammo back. ]]
local RECONCILE_GRACE = 0.4

--[[ When the pump happens, from WeaponConfig so the character animation on the
     server fires at the same instant this does. See WeaponConfig.PumpPoint. ]]
local PUMP_POINT = WeaponConfig.PumpPoint

-- An empty trigger held down clicks at a readable rate rather than at the
-- weapon's rpm. Sixteen dry clicks a second is noise; three is a message.
local DRY_FIRE_INTERVAL = 0.3

--[[ Recoil is a learnable pattern only if the shot index climbs through a
     burst. Releasing the trigger for this long starts the pattern over, which
     is what makes tapping genuinely more accurate than holding. ]]
local BURST_RESET = 0.35

--[[ A small ring of Sound instances rather than one per shot: at the Vector's
     1100rpm a fresh Instance per round is eighteen allocations a second and
     eighteen more for the GC, for audio that is 60ms long. ]]
local SOUND_POOL_SIZE = 8

-- How long a predicted tracer stays remembered, for ImpactController to
-- recognise the server's echo of a shot we already drew. One round trip plus
-- slack; anything older cannot be an echo of ours.
local ECHO_MEMORY = 0.6
local ECHO_SLOTS = 12
local ECHO_TOLERANCE = 4 -- studs of slack between our origin and the server's

--[[ States in which no trigger does anything. Mirrors BallisticsService's list:
     incapacitated is absent because a downed survivor still has the pistol. ]]
local CANNOT_FIRE: { [string]: boolean } = {
	[STATE.Dead] = true,
	[STATE.Spectating] = true,
	[STATE.LedgeHanging] = true,
	[STATE.Pinned] = true,
}

local WeaponController = {}

WeaponController.weaponChanged = Signal.new() -- (weaponId, definition?)
WeaponController.ammoChanged = Signal.new() -- (ammo, reserve)

local player = Players.LocalPlayer
local trove = Trove.new()

local state = {
	weaponId = nil :: string?,
	definition = nil :: any,
	slot = Enums.Slot.Secondary,

	ammo = 0,
	reserve = 0,

	bloom = 0,
	bloomAt = 0,
	bloomWeaponId = nil :: string?,

	aiming = false,
	sentAiming = false,
	firing = false,
	nextFireAt = 0,
	lastPredictAt = 0,
	burstIndex = 0,
	nextDryAt = 0,
	pumpAt = 0,
	nextShoveAt = 0,
	nextSwingAt = 0,
	reload = nil :: any,

	--[[ Set when an attribute update disagreed with the prediction and was not
	     believed yet. The Heartbeat only re-reads the loadout while this is up,
	     so an idle player costs zero attribute reads per frame. ]]
	pendingReconcile = false,
}

local echoes = table.create(ECHO_SLOTS)
local echoCursor = 0
local sounds: { Sound } = {}

--[[ The one weapon that makes a continuous noise. Held rather than pooled: a
     loop has to be the SAME Sound from the moment the trigger goes down to the
     moment it comes up, and a pool would hand out a different one each time. ]]
local loopSound: Sound? = nil
local soundCursor = 0
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[WeaponController] " .. message)
end

-- ── local audio ─────────────────────────────────────────────────────────────

--[[
	The shooter's own gun has to be heard on the frame it fired, so it is played
	here rather than waiting for AudioService's server-side copy to replicate.
	Parented to the camera, which makes it 2D: your own weapon is not a thing
	happening somewhere in the room, it is a thing happening to you.

	The id comes from AudioConfig.pickId, never from `definition.id` directly.
	A definition carrying an `ids` list means the sound is one the player hears
	often enough to recognise the waveform — and reading `.id` takes the first
	sample every time, which is exactly the buzzsaw the variation exists to stop.
]]
--[[
	The shooter's own gun, reload and melee draw. Pooled, pitch-varied, 2D.

	── PARENTED TO SoundService, NOT TO THE CAMERA ──────────────────────────────
	Both are 2D — a Sound is only positional under a BasePart or an Attachment,
	and a Camera is neither — so the audible result is identical. What is not
	identical is that MainMenuController adopts every Sound under SoundService
	into the master SoundGroup on DescendantAdded, and that group is what the
	volume slider actually drives.

	Under the camera these were never adopted, so turning the master volume down
	silenced the menu, the hitmarker and every sound the SERVER played, and left
	the player's own weapon at full volume. The setting appeared to half work,
	which is worse than not having it.

	`Mix.MasterVolume` below is the config's baseline mix, not the player's
	setting; the two multiply, which is the intent.
]]
--[[
	Starts or stops the sustained bed for a weapon that has one.

	Called on the firing edge and on every path that ends a shot — a dry
	magazine, a weapon swap, a menu opening — because a loop is the one sound
	that keeps playing if nobody tells it to stop, and a flamethrower still
	roaring after you switched to a pistol is the kind of bug that survives a
	whole playtest because everyone assumes somebody else noticed.

	A weapon with no WeaponLoop row silences whatever was playing and returns,
	so switching from the flamethrower to anything at all stops it.
]]
local function setWeaponLoop(definition: any, on: boolean)
	local row = definition and AudioConfig.WeaponLoop[definition.id]
	if not row or not on or not AudioConfig.isConfigured(row) then
		if loopSound then
			loopSound:Stop()
		end
		return
	end

	if not loopSound or not loopSound.Parent then
		loopSound = Instance.new("Sound")
		loopSound.Name = "FL_WeaponLoop"
		loopSound.Parent = SoundService
		trove:add(loopSound)
	end
	local live = loopSound :: Sound
	live.SoundId = row.id
	live.Volume = row.volume
	live.Looped = true
	if not live.IsPlaying then
		live:Play()
	end
end

local function playLocal(definition: any)
	if not AudioConfig.isConfigured(definition) then
		return
	end

	soundCursor = (soundCursor % SOUND_POOL_SIZE) + 1
	local sound = sounds[soundCursor]
	if not sound or not sound.Parent then
		sound = Instance.new("Sound")
		sound.Name = "FL_WeaponSound"
		sound.Parent = SoundService
		sounds[soundCursor] = sound
		trove:add(sound)
	end

	sound.SoundId = AudioConfig.pickId(definition)
	sound.Volume = definition.volume * AudioConfig.Mix.MasterVolume
	sound.PlaybackSpeed = math.random() * (definition.pitchMax - definition.pitchMin) + definition.pitchMin
	sound:Play()
end

-- ── the character, as the cone model sees it ────────────────────────────────

local function humanoidOf(): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function isMoving(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	if humanoid.MoveDirection.Magnitude > MOVE_INTENT_EPSILON then
		return true
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local velocity = root.AssemblyLinearVelocity
	return velocity.X * velocity.X + velocity.Z * velocity.Z > MOVING_SPEED_SQUARED
end

local function survivorState(): string
	return Attributes.get(player, PA.State, STATE.Spectating)
end

-- ── bloom, mirroring BallisticsService ──────────────────────────────────────

local function decayBloom(now: number)
	local definition = state.definition
	if not definition then
		return
	end
	if state.bloomWeaponId ~= definition.id then
		-- The cone belongs to the gun that blew it out, not to the player.
		state.bloomWeaponId = definition.id
		state.bloom = 0
	else
		local elapsed = math.max(now - state.bloomAt, 0)
		state.bloom = math.max(state.bloom - definition.bloomRecovery * elapsed, 0)
	end
	state.bloomAt = now
end

local function coneFor(): number
	local definition = state.definition
	if not definition then
		return 0
	end
	local base = if state.aiming then definition.spreadAim else definition.spreadHip
	if isMoving() then
		base += definition.spreadMoving
	end
	-- max() guards a definition whose spreadMax sits under its own base spread:
	-- bloom may widen the cone, never tighten it.
	local cone = math.min(base + state.bloom, math.max(definition.spreadMax, base))
	--[[ Crouch last, on the clamped total, so it tightens the movement penalty
	     and the recoil bloom as well as the base. Line for line what
	     BallisticsService.coneFor does, off the same server-owned attribute —
	     the crosshair renders this and the server fires it, so the two agreeing
	     is the whole contract. ]]
	if Attributes.get(player, PA.IsCrouching, false) then
		cone *= GameConfig.Survivor.CrouchSpreadMultiplier
	end
	return cone
end

--[[
	The cone the next shot will use, in degrees of half-angle. This is what the
	crosshair renders, and it is the same number the server will compute — the
	gap between the ticks is not a mood, it is the shot.
]]
function WeaponController:getSpread(): number
	decayBloom(os.clock())
	return coneFor()
end

-- ── loadout, read from the attributes the server publishes ──────────────────

local function readSlotAmmo(slot: string, definition: any): (number, number)
	if slot == Enums.Slot.Primary then
		return Attributes.get(player, LA.PrimaryAmmo, 0), Attributes.get(player, LA.PrimaryReserve, 0)
	end
	if slot == Enums.Slot.Secondary then
		--[[ There is no SecondaryReserve attribute and there should not be: every
		     secondary either has infinite reserve or no magazine at all. The
		     definition already says which, so we read it from there. ]]
		return Attributes.get(player, LA.SecondaryAmmo, 0), if definition then definition.reserveMax else 0
	end
	--[[ Melee lands here and should: it has no magazine and no reserve, and
	     there is no MeleeAmmo attribute for the same reason. Zero is the honest
	     answer rather than a missing case. ]]
	return 0, 0
end

local function activeWeaponId(slot: string): string
	if slot == Enums.Slot.Primary then
		return Attributes.get(player, LA.PrimaryId, "")
	end
	if slot == Enums.Slot.Secondary then
		return Attributes.get(player, LA.SecondaryId, "")
	end
	--[[ Melee, which this did not know about when melee got a slot of its own —
	     and the consequence was the whole feature. Falling through to "" left
	     `state.definition` nil the moment the player drew a machete, so fireOnce
	     returned on its first line and the swing did nothing, ViewmodelController
	     was handed no weapon and drew no hands, and the only sign anything was
	     equipped was the third-person model the SERVER had welded on. ]]
	if slot == Enums.Slot.Melee then
		return Attributes.get(player, LA.MeleeId, "")
	end
	-- Throwables, medkits and pills are held, not wielded. No weapon in hand.
	return ""
end

local function endReload(finished: boolean)
	if not state.reload then
		return
	end
	local perShell = state.reload.perShell
	state.reload = nil
	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:onReloadFinished(finished)
	end
end

local function pushWeapon()
	local definition = state.definition
	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:setWeapon(state.weaponId, definition)
	end
	local camera = Registry.find("CameraController")
	if camera then
		camera:setWeapon(definition)
	end
end

--[[
	Re-reads the whole loadout from attributes. Called on every relevant
	attribute change rather than polled, so an idle player costs nothing.
]]
local function refreshLoadout(force: boolean)
	local slot = Attributes.get(player, LA.ActiveSlot, Enums.Slot.Secondary)
	local weaponId = activeWeaponId(slot)
	local definition = if weaponId ~= "" then WeaponConfig.get(weaponId) else nil

	local switched = force or slot ~= state.slot or weaponId ~= (state.weaponId or "")
	state.slot = slot

	if switched then
		state.weaponId = if weaponId ~= "" then weaponId else nil
		state.definition = definition
		state.burstIndex = 0
		state.firing = false
		setWeaponLoop(nil, false)
		state.pumpAt = 0
		endReload(false)

		if definition then
			-- Drawing costs time; a swap that fires instantly is how a player
			-- learns to quick-swap out of every reload in the game.
			state.nextFireAt = os.clock() + definition.drawTime

			--[[ Melee only, and deliberately. Every slot switch making a noise
			     would be a sound three times a fight for no information; the melee
			     key is a toggle you press mid-panic without looking, and the cue
			     is how you know it took. ]]
			if definition.slot == Enums.Slot.Melee then
				playLocal(AudioConfig.UI.MeleeDraw)
			end
		end
		pushWeapon()
		WeaponController.weaponChanged:fire(state.weaponId, definition)
	end

	local ammo, reserve = readSlotAmmo(slot, definition)
	local now = os.clock()

	--[[
		Who to believe about the magazine.

		A weapon swap: the server, always — nothing was predicted yet.
		Mid-reload: neither. Both sides are counting shells on their own clock and
		will disagree by up to one; correcting each other every shell is a counter
		that visibly stutters while you watch it. The last shell sets
		lastPredictAt, so the grace window below covers the round trip.
		Otherwise: a LOWER server count is believed at once, because the server
		never hands ammo back, and a higher one is latency until the trigger has
		been quiet for a round trip's worth of grace.
	]]
	local believeServer
	if switched then
		believeServer = true
	elseif state.reload then
		believeServer = false
	else
		believeServer = ammo < state.ammo or now - state.lastPredictAt >= RECONCILE_GRACE
	end

	if believeServer then
		state.pendingReconcile = false
		if state.ammo ~= ammo or state.reserve ~= reserve then
			state.ammo = ammo
			state.reserve = reserve
			WeaponController.ammoChanged:fire(ammo, reserve)
		end
	elseif state.reserve ~= reserve and not state.reload then
		-- The reserve is not predicted while firing, so it is safe to take on its
		-- own; it only moves when the server actually spends it.
		state.reserve = reserve
		WeaponController.ammoChanged:fire(state.ammo, reserve)
		state.pendingReconcile = state.ammo ~= ammo
	else
		state.pendingReconcile = state.ammo ~= ammo or state.reserve ~= reserve
	end
end

-- ── firing ──────────────────────────────────────────────────────────────────

--[[
	Where a shot starts and which way it goes.

	CameraController's AIM CFrame, not the camera's own. The two differ by the
	share of the recoil the aim does not inherit, plus all of the screen shake and
	every explosion impulse — none of which should move a bullet. Reading
	camera.CFrame here meant a Tank landing beside you threw the whole magazine,
	and it was invisible in testing because at close range the two agree to within
	a few pixels.

	Falls back to the camera if the controller is missing, which is the old
	behaviour and better than not firing at all.
]]
local function cameraRay(): (Vector3, Vector3)
	local cameraController = Registry.find("CameraController")
	if cameraController and typeof(cameraController.getAimCFrame) == "function" then
		local ok, cframe = pcall(cameraController.getAimCFrame, cameraController)
		if ok and typeof(cframe) == "CFrame" then
			return cframe.Position, cframe.LookVector
		end
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.zero, Vector3.zAxis
	end
	return camera.CFrame.Position, camera.CFrame.LookVector
end

local function rememberEcho(origin: Vector3, at: number)
	echoCursor = (echoCursor % ECHO_SLOTS) + 1
	local slot = echoes[echoCursor]
	if slot then
		slot.origin = origin
		slot.at = at
	else
		echoes[echoCursor] = { origin = origin, at = at }
	end
end

--[[
	True when a TracerEffect the server just sent is the echo of a shot this
	client already drew locally.

	BallisticsService range-culls TracerEffect rather than excluding the shooter,
	so the player who fired receives their own tracer a round trip after they
	drew it. ImpactController should call this and drop the duplicate; without
	it, every shot draws twice, the second one late, and a shotgun looks like it
	fired twice.
]]
function WeaponController:isPredictedTracer(origin: Vector3, at: number?): boolean
	local now = at or os.clock()
	for _, slot in echoes do
		if now - slot.at <= ECHO_MEMORY and (slot.origin - origin).Magnitude <= ECHO_TOLERANCE then
			return true
		end
	end
	return false
end

--[[ One RaycastParams for the whole session, refiltered only when the character
     changes. A fresh one per trigger pull is an allocation the GC eventually
     charges to a frame in the middle of a horde. ]]
local castParams = RaycastUtil.excluding({})
local castCharacter: Model? = nil

local function tracerParams(): RaycastParams
	local character = player.Character
	if character ~= castCharacter then
		castCharacter = character
		castParams.FilterDescendantsInstances = if character then { character } else {}
	end
	return castParams
end

--[[
	Draws what the shot will look like before the server has said what it hit.

	The directions come from ShotPattern with the seed we are about to send, so
	these are not "roughly where the pellets went" — they are the pellets. The
	raycast is only to find where each one stops; the server does its own and
	agrees, because the inputs are identical.
]]
local function drawTracers(origin: Vector3, direction: Vector3, seed: number, spread: number, definition: any)
	local impacts = Registry.find("ImpactController")
	if not impacts or typeof(impacts.drawTracer) ~= "function" then
		warnOnce(
			"tracer",
			"ImpactController:drawTracer(origin, endPosition, weaponId) is missing; shots will not draw a tracer"
		)
		return
	end

	--[[
		The ray starts at the camera; the LINE starts at the barrel.

		Those are two different questions and they used to share one answer. You
		shoot where you look, so the raycast has to come from the camera or the
		shot would not land under the crosshair — but in first person the gun sits
		below and to the right of the eye, so a tracer drawn from the camera
		visibly leaves the player's face. Same hit point, different line, and the
		line is the only part anybody sees.

		Falls back to the camera when there is no viewmodel — third person,
		spectating — which is also the case where the two are close enough not to
		matter.
	]]
	local visualOrigin = origin
	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel and typeof(viewmodel.getMuzzlePosition) == "function" then
		local ok, muzzlePosition = pcall(viewmodel.getMuzzlePosition, viewmodel)
		if ok and typeof(muzzlePosition) == "Vector3" then
			visualOrigin = muzzlePosition
		end
	end

	local directions = ShotPattern.generate(direction, seed, definition.pellets, spread)
	local count = math.min(#directions, MAX_PREDICTED_TRACERS)
	local range = definition.maxRange
	local params = tracerParams()

	for index = 1, count do
		local pellet = directions[index]
		local hit = Workspace:Raycast(origin, pellet * range, params)
		local endPosition = if hit then hit.Position else origin + pellet * range
		impacts:drawTracer(visualOrigin, endPosition, definition.id)
	end
end

local function canAct(): boolean
	local humanoid = humanoidOf()
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	--[[ Sitting in a turret. The trigger belongs to the gun you are behind, not
	     the one in your hands, and without this both fire on the same click.

	     Read off the PLAYER rather than off the seat, because the server writes
	     it: whether you are manning a turret is a fact it already owns — it is
	     what routes your input — and asking the character which seat it is in
	     would be this file's own second opinion about the same thing. ]]
	if Attributes.get(player, PA.ManningTurret, false) == true then
		return false
	end
	local survivor = survivorState()
	if CANNOT_FIRE[survivor] then
		return false
	end
	--[[ Down means the pistol and only the pistol. BallisticsService drops
	     anything else outright, so predicting it would only ever be a lie. ]]
	if survivor == STATE.Incapacitated and state.weaponId ~= GameConfig.Survivor.IncapWeapon then
		return false
	end
	return true
end

local function dryFire()
	local now = os.clock()
	if now < state.nextDryAt then
		return
	end
	state.nextDryAt = now + DRY_FIRE_INTERVAL

	playLocal(AudioConfig.WeaponReload.DryFire)
	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:onDryFire()
	end

	-- Pulling an empty trigger IS the reload command. Making the player press a
	-- second key to say what they obviously meant is a tax on panic.
	WeaponController:beginReload()
end

local function swingMelee()
	local definition = state.definition
	if not definition then
		return
	end
	local now = os.clock()
	if now < state.nextSwingAt or not canAct() then
		return
	end
	state.nextSwingAt = now + WeaponConfig.getFireDelay(definition)

	local origin, direction = cameraRay()
	Remotes.Event.SwingMelee:FireServer({
		origin = origin,
		direction = direction,
		clientTime = Workspace:GetServerTimeNow(),
	})

	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:onMeleeSwing(definition)
	end
	local camera = Registry.find("CameraController")
	if camera then
		camera:onWeaponFired(definition, 0, 0)
	end
	playLocal(AudioConfig.WeaponFire[definition.id])
end

--[[
	One trigger pull, resolved locally and then announced.

	Order matters here and is not negotiable: every scrap of feedback happens
	BEFORE the remote call, because FireServer is where the frame's latency
	lives. Flash, tracer, kick, shake, sound, counter — then the packet.
]]
--[[
	The trigger, with something in your hands that is not a gun.

	Selecting a medkit and pulling the trigger did nothing at all: a health slot
	carries no weapon definition, so this function returned on its first line. The
	only way to heal was H, or pressing the slot key a second time, and a player
	who knows neither reasonably concludes the game will not let them heal.

	So the trigger uses it, which is what the trigger does in the game this one is
	modelled on. Pills too — the same rule, and a heal key that worked for one and
	not the other would be a worse thing to have to remember.

	── AND THE THROWABLE, WHICH THIS USED TO REFUSE ────────────────────────────
	It was Health and Pills only, on a stated fear that turned out to be about a
	fallback that does not exist: "the UseItem action falls back to Health when
	the selected slot is not something it can spend", so a click meant as a throw
	would burn a medkit. A throwable IS something UseItem can spend — it is in
	InputController's CONSUMABLE_SLOTS — so that guard was never false with a
	bomb in hand and no kit was ever at risk.

	What the exclusion cost instead was the whole verb. A player holding a pipe
	bomb and clicking got NOTHING: no throw, no sound, no notice, silence
	indistinguishable from a broken item. G threw it and H threw it, and the HUD
	names neither — the throwable tile draws "3", the key that SELECTS it,
	because the glyph comes from bindings that carry a slot and Throw carries
	none. On a gamepad or a phone there was no throw binding at all.

	── AND WHY THE THROWABLE RAISES Throw AND NOT UseItem ──────────────────────
	Both end at ProjectileService:throw and they do not aim alike. Throw sends a
	CAMERA ray. UseItem sends no direction at all, and the server then falls back
	to its own view of the character — a level LookVector. Route the trigger
	through UseItem and every bomb leaves your hand flat: up onto a balcony and
	down a stairwell both become a lob at the floor in front of you, at the one
	moment the player was aiming hardest.

	── AND IT IS GATED ON THE SLOT, NOT ON WHAT YOU CARRY ──────────────────────
	It asks which slot is actually out rather than what is in the pack. The slot
	attribute lags a SwitchSlot by one round trip, which means pressing 4 and
	clicking inside a tenth of a second does nothing and wants a second click.
	That is the right way round for the trade.

	It delegates the WHICH to InputController, whose actions already resolve it,
	rather than firing a remote from here. Named rather than referenced because
	this table is built before any controller is reachable; the name is looked up
	on input.Action at the moment of use.
]]
local TRIGGER_ACTION: { [string]: string } = {
	[Enums.Slot.Health] = "UseItem",
	[Enums.Slot.Pills] = "UseItem",
	[Enums.Slot.Throwable] = "Throw",
}

local function useHeldConsumable(): boolean
	local wanted = TRIGGER_ACTION[Attributes.get(player, LA.ActiveSlot, "")]
	if not wanted then
		return false
	end
	local input = Registry.find("InputController")
	if not input or typeof(input.raise) ~= "function" then
		return false
	end
	local action = input.Action and input.Action[wanted]
	if not action then
		return false
	end
	input:raise(action, true)
	input:raise(action, false)
	return true
end

local function fireOnce()
	local definition = state.definition
	if not definition then
		--[[ No gun in hand. If something spendable is, the trigger spends it.

		     Holding the button down is harmless for all three. The auto-fire
		     loop below is gated on `definition`, which is nil for every one of
		     these slots, so a held trigger is exactly one press. Beyond that the
		     medkit's own use timer owns the rest and the server refuses a second
		     use while one is running, and a thrown bomb has already emptied its
		     slot before a second click could arrive. ]]
		useHeldConsumable()
		return
	end
	if definition.fireMode == "Melee" then
		swingMelee()
		return
	end

	local now = os.clock()
	if now < state.nextFireAt or not canAct() then
		return
	end
	if state.ammo <= 0 then
		dryFire()
		return
	end

	-- Firing keeps the shells already loaded and drops the rest of the reload,
	-- exactly as InventoryService:consumeAmmo does. The doorway decision between
	-- two more shells and shooting now is the point of a shell reload.
	endReload(false)

	local origin, direction = cameraRay()
	local seed = ShotPattern.generateSeed()

	decayBloom(now)
	local spread = coneFor()
	state.bloom = math.min(state.bloom + definition.bloomPerShot, math.max(definition.spreadMax, 0))

	--[[ Accumulate the next shot time rather than resetting it, so a 900rpm SMG
	     keeps its real cadence instead of quantising to the frame rate. Clamped
	     forward so a frame hitch cannot bank a burst of free shots. ]]
	local fireDelay = WeaponConfig.getFireDelay(definition)
	if state.nextFireAt < now - fireDelay then
		state.nextFireAt = now
	end
	state.nextFireAt += fireDelay

	if now - state.lastPredictAt > BURST_RESET then
		state.burstIndex = 0
	end
	state.burstIndex += 1
	state.lastPredictAt = now

	state.ammo -= 1
	WeaponController.ammoChanged:fire(state.ammo, state.reserve)

	if definition.fireMode == "Pump" then
		state.pumpAt = now + fireDelay * PUMP_POINT
	end

	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:onFired(definition, seed)
	end
	local camera = Registry.find("CameraController")
	if camera then
		camera:onWeaponFired(definition, seed, state.burstIndex)
	end
	playLocal(AudioConfig.WeaponFire[definition.id])
	rememberEcho(origin, now)
	drawTracers(origin, direction, seed, spread, definition)

	Remotes.Event.FireWeapon:FireServer({
		origin = origin,
		direction = direction,
		seed = seed,
		clientTime = Workspace:GetServerTimeNow(),
	})
end

-- ── reloading ───────────────────────────────────────────────────────────────

--[[
	Asks for a reload and starts the local clock that mirrors it.

	The mirror exists so the viewmodel and the ammo counter move on the frame the
	key is pressed. InventoryService owns the real thing and publishes the result
	through the attributes; anything this predicts wrong is corrected within a
	round trip.
]]
function WeaponController:beginReload(): boolean
	local definition = state.definition
	if not definition or state.reload or definition.magSize <= 0 then
		return false
	end
	if state.ammo >= definition.magSize or state.reserve == 0 then
		return false
	end
	if not canAct() then
		return false
	end

	Remotes.Event.ReloadWeapon:FireServer()

	state.reload = {
		weaponId = definition.id,
		perShell = definition.reloadPerShell > 0,
		phase = "Load",
		timer = 0,
		startedAt = os.clock(),
	}
	playLocal(AudioConfig.WeaponReload.MagOut)

	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:onReloadStarted(definition, state.reload.perShell)
	end
	return true
end

--[[ Mirrors InventoryService:_stepReload, including the pump-and-ready tail. ]]
local function stepReload(dt: number)
	local reload = state.reload
	local definition = state.definition
	if not reload or not definition or reload.weaponId ~= definition.id then
		endReload(false)
		return
	end

	reload.timer += dt
	local viewmodel = Registry.find("ViewmodelController")

	if reload.phase == "Load" then
		if reload.perShell then
			-- A long frame must commit every shell it earned, not just one.
			local shell = shellTimeFor(definition)
			while shell > 0 and reload.timer >= shell do
				reload.timer -= shell
				if state.ammo >= definition.magSize or state.reserve == 0 then
					reload.phase = "Tail"
					reload.timer = 0
					break
				end
				state.ammo += 1
				if state.reserve > 0 then
					state.reserve -= 1
				end
				state.lastPredictAt = os.clock()
				WeaponController.ammoChanged:fire(state.ammo, state.reserve)
				playLocal(AudioConfig.WeaponReload.ShellInsert)
				if viewmodel then
					viewmodel:onShellLoaded()
				end
				if state.ammo >= definition.magSize then
					reload.phase = "Tail"
					reload.timer = 0
					break
				end
			end
		elseif reload.timer >= reloadTimeFor(definition) then
			local need = definition.magSize - state.ammo
			local taken = need
			if state.reserve >= 0 then
				taken = math.min(need, state.reserve)
				state.reserve -= taken
			end
			state.ammo += taken
			state.lastPredictAt = os.clock()
			WeaponController.ammoChanged:fire(state.ammo, state.reserve)
			playLocal(AudioConfig.WeaponReload.MagIn)
			endReload(true)
			return
		end
	end

	if reload.phase == "Tail" and reload.timer >= reloadTimeFor(definition) then
		playLocal(AudioConfig.WeaponReload.Pump)
		if viewmodel then
			viewmodel:onPump()
		end
		endReload(true)
	end
end

-- ── aim, shove ──────────────────────────────────────────────────────────────

function WeaponController:setAiming(value: boolean)
	if state.aiming == value then
		return
	end
	state.aiming = value

	--[[ SetAimState is what the server's cone reads, so it goes out immediately
	     rather than on a timer. It is a discrete edge, not a stream: toggling it
	     costs one packet per press, which is nothing. ]]
	if state.sentAiming ~= value then
		state.sentAiming = value
		Remotes.Event.SetAimState:FireServer(value)
	end

	local camera = Registry.find("CameraController")
	if camera then
		camera:setAiming(value)
	end
	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:setAiming(value)
	end
end

function WeaponController:shove()
	local now = os.clock()
	if now < state.nextShoveAt or not canAct() then
		return
	end
	-- The local gate is the animation's, not the rule's: MeleeService owns
	-- fatigue and will refuse a shove this side thought was fine.
	state.nextShoveAt = now + GameConfig.Shove.Cooldown

	local origin, direction = cameraRay()
	Remotes.Event.Shove:FireServer({ origin = origin, direction = direction })

	local viewmodel = Registry.find("ViewmodelController")
	if viewmodel then
		viewmodel:onShove()
	end
end

-- ── reads, for the HUD and the crosshair ────────────────────────────────────

function WeaponController:getWeaponId(): string?
	return state.weaponId
end

function WeaponController:getDefinition(): any
	return state.definition
end

--[[ Predicted magazine and reserve. Reserve is -1 for a weapon with an infinite
     one (every pistol), which the ammo counter should render as a symbol rather
     than as a number. ]]
function WeaponController:getAmmo(): (number, number)
	return state.ammo, state.reserve
end

function WeaponController:isAiming(): boolean
	return state.aiming
end

function WeaponController:isReloading(): boolean
	return state.reload ~= nil
end

--[[
	How far the load step now running has got, 0-1, or -1 when nothing is
	reloading.

	For a magazine reload that is the whole reload. For a shell-fed gun it is the
	one shell going in right now, so the bar ticks once per shell alongside the
	count climbing — which is both what the player is actually waiting on and
	what a single bar spanning the whole reload would misrepresent, since a
	shotgun reload can be cancelled after any shell. The tail (pump, ready)
	reports 1: the ammo is already in the gun by then.
]]
function WeaponController:getReloadProgress(): number
	local reload = state.reload
	local definition = state.definition
	if not reload or not definition then
		return -1
	end
	if reload.phase ~= "Load" then
		return 1
	end
	local step = if reload.perShell then shellTimeFor(definition) else reloadTimeFor(definition)
	if step <= 0 then
		return 1
	end
	return math.clamp(reload.timer / step, 0, 1)
end

function WeaponController:isFiring(): boolean
	return state.firing
end

function WeaponController:getActiveSlot(): string
	return state.slot
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function WeaponController:init()
	--[[ Every attribute that can change what is in the player's hands or what it
	     has in it.

	     MeleeId was missing, and it is a real gap rather than a tidiness one:
	     activeWeaponId reads it, so picking a different melee off the floor while
	     the melee slot is selected changes what should be drawn — and nothing
	     told this function to look, so the old one stayed in frame until the next
	     slot switch.

	     The three consumable ids are deliberately NOT here. Nothing on the client
	     draws them: the medkit, the pills and the throwable a player sees in
	     their own hands are the SERVER's hands mount, left visible to its owner
	     because no viewmodel is standing in for it — see hideOwnWorldWeapon. The
	     server rebuilds that mount from its own loadout signal, so watching the
	     ids here would be a refresh with nothing to refresh. ]]
	local WATCHED = {
		LA.ActiveSlot,
		LA.PrimaryId,
		LA.SecondaryId,
		LA.MeleeId,
		LA.PrimaryAmmo,
		LA.SecondaryAmmo,
		LA.PrimaryReserve,
	}
	for _, name in WATCHED do
		trove:connect(player:GetAttributeChangedSignal(name), function()
			refreshLoadout(false)
		end)
	end

	--[[
		Whether the last state we saw was one that takes the gun away.

		The force-refresh below used to run on EVERY edge of this attribute, on
		the reasoning in its old comment — "going down swaps the weapon out from
		under us". That is true of going down and of nothing else, and this
		attribute also carries Hurt and Healthy, which change nothing about what
		is in your hands.

		A forced refresh is not a re-read. It sets `switched` true whether or not
		anything switched, and the switch path ends a reload, kills the weapon
		loop and clears the firing flag. So crossing the hurt line MID-RELOAD
		killed the client's half of that reload while the server carried on with
		its own: you heard the magazine come out on the frame you pressed R, then
		never heard it go back in — the client's own cues live in stepReload,
		which had stopped — and got the server's copy a round trip later, off
		your own body, positional and rolled off instead of flat and immediate.
		The viewmodel dropped the pose early, the HUD kept the word RELOADING lit
		over a bar that had vanished, a shotgun's per-shell clicks stopped while
		its ammo count kept climbing, and a flamethrower's sustained loop was cut
		dead mid-burst.

		ADRENALINE IS THE RELIABLE WAY TO SEE IT, which is why it was reported as
		a pair. Twenty-five temporary health carries a hurt survivor back over
		HurtThreshold on the frame the shot goes in, and the same twenty-five
		drains back under it a few seconds later — two crossings per shot, each
		landing on whatever reload happens to be in flight.

		So the force is spent on the transition that actually justifies it, and
		every other edge gets the ordinary re-read, which still notices a real
		weapon change because it compares the ids.
	]]
	local wasBlocked = CANNOT_FIRE[survivorState()] == true

	trove:connect(player:GetAttributeChangedSignal(PA.State), function()
		local survivor = survivorState()
		local blocked = CANNOT_FIRE[survivor] == true
		if blocked then
			state.firing = false
			setWeaponLoop(nil, false)
			endReload(false)
			WeaponController:setAiming(false)
		end
		local changed = blocked ~= wasBlocked
		wasBlocked = blocked
		-- Going down, or getting back up, swaps the weapon out from under us.
		refreshLoadout(changed)
	end)
end

function WeaponController:start()
	local input = Registry.get("InputController")
	local Action = input.Action

	trove:add(input:onBegan(Action.Fire):connect(function()
		state.firing = true
		setWeaponLoop(state.definition, true)
		fireOnce()
	end))
	trove:add(input:onEnded(Action.Fire):connect(function()
		state.firing = false
		setWeaponLoop(nil, false)
	end))

	trove:add(input:onBegan(Action.Aim):connect(function()
		WeaponController:setAiming(true)
	end))
	trove:add(input:onEnded(Action.Aim):connect(function()
		WeaponController:setAiming(false)
	end))

	trove:add(input:onBegan(Action.Reload):connect(function()
		WeaponController:beginReload()
	end))
	trove:add(input:onBegan(Action.Shove):connect(function()
		WeaponController:shove()
	end))
	--[[ Action.Melee is a SLOT key now, handled entirely in InputController: it
	     draws the melee or puts it away. Swinging is what the trigger does while
	     it is out, through fireOnce's `fireMode == "Melee"` branch. It used to be
	     bound here and called swingMelee() directly, which meant pressing V with a
	     rifle in hand sent the server a swing carrying a rifle's definition. ]]

	-- Sprinting cancels the sights. You cannot run and aim, and letting the
	-- player try is how they end up doing neither.
	trove:add(input:onBegan(Action.Sprint):connect(function()
		WeaponController:setAiming(false)
	end))

	refreshLoadout(true)

	--[[ One connection for the whole controller: held-auto fire, the reload
	     clock, the pump, and the slow half of ammo reconciliation. ]]
	trove:connect(RunService.Heartbeat, function(dt: number)
		local now = os.clock()
		local definition = state.definition

		if state.reload then
			--[[ The server can refuse a reload we optimistically started — a
			     throttled request, a pickup that changed the weapon, going down
			     mid-reload. IsReloading is its answer; once a round trip has
			     passed and it still says no, the local mirror is wrong and is
			     dropped rather than left to finish into a magazine that never
			     filled. ]]
			local serverReloading = Attributes.get(player, LA.IsReloading, false)
			if not serverReloading and now - state.reload.startedAt > RECONCILE_GRACE then
				endReload(false)
				refreshLoadout(false)
			else
				stepReload(dt)
			end
		end

		if state.pumpAt > 0 and now >= state.pumpAt then
			state.pumpAt = 0
			playLocal(AudioConfig.WeaponReload.Pump)
			local viewmodel = Registry.find("ViewmodelController")
			if viewmodel then
				viewmodel:onPump()
			end
		end

		if state.firing and definition then
			if definition.fireMode == "Auto" then
				fireOnce()
			elseif definition.fireMode == "Melee" then
				swingMelee()
			elseif state.ammo <= 0 and now >= state.nextFireAt then
				-- Semi and Pump fire once per press, but an empty gun still has
				-- to keep telling you it is empty while you hold the trigger.
				dryFire()
			end
		end

		--[[ The upward half of reconciliation. Only runs when an earlier
		     attribute update was disbelieved, so a player who is not shooting
		     does no work here at all. ]]
		if state.pendingReconcile and not state.reload and now - state.lastPredictAt >= RECONCILE_GRACE then
			refreshLoadout(false)
		end
	end)
end

--[[ Seeded by the bootstrap once RequestInitialState returns. Nothing in the
     payload changes a weapon, but a fresh join has to read its loadout once
     rather than wait for the first attribute to change. ]]
function WeaponController:onInitialState(_payload: any)
	refreshLoadout(true)
end

function WeaponController:destroy()
	trove:destroy()
end

Registry.register("WeaponController", WeaponController)

return WeaponController
