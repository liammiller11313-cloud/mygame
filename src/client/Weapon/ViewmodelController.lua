--!nonstrict
--[[
	ViewmodelController — the gun the player actually looks at.

	Almost everything a shooter's weapons "feel" like lives in this file. The
	damage numbers are in WeaponConfig, the hits are on the server, and the
	player experiences neither. What they experience is a shape in the lower
	right of the screen that leans when they turn, settles when they stop, drops
	into the sights when they aim, and snaps when they fire.

	── SPRINGS, NOT TWEENS ─────────────────────────────────────────────────────
	Read Shared/Util/Spring.lua's header. Every motion below is a spring because
	a shot fired mid-recovery has to ADD to what is already moving. A tween would
	have to cancel and restart, and the restart is visible: the weapon stalls for
	a frame on exactly the shots where the player most needs it to feel
	continuous. Springs just accumulate.

	Impulses are scaled by `speed * e` so the config numbers mean what they say.
	A critically damped spring kicked with velocity v0 peaks at v0/(w*e), so
	feeding it `kickback * w * e` makes the weapon travel exactly `kickback`
	studs at the top of the kick. WeaponConfig's units stay honest.

	── WHERE THE MODEL COMES FROM ──────────────────────────────────────────────
	ReplicatedStorage.Assets.Viewmodels, cloned. The lookup key is WeaponConfig's
	`modelName` FIRST, because that is the literal name of the artist's model and
	the only key guaranteed to match it: the PPSh ships as "(71 Mag) PPSh-41",
	which is neither our enum key nor its display name. Weapon id, display name
	and a whitespace-insensitive sweep follow, so a folder populated by
	PlaceholderFactory's grey-boxes still resolves.

	Whatever is found is treated as somebody else's model rather than as ours:
	scripts are stripped before it can run any, every part is anchored and made
	unqueryable, a Muzzle is invented at the front of its bounding box if the art
	did not ship one, and a model whose scale is wildly wrong for its class is
	fitted to it — a six-stud rifle a stud and a half from the eye is a wall, not
	a weapon.

	If nothing matches, a blocky stand-in is built here instead. That is not a
	nicety: a client that boots before the asset folder replicates must still
	have a weapon in frame, and a player holding nothing has no idea whether the
	game is broken or they are out of ammo.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	One render-step binding, running after the camera so it poses against the
	final camera CFrame. Every part is anchored and the whole model moves with a
	single Model:PivotTo, which is one engine-side call regardless of part count.
	Shells come from a fixed ring of parts that is never grown and never
	destroyed, so a firefight allocates nothing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local AmmoConfig = require(Shared.Config.AmmoConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(Shared.Util.Registry)
local Device = require(Shared.Util.Device)
local Spring = require(Shared.Util.Spring)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player
local STATE = Enums.SurvivorState

-- After the camera, so the weapon is posed against the CFrame that will
-- actually be rendered this frame — including recoil, shake and hit-stop.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local RENDER_NAME = "FL_Viewmodel"

export type Pose = {
	hip: Vector3,
	aim: Vector3,
	tilt: number,
	length: number,
}

--[[
	Where the weapon sits relative to the camera, in studs (right, up, forward),
	and how long a weapon of that class is assumed to be at that distance.

	None of this lives in a Config: WeaponConfig owns what a gun DOES, and the
	pose is a property of the viewmodel art, not of the balance. Anything a
	designer would retune lives there; anything an artist would retune is here.

	Keyed by `definition.class`, NOT by weapon id. A pose describes how a weapon
	is held rather than which one it is — every rifle in the roster sits in the
	same place — so six entries cover all sixteen guns, and the seventeenth
	inherits a correct pose on the day someone adds it instead of silently
	falling through to a generic one. Per-weapon exceptions go in WEAPON_POSE.

	`aim` puts the weapon on the screen's centre line. When a model carries a
	"Sight" or "AimPoint" attachment, that point is put there instead and this
	becomes the pose of the model around it.

	`length` is what the offsets assume the gun measures along its longest axis.
	It is what the grey-box is built to and what a supplied model is fitted to,
	so a real model and a placeholder frame identically.
]]
local DEFAULT_POSE: Pose = {
	hip = Vector3.new(0.85, -0.75, -1.55),
	aim = Vector3.new(0, -0.32, -1.05),
	tilt = math.rad(-3), -- a dead-square weapon reads as a screenshot, not a gun
	length = 1.8,
}

local CLASS_POSE: { [string]: Pose } = {
	Pistol = {
		hip = Vector3.new(0.7, -0.62, -1.2),
		aim = Vector3.new(0, -0.26, -0.85),
		tilt = math.rad(-4),
		length = 0.95,
	},
	SMG = {
		hip = Vector3.new(0.8, -0.7, -1.4),
		aim = Vector3.new(0, -0.3, -1.0),
		tilt = math.rad(-3),
		length = 1.55,
	},
	Rifle = {
		hip = Vector3.new(0.85, -0.75, -1.6),
		aim = Vector3.new(0, -0.3, -1.1),
		tilt = math.rad(-3),
		length = 1.9,
	},
	-- The glass has to sit dead on the centre line or the pull-in reads as a
	-- misalignment rather than as magnification.
	Marksman = {
		hip = Vector3.new(0.88, -0.78, -1.75),
		aim = Vector3.new(0, -0.22, -0.7),
		tilt = math.rad(-2),
		length = 2.15,
	},
	Shotgun = {
		hip = Vector3.new(0.9, -0.8, -1.7),
		aim = Vector3.new(0, -0.34, -1.2),
		tilt = math.rad(-2),
		length = 2.0,
	},
	--[[ Longer and heavier than a rifle, and held lower to say so. A belt-fed gun
	     is carried rather than shouldered — dropping the hip pose and pulling it
	     further out is what reads as weight before the player has fired it. ]]
	LMG = {
		hip = Vector3.new(0.92, -0.86, -1.85),
		aim = Vector3.new(0, -0.34, -1.15),
		tilt = math.rad(-3),
		length = 2.3,
	},
	--[[ On the shoulder, not in front of the chest. Well right of centre and
	     tilted hard, because the tube has to clear the head — a launcher posed
	     like a rifle puts its own body through the camera. ]]
	Launcher = {
		hip = Vector3.new(1.05, -0.55, -1.7),
		aim = Vector3.new(0.42, -0.3, -1.1),
		tilt = math.rad(-8),
		length = 2.6,
	},
	Melee = {
		hip = Vector3.new(0.95, -0.9, -1.3),
		aim = Vector3.new(0.75, -0.7, -1.2),
		tilt = math.rad(-14),
		length = 1.6,
	},
}

--[[ Exceptions, keyed by weapon id, for the guns whose class pose is wrong for
     them specifically. Kept as short as possible: an entry here is a promise to
     retune it by hand every time the class pose moves. ]]
local WEAPON_POSE: { [string]: Pose } = {
	-- A six-inch revolver is a hand longer than the 1911 and hangs heavier, so
	-- it sits further out and further down than the rest of its class.
	[Enums.Weapon.Magnum357] = {
		hip = Vector3.new(0.72, -0.66, -1.32),
		aim = Vector3.new(0, -0.27, -0.92),
		tilt = math.rad(-4),
		length = 1.15,
	},
}

--[[ The pose for a weapon: its own if it has earned one, otherwise its class's.
     The class lookup is the one that must always resolve, so an unknown or
     missing class falls through to the generic long-gun pose rather than nil. ]]
local function poseFor(weaponId: string?, definition: any): Pose
	local override = if weaponId then WEAPON_POSE[weaponId] else nil
	if override then
		return override
	end
	local class = definition and definition.class
	return (class and CLASS_POSE[class]) or DEFAULT_POSE
end

--[[
	The field of view the offsets above were authored against — Roblox's default,
	and what the camera sits at from the hip.

	Apparent size goes as 1/tan(fov/2), so a scope that pulls the frame from 70
	degrees to the M1A EBR's 34 magnifies the weapon 2.3x. Left uncompensated the
	gun swallows the screen at exactly the moment the player is trying to see
	past it, so the pose is pushed out by the same factor and the weapon keeps
	the size it has from the hip. Read off the live camera rather than off
	definition.aimFov so it tracks the aim ramp and the sprint widen for free.
]]
local POSE_FOV = 70
local POSE_FOV_TAN = math.tan(math.rad(POSE_FOV) * 0.5)
-- The narrowest gun in the roster, the M1A EBR at 34 degrees, asks for 2.3x.
local MAX_FOV_COMPENSATION = 3

--[[ How far a supplied model's longest axis may be from its class `length`
     before it is scaled to fit. Artists' guns arrive at wildly different
     scales; a band this wide leaves anything plausible alone and only rescues
     the ones that would otherwise fill the frame or vanish into it. ]]
local FIT_TOLERANCE = 1.45

--[[ A "Sight" further from the model's pivot than this is not a sight, it is a
     mis-named attachment on somebody's free model, and honouring it would throw
     the weapon off screen the moment the player aims. ]]
local SIGHT_MAX_OFFSET = 2.5

local MUZZLE_NAMES = { "Muzzle", "MuzzlePoint", "MuzzleAttachment", "FirePoint", "Tip" }
local SIGHT_NAMES = { "Sight", "AimPoint", "AimPart", "Iron" }

-- Sway. The weapon lags the camera, which is the single cheapest cue that the
-- thing has mass. Clamped so a flick of the mouse cannot throw it off screen.
local SWAY_SPEED = 11
local SWAY_DAMPING = 0.85
local SWAY_POSITION_GAIN = 1.5
local SWAY_ROTATION_GAIN = 2.6
local SWAY_MAX = 0.14
local SWAY_AIM_SCALE = 0.25 -- down the sights the weapon is braced, not carried

-- Bob. Frequency is per stud travelled rather than per second, so it stays in
-- step with the legs whatever the survivor's speed multiplier is doing.
local BOB_FREQUENCY = 0.75
local BOB_HORIZONTAL = 0.055
local BOB_VERTICAL = 0.04
local BOB_ROLL = math.rad(0.9)
local BOB_AIM_SCALE = 0.3
local BOB_SMOOTHING = 8

-- Kick. speed/damping are the spring's; the magnitude comes from the weapon.
local KICK_SPEED = 19
local KICK_DAMPING = 0.62
local KICK_ROTATION_SPEED = 17
local KICK_ROTATION_DAMPING = 0.55
-- Peak displacement of a critically damped spring kicked with velocity v0 is
-- v0/(w*e). Pre-multiplying by w*e makes the config number the actual peak.
local IMPULSE_GAIN = math.exp(1)
-- Degrees of muzzle rise per stud of kickback. Pure feel; the camera's real
-- recoil is CameraController's and comes from WeaponConfig.
local KICK_PITCH_PER_STUD = 26
--[[ Down the sights the weapon is shouldered, and the M1A EBR's 0.5-stud kick
     would otherwise throw thirteen degrees of pitch across a 34-degree frame —
     the sights leave the screen entirely between shots. Braced, the same shot
     still reads, because the camera's own recoil is doing the shouting. ]]
local KICK_AIM_SCALE = 0.5

local FLASH_SECONDS = 0.035 -- roughly two frames; any longer reads as a flare

--[[ Particles per shot at a muzzleFlashSize of 1, scaled by the weapon's own.
     Small numbers on purpose: at 1100rpm even eight sparks a shot is 150 live
     particles, and the point is a suggestion of burning powder rather than a
     firework. ]]
local MUZZLE_SPARKS = 8
local MUZZLE_SMOKE = 2

--[[
	Muzzle particles are the most expensive pixels the client draws, and not
	because there are many of them: they are a foot from the near plane, so a
	handful of soft alpha quads covers a large fraction of the screen and every
	one of them is overdraw. On a phone, at a Vector's eleven hundred rounds a
	minute, that is the fill-rate spike arriving on exactly the frames the player
	is trying to aim.

	Smoke takes the deeper cut of the two. Sparks are small, bright and brief and
	are what actually reads as a shot; smoke is the large soft one and is nearly
	all of the overdraw.

	Floors of 3 and 1 stay below, so a shot on a phone still flashes — the
	existing math.max is what keeps this from ever silencing a gun.
]]
local muzzleSparkScale = 1
local muzzleSmokeScale = 1

local function adoptMuzzleScale()
	muzzleSparkScale = Device.pick({ Mobile = 0.55, Tablet = 0.75 }, 1)
	muzzleSmokeScale = Device.pick({ Mobile = 0.3, Tablet = 0.6 }, 1)
end
local FLASH_LIGHT_RANGE = 14
local FLASH_LIGHT_BRIGHTNESS = 5

--[[ Sized for the fastest gun in the roster, not for a comfortable average: the
     Vector cycles at 1100rpm, so a ten-shell ring is recycling brass that is
     still in the air and a burst looks like it ejected three cases. ]]

-- Placeholder geometry only. Real weapons come from Assets/Viewmodels; these
-- colours exist so a missing model reads as "no art yet" rather than as a bug.
local BLOCK_COLOR = Color3.fromRGB(46, 44, 42)
local BLOCK_ACCENT = Color3.fromRGB(28, 27, 26)
local BLADE_COLOR = Color3.fromRGB(168, 170, 176)

--[[ States in which the weapon is not in the player's hands. A downed survivor
     is firing a pistol from the floor and a pinned one has both arms occupied;
     in neither case does a viewmodel in the corner of the screen tell the truth
     about what is happening to them. ]]
local HIDDEN_STATES: { [string]: boolean } = {
	[STATE.Incapacitated] = true,
	[STATE.Pinned] = true,
	[STATE.Dead] = true,
	[STATE.Spectating] = true,
}

local ViewmodelController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local model: Model? = nil
local muzzle: Attachment? = nil
local flashPart: BasePart? = nil
local flashLight: PointLight? = nil
local flashSparks: ParticleEmitter? = nil
local flashSmoke: ParticleEmitter? = nil
local flashUntil = 0

local swayPosition = Spring.new(Vector3.zero, SWAY_SPEED, SWAY_DAMPING)
local swayRotation = Spring.new(Vector3.zero, SWAY_SPEED, SWAY_DAMPING)
local kickPosition = Spring.new(Vector3.zero, KICK_SPEED, KICK_DAMPING)
local kickRotation = Spring.new(Vector3.zero, KICK_ROTATION_SPEED, KICK_ROTATION_DAMPING)

local current = {
	weaponId = nil :: string?,
	definition = nil :: any,
	pose = DEFAULT_POSE :: Pose,
	--[[ The model's sight, in pivot space, or nil for a model that did not ship
	     one. Down the sights the pose is solved so that THIS point lands on the
	     centre line, which is what makes a scoped model's glass line up with the
	     crosshair instead of merely near it. ]]
	sightOffset = nil :: Vector3?,
	aiming = false,
	aimAlpha = 0,
	bobPhase = 0,
	bobAmount = 0,
	lastYaw = 0,
	lastPitch = 0,
	hidden = false,
	reloadRoll = 0, -- eased target for the reload lean, 0 or 1
	reloading = false,
	--[[ Seconds into the inspect, or -1 when it is not running. See INSPECT_*. ]]
	inspectClock = -1,
	--[[ Which way the next melee stroke travels. See onMeleeSwing. ]]
	swingSign = 1,
}

--[[
	The inspect: the gun turned over in your hands so you can actually look at it.

	Everything about the viewmodel until now was REACTIVE — sway answers the
	mouse, bob answers your feet, kick answers the trigger — so the weapon was
	only ever seen from the one angle it is held at, moving because something
	happened to it. This is the one motion the player asks for.

	Blended on top of the same pose everything else composes into rather than
	replacing it, so a shove or a step still reads through the inspect and the
	gun never goes rigid.

	── IT MUST NEVER COST YOU A FIGHT ──────────────────────────────────────────
	Cancelled the instant anything real happens: aiming, firing, reloading, a
	swing, a shove, a weapon swap, or the model being hidden. A player who is
	admiring their rifle when a Hunter comes round the corner has to be shooting
	on the next frame, not on the frame after the animation finished. That rule is
	why this is an offset and not a takeover — cancelling is just letting the
	alpha fall, and the fall is already the return half of the motion.
]]
local INSPECT_SECONDS = 2.1
--[[ Fractions of the motion spent coming up and going back. The remainder is the
     hold, which is the part the player is actually looking at. ]]
local INSPECT_IN = 0.22
local INSPECT_OUT = 0.26
--[[ Where it goes. Z is toward the camera — the pose table's hip Z is negative,
     which is away — so this brings the weapon closer as well as up, and inboard
     toward the centre line where there is room to turn it. ]]
local INSPECT_OFFSET = Vector3.new(-0.22, 0.30, 0.38)
--[[ And which way it turns. Yaw swings the muzzle across so the receiver's flank
     faces the camera, roll lays it over, pitch lifts the barrel. ]]
local INSPECT_PITCH = math.rad(12)
local INSPECT_YAW = math.rad(48)
local INSPECT_ROLL = math.rad(-22)
--[[ A slow extra turn across the hold, so the weapon is still moving while it is
     being looked at. A pose that arrives and freezes reads as a stuck frame. ]]
local INSPECT_TURN = math.rad(16)

--[[
	The reload, which the viewmodel has never shown.

	`reloadRoll` has been declared in `current` since the file was written, with
	the comment "eased target for the reload lean", and nothing has ever read it.
	So everyone else watches you reload — CarryVisualService animates the
	third-person model — and the one person who cannot see it is you. In a
	first-person shooter the reload is the second most-performed animation there
	is, and this one was a number counting down behind a gun that did not move.

	── ROLLED, NOT PULLED IN ───────────────────────────────────────────────────
	The obvious version drags the weapon toward the chest, and it is wrong: those
	2.6 seconds are the most vulnerable in the game, and taking away the middle of
	the screen while a Hunter is closing is punishing the player for a mechanic
	they did not choose to be in. Rolling the weapon about its own long axis turns
	the receiver toward the camera — which is what selling a reload actually
	needs — while leaving the view down the barrel clear.

	Scaled by (1 - aimAlpha) as well: the aim pose is solved around the model's
	own sight so the glass lands on the crosshair, and rolling it while aiming
	would peel the sight off the centre line.
]]
local RELOAD_SECONDS = 0.16 -- how fast the lean eases in and out
local RELOAD_ROLL = math.rad(34)
local RELOAD_PITCH = math.rad(-11)
local RELOAD_DROP = Vector3.new(0.04, -0.10, 0.06)

--[[ Ease in and out of a 0..1 ramp. The motion is a trapezoid and every corner
     of it goes through here, so nothing in the inspect starts or stops abruptly. ]]
local function smoothstep(alpha: number): number
	local a = math.clamp(alpha, 0, 1)
	return a * a * (3 - 2 * a)
end

local cameraController: any = nil

-- ── model construction ──────────────────────────────────────────────────────

--[[
	Makes somebody else's model safe to hold.

	The supplied guns are real models with real baggage: a LocalScript in one
	would run the moment the clone is parented to the Camera, and a Sound left
	Playing would loop under the player's ear forever with nothing to stop it.
	Both are stripped here, while the clone is still parented to nil.
]]
local function prepare(instance: Instance)
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			--[[ Anchored, unqueryable and shadowless. A viewmodel lives under the
			     Camera where there is no physics anyway, but leaving CanQuery on
			     would let the player's own shots raycast into their gun. ]]
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Massless = true
		elseif descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		elseif descendant:IsA("Sound") then
			-- Every sound this weapon makes is played by WeaponController, in 2D,
			-- on the frame it happened. Nothing the model brought is wanted.
			descendant:Destroy()
		end
	end
end

local function block(parent: Instance, name: string, size: Vector3, offset: CFrame, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = offset
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.NormalId.Front
	part.BottomSurface = Enum.NormalId.Front
	part.Parent = parent
	return part
end

--[[
	The stand-in. Deliberately crude and deliberately correct in silhouette: a
	pistol is short, a rifle is long, a shotgun is fat, a machete is a blade.
	The player must be able to tell what they are holding from the shape alone,
	because that is all a placeholder can promise.
]]
local function buildFallback(weaponId: string, definition: any, pose: Pose): Model
	local built = Instance.new("Model")
	built.Name = weaponId

	-- Built to the pose's own length, so a stand-in frames exactly where the
	-- real model will and swapping the art in is not also a retune.
	local length = pose.length

	if definition and definition.fireMode == "Melee" then
		local grip =
			block(built, "Handle", Vector3.new(0.16, 0.16, 0.25 * length), CFrame.new(), BLOCK_ACCENT)
		block(
			built,
			"Blade",
			Vector3.new(0.06, 0.42, 0.75 * length),
			CFrame.new(0, 0.12, -0.5 * length) * CFrame.Angles(math.rad(6), 0, 0),
			BLADE_COLOR
		)
		built.PrimaryPart = grip
		return built
	end

	--[[ Girth is the weapon's own: a sidearm is thin everywhere, and ten pellets
	     leave a barrel wide enough to see. Both read off the definition so the
	     silhouette still says something true about what is being held. ]]
	local girth = (if definition and definition.slot == Enums.Slot.Secondary then 0.74 else 1.0)
		* (if definition and definition.pellets > 1 then 1.3 else 1.0)

	local receiver = block(
		built,
		"Handle",
		Vector3.new(0.2 * girth, 0.34 * girth, 0.5 * length),
		CFrame.new(0, 0, 0.05 * length),
		BLOCK_COLOR
	)
	block(
		built,
		"Barrel",
		Vector3.new(0.12 * girth, 0.12 * girth, 0.55 * length),
		CFrame.new(0, 0.06 * girth, -0.45 * length),
		BLOCK_ACCENT
	)
	block(
		built,
		"Grip",
		Vector3.new(0.16 * girth, 0.46 * girth, 0.22 * girth),
		CFrame.new(0, -0.36 * girth, 0.2 * length) * CFrame.Angles(math.rad(12), 0, 0),
		BLOCK_ACCENT
	)
	if definition and definition.magSize > 0 then
		-- Clamped hard at the top: the PPSh's seventy-one rounds would otherwise
		-- hang a magazine down past the bottom of the screen.
		local depth = math.clamp(definition.magSize / 50, 0.35, 1) * 0.5
		block(
			built,
			"Magazine",
			Vector3.new(0.14 * girth, depth, 0.2 * girth),
			CFrame.new(0, -0.2 * girth - depth * 0.5, -0.05 * length),
			BLOCK_ACCENT
		)
	end

	built.PrimaryPart = receiver
	return built
end

--[[ A name reduced to the part a human would call the same: "AK-12", "AK 12"
     and "ak_12" all collapse onto one key. ]]
local function normalise(name: string): string
	local stripped = string.gsub(name, "[%s%-_%.]", "")
	return string.lower(stripped)
end

--[[ A candidate template: the model itself, or one out of a folder of variants,
     since OrganizeAssets lays some categories out that way. ]]
local function asModel(entry: Instance?): Model?
	if not entry then
		return nil
	end
	if entry:IsA("Model") then
		return entry
	end
	if entry:IsA("Folder") then
		return entry:FindFirstChildOfClass("Model")
	end
	return nil
end

--[[
	The model for a weapon, out of ReplicatedStorage.Assets.Viewmodels.

	`modelName` is tried FIRST and that ordering is the entire reason the field
	exists: the artist's PPSh is called "(71 Mag) PPSh-41", which matches neither
	the enum key `PPSh41` nor the display name "PPSh-41", and every earlier
	lookup order silently handed that weapon a grey box. Weapon id and display
	name follow for the grey-boxes PlaceholderFactory names after the enum, then
	a whitespace- and case-insensitive sweep as a last resort for "AK 12" vs
	"AK-12" and friends.
]]
local function findTemplate(weaponId: string, definition: any): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild("Viewmodels")
	if not folder then
		return nil
	end

	local keys = table.create(3)
	if definition and definition.modelName then
		table.insert(keys, definition.modelName)
	end
	table.insert(keys, weaponId)
	if definition and definition.displayName then
		table.insert(keys, definition.displayName)
	end

	for _, key in keys do
		local found = asModel(folder:FindFirstChild(key))
		if found then
			return found
		end
	end

	local wanted = {}
	for _, key in keys do
		wanted[normalise(key)] = true
	end
	for _, child in folder:GetChildren() do
		if wanted[normalise(child.Name)] then
			local found = asModel(child)
			if found then
				return found
			end
		end
	end
	return nil
end

local function largestPart(instance: Instance): BasePart?
	local best: BasePart? = nil
	local bestVolume = -1
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			local size = descendant.Size
			local volume = size.X * size.Y * size.Z
			if volume > bestVolume then
				best = descendant
				bestVolume = volume
			end
		end
	end
	return best
end

--[[ First attachment matching any of `names`, ranked by the order given rather
     than by tree order, in one descendant walk. A supplied model can carry
     dozens of parts and walking it once per candidate name is wasteful on a
     weapon swap that already has a clone to pay for. ]]
local function findAttachment(root: Instance, names: { string }): Attachment?
	local best: Attachment? = nil
	local bestRank = math.huge
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Attachment") then
			local rank = table.find(names, descendant.Name)
			if rank and rank < bestRank then
				best = descendant
				bestRank = rank
			end
		end
	end
	return best
end

--[[ Something to hang attachments off. Prefers the artist's own PrimaryPart,
     then a "Handle" (what a Tool-derived model calls its grip), then the
     biggest thing present. Deliberately never PROMOTED to PrimaryPart: a part
     whose own rotation is arbitrary would drag the whole weapon's orientation
     with it the first time the model is pivoted. ]]
local function attachmentHost(built: Model): BasePart?
	local primary = built.PrimaryPart
	if primary then
		return primary
	end
	local handle = built:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		return handle
	end
	return largestPart(built)
end

--[[ Pins the pivot to the centre of the model's own bounding box when the
     artist did not choose one. An unset pivot is recomputed by the engine as
     the parts move, and the pose, the fit and the muzzle below are all measured
     against it — it has to hold still. ]]
local function pinPivot(built: Model)
	if built.PrimaryPart then
		return
	end
	local boxCFrame = built:GetBoundingBox()
	built.WorldPivot = boxCFrame
end

--[[
	Scales a supplied model to the length its class pose was authored for.

	Guns arrive at every scale imaginable: the same rifle exported at Roblox's
	scale, at another engine's, or at whatever the mesh happened to be. Anything
	within FIT_TOLERANCE is left exactly as the artist made it; only the models
	that would otherwise fill the frame or vanish inside it are touched. Measured
	on the longest axis, because which way a model points is the one thing about
	it we genuinely cannot know.
]]
local function fitScale(built: Model, pose: Pose)
	local _, size = built:GetBoundingBox()
	local longest = math.max(size.X, size.Y, size.Z)
	if longest < 1e-3 then
		return
	end
	local ratio = longest / pose.length
	if ratio <= FIT_TOLERANCE and ratio >= 1 / FIT_TOLERANCE then
		return
	end
	-- ScaleTo rejects a handful of exotic instance trees; a model at the wrong
	-- scale is survivable, an error that kills the swap is not.
	local ok = pcall(function()
		built:ScaleTo(built:GetScale() * (pose.length / longest))
	end)
	if not ok then
		warn(string.format("[ViewmodelController] could not scale %q to fit", built.Name))
	end
end

-- ── arms ────────────────────────────────────────────────────────────────────

--[[
	First-person arms, cloned from the player's own avatar.

	These are the ACTUAL arm parts off the local character, not stand-ins: the
	same mesh, the same skin tone, the same shirt texture, the same accessories
	if any are welded to them. That is the whole point — a player should see their
	own hands, and a generic pair of blocks in front of a customised avatar reads
	as somebody else's arms.

	They are built as CHILDREN OF THE WEAPON MODEL rather than posed separately.
	That is what makes them cheap: the weapon is already moved once per frame with
	one PivotTo, and anything parented into it inherits every bit of the sway,
	bob, recoil kick and aim transition without a second line of maths. It also
	makes them correct by construction — hands welded to a gun cannot drift off
	it, which is exactly the failure mode of arms driven by their own IK.

	R6 and R15 both work and are handled separately, because they are genuinely
	different problems: R6 has one part per arm, so the whole limb is a single
	rigid piece placed at the grip. R15 has three (upper, lower, hand) and they
	are chained so the arm bends at the elbow.

	The shoulder end runs off the bottom of the frame on purpose. Nobody sees an
	elbow in a first-person shooter, and solving for one costs geometry for
	something the player will never look at.
]]

-- Where the hands sit on the weapon, as fractions of its own bounding box, so
-- the same numbers land correctly on a pistol and on a battle rifle.
local GRIP_BACK = 0.16 -- toward the shooter, along the weapon's length
local GRIP_DROP = 0.34 -- below the bore line: a grip hangs under the receiver
local SUPPORT_FORWARD = 0.28 -- the off hand, forward along the handguard
local SUPPORT_DROP = 0.22

-- Which way each arm runs back toward the camera. The right arm comes in tighter
-- than the left because the shooting hand sits behind the gun while the support
-- hand reaches across for it.
local RIGHT_RUN = Vector3.new(0.42, -0.34, 1.0)
local LEFT_RUN = Vector3.new(-0.58, -0.30, 1.0)

-- Fallback geometry, used only when the character has no arm to clone — which
-- happens for exactly as long as it takes an avatar to load.
local FALLBACK_HAND = Vector3.new(0.30, 0.30, 0.34)
local FALLBACK_THICKNESS = 0.27
local FALLBACK_LENGTH = 1.45
local FALLBACK_SKIN = Color3.fromRGB(198, 158, 122)
local FALLBACK_SLEEVE = Color3.fromRGB(64, 62, 58)

--[[ R15 arm chain, shoulder outward. Cloning the whole chain is what lets the
     arm bend rather than being one rigid stick. ]]
local R15_RIGHT = { "RightUpperArm", "RightLowerArm", "RightHand" }
local R15_LEFT = { "LeftUpperArm", "LeftLowerArm", "LeftHand" }

--[[ Strips a cloned avatar part down to something safe to weld onto a viewmodel:
     no physics, no queries, no scripts that came in on an accessory. ]]
--[[
	Strips a cloned avatar part down to something safe to weld onto a viewmodel.

	THE JOINTS MUST GO FIRST, AND ALL OF THEM.

	Roblox's clone semantics keep references that point OUTSIDE the cloned
	subtree. A limb cloned off a live character therefore arrives still carrying
	joints whose Part0 is the real body — so anchoring the clone anchors the
	whole assembly it is still attached to, and the player's actual avatar floats
	in the air rotating to follow the camera.

	Stripping Motor6D and Weld was not enough: accessories and layered clothing
	attach with WeldConstraint, and the older rigs use Snap and ManualWeld. So
	this removes every JointInstance, every WeldConstraint and every Constraint,
	and only then changes any property.
]]
local function prepareArmPart(part: BasePart)
	for _, descendant in part:GetDescendants() do
		if
			descendant:IsA("JointInstance")
			or descendant:IsA("WeldConstraint")
			or descendant:IsA("Constraint")
			or descendant:IsA("LuaSourceContainer")
			or descendant:IsA("BodyMover")
		then
			descendant:Destroy()
		end
	end

	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

--[[ Clones one avatar part by name, or nil when the character has not loaded it
     yet. Everything about the original is kept: mesh, texture, colour, size. ]]
local function cloneAvatarPart(character: Model?, name: string): BasePart?
	if not character then
		return nil
	end
	local source = character:FindFirstChild(name)
	if not source or not source:IsA("BasePart") then
		return nil
	end
	local clone = source:Clone()
	prepareArmPart(clone)
	return clone
end

--[[
	Places one arm.

	`handAt` is where the hand goes, in the weapon's own frame. `run` is the
	direction the rest of the arm travels away from it. The chain is laid out by
	walking outward from the hand, each segment placed end to end, so an R15 arm
	comes out bent at roughly the angle a real one would be.
]]
local function buildAvatarArm(
	built: Model,
	character: Model?,
	origin: CFrame,
	handAt: Vector3,
	run: Vector3,
	chain: { string },
	r6Name: string
)
	local direction = origin:VectorToWorldSpace(run.Unit)
	local handWorld = origin * CFrame.new(handAt)

	-- R15 first: three parts, hand at the weapon, upper arm furthest away.
	local parts: { BasePart } = {}
	for index = #chain, 1, -1 do
		local part = cloneAvatarPart(character, chain[index])
		if part then
			table.insert(parts, part)
		end
	end

	if #parts > 0 then
		local cursor = 0
		-- parts[1] is the hand; each subsequent segment is pushed further back
		-- along `direction` by its own length.
		for _, part in parts do
			local length = math.max(part.Size.Y, part.Size.Z, 0.2)
			local centre = handWorld.Position + direction * (cursor + length * 0.5)
			-- Limb meshes are authored along their own Y axis, so the arm is
			-- aimed by pointing that axis down the run direction.
			part.CFrame = CFrame.lookAt(centre, centre + direction) * CFrame.Angles(math.pi / 2, 0, 0)
			part.Parent = built
			cursor += length * 0.92 -- slight overlap, so there is no seam at a joint
		end
		return
	end

	-- R6: one part for the entire arm, placed so its lower end is at the grip.
	local single = cloneAvatarPart(character, r6Name)
	if single then
		local length = math.max(single.Size.Y, 0.4)
		local centre = handWorld.Position + direction * (length * 0.42)
		single.CFrame = CFrame.lookAt(centre, centre + direction) * CFrame.Angles(math.pi / 2, 0, 0)
		single.Parent = built
		return
	end

	--[[ Nothing to clone. This is the window between spawning and the avatar
	     replicating, and it is short — but a weapon floating with no hands at all
	     during it looks far worse than a plain pair, so one is built. ]]
	local hand = Instance.new("Part")
	hand.Name = "FL_Hand"
	hand.Size = FALLBACK_HAND
	hand.Color = FALLBACK_SKIN
	hand.Material = Enum.Material.SmoothPlastic
	prepareArmPart(hand)
	hand.CFrame = handWorld
	hand.Parent = built

	local mid = handWorld.Position + direction * (FALLBACK_LENGTH * 0.5 - 0.1)
	local forearm = Instance.new("Part")
	forearm.Name = "FL_Forearm"
	forearm.Size = Vector3.new(FALLBACK_THICKNESS, FALLBACK_THICKNESS, FALLBACK_LENGTH)
	forearm.Color = FALLBACK_SLEEVE
	forearm.Material = Enum.Material.Fabric
	prepareArmPart(forearm)
	forearm.CFrame = CFrame.lookAt(mid, mid + direction)
	forearm.Parent = built
end

--[[
	Safety net for the one failure this system can produce that ruins a round.

	Cloning a limb off a LIVE character and anchoring the copy is only safe while
	every joint the copy carries has been removed — Roblox preserves references
	that point outside a cloned subtree, so a surviving joint anchors the real
	body through it, and the player floats in the air rotating to follow the
	camera. prepareArmPart strips every joint type there is, and this checks that
	it worked rather than trusting it.

	Cheap: a handful of parts, once per weapon swap. And it repairs rather than
	just complaining, because a player who cannot walk does not care whose fault
	it was.
]]
local function releaseCharacter(character: Model?)
	if not character then
		return
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Anchored then
			part.Anchored = false
			warn(
				string.format(
					"[ViewmodelController] %s was left anchored by an arm clone and has been released. "
						.. "A joint type is getting past prepareArmPart.",
					part:GetFullName()
				)
			)
		end
	end
end

--[[
	Places both arms on a built weapon.

	The support hand is skipped for a pistol: a one-handed grip with a second hand
	floating under the barrel looks far worse than no second hand, and the whole
	point of a sidearm silhouette is that it is held in one.
]]
local function buildArms(built: Model, definition: any)
	local ok, _, size = pcall(function()
		return built:GetBoundingBox()
	end)
	if not ok or not size then
		return
	end

	local origin = built:GetPivot()
	-- Weapons point down -Z, so +Z is toward the shooter.
	local depth = math.max(size.Z, 0.4)
	local drop = math.max(size.Y, 0.25)
	local character = player.Character

	buildAvatarArm(
		built,
		character,
		origin,
		Vector3.new(0.02, -drop * GRIP_DROP, depth * GRIP_BACK),
		RIGHT_RUN,
		R15_RIGHT,
		"Right Arm"
	)

	if definition and definition.class == "Pistol" then
		return
	end

	buildAvatarArm(
		built,
		character,
		origin,
		Vector3.new(-0.04, -drop * SUPPORT_DROP, -depth * SUPPORT_FORWARD),
		LEFT_RUN,
		R15_LEFT,
		"Left Arm"
	)

	releaseCharacter(character)
end

--[[ Every model gets a Muzzle. When the art did not ship one it is invented at
     the forward-most point of the bounding box — the tip of the barrel, for any
     model posed the way the table above assumes — so the flash, the tracer
     origin and the ejection port have somewhere to be either way. ]]
local function ensureMuzzle(built: Model, host: BasePart): Attachment
	local existing = findAttachment(built, MUZZLE_NAMES)
	if existing then
		return existing
	end
	local boxCFrame, size = built:GetBoundingBox()
	local attachment = Instance.new("Attachment")
	attachment.Name = "Muzzle"
	attachment.Parent = host
	attachment.WorldCFrame = boxCFrame * CFrame.new(0, 0, -size.Z * 0.5)
	return attachment
end

--[[ The model's sight, in pivot space, or nil for art that did not ship one.
     Measured once per swap: the model never moves relative to its own pivot. ]]
local function sightOffsetOf(built: Model): Vector3?
	local sight = findAttachment(built, SIGHT_NAMES)
	if not sight then
		return nil
	end
	local offset = built:GetPivot():Inverse() * sight.WorldPosition
	if offset.Magnitude > SIGHT_MAX_OFFSET then
		return nil
	end
	return offset
end

local function destroyModel()
	if model then
		model:Destroy()
		model = nil
	end
	muzzle = nil
	flashPart = nil
	flashLight = nil
	flashSparks = nil
	flashSmoke = nil
	flashUntil = 0
	current.sightOffset = nil
end

local function buildFlash(definition: any)
	if not model or not muzzle or not definition or definition.muzzleFlashSize <= 0 then
		return
	end

	--[[ One part, reused for every shot, parented inside the model so PivotTo
	     carries it along. Creating and destroying a flash per round is the kind
	     of allocation that only shows up as a stutter at 900rpm. ]]
	local size = definition.muzzleFlashSize
	local part = Instance.new("Part")
	part.Name = "FL_MuzzleFlash"
	part.Size = Vector3.new(0.35 * size, 0.35 * size, 0.5 * size)
	part.Color = definition.tracerColor
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.CFrame = muzzle.WorldCFrame
	part.Parent = model

	local light = Instance.new("PointLight")
	light.Color = definition.tracerColor
	light.Range = FLASH_LIGHT_RANGE * size
	light.Brightness = FLASH_LIGHT_BRIGHTNESS
	light.Enabled = false
	light.Shadows = false
	light.Parent = part

	--[[
		The two particle layers that make a shot read as a shot.

		Sparks are the fast, bright, directional half — unburnt powder thrown
		forward down the barrel line, gone inside a tenth of a second. Smoke is
		the slow half: a small puff that lingers just long enough to still be
		there for the next round, so sustained fire builds a haze at the muzzle
		instead of each shot looking identical and separate.

		Both are Emit()-on-demand with Rate 0, so they cost nothing between shots
		and never need to be enabled and disabled. One pair per weapon, built
		here with the flash and destroyed with it — at the Vector's 1100rpm,
		creating emitters per shot is eighteen instances a second and eighteen
		more for the collector.
	]]
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "FL_MuzzleSparks"
	sparks.Rate = 0
	sparks.Enabled = false
	sparks.Speed = NumberRange.new(14 * size, 26 * size)
	sparks.Lifetime = NumberRange.new(0.04, 0.11)
	sparks.Rotation = NumberRange.new(0, 360)
	sparks.RotSpeed = NumberRange.new(-220, 220)
	sparks.SpreadAngle = Vector2.new(14, 14)
	sparks.Acceleration = Vector3.new(0, -28, 0)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Color = ColorSequence.new(definition.tracerColor)
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22 * size),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new(0)
	sparks.Parent = part

	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "FL_MuzzleSmoke"
	smoke.Rate = 0
	smoke.Enabled = false
	smoke.Speed = NumberRange.new(2.5 * size, 5 * size)
	smoke.Lifetime = NumberRange.new(0.25, 0.55)
	smoke.Rotation = NumberRange.new(0, 360)
	smoke.RotSpeed = NumberRange.new(-40, 40)
	smoke.SpreadAngle = Vector2.new(22, 22)
	--[[ Drifts UP, not down. Hot gas rises, and a puff that falls reads as dust
	     kicked off the gun rather than as something that just burned. ]]
	smoke.Acceleration = Vector3.new(0, 4, 0)
	smoke.LightEmission = 0.15
	smoke.LightInfluence = 1
	smoke.Color = ColorSequence.new(Color3.fromRGB(96, 92, 88))
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18 * size),
		NumberSequenceKeypoint.new(1, 1.1 * size),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.35, 0.72),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Parent = part

	flashPart = part
	flashLight = light
	flashSparks = sparks
	flashSmoke = smoke
end

--[[
	Swaps the weapon in frame. Cheap enough to call on every attribute change:
	it early-outs when the id has not moved, and a real swap is one clone.
]]
function ViewmodelController:setWeapon(weaponId: string?, definition: any)
	if current.weaponId == weaponId and model then
		current.definition = definition
		return
	end

	destroyModel()
	current.weaponId = weaponId
	current.definition = definition
	current.pose = poseFor(weaponId, definition)

	--[[ Nor the previous gun's inspect. The clock is in seconds rather than tied
	     to a model, so a swap mid-inspect would have carried the remainder onto
	     whatever was drawn next. ]]
	current.inspectClock = -1
	--[[ Nor which way the last weapon was mid-swing. Drawing a machete should
	     always open with the same stroke. ]]
	current.swingSign = 1

	-- A weapon swap must not inherit the previous gun's recoil; the springs are
	-- reset rather than left to settle, which would look like a flinch.
	kickPosition:reset(Vector3.zero)
	kickRotation:reset(Vector3.zero)
	swayPosition:reset(Vector3.zero)
	swayRotation:reset(Vector3.zero)

	if not weaponId then
		return
	end

	local pose = current.pose
	local template = findTemplate(weaponId, definition)
	local built: Model
	if template then
		built = template:Clone()
	else
		built = buildFallback(weaponId, definition, pose)
	end

	prepare(built)
	local host = attachmentHost(built)
	if not host then
		-- A model with no parts cannot be posed; fall back rather than render
		-- an invisible weapon the player will read as a bug.
		built:Destroy()
		built = buildFallback(weaponId, definition, pose)
		prepare(built)
		host = attachmentHost(built) :: BasePart
	end

	built.Name = "FL_Viewmodel"
	pinPivot(built)
	-- Fit before measuring anything off the model: the muzzle, the sight and the
	-- flash are all placed against its final geometry.
	fitScale(built, pose)

	model = built
	muzzle = ensureMuzzle(built, host)
	current.sightOffset = sightOffsetOf(built)

	buildFlash(definition)

	--[[ Arms go on LAST, and that ordering is load-bearing: an invented muzzle is
	     the forward-most point of the bounding box and the sight offset is
	     measured off it too, so adding a forearm before either of them would put
	     the muzzle flash on the player's elbow. ]]
	buildArms(built, definition)

	local camera = Workspace.CurrentCamera
	if camera and not current.hidden then
		built.Parent = camera
	end
end

-- ── shells ──────────────────────────────────────────────────────────────────

--[[
	Brass, by calibre.

	The pool used to be one shape for every gun in the game, which meant a
	shotgun threw the same little rifle case a Vector did. AmmoConfig now names a
	calibre per weapon, and each calibre gets its own small pool built the first
	time a gun that uses it is drawn.

	Pools are per calibre rather than per weapon on purpose: sixteen guns share
	six calibres, so a full loadout costs six pools instead of sixteen, and
	swapping between two rifles that both eject 5.56 reuses the same brass.

	If the artist has supplied a real model at
	`ReplicatedStorage.Assets.Ammo.Casings.<name>` it is cloned; otherwise the
	pool is blocks at the size AmmoConfig gives, which is still the right SHAPE
	per calibre and is most of what the eye is reading at this distance.
]]
local CASING_POOL = 18

type CasingSlot = {
	container: Instance,
	root: BasePart,
	parts: { BasePart },
}

type CasingPool = {
	slots: { CasingSlot },
	expiry: { number },
	cursor: number,
	definition: any,
}

local casingPools: { [string]: CasingPool } = {}
local casingFolder: Folder? = nil

local function ensureCasingFolder(): Folder
	if casingFolder then
		return casingFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "FL_Casings"
	folder.Parent = Workspace
	casingFolder = folder
	trove:add(folder)
	return folder
end

--[[
	Finds a supplied model, or nil. Returns the instance AS IS — a BasePart or a
	Model — because AmmoFactory builds real multi-part cartridges (a bottleneck
	case is a body, a shoulder and a neck) and taking only the first part out of
	one would leave the player watching a floating case mouth.
]]
local function findAmmoTemplate(folderName: string, name: string): Instance?
	if name == "" then
		return nil
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local ammo = assets and assets:FindFirstChild(AmmoConfig.FolderName)
	local group = ammo and ammo:FindFirstChild(folderName)
	local entry = group and group:FindFirstChild(name)
	if entry and (entry:IsA("BasePart") or entry:IsA("Model")) then
		return entry
	end
	return nil
end

--[[
	Turns a template into something the pool can throw.

	Returns the container to parent and reparent, the single part to apply
	velocity to, and every part in it so visibility can be toggled. A model
	arrives already welded to its PrimaryPart, so moving that one part carries
	the rest — which is why the pool never has to know how many pieces a
	cartridge is made of.
]]
local function instantiateAmmo(
	template: Instance?,
	fallbackSize: Vector3,
	fallbackColor: Color3,
	fallbackMaterial: Enum.Material
): (Instance, BasePart, { BasePart })
	if template then
		local clone = template:Clone()
		local root: BasePart?
		if clone:IsA("BasePart") then
			clone:ClearAllChildren()
			root = clone
		else
			local model = clone :: Model
			root = model.PrimaryPart
			if not root then
				local best, bestVolume = nil, -1
				for _, part in model:GetDescendants() do
					if part:IsA("BasePart") then
						local volume = part.Size.X * part.Size.Y * part.Size.Z
						if volume > bestVolume then
							best, bestVolume = part, volume
						end
					end
				end
				root = best
			end
		end

		if root then
			local parts = {}
			if clone:IsA("BasePart") then
				parts[1] = clone :: BasePart
			else
				for _, part in clone:GetDescendants() do
					if part:IsA("BasePart") then
						table.insert(parts, part)
					end
				end
			end
			return clone, root, parts
		end
		clone:Destroy()
	end

	local block = Instance.new("Part")
	block.Size = fallbackSize
	block.Color = fallbackColor
	block.Material = fallbackMaterial
	return block, block, { block }
end

--[[ Applies the properties every piece of thrown ammunition needs, whether it is
     one part or seven. Only the root carries collision; the rest ride along
     welded, which keeps the physics cost of a bottleneck case identical to a
     block's. ]]
local function configureAmmo(root: BasePart, parts: { BasePart }, collide: boolean)
	for _, part in parts do
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Anchored = false
		part.Massless = part ~= root
		part.CanCollide = collide and part == root
		--[[ Debris never collides with a survivor or an infected, which is what
		     stops a magazine's worth of brass from nudging a player off a ledge.
		     The group is registered by the server bootstrap; if this client got
		     here first, non-colliding brass is the safe failure. ]]
		local ok = pcall(function()
			part.CollisionGroup = "Debris"
		end)
		if not ok then
			part.CanCollide = false
		end
	end
end

local function setAmmoVisible(parts: { BasePart }, visible: boolean)
	for _, part in parts do
		part.Transparency = if visible then 0 else 1
	end
end

--[[
	Builds the pool for one calibre, on first use.

	Per calibre rather than per weapon: sixteen guns share six calibres, so a full
	loadout costs six pools instead of sixteen, and swapping between two rifles
	that both eject 5.56 reuses the same brass. Everything is parked anchored and
	invisible until it is thrown, so an idle pool costs no physics at all.
]]
local function buildCasingPool(calibre: string, definition: any): CasingPool
	local folder = ensureCasingFolder()
	local template = findAmmoTemplate(AmmoConfig.CasingFolder, definition.model)

	local pool: CasingPool = { slots = {}, expiry = {}, cursor = 0, definition = definition }

	for index = 1, CASING_POOL do
		local container, root, parts =
			instantiateAmmo(template, definition.size, definition.color, definition.material)

		container.Name = "FL_Casing_" .. calibre
		configureAmmo(root, parts, true)
		setAmmoVisible(parts, false)
		for _, part in parts do
			part.Anchored = true
		end
		container.Parent = folder

		pool.slots[index] = { container = container, root = root, parts = parts }
		pool.expiry[index] = 0
	end

	casingPools[calibre] = pool
	return pool
end

local function ejectShell()
	if not muzzle then
		return
	end

	local entry = AmmoConfig.forWeapon(current.weaponId)
	local calibre = entry and entry.casing or ""
	if calibre == "" then
		return -- melee, and anything else that does not throw brass
	end

	local definition = AmmoConfig.Casings[calibre]
	if not definition then
		return
	end

	local pool = casingPools[calibre] or buildCasingPool(calibre, definition)
	pool.cursor = (pool.cursor % CASING_POOL) + 1
	local slot = pool.slots[pool.cursor]
	if not slot then
		return
	end
	local shell = slot.root

	--[[ Out of the right of the weapon, back from the muzzle by a fraction of the
	     weapon's own length rather than by a fixed distance — a constant tuned
	     for a rifle throws a pistol's brass out of the barrel. ]]
	local base = muzzle.WorldCFrame * CFrame.new(0.18, 0, current.pose.length * 0.45)
	for _, part in slot.parts do
		part.Anchored = false
	end
	setAmmoVisible(slot.parts, true)
	-- The root carries the assembly: every other piece is welded to it.
	shell.CFrame = base * CFrame.Angles(0, math.random() * math.pi * 2, 0)
	shell.AssemblyLinearVelocity = base.RightVector * definition.ejectSpeed
		+ base.UpVector * definition.ejectUp
	shell.AssemblyAngularVelocity = Vector3.new(
		(math.random() - 0.5) * definition.spin,
		(math.random() - 0.5) * definition.spin,
		(math.random() - 0.5) * definition.spin
	)
	pool.expiry[pool.cursor] = os.clock() + definition.lifetime
end

local function stepShells(now: number)
	for _, pool in casingPools do
		for index = 1, CASING_POOL do
			local expiry = pool.expiry[index]
			if expiry > 0 and now >= expiry then
				local slot = pool.slots[index]
				if slot then
					slot.root.AssemblyLinearVelocity = Vector3.zero
					setAmmoVisible(slot.parts, false)
					for _, part in slot.parts do
						part.Anchored = true
					end
				end
				pool.expiry[index] = 0
			end
		end
	end
end

-- ── magazines ───────────────────────────────────────────────────────────────

--[[
	The dropped magazine.

	Worth its own system rather than reusing the brass pool, because it is the
	one piece of ammunition the player genuinely looks at: it falls out of frame
	over about a second at arm's length, and it is the clearest signal in the
	game that a reload is happening and how far through it you are.

	One at a time is enough — a second reload before the first magazine has
	landed simply recycles it.
]]
local MAGAZINE_LIFETIME = 4
local magazineContainer: Instance? = nil
local magazineExpiry = 0

local function dropMagazine()
	local definition = AmmoConfig.magazineFor(current.weaponId)
	-- A shell-by-shell weapon has no magazine to drop; the shotgun's reload reads
	-- through the pump and the shells instead.
	if not definition or definition.perShellRound then
		return
	end
	if not model or not muzzle then
		return
	end

	local folder = ensureCasingFolder()

	if magazineContainer then
		magazineContainer:Destroy()
		magazineContainer = nil
	end

	local template = findAmmoTemplate(AmmoConfig.MagazineFolder, definition.model)
	local container, root, parts =
		instantiateAmmo(template, definition.size, definition.color, definition.material)

	container.Name = "FL_Magazine"
	configureAmmo(root, parts, true)
	setAmmoVisible(parts, true)

	-- Out of the magazine well: under the receiver, behind the muzzle.
	local well = muzzle.WorldCFrame * CFrame.new(0, -0.28, current.pose.length * 0.55)
	root.CFrame = well
	root.AssemblyLinearVelocity = -well.UpVector * definition.dropSpeed
		+ well.LookVector * (definition.dropSpeed * 0.25)
	root.AssemblyAngularVelocity =
		Vector3.new((math.random() - 0.5) * 6, (math.random() - 0.5) * 4, (math.random() - 0.5) * 6)
	container.Parent = folder

	magazineContainer = container
	magazineExpiry = os.clock() + MAGAZINE_LIFETIME
end

local function stepMagazine(now: number)
	if magazineContainer and magazineExpiry > 0 and now >= magazineExpiry then
		magazineContainer:Destroy()
		magazineContainer = nil
		magazineExpiry = 0
	end
end

-- ── feedback the weapon controller drives ───────────────────────────────────

--[[ One shot: the flash, the punch and the brass, all on this frame. ]]
function ViewmodelController:onFired(definition: any, _seed: number)
	-- Shooting ends the inspect. See ViewmodelController.inspect.
	current.inspectClock = -1

	if not definition then
		return
	end

	-- One brace factor covers the punch and the rise below, because the pitch is
	-- derived from the kickback rather than tuned separately.
	local kickback = definition.kickback * (1 - current.aimAlpha * (1 - KICK_AIM_SCALE))
	local speed = kickPosition.speed
	--[[ Back along the barrel, up, and a touch to the left, so a burst walks
	     rather than pistons. The lateral component is signed randomly, which is
	     the difference between a gun that lives and one that repeats. ]]
	kickPosition:impulse(
		Vector3.new(
			kickback * 0.25 * (if math.random() < 0.5 then -1 else 1) * speed * IMPULSE_GAIN,
			kickback * 0.35 * speed * IMPULSE_GAIN,
			kickback * speed * IMPULSE_GAIN
		)
	)

	local rotationSpeed = kickRotation.speed
	local pitch = math.rad(kickback * KICK_PITCH_PER_STUD)
	kickRotation:impulse(
		Vector3.new(
			pitch * rotationSpeed * IMPULSE_GAIN,
			pitch * 0.25 * (math.random() - 0.5) * rotationSpeed * IMPULSE_GAIN,
			pitch * 0.4 * (math.random() - 0.5) * rotationSpeed * IMPULSE_GAIN
		)
	)

	if flashPart and flashLight then
		flashPart.Transparency = 0.1
		flashLight.Enabled = true
		flashUntil = os.clock() + FLASH_SECONDS

		--[[ Scaled by the weapon's own flash size, so a .357 throws a handful of
		     sparks and the shotgun throws a fistful. A shell-fed gun that emitted
		     the same count as a Vector would read as identical at every calibre. ]]
		local scale = definition.muzzleFlashSize
		if flashSparks then
			flashSparks:Emit(math.max(math.floor(MUZZLE_SPARKS * scale * muzzleSparkScale), 3))
		end
		if flashSmoke then
			flashSmoke:Emit(math.max(math.floor(MUZZLE_SMOKE * scale * muzzleSmokeScale), 1))
		end
	end

	if definition.shellEject then
		ejectShell()
	end
end

--[[ The empty click has to be felt before the number is read. A short downward
     nudge is enough: the weapon dips, nothing happens, and the player knows. ]]
--[[
	Where the barrel actually is, in world space, or nil when nothing is drawn.

	WeaponController raycasts from the CAMERA — you shoot where you look, and
	that must not change — but a tracer drawn from the camera appears to leave
	the player's face, because in first person the gun sits below and to the
	right of the eye. The hit point is the same either way; only the line
	between differs, and drawing it from here is what makes a shot look like it
	came out of the gun.

	Nil while the viewmodel is hidden (third person, spectating, downed with no
	model), and the caller falls back to the camera rather than skipping the
	tracer — a tracer from slightly the wrong place beats no tracer at all.
]]
function ViewmodelController:getMuzzlePosition(): Vector3?
	if not model or not muzzle then
		return nil
	end
	return muzzle.WorldPosition
end

--[[
	Turn the gun over so the player can look at it.

	Reached by re-selecting the weapon slot you are already holding — see
	InputController.forward, which is where the same "press it again" rule already
	commits a consumable. Costs nothing, so unlike that one it is not restricted
	to the schemes with no better option: a desktop player pressing 1 twice gets a
	look at their rifle, and a phone player tapping the tile they are already on
	gets the same thing with no ninth button on the pad.

	Re-pressing RESTARTS it rather than being ignored. A player pressing again is
	asking for another look, and swallowing that reads as the key not working.
]]
function ViewmodelController:inspect()
	if not model or current.hidden or current.aiming or current.reloading then
		return
	end
	current.inspectClock = 0
end

function ViewmodelController:onDryFire()
	local speed = kickPosition.speed
	kickPosition:impulse(Vector3.new(0, -0.05 * speed * IMPULSE_GAIN, 0.02 * speed * IMPULSE_GAIN))
end

function ViewmodelController:onReloadStarted(_definition: any, _perShell: boolean)
	current.inspectClock = -1

	dropMagazine()
	current.reloading = true
end

function ViewmodelController:onShellLoaded()
	local speed = kickPosition.speed
	kickPosition:impulse(Vector3.new(0, -0.03 * speed * IMPULSE_GAIN, 0.03 * speed * IMPULSE_GAIN))
end

function ViewmodelController:onReloadFinished(_completed: boolean)
	current.reloading = false
end

--[[ The pump, the bolt, the slide — whatever the weapon calls it, the hand
     moves and the weapon rocks. Sharp and short; this is punctuation. ]]
function ViewmodelController:onPump()
	local speed = kickPosition.speed
	kickPosition:impulse(Vector3.new(0, 0.04 * speed * IMPULSE_GAIN, 0.16 * speed * IMPULSE_GAIN))
	local rotationSpeed = kickRotation.speed
	kickRotation:impulse(Vector3.new(math.rad(4) * rotationSpeed * IMPULSE_GAIN, 0, 0))
end

--[[
	A swing, and the next one comes back the other way.

	Every stroke used to be the identical impulse on all six axes, so a knife at
	two and a half swings a second was the same frame played over and over — which
	does not read as swinging, it reads as the viewmodel stuttering. A person
	swinging a machete alternates, because the arm has to come back before it can
	go again.

	Only the LATERAL terms flip. The downward pitch and the pull toward the body
	stay as they are: a swing always comes down and always comes in, and mirroring
	those would turn every second stroke into an uppercut thrown backwards.

	The sign is stored per weapon rather than globally, and reset on a swap, so
	drawing a machete always opens with the same stroke instead of inheriting
	whichever way the last knife happened to leave it.
]]
function ViewmodelController:onMeleeSwing(definition: any)
	current.inspectClock = -1

	local sign = current.swingSign
	current.swingSign = -sign

	local speed = kickPosition.speed
	local reach = if definition then definition.kickback else 0.3
	kickPosition:impulse(
		Vector3.new(
			-reach * 1.6 * speed * IMPULSE_GAIN * sign,
			-reach * 0.8 * speed * IMPULSE_GAIN,
			-reach * 1.2 * speed * IMPULSE_GAIN
		)
	)
	local rotationSpeed = kickRotation.speed
	kickRotation:impulse(
		Vector3.new(
			math.rad(-18) * rotationSpeed * IMPULSE_GAIN,
			math.rad(26) * rotationSpeed * IMPULSE_GAIN * sign,
			math.rad(-30) * rotationSpeed * IMPULSE_GAIN * sign
		)
	)
end

--[[ The shove is a shoulder-and-forearm push. It throws the weapon out of frame
     hard, which is exactly the cost the verb is supposed to have. ]]
function ViewmodelController:onShove()
	current.inspectClock = -1

	local speed = kickPosition.speed
	kickPosition:impulse(
		Vector3.new(-0.35 * speed * IMPULSE_GAIN, -0.2 * speed * IMPULSE_GAIN, -0.5 * speed * IMPULSE_GAIN)
	)
	local rotationSpeed = kickRotation.speed
	kickRotation:impulse(Vector3.new(math.rad(-14) * rotationSpeed * IMPULSE_GAIN, 0, 0))
end

function ViewmodelController:setAiming(value: boolean)
	current.aiming = value
end

function ViewmodelController:getModel(): Model?
	return model
end

--[[ Where a tracer or a flash should originate in world space. Nil when there
     is no weapon in frame, which callers must handle rather than assume. ]]
function ViewmodelController:getMuzzlePosition(): Vector3?
	if not muzzle then
		return nil
	end
	return muzzle.WorldPosition
end

function ViewmodelController:isVisible(): boolean
	return not current.hidden and model ~= nil
end

--[[
	Whether the camera has left first person — whatever put it there.

	Two things do. A player who is dead or spectating gets Classic and an unpinned
	zoom from CameraController so they can pull back and watch the team. And ANY
	screen with something to click calls FreeCursor.take, which sets Classic, a
	max zoom of 12 and a MIN zoom of 4 — Roblox forces first person below about a
	stud, so releasing the cursor means pushing the camera out, and there is no
	version of that which leaves the player looking down their own sights.

	The comment this replaces claimed the first was the only case. It was wrong
	about the second and the cost was on screen: opening the round-start loadout
	picker, the pause menu, the shop or the settings panel popped the camera to
	four studs behind the survivor and left the VIEWMODEL parented to it — a pair
	of arms and a gun the size of a car floating across the middle of the screen,
	because a viewmodel is built to be inches from a lens that is no longer there.

	Read off the camera rather than off a copy of either state list, so a third
	reason to leave first person is handled the day it is added.
]]
local function cameraIsThirdPerson(): boolean
	return player.CameraMode == Enum.CameraMode.Classic and player.CameraMaxZoomDistance > 1
end

-- ── the frame ───────────────────────────────────────────────────────────────

local function setHidden(hidden: boolean)
	if current.hidden == hidden then
		return
	end
	current.hidden = hidden
	if not model then
		return
	end
	if hidden then
		--[[ Reparented out rather than made transparent: an invisible viewmodel
		     is still a rendered viewmodel, and a downed survivor's frame budget
		     is being spent on the four zombies standing over them. ]]
		model.Parent = nil
	else
		model.Parent = Workspace.CurrentCamera
	end
end

--[[ Whether the player's STATE says to hide it — dead, spectating, and the rest
     of HIDDEN_STATES. Kept apart from the camera's reason because they change on
     completely different signals: this one on an attribute, the camera's on any
     screen opening, and either alone is enough to hide. ]]
local hiddenByState = false

local function applyHidden()
	setHidden(hiddenByState or cameraIsThirdPerson())
end

local function refreshHidden()
	hiddenByState = HIDDEN_STATES[Attributes.get(player, PA.State, STATE.Spectating)] == true
	applyHidden()
end

--[[
	The world gun on the LOCAL player's own character.

	CarryVisualService welds one to every survivor's hand so that teammates can
	see what each other are holding. That includes this player, whose own copy
	sits a couple of studs in front of a first-person camera — a second rifle,
	floating through the viewmodel.

	Roblox's own TransparencyController already fades the local character to
	nothing at first-person range and our model is a descendant of it, so this is
	belt and braces. It is worth the lines anyway: it is not documented behaviour
	that a welded Model under the character is cached by that controller, and the
	failure mode if it is not is the single most obvious visual bug this feature
	could have.

	Note this is NOT the same question as whether the viewmodel is hidden. A
	downed survivor's viewmodel goes away and their camera stays at their head,
	so keying off that would put their own pistol in their face for exactly as
	long as they were on the floor.

	LocalTransparencyModifier rather than Transparency, because Transparency
	replicates and would hide the gun for everybody else too.

	The TORCH on it goes with the model, for a different reason. This player has
	their own beam from the eye — see FlashlightController — and leaving their
	gun's lit as well would be two coincident lights, doubling their brightness
	and nobody else's. A client writing to a replicated instance changes only its
	own copy, so switching it off here takes it off for this player and leaves
	every teammate's view of it alone.
]]
local CARRIED_PREFIX = "FL_Carried"
--[[ CarryVisualService names its mounts CARRY_NAME .. mount, so the two models
     on a character are exactly these. The hands one is the only one the owner
     could ever see. ]]
local HANDS_MOUNT = CARRIED_PREFIX .. "Hands"

--[[
	── WHY THIS IS PER-MOUNT AND NOT ONE BOOLEAN ────────────────────────────────
	Hiding the world weapon is right because the VIEWMODEL replaces it. That is
	the entire justification, and it only holds when there is a viewmodel.

	A medkit is held, not wielded: WeaponController.activeWeaponId returns "" for
	the Health slot, so setWeapon(nil) destroys the viewmodel and builds nothing.
	The kit still goes into the hands mount as FL_CarriedHands — and this
	function, matching on the prefix alone, blanked it every frame. The player
	took a kit off the map, selected it, and saw an empty screen; their teammates
	saw it in their hands the whole time, because LocalTransparencyModifier is
	client-local. That is the whole of the reported "I can't see it".

	So the hands mount is hidden only when something is standing in for it. The
	BACK mount stays hidden unconditionally: the owner cannot see their own back,
	and letting it through would only give it a chance to clip the camera.
]]
--[[
	The parts of the carried mounts, and whether each one belongs to the hands.

	Flattened and cached because the write below has to happen EVERY frame (see
	`update`), and the obvious version of it — GetChildren on the character, then
	GetDescendants on each mount — allocates two or three tables per frame plus a
	class check per descendant, forever, to write two or three properties. That is
	garbage generated sixty times a second for a loop whose entire job is to be
	invisible.

	Rebuilt only when the character's shape actually changes, which is a respawn
	or a weapon swap, not a frame.
]]
type CarriedPart = { part: BasePart?, light: Light?, hands: boolean }

local carried: { CarriedPart } = {}
local carriedFor: Model? = nil
local carriedDirty = true

local function rebuildCarried(character: Model)
	table.clear(carried)
	carriedFor = character
	carriedDirty = false

	for _, child in character:GetChildren() do
		if not child:IsA("Model") or string.sub(child.Name, 1, #CARRIED_PREFIX) ~= CARRIED_PREFIX then
			continue
		end
		local hands = child.Name == HANDS_MOUNT
		for _, descendant in child:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(carried, { part = descendant, light = nil, hands = hands })
			elseif descendant:IsA("Light") then
				table.insert(carried, { part = nil, light = descendant, hands = hands })
			end
		end
	end
end

--[[ Anything appearing under or leaving the character invalidates the list. One
     boolean, set from an event that fires on a respawn or a weapon swap; the
     rebuild itself happens on the next frame that needs it.

     Its own trove, cleaned at the top of every call, because this is re-armed on
     each respawn: adding to the module trove instead would leave a live pair of
     connections per life for the whole session, all setting the same boolean.
     That is the bug the jump-button Visible guard had. ]]
local carriedTrove = trove:add(Trove.new())

local function watchCarried(character: Model)
	carriedTrove:clean()
	carriedDirty = true
	carriedTrove:connect(character.DescendantAdded, function()
		carriedDirty = true
	end)
	carriedTrove:connect(character.DescendantRemoving, function()
		carriedDirty = true
	end)
end

local function hideOwnWorldWeapon(hidden: boolean)
	local character = player.Character
	if not character then
		return
	end
	if carriedDirty or carriedFor ~= character then
		rebuildCarried(character)
	end
	if #carried == 0 then
		return
	end

	--[[ `current.weaponId` is nil for every held-not-wielded slot, which is the
	     same condition that decided not to build a viewmodel. Reading it here
	     rather than inventing a second flag is what keeps the two from ever
	     disagreeing — the hands mount is only hidden when something is standing
	     in for it, and the BACK mount is hidden unconditionally because the owner
	     cannot see their own back. ]]
	local handsReplaced = current.weaponId ~= nil

	for _, entry in carried do
		local hideThis = hidden and (handsReplaced or not entry.hands)
		local part = entry.part
		if part then
			if part.Parent then
				part.LocalTransparencyModifier = if hideThis then 1 else 0
			end
		else
			local light = entry.light
			if light and light.Parent then
				light.Enabled = not hideThis
			end
		end
	end
end

local function update(deltaTime: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local now = os.clock()

	if flashUntil > 0 and now >= flashUntil then
		flashUntil = 0
		if flashPart then
			flashPart.Transparency = 1
		end
		if flashLight then
			flashLight.Enabled = false
		end
	end
	stepShells(now)
	stepMagazine(now)

	--[[
		The camera can leave first person without anything telling this module:
		FreeCursor is called by five different screens and reports to none of
		them. Polling the pair of properties is two reads, and both the writes
		below early-out when nothing changed.

		Order matters between these two. `applyHidden` reparents the viewmodel out
		of the camera, and hideOwnWorldWeapon is what puts the real gun back in
		the player's hands as it goes — running them the other way round leaves a
		frame with neither.
	]]
	local thirdPerson = cameraIsThirdPerson()

	--[[ Every frame, because Roblox's TransparencyController writes the same
	     property on the same parts and whoever writes last wins. Two or three
	     parts on one model; the cost is noise next to the pose below. ]]
	hideOwnWorldWeapon(not thirdPerson)
	applyHidden()

	if not model or current.hidden then
		return
	end

	--[[ Hit-stop is a shared clock. The camera owns it; the weapon reads it, so
	     the freeze lands on both at once. A camera that stops while the gun
	     keeps recovering reads as a dropped frame instead of as an impact. ]]
	if not cameraController then
		cameraController = Registry.find("CameraController")
	end
	local timeScale = if cameraController then cameraController:getTimeScale() else 1
	local dt = deltaTime * timeScale

	local definition = current.definition
	local pose = current.pose

	-- ADS. The same alpha the camera uses for its FOV pull, so the pose and the
	-- zoom arrive together instead of racing each other.
	if cameraController then
		current.aimAlpha = cameraController:getAimAlpha()
	else
		local aimTime = math.max(if definition then definition.aimTime else 0.2, 1e-3)
		local target = if current.aiming then 1 else 0
		current.aimAlpha += math.clamp((target - current.aimAlpha) * (dt / aimTime) * 4, -1, 1)
		current.aimAlpha = math.clamp(current.aimAlpha, 0, 1)
	end
	local aimAlpha = current.aimAlpha

	--[[ Sway is driven by how far the LOOK moved, not by the mouse, so it works
	     identically on a gamepad and on a touchscreen. The angles come from the
	     camera before its own recoil and shake are applied — otherwise the
	     weapon would sway in response to its own kick. ]]
	local yaw, pitch
	if cameraController then
		yaw, pitch = cameraController:getLookAngles()
	else
		local look = camera.CFrame.LookVector
		yaw = math.atan2(-look.X, -look.Z)
		pitch = math.asin(math.clamp(look.Y, -1, 1))
	end

	local deltaYaw = yaw - current.lastYaw
	-- Unwrap: crossing the -pi/pi seam must not read as a full-speed spin.
	if deltaYaw > math.pi then
		deltaYaw -= math.pi * 2
	elseif deltaYaw < -math.pi then
		deltaYaw += math.pi * 2
	end
	local deltaPitch = pitch - current.lastPitch
	current.lastYaw = yaw
	current.lastPitch = pitch

	local swayScale = 1 - aimAlpha * (1 - SWAY_AIM_SCALE)
	swayPosition.target = Vector3.new(
		math.clamp(-deltaYaw * SWAY_POSITION_GAIN, -SWAY_MAX, SWAY_MAX) * swayScale,
		math.clamp(-deltaPitch * SWAY_POSITION_GAIN, -SWAY_MAX, SWAY_MAX) * swayScale,
		0
	)
	swayRotation.target = Vector3.new(
		math.clamp(deltaPitch * SWAY_ROTATION_GAIN, -SWAY_MAX, SWAY_MAX) * swayScale,
		math.clamp(deltaYaw * SWAY_ROTATION_GAIN, -SWAY_MAX, SWAY_MAX) * swayScale,
		math.clamp(deltaYaw * SWAY_ROTATION_GAIN * 1.6, -SWAY_MAX, SWAY_MAX) * swayScale
	)

	local swayOffset = swayPosition:update(dt)
	local swayAngles = swayRotation:update(dt)

	-- Bob, from actual planar speed rather than from the input axis, so being
	-- dragged by a Smoker bobs the weapon exactly as walking does.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local speed = 0
	if root and root:IsA("BasePart") then
		local velocity = root.AssemblyLinearVelocity
		speed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	end

	local bobTarget = math.clamp(speed / GameConfig.Survivor.SprintSpeed, 0, 1)
	current.bobAmount += (bobTarget - current.bobAmount) * math.min(dt * BOB_SMOOTHING, 1)
	current.bobPhase += speed * BOB_FREQUENCY * dt

	local bobScale = current.bobAmount * (1 - aimAlpha * (1 - BOB_AIM_SCALE))
	local bobX = math.sin(current.bobPhase) * BOB_HORIZONTAL * bobScale
	local bobY = -math.abs(math.sin(current.bobPhase * 2)) * BOB_VERTICAL * bobScale
	local bobRoll = math.sin(current.bobPhase) * BOB_ROLL * bobScale

	local kickOffset = kickPosition:update(dt)
	local kickAngles = kickRotation:update(dt)

	--[[
		The inspect, as a trapezoid: rise, hold, return. See the INSPECT_ block.

		Cancelled rather than paused by anything that needs the weapon, and
		cancelling is only clearing the clock — the alpha then falls through the
		return half on the next frames, so the gun comes back down instead of
		snapping. Aiming is the one that matters: the aim pose is solved around the
		model's sight, and an inspect still blended into it would put the sight
		somewhere the crosshair is not.
	]]
	local inspectAlpha = 0
	local inspectTurn = 0
	if current.inspectClock >= 0 then
		if current.aiming or current.reloading or current.hidden then
			current.inspectClock = -1
		else
			current.inspectClock += dt
			local t = current.inspectClock / INSPECT_SECONDS
			if t >= 1 then
				current.inspectClock = -1
			else
				if t < INSPECT_IN then
					inspectAlpha = smoothstep(t / INSPECT_IN)
				elseif t > 1 - INSPECT_OUT then
					inspectAlpha = smoothstep((1 - t) / INSPECT_OUT)
				else
					inspectAlpha = 1
				end
				inspectTurn = math.sin(t * math.pi) * INSPECT_TURN
			end
		end
	end
	--[[ Aim wins outright. The cancel above already covers the steady state; this
	     covers the single frame between the aim beginning and the cancel, which is
	     the frame the sight would visibly jump on. ]]
	local inspectScale = inspectAlpha * (1 - aimAlpha)

	--[[ The reload lean, eased both ways so a cancelled reload settles rather
	     than snapping. See the RELOAD_ block. ]]
	local wantedRoll = if current.reloading then 1 else 0
	current.reloadRoll += (wantedRoll - current.reloadRoll) * math.min(dt / RELOAD_SECONDS, 1)
	local reloadScale = current.reloadRoll * (1 - aimAlpha)

	--[[ Push the pose out by however much the frame narrowed. Same direction from
	     the camera, so the weapon does not move on screen; further away, so it
	     keeps the size it has from the hip instead of being magnified into a wall
	     by an M1A EBR's 34-degree pull. Floored at 1 because a WIDER frame
	     dragging the weapon toward the near plane is not an improvement, and
	     ceilinged because a cinematic that pulls the camera to a few degrees is
	     not a reason to park the weapon thirty studs down the corridor. ]]
	local fovScale =
		math.clamp(POSE_FOV_TAN / math.tan(math.rad(camera.FieldOfView) * 0.5), 1, MAX_FOV_COMPENSATION)

	local tilt = pose.tilt * (1 - aimAlpha)
	local rotation = CFrame.Angles(
		swayAngles.X + kickAngles.X,
		swayAngles.Y + kickAngles.Y,
		tilt + bobRoll + swayAngles.Z + kickAngles.Z
	)
	--[[ Composed on the RIGHT, so the inspect turns the weapon about its own axes
	     rather than about the camera's. Multiplied the other way round a gun being
	     inspected while the player turns would swing out of frame. ]]
	if inspectScale > 0 then
		rotation = rotation
			* CFrame.Angles(
				INSPECT_PITCH * inspectScale,
				(INSPECT_YAW + inspectTurn) * inspectScale,
				INSPECT_ROLL * inspectScale
			)
	end
	--[[ Composed on the right like the inspect, so the roll is about the weapon's
	     own long axis rather than about the camera's. ]]
	if reloadScale > 0 then
		rotation = rotation * CFrame.Angles(RELOAD_PITCH * reloadScale, 0, RELOAD_ROLL * reloadScale)
	end

	local aimRest = pose.aim * fovScale
	--[[ Solve the aim pose around the model's own sight rather than around its
	     pivot: the point the player is looking through is the one that has to sit
	     on the centre line, and on a scoped model those are nowhere near each
	     other. Rotated by the same angles the model is about to be posed with, so
	     the alignment survives sway, bob and kick instead of only holding still. ]]
	local sightOffset = current.sightOffset
	if sightOffset then
		aimRest -= rotation:VectorToWorldSpace(sightOffset)
	end

	local rest = pose.hip:Lerp(aimRest, aimAlpha)
	local offset = rest
		+ swayOffset
		+ kickOffset
		+ Vector3.new(bobX, bobY, 0)
		+ INSPECT_OFFSET * inspectScale
		+ RELOAD_DROP * reloadScale

	model:PivotTo(camera.CFrame * CFrame.new(offset) * rotation)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function ViewmodelController:init()
	trove:connect(player:GetAttributeChangedSignal(PA.State), refreshHidden)

	--[[ The camera instance is replaced on respawn and on some death cameras. A
	     viewmodel parented to the old one renders nowhere, which looks exactly
	     like the model failing to load. ]]
	trove:connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		if model and not current.hidden and Workspace.CurrentCamera then
			model.Parent = Workspace.CurrentCamera
		end
	end)

	adoptMuzzleScale()
	trove:add(Device.changed:connect(adoptMuzzleScale))
end

function ViewmodelController:start()
	refreshHidden()

	--[[ The arms are clones of the avatar, so a respawn invalidates them: the
	     character they came from no longer exists. Rebuilding the weapon is the
	     simplest correct answer and costs one model swap on a respawn, which is
	     already the most expensive frame in the round.

	     Waiting on the parts matters as much as the event does. CharacterAdded
	     fires before limbs replicate, and building at that instant would clone
	     nothing and fall through to the plain fallback hands for the rest of the
	     life — so this waits for an arm to actually exist first. ]]
	if player.Character then
		watchCarried(player.Character)
	end

	trove:connect(player.CharacterAdded, function(character)
		watchCarried(character)
		task.spawn(function()
			local arm = character:WaitForChild("RightHand", 5) or character:WaitForChild("Right Arm", 5)
			if not arm then
				return
			end
			local weaponId, definition = current.weaponId, current.definition
			if weaponId and model then
				current.weaponId = nil
				ViewmodelController:setWeapon(weaponId, definition)
			end
		end)
	end)

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, update)
	trove:add(function()
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end)
end

function ViewmodelController:destroy()
	destroyModel()
	trove:destroy()
end

Registry.register("ViewmodelController", ViewmodelController)

return ViewmodelController
