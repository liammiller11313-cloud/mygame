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
	ReplicatedStorage.Assets.Viewmodels.<weaponId>, cloned. That folder is built
	either by the server's PlaceholderFactory or by studio-scripts/OrganizeAssets
	from the user's own models. It is matched by weapon id first, then by
	displayName, then case-insensitively, because an artist's folder is named
	after their model rather than after our enum.

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
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(Shared.Util.Registry)
local Spring = require(Shared.Util.Spring)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player
local STATE = Enums.SurvivorState

-- After the camera, so the weapon is posed against the CFrame that will
-- actually be rendered this frame — including recoil, shake and hit-stop.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local RENDER_NAME = "FL_Viewmodel"

--[[
	Where the weapon sits relative to the camera, in studs (right, up, forward).
	None of this exists in a Config: WeaponConfig owns what a gun DOES, and the
	pose is a property of the viewmodel art, not of the balance. Anything a
	designer would retune lives there; anything an artist would retune is here.

	`aim` puts the weapon on the screen's centre line. When a model carries a
	"Sight" or "AimPoint" attachment, that is used instead and this is only the
	fallback for models that do not.
]]
local DEFAULT_POSE = {
	hip = Vector3.new(0.85, -0.75, -1.55),
	aim = Vector3.new(0, -0.32, -1.05),
	tilt = math.rad(-3), -- a dead-square weapon reads as a screenshot, not a gun
}

local POSE: { [string]: { hip: Vector3, aim: Vector3, tilt: number } } = {
	[Enums.Weapon.Pistol] = {
		hip = Vector3.new(0.7, -0.62, -1.2),
		aim = Vector3.new(0, -0.26, -0.85),
		tilt = math.rad(-4),
	},
	[Enums.Weapon.Magnum] = {
		hip = Vector3.new(0.72, -0.64, -1.3),
		aim = Vector3.new(0, -0.27, -0.9),
		tilt = math.rad(-4),
	},
	[Enums.Weapon.SMG] = {
		hip = Vector3.new(0.8, -0.7, -1.4),
		aim = Vector3.new(0, -0.3, -1.0),
		tilt = math.rad(-3),
	},
	[Enums.Weapon.PumpShotgun] = {
		hip = Vector3.new(0.9, -0.8, -1.7),
		aim = Vector3.new(0, -0.34, -1.2),
		tilt = math.rad(-2),
	},
	[Enums.Weapon.AutoShotgun] = {
		hip = Vector3.new(0.9, -0.8, -1.7),
		aim = Vector3.new(0, -0.34, -1.2),
		tilt = math.rad(-2),
	},
	[Enums.Weapon.AssaultRifle] = {
		hip = Vector3.new(0.85, -0.75, -1.6),
		aim = Vector3.new(0, -0.3, -1.1),
		tilt = math.rad(-3),
	},
	-- The scope has to sit dead on the centre line or the pull-in reads as a
	-- misalignment rather than as magnification.
	[Enums.Weapon.HuntingRifle] = {
		hip = Vector3.new(0.88, -0.78, -1.75),
		aim = Vector3.new(0, -0.22, -0.7),
		tilt = math.rad(-2),
	},
	[Enums.Weapon.Machete] = {
		hip = Vector3.new(0.95, -0.9, -1.3),
		aim = Vector3.new(0.75, -0.7, -1.2),
		tilt = math.rad(-14),
	},
}

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

local FLASH_SECONDS = 0.035 -- roughly two frames; any longer reads as a flare
local FLASH_LIGHT_RANGE = 14
local FLASH_LIGHT_BRIGHTNESS = 5

local SHELL_POOL = 10
local SHELL_LIFETIME = 2.5
local SHELL_SIZE = Vector3.new(0.09, 0.09, 0.22)
local SHELL_SPEED = 7
local SHELL_SPIN = 22
local SHELL_COLOR = Color3.fromRGB(196, 158, 74)

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
local flashUntil = 0

local shells: { BasePart } = {}
local shellExpiry: { number } = {}
local shellCursor = 0
local shellFolder: Folder? = nil

local swayPosition = Spring.new(Vector3.zero, SWAY_SPEED, SWAY_DAMPING)
local swayRotation = Spring.new(Vector3.zero, SWAY_SPEED, SWAY_DAMPING)
local kickPosition = Spring.new(Vector3.zero, KICK_SPEED, KICK_DAMPING)
local kickRotation = Spring.new(Vector3.zero, KICK_ROTATION_SPEED, KICK_ROTATION_DAMPING)

local current = {
	weaponId = nil :: string?,
	definition = nil :: any,
	pose = DEFAULT_POSE,
	aiming = false,
	aimAlpha = 0,
	bobPhase = 0,
	bobAmount = 0,
	lastYaw = 0,
	lastPitch = 0,
	hidden = false,
	reloadRoll = 0, -- eased target for the reload lean, 0 or 1
	reloading = false,
}

local cameraController: any = nil

-- ── model construction ──────────────────────────────────────────────────────

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
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
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
local function buildFallback(weaponId: string, definition: any): Model
	local built = Instance.new("Model")
	built.Name = weaponId

	if definition and definition.fireMode == "Melee" then
		local grip = block(built, "Handle", Vector3.new(0.16, 0.16, 0.5), CFrame.new(), BLOCK_ACCENT)
		block(
			built,
			"Blade",
			Vector3.new(0.06, 0.42, 1.5),
			CFrame.new(0, 0.12, -1.0) * CFrame.Angles(math.rad(6), 0, 0),
			BLADE_COLOR
		)
		built.PrimaryPart = grip
		return built
	end

	-- Length tracks how far the gun reaches; magazine depth tracks how much it
	-- holds. Both come from the definition so every weapon reads differently.
	local isSecondary = definition and definition.slot == Enums.Slot.Secondary
	local scale = if isSecondary then 0.72 else 1.0
	local length = (if definition then math.clamp(definition.maxRange / 900, 0.55, 1.35) else 1) * scale

	local receiver = block(
		built,
		"Handle",
		Vector3.new(0.2 * scale, 0.34 * scale, 1.0 * length),
		CFrame.new(),
		BLOCK_COLOR
	)
	block(
		built,
		"Barrel",
		Vector3.new(0.12 * scale, 0.12 * scale, 1.1 * length),
		CFrame.new(0, 0.06 * scale, -0.95 * length),
		BLOCK_ACCENT
	)
	block(
		built,
		"Grip",
		Vector3.new(0.16 * scale, 0.46 * scale, 0.22 * scale),
		CFrame.new(0, -0.36 * scale, 0.28 * length) * CFrame.Angles(math.rad(12), 0, 0),
		BLOCK_ACCENT
	)
	if definition and definition.magSize > 0 then
		local depth = math.clamp(definition.magSize / 50, 0.35, 1) * 0.5
		block(
			built,
			"Magazine",
			Vector3.new(0.14 * scale, depth, 0.2 * scale),
			CFrame.new(0, -0.2 * scale - depth * 0.5, -0.1 * length),
			BLOCK_ACCENT
		)
	end

	built.PrimaryPart = receiver
	return built
end

--[[ Weapon id, then the artist's display name, then a loose case-insensitive
     match — the folder is named after somebody's model, not after our enum. ]]
local function findTemplate(weaponId: string, definition: any): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild("Viewmodels")
	if not folder then
		return nil
	end

	local exact = folder:FindFirstChild(weaponId)
	if exact and exact:IsA("Model") then
		return exact
	end
	if definition then
		local named = folder:FindFirstChild(definition.displayName)
		if named and named:IsA("Model") then
			return named
		end
	end

	local wanted = string.lower(string.gsub(weaponId, "%s", ""))
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and string.lower(string.gsub(child.Name, "%s", "")) == wanted then
			return child
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

local function findAttachment(root: Instance, names: { string }): Attachment?
	for _, name in names do
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("Attachment") and descendant.Name == name then
				return descendant
			end
		end
	end
	return nil
end

local function destroyModel()
	if model then
		model:Destroy()
		model = nil
	end
	muzzle = nil
	flashPart = nil
	flashLight = nil
	flashUntil = 0
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

	flashPart = part
	flashLight = light
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
	current.pose = (weaponId and POSE[weaponId]) or DEFAULT_POSE

	-- A weapon swap must not inherit the previous gun's recoil; the springs are
	-- reset rather than left to settle, which would look like a flinch.
	kickPosition:reset(Vector3.zero)
	kickRotation:reset(Vector3.zero)
	swayPosition:reset(Vector3.zero)
	swayRotation:reset(Vector3.zero)

	if not weaponId then
		return
	end

	local template = findTemplate(weaponId, definition)
	local built: Model
	if template then
		built = template:Clone()
	else
		built = buildFallback(weaponId, definition)
	end

	prepare(built)
	if not built.PrimaryPart then
		built.PrimaryPart = largestPart(built)
	end
	if not built.PrimaryPart then
		-- A model with no parts cannot be posed; fall back rather than render
		-- an invisible weapon the player will read as a bug.
		built:Destroy()
		built = buildFallback(weaponId, definition)
		prepare(built)
	end

	built.Name = "FL_Viewmodel"
	model = built

	muzzle = findAttachment(built, { "Muzzle", "MuzzlePoint", "FirePoint" })
	if not muzzle then
		--[[ Every model gets a Muzzle, invented at the front of the pivot part if
		     the art did not ship one, so the flash and the shell have somewhere
		     to be regardless of whose model this is. ]]
		local anchor = built.PrimaryPart :: BasePart
		local attachment = Instance.new("Attachment")
		attachment.Name = "Muzzle"
		attachment.CFrame = CFrame.new(0, 0, -anchor.Size.Z * 0.5 - 0.6)
		attachment.Parent = anchor
		muzzle = attachment
	end

	buildFlash(definition)

	local camera = Workspace.CurrentCamera
	if camera and not current.hidden then
		built.Parent = camera
	end
end

-- ── shells ──────────────────────────────────────────────────────────────────

local function ensureShells()
	if shellFolder then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "FL_Shells"
	folder.Parent = Workspace
	shellFolder = folder
	trove:add(folder)

	for index = 1, SHELL_POOL do
		local shell = Instance.new("Part")
		shell.Name = "FL_Shell"
		shell.Size = SHELL_SIZE
		shell.Color = SHELL_COLOR
		shell.Material = Enum.Material.Metal
		shell.CanCollide = true
		shell.CanQuery = false
		shell.CanTouch = false
		shell.CastShadow = false
		shell.Massless = true
		--[[ Debris never collides with a survivor or an infected, which is what
		     stops a magazine's worth of brass from nudging the player off a
		     ledge. The group is registered by the server bootstrap; if this
		     client got here first, non-colliding brass is the safe failure. ]]
		local ok = pcall(function()
			shell.CollisionGroup = "Debris"
		end)
		if not ok then
			shell.CanCollide = false
		end
		shell.Transparency = 1
		shell.Anchored = true
		shell.Parent = folder
		shells[index] = shell
		shellExpiry[index] = 0
	end
end

local function ejectShell()
	if not muzzle then
		return
	end
	ensureShells()

	shellCursor = (shellCursor % SHELL_POOL) + 1
	local shell = shells[shellCursor]
	if not shell then
		return
	end

	-- Out of the right of the weapon and slightly back, which is where a real
	-- ejection port throws and where the player's eye already expects to see it.
	local base = muzzle.WorldCFrame * CFrame.new(0.18, 0, 0.9)
	shell.Anchored = false
	shell.Transparency = 0
	shell.CFrame = base
	shell.AssemblyLinearVelocity = base.RightVector * SHELL_SPEED + base.UpVector * (SHELL_SPEED * 0.45)
	shell.AssemblyAngularVelocity = Vector3.new(
		(math.random() - 0.5) * SHELL_SPIN,
		(math.random() - 0.5) * SHELL_SPIN,
		(math.random() - 0.5) * SHELL_SPIN
	)
	shellExpiry[shellCursor] = os.clock() + SHELL_LIFETIME
end

local function stepShells(now: number)
	for index = 1, SHELL_POOL do
		local expiry = shellExpiry[index]
		if expiry > 0 and now >= expiry then
			local shell = shells[index]
			if shell then
				shell.Anchored = true
				shell.Transparency = 1
				shell.AssemblyLinearVelocity = Vector3.zero
			end
			shellExpiry[index] = 0
		end
	end
end

-- ── feedback the weapon controller drives ───────────────────────────────────

--[[ One shot: the flash, the punch and the brass, all on this frame. ]]
function ViewmodelController:onFired(definition: any, _seed: number)
	if not definition then
		return
	end

	local kickback = definition.kickback
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
	end

	if definition.shellEject then
		ejectShell()
	end
end

--[[ The empty click has to be felt before the number is read. A short downward
     nudge is enough: the weapon dips, nothing happens, and the player knows. ]]
function ViewmodelController:onDryFire()
	local speed = kickPosition.speed
	kickPosition:impulse(Vector3.new(0, -0.05 * speed * IMPULSE_GAIN, 0.02 * speed * IMPULSE_GAIN))
end

function ViewmodelController:onReloadStarted(_definition: any, _perShell: boolean)
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

function ViewmodelController:onMeleeSwing(definition: any)
	local speed = kickPosition.speed
	local reach = if definition then definition.kickback else 0.3
	kickPosition:impulse(
		Vector3.new(
			-reach * 1.6 * speed * IMPULSE_GAIN,
			-reach * 0.8 * speed * IMPULSE_GAIN,
			-reach * 1.2 * speed * IMPULSE_GAIN
		)
	)
	local rotationSpeed = kickRotation.speed
	kickRotation:impulse(
		Vector3.new(
			math.rad(-18) * rotationSpeed * IMPULSE_GAIN,
			math.rad(26) * rotationSpeed * IMPULSE_GAIN,
			math.rad(-30) * rotationSpeed * IMPULSE_GAIN
		)
	)
end

--[[ The shove is a shoulder-and-forearm push. It throws the weapon out of frame
     hard, which is exactly the cost the verb is supposed to have. ]]
function ViewmodelController:onShove()
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

local function refreshHidden()
	setHidden(HIDDEN_STATES[Attributes.get(player, PA.State, STATE.Spectating)] == true)
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

	local rest = pose.hip:Lerp(pose.aim, aimAlpha)
	local tilt = pose.tilt * (1 - aimAlpha)

	local offset = rest + swayOffset + kickOffset + Vector3.new(bobX, bobY, 0)
	local final = camera.CFrame
		* CFrame.new(offset)
		* CFrame.Angles(
			swayAngles.X + kickAngles.X,
			swayAngles.Y + kickAngles.Y,
			tilt + bobRoll + swayAngles.Z + kickAngles.Z
		)

	model:PivotTo(final)
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
end

function ViewmodelController:start()
	refreshHidden()

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
