--!nonstrict
--[[
	CameraController — the camera, every frame, and everything that hits it.

	Four jobs, in the order they compose onto the frame:

	  1. FIELD OF VIEW   pulls in to definition.aimFov over definition.aimTime
	  2. RECOIL          ShotPattern's kick, through a spring, recovering at
	                     definition.recoilRecovery so the pattern is learnable
	  3. SHAKE           trauma-based, driven by definition.shakeMagnitude and
	                     shakeRoughness, plus the CameraImpulse remote
	  4. HIT-STOP        a brief freeze on a kill, per GoreConfig.HitStop

	── WHY THIS SITS ON TOP OF THE DEFAULT CAMERA ──────────────────────────────
	The camera stays CameraType.Custom with CameraMode.LockFirstPerson, and this
	controller runs one render-step binding immediately AFTER Roblox's own camera
	script and post-multiplies its output. Roblox's camera already does mouse,
	gamepad and touch look, character rotation, sensitivity settings and
	accessibility options correctly, and reimplementing all of that to gain
	nothing but ownership would be a large amount of code and several regressions.

	Everything this controller adds is an offset from that base, so the shot
	direction WeaponController reads off the camera already includes the recoil
	— the kick genuinely moves your aim, and the spring genuinely gives it back.

	── HIT-STOP ────────────────────────────────────────────────────────────────
	The cheapest trick in the satisfaction toolbox: freeze for two frames on a
	kill and the kill lands physically instead of merely resolving. A client
	cannot change global time, so this scales the CAMERA's own clock instead —
	every spring, the shake, the aim transition and (via getTimeScale) the
	viewmodel all step at GoreConfig.HitStop.TimeScale, and the camera CFrame is
	blended toward its previous value by the same factor. The player's look input
	still registers at 6% speed, which is why it reads as impact rather than as
	a dropped frame.

	The freeze belongs to the player who earned it. GoreService already decides
	that and puts the attacker in the GoreEvent payload; nothing here freezes on
	a teammate's kill.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	Exactly one render-step binding. No per-shot instances, no allocation in the
	frame beyond the CFrames the composition needs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local ShotPattern = require(Shared.Util.ShotPattern)
local Spring = require(Shared.Util.Spring)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player
local STATE = Enums.SurvivorState
local HITSTOP = GoreConfig.HitStop

-- One past Roblox's own camera update, so we post-multiply the CFrame it just
-- wrote rather than fighting it for the property.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local RENDER_NAME = "FL_Camera"

-- Roblox's default field of view. Every aimFov in WeaponConfig is expressed
-- against this, so it is the one number the config does not carry.
local HIP_FOV = 70
-- Sprinting widens the frame slightly. Small enough to read as speed rather
-- than as a zoom, and it is the only feedback a sprint key has in this build.
local SPRINT_FOV_BONUS = 4
local SPRINT_FOV_SPEED = 6

--[[ How far the view drops when crouched, and how fast it gets there. Fast
     enough to feel like ducking, slow enough not to read as a teleport. ]]
local CROUCH_DROP = GameConfig.Survivor.CrouchCameraDrop
local CROUCH_SPEED = 9

--[[ Peak displacement of a spring kicked with velocity v0 is v0/(w*e), so
     pre-multiplying an impulse by w*e makes the config number the actual peak.
     recoilVertical: 1.15 degrees means the camera rises 1.15 degrees. ]]
local IMPULSE_GAIN = math.exp(1)
local RECOIL_DAMPING = 0.78 -- a little overshoot; a dead-flat return reads as a script

--[[ The two halves of the recoil contract. See GameConfig.Recoil: the first
     scales the kick the camera takes, the second decides how much of that kick
     the bullets inherit. ]]
local RECOIL_VIEW_SCALE = GameConfig.Recoil.ViewScale
local RECOIL_AIM_FOLLOW = GameConfig.Recoil.AimFollow

-- Trauma is normalised 0-1 and shakes by its square, so small hits barely
-- register and a Tank landing on you fills the frame. shakeMagnitude decides
-- how much trauma one shot adds; shakeRoughness decides how fast it rattles.
local TRAUMA_PER_MAGNITUDE = 0.12
local TRAUMA_DECAY = 1.6
local MAX_SHAKE_DEGREES = 3.2
local MAX_SHAKE_ROLL_DEGREES = 2.0
local MAX_SHAKE_STUDS = 0.16
local DEFAULT_ROUGHNESS = 10

-- CameraImpulse carries its own decay, which becomes these springs' speed.
local IMPULSE_DAMPING = 0.7
local DEFAULT_IMPULSE_DECAY = 8

--[[ On the floor. The camera drops to roughly a lying survivor's eye line,
     rolls, and stops being able to look behind itself — a downed player is
     supposed to be able to see the teammate who is coming, and nothing else. ]]
local INCAP_DROP = 2.6
local INCAP_ROLL = math.rad(14)
local INCAP_YAW_LIMIT = math.rad(95)
local INCAP_PITCH_UP = math.rad(35)
local INCAP_PITCH_DOWN = math.rad(-55)
local INCAP_BLEND_SPEED = 4

local DOWNED_STATES: { [string]: boolean } = {
	[STATE.Incapacitated] = true,
	[STATE.LedgeHanging] = true,
}

local NO_CHARACTER_STATES: { [string]: boolean } = {
	[STATE.Dead] = true,
	[STATE.Spectating] = true,
}

local CameraController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

-- (pitch, yaw) in degrees. Vector2 rather than two springs so one impulse is
-- one call and the two axes can never desynchronise.
local recoil = Spring.new(Vector2.zero, 9, RECOIL_DAMPING)
local impulsePosition = Spring.new(Vector3.zero, DEFAULT_IMPULSE_DECAY, IMPULSE_DAMPING)
local impulseRotation = Spring.new(Vector3.zero, DEFAULT_IMPULSE_DECAY, IMPULSE_DAMPING)

local state = {
	definition = nil :: any,
	aiming = false,
	aimAlpha = 0, -- raw 0-1 ramp
	aimEased = 0, -- smoothstepped; this is what the FOV and the viewmodel use
	sprintAlpha = 0,
	crouchAlpha = 0,

	trauma = 0,
	roughness = DEFAULT_ROUGHNESS,

	hitStopUntil = 0,
	hitStopScale = HITSTOP.TimeScale,

	lookYaw = 0,
	lookPitch = 0,
	baseCFrame = CFrame.identity,
	--[[ Where the shot goes: base plus the aim's share of the recoil, and nothing
	     else. Written every frame by the render step, read by WeaponController
	     and by the crosshair. ]]
	aimCFrame = CFrame.identity,
	lastCFrame = CFrame.identity,

	downed = 0, -- eased 0-1 blend into the incapacitated camera
	downedAnchor = 0, -- yaw the look cone is clamped around
	anchored = false,
	survivorState = STATE.Spectating,
}

local inputController: any = nil

--[[ The screen-shake setting. On by default; see setShakeEnabled for why
     recoil is not part of it. ]]
local shakeEnabled = true

local function wrapAngle(angle: number): number
	if angle > math.pi then
		return angle - math.pi * 2
	elseif angle < -math.pi then
		return angle + math.pi * 2
	end
	return angle
end

-- ── what the weapon pushes in ───────────────────────────────────────────────

--[[ Called on every weapon swap. Recoil is reset rather than left to settle:
     carrying a Magnum's kick into a pistol would look like the game glitched. ]]
function CameraController:setWeapon(definition: any)
	state.definition = definition
	if definition then
		recoil.speed = math.max(definition.recoilRecovery, 1)
		state.roughness = math.max(definition.shakeRoughness, 1)
	else
		recoil.speed = 9
		state.roughness = DEFAULT_ROUGHNESS
	end
	recoil:reset(Vector2.zero)
end

function CameraController:setAiming(value: boolean)
	state.aiming = value
end

--[[ Degrees of kick. Vertical is up, horizontal is signed. Scaled so the number
     in WeaponConfig is the peak the camera actually reaches. ]]
function CameraController:addRecoil(vertical: number, horizontal: number)
	local gain = recoil.speed * IMPULSE_GAIN * RECOIL_VIEW_SCALE
	recoil:impulse(Vector2.new(vertical * gain, horizontal * gain))
end

--[[ Adds camera trauma, 0-1. Shake is trauma squared, so two small hits are
     much quieter than one big one — which is what stops a horde of Commons from
     turning the screen into static. ]]
function CameraController:addTrauma(amount: number)
	if not shakeEnabled then
		return
	end
	state.trauma = math.clamp(state.trauma + amount, 0, 1)
end

--[[
	The screen-shake setting.

	Turns off trauma and world impulses — the two things that move the camera
	WITHOUT the player asking. Recoil is deliberately untouched: it is the gun
	pushing the aim, it is something the player is doing and has to counter, and
	a game where the recoil setting is optional is a game with two balances.

	Motion sickness is the reason this exists, so it also drops whatever shake is
	already running rather than letting it decay.
]]
function CameraController:setShakeEnabled(value: boolean)
	shakeEnabled = value ~= false
	if not shakeEnabled then
		state.trauma = 0
		impulsePosition:reset(Vector3.zero)
		impulseRotation:reset(Vector3.zero)
	end
end

function CameraController:isShakeEnabled(): boolean
	return shakeEnabled
end

--[[
	One shot's worth of camera. The recoil comes from ShotPattern with the shot's
	own seed and index, so the vertical climb is consistent enough to counter and
	the horizontal is symmetric noise that cannot simply be pre-aimed.
]]
function CameraController:onWeaponFired(definition: any, seed: number, shotIndex: number)
	if not definition then
		return
	end
	if definition.recoilVertical > 0 or definition.recoilHorizontal > 0 then
		local vertical, horizontal = ShotPattern.generateRecoil(
			seed,
			shotIndex,
			definition.recoilVertical,
			definition.recoilHorizontal
		)
		self:addRecoil(vertical, horizontal)
	end
	self:addTrauma(definition.shakeMagnitude * TRAUMA_PER_MAGNITUDE)
	state.roughness = math.max(definition.shakeRoughness, 1)
end

--[[
	The CameraImpulse remote: explosions, Tank swings, Charger slams, being
	freed from a pin. `rotation` is degrees, `position` is studs, `decay` becomes
	the spring's speed so a heavy hit can settle slowly and a shove snaps back.
]]
function CameraController:impulse(position: Vector3?, rotation: Vector3?, decay: number?)
	if not shakeEnabled then
		return
	end
	local speed = math.max(decay or DEFAULT_IMPULSE_DECAY, 1)
	if position then
		impulsePosition.speed = speed
		impulsePosition:impulse(position * (speed * IMPULSE_GAIN))
	end
	if rotation then
		impulseRotation.speed = speed
		impulseRotation:impulse(rotation * (speed * IMPULSE_GAIN))
	end
end

-- ── hit-stop ────────────────────────────────────────────────────────────────

--[[
	Freezes the camera and the viewmodel for `seconds`. Overlapping calls take
	the longer of the two rather than stacking, so a gib that arrives as both a
	HitConfirmed and a GoreEvent freezes once, for the longer of the two.
]]
function CameraController:hitStop(seconds: number, timeScale: number?)
	if not HITSTOP.Enabled or not seconds or seconds <= 0 then
		return
	end
	local finish = os.clock() + seconds
	if finish > state.hitStopUntil then
		state.hitStopUntil = finish
		state.hitStopScale = math.clamp(timeScale or HITSTOP.TimeScale, 0, 1)
	end
end

--[[ 1 normally, GoreConfig.HitStop.TimeScale during a freeze. ViewmodelController
     multiplies its own delta by this so both stop and start on the same frame. ]]
function CameraController:getTimeScale(): number
	if os.clock() < state.hitStopUntil then
		return state.hitStopScale
	end
	return 1
end

function CameraController:isHitStopped(): boolean
	return os.clock() < state.hitStopUntil
end

-- ── reads ───────────────────────────────────────────────────────────────────

--[[ The look angles BEFORE recoil, shake and impulse. ViewmodelController sways
     off these; swaying off the final camera would make the weapon respond to
     its own kick, which reads as the model coming loose. ]]
function CameraController:getLookAngles(): (number, number)
	return state.lookYaw, state.lookPitch
end

function CameraController:getBaseCFrame(): CFrame
	return state.baseCFrame
end

--[[
	The CFrame a shot is fired along — NOT the camera's.

	It carries GameConfig.Recoil.AimFollow of the recoil and none of the shake or
	explosion impulse, so the view can kick harder than the aim moves and being
	hit cannot steer your bullets.

	Anything that fires, traces or draws a reticle must use this. Reading
	camera.CFrame instead is the bug this exists to fix, and it is invisible in
	testing because at close range the two agree to within a few pixels.
]]
function CameraController:getAimCFrame(): CFrame
	return state.aimCFrame
end

--[[ 0 at the hip, 1 fully down the sights, smoothstepped. The viewmodel reads
     this so the pose and the FOV pull arrive together. ]]
function CameraController:getAimAlpha(): number
	return state.aimEased
end

function CameraController:getTrauma(): number
	return state.trauma
end

-- ── the frame ───────────────────────────────────────────────────────────────

local function stepAim(dt: number)
	local definition = state.definition
	local aimTime = math.max(if definition then definition.aimTime else 0.2, 1e-3)
	local target = if state.aiming then 1 else 0
	local step = dt / aimTime

	if state.aimAlpha < target then
		state.aimAlpha = math.min(state.aimAlpha + step, target)
	elseif state.aimAlpha > target then
		state.aimAlpha = math.max(state.aimAlpha - step, target)
	end

	local alpha = state.aimAlpha
	-- Smoothstep. A linear FOV ramp is legible as a ramp; this one is legible
	-- as the weapon coming up.
	state.aimEased = alpha * alpha * (3 - 2 * alpha)
end

--[[
	Drops the view to where a crouched head would be.

	Eased rather than snapped, and driven off the SERVER's attribute rather than
	off the key — the server decides whether a crouch was granted (it refuses one
	from a survivor who is down), and a camera that ducked on a refused request
	would be the view disagreeing with the body.

	CameraOffset rather than moving the camera CFrame: the offset is applied by
	the humanoid, so it follows the character through everything else this
	controller does to the frame.
]]
local function stepCrouch(dt: number)
	local wanted = Attributes.get(player, Attributes.Player.IsCrouching, false) and 1 or 0
	if math.abs(state.crouchAlpha - wanted) < 0.001 then
		state.crouchAlpha = wanted
	else
		state.crouchAlpha += (wanted - state.crouchAlpha) * math.min(dt * CROUCH_SPEED, 1)
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.CameraOffset = Vector3.new(0, -CROUCH_DROP * state.crouchAlpha, 0)
	end
end

local function stepSprint(dt: number)
	if not inputController then
		inputController = Registry.find("InputController")
	end
	local sprinting = false
	if inputController then
		sprinting = inputController:isDown(inputController.Action.Sprint) and not state.aiming
	end
	local target = if sprinting then 1 else 0
	state.sprintAlpha += (target - state.sprintAlpha) * math.min(dt * SPRINT_FOV_SPEED, 1)
end

--[[ The downed camera. Clamped in the base CFrame rather than as an offset, so
     the restriction is real: the shot direction WeaponController reads is
     clamped too, and a downed survivor genuinely cannot shoot behind themselves. ]]
local function clampDowned(base: CFrame, blend: number): CFrame
	local look = base.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local pitch = math.asin(math.clamp(look.Y, -1, 1))

	if not state.anchored then
		state.anchored = true
		state.downedAnchor = yaw
	end

	local clampedYaw = state.downedAnchor
		+ math.clamp(wrapAngle(yaw - state.downedAnchor), -INCAP_YAW_LIMIT, INCAP_YAW_LIMIT)
	local clampedPitch = math.clamp(pitch, INCAP_PITCH_DOWN, INCAP_PITCH_UP)

	local position = base.Position - Vector3.new(0, INCAP_DROP * blend, 0)
	local free = CFrame.new(position) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local held = CFrame.new(position)
		* CFrame.Angles(0, clampedYaw, 0)
		* CFrame.Angles(clampedPitch, 0, 0)
		* CFrame.Angles(0, 0, INCAP_ROLL)

	return free:Lerp(held, blend)
end

local function update(deltaTime: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	-- Everything on this controller's clock, which hit-stop scales.
	local scale = CameraController:getTimeScale()
	local dt = deltaTime * scale

	local base = camera.CFrame

	local downedTarget = if DOWNED_STATES[state.survivorState] then 1 else 0
	state.downed += (downedTarget - state.downed) * math.min(deltaTime * INCAP_BLEND_SPEED, 1)
	if state.downed > 0.001 then
		base = clampDowned(base, state.downed)
	end

	-- Recorded before the offsets: this is what the viewmodel sways against.
	local look = base.LookVector
	state.lookYaw = math.atan2(-look.X, -look.Z)
	state.lookPitch = math.asin(math.clamp(look.Y, -1, 1))
	state.baseCFrame = base

	stepAim(dt)
	stepSprint(dt)
	stepCrouch(dt)

	local kick = recoil:update(dt)
	local impulseOffset = impulsePosition:update(dt)
	local impulseAngles = impulseRotation:update(dt)

	state.trauma = math.max(state.trauma - TRAUMA_DECAY * dt, 0)

	local target = base * CFrame.Angles(math.rad(kick.X), math.rad(kick.Y), 0)

	--[[
		Where the shot actually goes, recorded before the shake and the impulse
		are layered on.

		Only AimFollow of the kick, so the camera can punch harder than the aim
		moves — and none of the shake or the explosion impulse, because being hit
		should rattle the frame without steering your bullets. It silently did:
		WeaponController read the finished camera CFrame, so a Tank landing next
		to you threw every round in the magazine and nothing said so.
	]]
	state.aimCFrame = base
		* CFrame.Angles(math.rad(kick.X * RECOIL_AIM_FOLLOW), math.rad(kick.Y * RECOIL_AIM_FOLLOW), 0)

	if state.trauma > 0.001 then
		--[[ Perlin noise rather than random(): consecutive frames have to be
		     related or the result is static, not a shake. Sampling three
		     separate lanes of the same field keeps the axes independent. ]]
		local shake = state.trauma * state.trauma
		local t = os.clock() * state.roughness
		local nx = math.noise(t, 0, 0) * 2
		local ny = math.noise(0, t, 0) * 2
		local nz = math.noise(0, 0, t) * 2
		target = target
			* CFrame.Angles(
				math.rad(MAX_SHAKE_DEGREES * shake * nx),
				math.rad(MAX_SHAKE_DEGREES * shake * ny),
				math.rad(MAX_SHAKE_ROLL_DEGREES * shake * nz)
			)
			* CFrame.new(MAX_SHAKE_STUDS * shake * ny, MAX_SHAKE_STUDS * shake * nx, 0)
	end

	target = target
		* CFrame.new(impulseOffset)
		* CFrame.Angles(math.rad(impulseAngles.X), math.rad(impulseAngles.Y), math.rad(impulseAngles.Z))

	--[[ The freeze itself. Blending toward the previous frame's CFrame by the
	     same factor everything else is stepping at means the camera does not
	     lock solid — it crawls, which is what sells a hit instead of reading as
	     a hitch. At TimeScale 1 this is an exact assignment and costs nothing. ]]
	if scale < 1 then
		camera.CFrame = state.lastCFrame:Lerp(target, scale)
	else
		camera.CFrame = target
	end
	state.lastCFrame = camera.CFrame

	local definition = state.definition
	local aimFov = if definition then definition.aimFov else HIP_FOV
	local hipFov = HIP_FOV + SPRINT_FOV_BONUS * state.sprintAlpha
	camera.FieldOfView = hipFov + (aimFov - hipFov) * state.aimEased
end

-- ── state ───────────────────────────────────────────────────────────────────

local function applyCameraMode()
	local survivor = state.survivorState
	if NO_CHARACTER_STATES[survivor] then
		-- Dead or spectating: let the player pull back and watch the team, which
		-- is the only thing left to do and is most of what makes death bearable.
		player.CameraMode = Enum.CameraMode.Classic
		player.CameraMinZoomDistance = 0.5
		player.CameraMaxZoomDistance = 128
	else
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		player.CameraMinZoomDistance = 0.5
		player.CameraMaxZoomDistance = 0.5
	end
end

local function refreshState()
	local survivor = Attributes.get(player, PA.State, STATE.Spectating)
	if survivor == state.survivorState then
		return
	end
	state.survivorState = survivor

	if not DOWNED_STATES[survivor] then
		-- Standing back up re-anchors the look cone on the next down.
		state.anchored = false
	end
	applyCameraMode()
end

--[[
	Re-asserts the camera mode this controller believes in.

	Public because it is not the only thing that writes those three properties:
	FreeCursor pushes the camera out and unpins the zoom so a screen with buttons
	on it can be clicked, and has to give the camera back afterwards. Replaying
	the values it captured is not good enough — they are a snapshot of whatever
	was true when the screen OPENED, and the answer can have changed underneath
	it. The main menu closing at round start is exactly that: it captured the
	lobby's spectator camera, the round then put the player in a body, and
	handing back the snapshot parked a live survivor in third person with a free
	mouse for the whole round.

	So FreeCursor asks instead of replaying, and this stays the one authority.
]]
function CameraController:refreshCameraMode()
	applyCameraMode()
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function CameraController:init()
	trove:connect(player:GetAttributeChangedSignal(PA.State), refreshState)
	refreshState()
	applyCameraMode()
end

function CameraController:start()
	trove:connect(Remotes.Event.CameraImpulse.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		CameraController:impulse(payload.position, payload.rotation, payload.decay)
	end)

	--[[
		Two sources of hit-stop, merged by taking the longer.

		HitConfirmed is the reliable one: it is sent to the attacker on every
		kill, unconditionally. GoreEvent is the precise one: it knows whether the
		body came apart, and carries GibSeconds when it did — but it is range
		culled and rate limited, so a kill during a full horde may not produce
		one. Neither alone is enough; together the freeze always lands and is the
		right length whenever the server had the budget to say so.
	]]
	trove:connect(Remotes.Event.HitConfirmed.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" or not payload.killed then
			return
		end
		local seconds = if payload.isHeadshot then HITSTOP.HeadshotKillSeconds else HITSTOP.KillSeconds
		CameraController:hitStop(seconds)
	end)

	trove:connect(Remotes.Event.GoreEvent.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		-- The freeze belongs to whoever earned it. Freezing all four survivors
		-- every time one of them kills a Common would be unreadable.
		if payload.attacker ~= player then
			return
		end
		CameraController:hitStop(payload.hitStop, payload.timeScale)
	end)

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, update)
	trove:add(function()
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end)
end

function CameraController:onInitialState(_payload: any)
	refreshState()
end

function CameraController:destroy()
	trove:destroy()
end

Registry.register("CameraController", CameraController)

return CameraController
