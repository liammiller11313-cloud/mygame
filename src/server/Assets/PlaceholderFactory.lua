--!nonstrict
--[[
	PlaceholderFactory — every asset in the game, built from parts at runtime.

	There are no .rbxm files and no asset ids anywhere in this repo, because an
	asset id that does not belong to the person running the place either fails to
	load or loads somebody else's model. So the whole game is greyboxed in code:
	rigs, guns, pickups and a full playable level. It is ugly on purpose and it is
	COMPLETE on purpose — every system downstream can be exercised end to end
	today, and the art can arrive later without a single line of code changing.

	── THE DROP-IN CONTRACT ─────────────────────────────────────────────────────
	Every build* method looks for a user-supplied Model first and only greyboxes
	when it does not find one:

	    ReplicatedStorage.Assets.Weapons.<WeaponId>       world model
	    ReplicatedStorage.Assets.Viewmodels.<WeaponId>    first-person model
	    ReplicatedStorage.Assets.Infected.<Kind>          rig  (ServerStorage too)
	    ReplicatedStorage.Assets.Pickups.<Slot>_<ItemId>  pickup

	Replacing a placeholder is therefore: drop a Model with the right NAME in the
	right folder. Nothing else. That is the same lookup WeaponConfig's header
	already promises ("drop a model in ReplicatedStorage.Assets.Weapons under the
	same name. No new code").

	A replacement rig must keep the R15 part names and the R15 Motor6D names,
	because GoreService dismembers by destroying the Motor6D whose Part1 is the
	named limb and ragdolls by replacing the rest. Get those names right and gore
	behaves identically on a hand-modelled zombie and on the boxes below.

	── SILHOUETTE ───────────────────────────────────────────────────────────────
	In a horde the silhouette is all a player gets: at twelve metres, in fog, at
	ClockTime 4.25, you cannot read a texture and you certainly cannot read a
	health bar. Every archetype is therefore shaped, not just tinted — the Tank is
	enormous and hunched, the Boomer is a sphere on legs, the Hunter is folded
	into a crouch, the Charger drags one absurd arm, the Smoker is a lamppost, the
	Witch is small and pale. That reads at a glance and it survives the art pass,
	because the proportions are what the real models will have to honour too.

	── PERFORMANCE ──────────────────────────────────────────────────────────────
	Every template is built ONCE and cloned. A SustainPeak horde is 46 rigs; laying
	out 46 rigs part by part would cost a visible hitch exactly when the game is
	trying to be at its most impressive. Limbs are massless and non-collidable —
	only the HumanoidRootPart has a physical footprint — because a horde whose
	forty-six pairs of hands each collide with the world is a horde that arrives
	as a slideshow.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local PlaceholderFactory = {}

local ASSETS_FOLDER = "Assets"
local MAP_NAME = "FadingLight_TestMap"

-- Categories the client has to be able to see live in ReplicatedStorage; every
-- other category is server-only and stays out of the replication budget.
local REPLICATED_CATEGORIES = table.freeze({ Weapons = true, Viewmodels = true })

local function V(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Template storage
-- ════════════════════════════════════════════════════════════════════════════

local function folderIn(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function storageFor(category: string): Folder
	local root = if REPLICATED_CATEGORIES[category] then ReplicatedStorage else ServerStorage
	return folderIn(folderIn(root, ASSETS_FOLDER), category)
end

--[[
	The user's model for this asset, if they have supplied one.

	ReplicatedStorage is checked first even for server-only categories: a person
	dropping models into a place will put them wherever is convenient, and being
	fussy about which storage they picked is exactly the kind of friction this
	module exists to remove.
]]
local function findSupplied(category: string, name: string): Model?
	for _, root in { ReplicatedStorage, ServerStorage } do
		local assets = root:FindFirstChild(ASSETS_FOLDER)
		local folder = assets and assets:FindFirstChild(category)
		local model = folder and folder:FindFirstChild(name)
		if model and model:IsA("Model") then
			return model
		end
	end
	return nil
end

--[[ Fetches a template, building and caching it on the first request. The cache
     lives in the same folder the user would drop a replacement into, so a
     generated placeholder and a hand-made model are interchangeable. ]]
local function template(category: string, name: string, build: () -> Model?): Model?
	local supplied = findSupplied(category, name)
	if supplied then
		return supplied
	end
	local built = build()
	if not built then
		return nil
	end
	built.Name = name
	built.Parent = storageFor(category)
	return built
end

-- ════════════════════════════════════════════════════════════════════════════
--  Part helpers
-- ════════════════════════════════════════════════════════════════════════════

--[[ A prop part: rendered, hittable, but never physical. Used for every piece of
     a rig, a gun and a pickup. Map geometry uses `mapBox` below instead. ]]
local function prop(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Locked = true
	return part
end

--[[ Renders a part as an ellipsoid without changing what a bullet hits. A Ball
     shaped Part would round the COLLISION geometry too, quietly shrinking the
     head hitbox — and a head hitbox smaller than the head it draws is the worst
     possible bug in a game whose entire skill expression is the headshot. ]]
local function roundOff(part: BasePart)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
end

local function weldTo(anchor: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = part
	weld.Parent = part
end

-- ════════════════════════════════════════════════════════════════════════════
--  Infected rigs
--
--  The joint names below are load-bearing. GoreService looks a limb up by the
--  name of the Motor6D's Part1 and reads its per-joint ragdoll limits from the
--  Motor6D's own name; GoreConfig.Dismemberment.Severable lists the part names
--  it is allowed to take off. All three tables have to agree, so the rig is
--  verified against GoreConfig once, at build time, below.
-- ════════════════════════════════════════════════════════════════════════════

local RIG_JOINTS = table.freeze({
	{ joint = "Root", parent = "HumanoidRootPart", child = "LowerTorso" },
	{ joint = "Waist", parent = "LowerTorso", child = "UpperTorso" },
	{ joint = "Neck", parent = "UpperTorso", child = "Head" },
	{ joint = "LeftShoulder", parent = "UpperTorso", child = "LeftUpperArm" },
	{ joint = "LeftElbow", parent = "LeftUpperArm", child = "LeftLowerArm" },
	{ joint = "LeftWrist", parent = "LeftLowerArm", child = "LeftHand" },
	{ joint = "RightShoulder", parent = "UpperTorso", child = "RightUpperArm" },
	{ joint = "RightElbow", parent = "RightUpperArm", child = "RightLowerArm" },
	{ joint = "RightWrist", parent = "RightLowerArm", child = "RightHand" },
	{ joint = "LeftHip", parent = "LowerTorso", child = "LeftUpperLeg" },
	{ joint = "LeftKnee", parent = "LeftUpperLeg", child = "LeftLowerLeg" },
	{ joint = "LeftAnkle", parent = "LeftLowerLeg", child = "LeftFoot" },
	{ joint = "RightHip", parent = "LowerTorso", child = "RightUpperLeg" },
	{ joint = "RightKnee", parent = "RightUpperLeg", child = "RightLowerLeg" },
	{ joint = "RightAnkle", parent = "RightLowerLeg", child = "RightFoot" },
})

local LEFT_ARM = table.freeze({ "LeftUpperArm", "LeftLowerArm", "LeftHand", "@LeftElbow", "@LeftWrist" })
local RIGHT_ARM = table.freeze({ "RightUpperArm", "RightLowerArm", "RightHand", "@RightElbow", "@RightWrist" })
local UPPER_BODY = table.freeze({
	"UpperTorso",
	"Head",
	"@Neck",
	"@LeftShoulder",
	"@RightShoulder",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"@LeftElbow",
	"@LeftWrist",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"@RightElbow",
	"@RightWrist",
})

--[[
	Proportions, in studs, BEFORE InfectedConfig's per-kind `scale` is applied.

	`hunch`, `armPitch`, `roll` and `headTilt` are degrees, and they are doing as
	much work as the sizes: a Common and a Hunter share most of their numbers and
	are still unmistakable from across a street, because one stands up and the
	other is folded almost double.
]]
local SHAPES = {
	[Enums.Infected.Common] = {
		head = V(0.90, 0.85, 0.90),
		neck = 0.10,
		upperTorso = V(1.70, 1.35, 0.95),
		lowerTorso = V(1.50, 0.55, 0.90),
		upperArm = V(0.62, 1.15, 0.62),
		lowerArm = V(0.55, 1.05, 0.55),
		hand = V(0.55, 0.42, 0.62),
		upperLeg = V(0.72, 1.25, 0.72),
		lowerLeg = V(0.66, 1.15, 0.66),
		foot = V(0.70, 0.35, 1.05),
		root = V(1.50, 1.40, 0.90),
		legSpread = 0.44,
		armDrop = 0.16,
		hunch = 14,
		armPitch = 18,
		roll = 0,
		headTilt = 10,
	},

	-- Folded into a crouch with arms that nearly touch the floor. Reads as
	-- "about to leap" from any angle, which is the only warning a lone survivor
	-- is going to get.
	[Enums.Infected.Hunter] = {
		head = V(0.78, 0.72, 0.78),
		neck = 0.05,
		upperTorso = V(1.45, 1.15, 0.85),
		lowerTorso = V(1.30, 0.50, 0.80),
		upperArm = V(0.55, 1.25, 0.55),
		lowerArm = V(0.50, 1.20, 0.50),
		hand = V(0.55, 0.50, 0.75),
		upperLeg = V(0.78, 0.95, 0.78),
		lowerLeg = V(0.70, 0.85, 0.70),
		foot = V(0.70, 0.35, 1.10),
		root = V(1.30, 1.20, 0.80),
		legSpread = 0.50,
		armDrop = 0.12,
		hunch = 58,
		armPitch = 52,
		roll = 0,
		headTilt = -30, -- looking up at you from under the hunch
	},

	-- A lamppost with a cough. Height is the whole read: if you can see it over
	-- the crowd, it can see you, and its tongue reaches 220 studs.
	[Enums.Infected.Smoker] = {
		head = V(0.72, 0.72, 0.72),
		neck = 0.55,
		upperTorso = V(1.25, 1.45, 0.70),
		lowerTorso = V(1.10, 0.50, 0.66),
		upperArm = V(0.42, 1.50, 0.42),
		lowerArm = V(0.38, 1.40, 0.38),
		hand = V(0.42, 0.45, 0.50),
		upperLeg = V(0.50, 1.70, 0.50),
		lowerLeg = V(0.46, 1.60, 0.46),
		foot = V(0.52, 0.35, 0.90),
		root = V(1.10, 1.40, 0.66),
		legSpread = 0.34,
		armDrop = 0.14,
		hunch = 10,
		armPitch = 6,
		roll = 0,
		headTilt = 6,
	},

	-- A sphere on stumps. Nothing else in the roster is round, so the shape
	-- alone tells a player not to shoot it from arm's length.
	[Enums.Infected.Boomer] = {
		head = V(0.72, 0.62, 0.72),
		neck = 0.0,
		upperTorso = V(3.40, 2.10, 3.00),
		lowerTorso = V(2.20, 0.60, 2.00),
		upperArm = V(0.60, 0.80, 0.60),
		lowerArm = V(0.55, 0.70, 0.55),
		hand = V(0.55, 0.40, 0.60),
		upperLeg = V(0.90, 0.50, 0.90),
		lowerLeg = V(0.85, 0.50, 0.85),
		foot = V(0.85, 0.35, 1.10),
		root = V(2.00, 1.30, 1.60),
		legSpread = 0.78,
		armDrop = 0.55,
		hunch = 6,
		armPitch = 28,
		roll = 0,
		headTilt = 4,
		roundTorso = true,
	},

	-- One arm the size of the rest of it. The asymmetry is the tell, and it
	-- survives being seen for a quarter of a second down a corridor.
	[Enums.Infected.Charger] = {
		head = V(0.72, 0.62, 0.72),
		neck = 0.0,
		upperTorso = V(2.30, 1.60, 1.20),
		lowerTorso = V(1.80, 0.60, 1.00),
		upperArm = V(0.70, 1.40, 0.70),
		lowerArm = V(0.62, 1.30, 0.62),
		hand = V(0.60, 0.50, 0.70),
		upperLeg = V(0.95, 1.10, 0.95),
		lowerLeg = V(0.90, 1.00, 0.90),
		foot = V(0.90, 0.40, 1.20),
		root = V(1.80, 1.40, 1.00),
		legSpread = 0.58,
		armDrop = 0.20,
		hunch = 26,
		armPitch = 16,
		roll = -9,
		headTilt = 8,
		leftArmScale = 0.50,
		rightArmScale = 2.20,
		rightArmLength = 1.35,
	},

	-- Small, pale and still. She is the only thing in the game a player is
	-- supposed to walk around, so she must not read as a threat until she does.
	[Enums.Infected.Witch] = {
		head = V(0.76, 0.74, 0.76),
		neck = 0.08,
		upperTorso = V(1.25, 1.15, 0.72),
		lowerTorso = V(1.10, 0.45, 0.66),
		upperArm = V(0.40, 1.20, 0.40),
		lowerArm = V(0.36, 1.15, 0.36),
		hand = V(0.50, 0.90, 0.70), -- claws
		upperLeg = V(0.55, 1.10, 0.55),
		lowerLeg = V(0.50, 1.00, 0.50),
		foot = V(0.55, 0.30, 0.85),
		root = V(1.10, 1.20, 0.66),
		legSpread = 0.34,
		armDrop = 0.12,
		hunch = 30,
		armPitch = 46,
		roll = 0,
		headTilt = 22,
		eyes = true,
	},

	-- The set piece. Shoulders wider than a doorway and a head you can barely
	-- find, so the answer is never "aim for the head", it is "everybody move".
	[Enums.Infected.Tank] = {
		head = V(0.70, 0.50, 0.70),
		neck = 0.0,
		upperTorso = V(2.60, 1.35, 1.50),
		lowerTorso = V(1.90, 0.55, 1.20),
		upperArm = V(1.10, 1.30, 1.10),
		lowerArm = V(1.00, 1.25, 1.00),
		hand = V(1.10, 0.75, 1.25),
		upperLeg = V(1.00, 0.85, 1.00),
		lowerLeg = V(0.95, 0.85, 0.95),
		foot = V(1.00, 0.40, 1.40),
		root = V(1.90, 1.40, 1.20),
		legSpread = 0.80,
		armDrop = 0.10,
		hunch = 30,
		armPitch = 14,
		roll = 0,
		headTilt = 12,
		shoulders = true,
	},
}

--[[ Verifies once, at build time, that every part GoreConfig is allowed to sever
     off an R15 body actually exists on this rig with a Motor6D behind it. A rig
     that quietly loses a joint name would show up much later as "dismemberment
     stopped working on Chargers", which is a miserable thing to debug. ]]
local verifiedSeverable = false
local function verifySeverable(model: Model)
	if verifiedSeverable then
		return
	end
	verifiedSeverable = true

	local motors: { [string]: boolean } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part1 then
			motors[descendant.Part1.Name] = true
		end
	end

	local missing = {}
	for _, name in GoreConfig.Dismemberment.Severable do
		-- The R6 aliases in that list are there for hand-made models; an R15 rig
		-- is not expected to carry them.
		if not string.find(name, " ") and not motors[name] then
			table.insert(missing, name)
		end
	end
	if #missing > 0 then
		warn(
			string.format(
				"[PlaceholderFactory] rig is missing severable joints: %s — GoreService will "
					.. "silently refuse to dismember those parts",
				table.concat(missing, ", ")
			)
		)
	end
end

--[[
	Lays out one archetype and joints it.

	The layout runs bottom-up in a neutral standing pose, then bends: arms pitch
	about their own shoulder, the head tilts about the neck, and the whole upper
	body hunches about the waist. Doing it in that order means a shape table only
	has to describe proportions and three angles, and the hunch lands correctly on
	arms that have already been posed.

	Joint sockets travel through the same transforms as the parts they connect, so
	`motor.C0` really is the socket. GoreService reads that CFrame to decide where
	a severed limb bleeds from, and a stump that bleeds from the middle of the arm
	that just left is a tell nobody can unsee.
]]
local function buildRig(kind: string): Model?
	local definition = InfectedConfig.get(kind)
	local shape = SHAPES[kind]
	if not definition or not shape then
		return nil
	end

	local scale = definition.scale
	local pose: { [string]: CFrame } = {}
	local sizes: { [string]: Vector3 } = {}

	local function place(name: string, size: Vector3, position: Vector3)
		sizes[name] = size * scale
		pose[name] = CFrame.new(position * scale)
	end
	local function socket(name: string, position: Vector3)
		pose["@" .. name] = CFrame.new(position * scale)
	end

	-- ── vertical stack, feet on y = 0 ───────────────────────────────────────
	local footTop = shape.foot.Y
	local kneeY = footTop + shape.lowerLeg.Y
	local hipY = kneeY + shape.upperLeg.Y
	local waistY = hipY + shape.lowerTorso.Y
	local shoulderTopY = waistY + shape.upperTorso.Y
	local shoulderY = shoulderTopY - shape.armDrop
	local headY = shoulderTopY + shape.neck + shape.head.Y * 0.5

	local spread = shape.legSpread
	for _, side in { -1, 1 } do
		local prefix = if side < 0 then "Left" else "Right"
		local x = side * spread
		place(prefix .. "Foot", shape.foot, V(x, shape.foot.Y * 0.5, -0.1))
		place(prefix .. "LowerLeg", shape.lowerLeg, V(x, footTop + shape.lowerLeg.Y * 0.5, 0))
		place(prefix .. "UpperLeg", shape.upperLeg, V(x, kneeY + shape.upperLeg.Y * 0.5, 0))
		socket(prefix .. "Ankle", V(x, footTop, 0))
		socket(prefix .. "Knee", V(x, kneeY, 0))
		socket(prefix .. "Hip", V(x, hipY, 0))
	end

	place("LowerTorso", shape.lowerTorso, V(0, hipY + shape.lowerTorso.Y * 0.5, 0))
	place("UpperTorso", shape.upperTorso, V(0, waistY + shape.upperTorso.Y * 0.5, 0))
	place("Head", shape.head, V(0, headY, 0))
	place("HumanoidRootPart", shape.root, V(0, hipY + shape.root.Y * 0.5, 0))
	socket("Root", V(0, hipY + shape.lowerTorso.Y * 0.5, 0))
	socket("Waist", V(0, waistY, 0))
	socket("Neck", V(0, shoulderTopY, 0))

	-- ── arms, per side, with the Charger's asymmetry baked in ───────────────
	for _, side in { -1, 1 } do
		local prefix = if side < 0 then "Left" else "Right"
		local thickness = if side < 0
			then (shape.leftArmScale or 1)
			else (shape.rightArmScale or 1)
		local length = if side < 0
			then (shape.leftArmLength or shape.leftArmScale or 1)
			else (shape.rightArmLength or shape.rightArmScale or 1)

		local function limb(base: Vector3): Vector3
			return V(base.X * thickness, base.Y * length, base.Z * thickness)
		end

		local upper, lower, hand = limb(shape.upperArm), limb(shape.lowerArm), limb(shape.hand)
		local x = side * (shape.upperTorso.X * 0.5 + upper.X * 0.5)
		local elbowY = shoulderY - upper.Y
		local wristY = elbowY - lower.Y

		place(prefix .. "UpperArm", upper, V(x, shoulderY - upper.Y * 0.5, 0))
		place(prefix .. "LowerArm", lower, V(x, elbowY - lower.Y * 0.5, 0))
		place(prefix .. "Hand", hand, V(x, wristY - hand.Y * 0.5, 0))
		socket(prefix .. "Shoulder", V(x, shoulderY, 0))
		socket(prefix .. "Elbow", V(x, elbowY, 0))
		socket(prefix .. "Wrist", V(x, wristY, 0))
	end

	-- ── posing ──────────────────────────────────────────────────────────────
	local function bend(names, pivot: Vector3, rotation: CFrame)
		local at = CFrame.new(pivot * scale)
		local delta = at * rotation * at:Inverse()
		for _, name in names do
			local current = pose[name]
			if current then
				pose[name] = delta * current
			end
		end
	end

	-- Negative pitch about X leans toward -Z, which is the direction a rig faces.
	local pitch = function(degrees: number)
		return CFrame.Angles(-math.rad(degrees), 0, 0)
	end

	bend(LEFT_ARM, V(-spread, shoulderY, 0), pitch(shape.armPitch))
	bend(RIGHT_ARM, V(spread, shoulderY, 0), pitch(shape.armPitch))
	bend({ "Head" }, V(0, shoulderTopY, 0), pitch(shape.headTilt))
	bend(UPPER_BODY, V(0, waistY, 0), pitch(shape.hunch))
	if shape.roll ~= 0 then
		bend(UPPER_BODY, V(0, hipY, 0), CFrame.Angles(0, 0, math.rad(shape.roll)))
	end

	-- ── instances ───────────────────────────────────────────────────────────
	local body = definition.bodyColor
	local accent = definition.accentColor
	-- Extremities in the accent colour: on a Common that is dried blood on the
	-- hands and feet, on the Witch it is the claws, and either way it breaks up
	-- an otherwise uniform silhouette so limbs read as limbs.
	local ACCENTED = table.freeze({
		LeftHand = true,
		RightHand = true,
		LeftFoot = true,
		RightFoot = true,
		LowerTorso = true,
	})

	local model = Instance.new("Model")
	model.Name = definition.displayName

	local parts: { [string]: BasePart } = {}
	for name, size in sizes do
		local color = if name == "Head"
			then body:Lerp(accent, 0.25)
			elseif ACCENTED[name] then accent
			else body
		local part = prop(name, size, pose[name], color)
		-- Only the root has a physical footprint. Forty-six rigs whose every limb
		-- collides is forty-six times more contact solving than the horde needs,
		-- and limbs snagging on scenery is what makes a shambler look drunk.
		part.CanCollide = name == "HumanoidRootPart"
		part.Massless = name ~= "HumanoidRootPart"
		part.CastShadow = name == "UpperTorso" or name == "Head"
		part.Parent = model
		parts[name] = part
	end

	local root = parts.HumanoidRootPart
	root.Transparency = 1
	root.CastShadow = false
	model.PrimaryPart = root

	roundOff(parts.Head)
	if shape.roundTorso then
		roundOff(parts.UpperTorso)
	end

	-- Decoration that extends the silhouette stays queryable — a Tank's shoulders
	-- are part of the target. Decoration that sits ON a hit surface does not, or
	-- it would steal headshots by absorbing the ray meant for the head behind it.
	if shape.shoulders then
		for _, side in { -1, 1 } do
			local radius = shape.upperTorso.Y * 0.85
			local hump = prop(
				"ShoulderPad",
				V(radius, radius, radius) * scale,
				parts.UpperTorso.CFrame
					* CFrame.new(side * shape.upperTorso.X * 0.42 * scale, shape.upperTorso.Y * 0.3 * scale, 0),
				body:Lerp(accent, 0.5)
			)
			hump.Massless = true
			roundOff(hump)
			hump.Parent = model
			weldTo(parts.UpperTorso, hump)
		end
	end
	if shape.eyes then
		local eyes = prop(
			"Eyes",
			V(shape.head.X * 0.62, shape.head.Y * 0.16, 0.08) * scale,
			parts.Head.CFrame * CFrame.new(0, 0, -shape.head.Z * 0.5 * scale),
			accent,
			Enum.Material.Neon
		)
		eyes.CanQuery = false
		eyes.Massless = true
		eyes.Parent = model
		weldTo(parts.Head, eyes)
	end

	for _, spec in RIG_JOINTS do
		local part0, part1 = parts[spec.parent], parts[spec.child]
		local at = pose["@" .. spec.joint]
		if part0 and part1 and at then
			local motor = Instance.new("Motor6D")
			motor.Name = spec.joint
			motor.Part0 = part0
			motor.Part1 = part1
			motor.C0 = part0.CFrame:Inverse() * at
			motor.C1 = part1.CFrame:Inverse() * at
			-- Parented to the CHILD, matching Roblox's own rigs and matching what
			-- GoreService assumes when it severs a limb and expects the joint to
			-- leave with it.
			motor.Parent = part1
		end
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.MaxHealth = definition.health
	humanoid.Health = definition.health
	humanoid.WalkSpeed = definition.walkSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = definition.jumpPower
	-- The root's bottom face sits exactly at the hip, so the distance from it to
	-- the floor IS hipY. Measured from the built pose rather than assumed: every
	-- archetype has a different leg length, and a Tank floating a stud above the
	-- floor is exactly as wrong as a Boomer buried in it.
	humanoid.HipHeight = hipY * scale
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayDistance = 0
	humanoid.NameDisplayDistance = 0
	humanoid.Parent = model

	-- Present so a real animation set can be played on these rigs later without
	-- anything else changing; GoreService already stops tracks on ragdoll.
	local animator = Instance.new("Animator")
	animator.Parent = humanoid

	--[[
		NOTE (contract): the Humanoid deliberately carries NO BodyHeightScale /
		BodyWidthScale / BodyDepthScale / HeadScale NumberValues, which makes
		RigUtil.scaleRig a no-op on these rigs. InfectedConfig's `scale` is
		already baked into every size above. That is on purpose: engine-side R15
		scaling only applies to rigs authored with the values it expects, so
		relying on it would leave a hand-built Tank exactly Common-sized, and
		applying it on top of a pre-scaled rig would give a Tank 5.5x. Scale is
		applied here, once. A user's real R15 rig that DOES carry those values
		should be authored unscaled and will scale through RigUtil as intended.
	]]

	verifySeverable(model)
	return model
end

--[[ A finished, unparented rig for `kind`, or nil for an unknown kind. Clones a
     cached template: a SustainPeak horde asks for this 46 times. ]]
function PlaceholderFactory:buildInfectedRig(kind: string): Model?
	if typeof(kind) ~= "string" then
		return nil
	end
	local source = template("Infected", kind, function()
		return buildRig(kind)
	end)
	if not source then
		return nil
	end
	return source:Clone()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Weapons
--
--  Every gun is a short parts list in one local frame: the Handle sits at the
--  origin, the weapon points along -Z (a CFrame's LookVector), and +Y is up. The
--  shapes are deliberately crude but never generic — a player has to be able to
--  tell the pump shotgun from the auto shotgun in a dark room, at a glance, while
--  something is eating them, so each one owns a distinct outline: tube magazine
--  and pump, box magazine and stock, carry handle, scope, revolver cylinder.
-- ════════════════════════════════════════════════════════════════════════════

-- Weapon greys. UITheme is the interface palette and these are the only place
-- its neutrals genuinely apply to geometry: a gun held against the HUD should
-- share the HUD's value range or it fights it.
local GUN = table.freeze({
	metal = UITheme.Color.Border,
	dark = UITheme.Color.Panel,
	polymer = UITheme.Color.PanelRaised,
	wood = UITheme.Color.AccentDim,
	optic = UITheme.Color.BorderBright,
})

-- { name, size, offset, colour key, optional rotation in degrees, optional shape }
local GUNS = {
	[Enums.Weapon.Pistol] = {
		muzzle = V(0, 0.14, -1.70),
		parts = {
			{ "Handle", V(0.42, 1.00, 0.50), V(0, -0.50, 0.06), "polymer", V(-8, 0, 0) },
			{ "Receiver", V(0.42, 0.52, 1.55), V(0, 0.14, -0.50), "dark" },
			{ "Barrel", V(0.20, 0.20, 0.45), V(0, 0.14, -1.45), "metal" },
			{ "TriggerGuard", V(0.16, 0.30, 0.44), V(0, -0.22, -0.26), "dark" },
		},
	},

	[Enums.Weapon.Magnum] = {
		muzzle = V(0, 0.20, -2.20),
		parts = {
			{ "Handle", V(0.46, 1.05, 0.56), V(0, -0.52, 0.08), "wood", V(-10, 0, 0) },
			{ "Receiver", V(0.44, 0.60, 1.20), V(0, 0.20, -0.35), "dark" },
			{ "Cylinder", V(0.72, 0.64, 0.64), V(0, 0.16, -0.45), "metal", V(0, 90, 0), "Cylinder" },
			{ "Barrel", V(0.26, 0.28, 1.50), V(0, 0.22, -1.40), "metal" },
			{ "TriggerGuard", V(0.16, 0.32, 0.46), V(0, -0.22, -0.20), "dark" },
		},
	},

	[Enums.Weapon.SMG] = {
		muzzle = V(0, 0.20, -2.45),
		parts = {
			{ "Handle", V(0.42, 0.95, 0.50), V(0, -0.48, 0.10), "polymer", V(-8, 0, 0) },
			{ "Receiver", V(0.50, 0.60, 2.00), V(0, 0.20, -0.60), "dark" },
			{ "Barrel", V(0.20, 0.20, 0.95), V(0, 0.20, -1.95), "metal" },
			{ "Magazine", V(0.30, 1.30, 0.55), V(0, -0.60, -0.55), "dark", V(6, 0, 0) },
			{ "Stock", V(0.34, 0.44, 0.90), V(0, 0.18, 0.78), "metal" },
			{ "Foregrip", V(0.26, 0.50, 0.30), V(0, -0.22, -1.55), "polymer" },
		},
	},

	[Enums.Weapon.PumpShotgun] = {
		muzzle = V(0, 0.28, -4.20),
		parts = {
			{ "Handle", V(0.42, 0.95, 0.52), V(0, -0.48, 0.18), "wood", V(-10, 0, 0) },
			{ "Receiver", V(0.50, 0.62, 1.40), V(0, 0.22, -0.55), "metal" },
			{ "Barrel", V(0.26, 0.28, 3.00), V(0, 0.30, -2.65), "metal" },
			{ "TubeMagazine", V(0.22, 0.22, 2.40), V(0, -0.02, -2.30), "metal" },
			{ "Pump", V(0.40, 0.42, 0.80), V(0, -0.02, -2.00), "wood" },
			{ "Stock", V(0.42, 0.76, 1.50), V(0, -0.06, 1.02), "wood", V(4, 0, 0) },
		},
	},

	[Enums.Weapon.AutoShotgun] = {
		muzzle = V(0, 0.26, -3.80),
		parts = {
			{ "Handle", V(0.44, 0.95, 0.52), V(0, -0.48, 0.16), "polymer", V(-8, 0, 0) },
			{ "Receiver", V(0.52, 0.68, 1.80), V(0, 0.20, -0.70), "dark" },
			{ "Barrel", V(0.26, 0.28, 2.20), V(0, 0.26, -2.65), "metal" },
			{ "HeatShield", V(0.34, 0.16, 1.70), V(0, 0.46, -2.45), "metal" },
			{ "Magazine", V(0.36, 0.90, 0.60), V(0, -0.52, -0.90), "dark" },
			{ "Stock", V(0.44, 0.70, 1.30), V(0, 0.06, 0.96), "polymer" },
		},
	},

	[Enums.Weapon.AssaultRifle] = {
		muzzle = V(0, 0.20, -3.60),
		parts = {
			{ "Handle", V(0.42, 0.92, 0.50), V(0, -0.46, 0.22), "polymer", V(-8, 0, 0) },
			{ "Receiver", V(0.48, 0.66, 2.20), V(0, 0.22, -0.70), "dark" },
			{ "CarryHandle", V(0.22, 0.30, 1.00), V(0, 0.66, -0.70), "dark" },
			{ "Barrel", V(0.20, 0.20, 1.80), V(0, 0.20, -2.65), "metal" },
			{ "Magazine", V(0.32, 1.00, 0.62), V(0, -0.66, -0.50), "dark", V(8, 0, 0) },
			{ "Foregrip", V(0.30, 0.34, 1.20), V(0, 0.02, -2.05), "polymer" },
			{ "Stock", V(0.42, 0.62, 1.40), V(0, 0.10, 1.05), "polymer" },
		},
	},

	[Enums.Weapon.HuntingRifle] = {
		muzzle = V(0, 0.22, -4.60),
		parts = {
			{ "Handle", V(0.42, 0.90, 0.50), V(0, -0.44, 0.32), "wood", V(-12, 0, 0) },
			{ "Receiver", V(0.46, 0.60, 1.70), V(0, 0.22, -0.50), "metal" },
			{ "Barrel", V(0.20, 0.20, 3.20), V(0, 0.22, -2.95), "metal" },
			{ "Magazine", V(0.30, 0.50, 0.55), V(0, -0.44, -0.55), "metal" },
			{ "Stock", V(0.44, 0.86, 2.00), V(0, -0.06, 1.36), "wood", V(4, 0, 0) },
			{ "ScopeTube", V(0.32, 0.32, 1.60), V(0, 0.74, -0.70), "dark", V(0, 90, 0), "Cylinder" },
			{ "ScopeMountFront", V(0.14, 0.30, 0.16), V(0, 0.50, -1.20), "dark" },
			{ "ScopeMountRear", V(0.14, 0.30, 0.16), V(0, 0.50, -0.24), "dark" },
			{ "ScopeLens", V(0.26, 0.26, 0.06), V(0, 0.74, -1.51), "optic" },
		},
	},

	-- No muzzle to speak of, but the attachment is built anyway so the effects
	-- code can ask any weapon where its business end is without a special case.
	[Enums.Weapon.Machete] = {
		muzzle = V(0, 0.34, -2.90),
		parts = {
			{ "Handle", V(0.30, 1.00, 0.34), V(0, -0.50, 0), "dark" },
			{ "Guard", V(0.52, 0.14, 0.40), V(0, 0.04, 0), "metal" },
			{ "Blade", V(0.10, 0.56, 2.40), V(0, 0.34, -1.30), "metal" },
			{ "Tip", V(0.10, 0.32, 0.40), V(0, 0.22, -2.68), "metal" },
		},
	},
}

--[[ A Cylinder-shaped Part extends along its own X axis, so a barrel-shaped
     cylinder is authored with the length in X and rotated into place. ]]
local function buildGun(weaponId: string): Model?
	local spec = GUNS[weaponId]
	local definition = WeaponConfig.get(weaponId)
	if not spec or not definition then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = weaponId

	local handle: BasePart? = nil
	local barrel: BasePart? = nil

	for _, entry in spec.parts do
		local name, size, offset, colorKey, rotation, shape = entry[1], entry[2], entry[3], entry[4], entry[5], entry[6]
		local cframe = CFrame.new(offset)
		if rotation then
			cframe = cframe * CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
		end
		if shape == "Cylinder" then
			-- Authored as (length, diameter, diameter); the rotation in the table
			-- turns that length onto the barrel axis.
			size = V(size.Z, size.Y, size.X)
		end

		local part = prop(name, size, cframe, GUN[colorKey], Enum.Material.Metal)
		if shape then
			part.Shape = (Enum.PartType :: any)[shape]
		end
		part.Parent = model

		if name == "Handle" then
			handle = part
		elseif name == "Barrel" or (name == "Blade" and not barrel) then
			barrel = part
		end
	end

	handle = handle or model:FindFirstChildWhichIsA("BasePart")
	if not handle then
		model:Destroy()
		return nil
	end
	model.PrimaryPart = handle

	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= handle then
			part.Massless = true
			weldTo(handle, part)
		end
	end

	-- Effects hang off "Muzzle": the flash, the smoke, the tracer origin. It lives
	-- on the barrel so a real model can move the barrel and the flash follows.
	local muzzleHost = barrel or handle
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.CFrame = muzzleHost.CFrame:Inverse() * CFrame.new(spec.muzzle)
	muzzle.Parent = muzzleHost

	return model
end

--[[ The world model: what a survivor is holding, seen by everybody else. Left
     unanchored so whoever equips it can weld it straight to a hand. ]]
function PlaceholderFactory:buildWeaponModel(weaponId: string): Model?
	if typeof(weaponId) ~= "string" then
		return nil
	end
	local source = template("Weapons", weaponId, function()
		local model = buildGun(weaponId)
		if model then
			for _, part in model:GetChildren() do
				if part:IsA("BasePart") then
					part.Anchored = false
				end
			end
		end
		return model
	end)
	return if source then source:Clone() else nil
end

--[[
	The first-person model. Same geometry at the same scale as the world model, on
	purpose: the Muzzle attachment then sits in the same place relative to the
	Handle in both, so a tracer that starts at the viewmodel's muzzle lines up with
	the one every other player sees leaving the world model.

	The Handle stays anchored — a viewmodel is driven by writing a CFrame every
	frame and must never be touched by physics — and the rest is welded to it.
]]
function PlaceholderFactory:buildViewmodel(weaponId: string): Model?
	if typeof(weaponId) ~= "string" then
		return nil
	end
	local source = template("Viewmodels", weaponId, function()
		local model = buildGun(weaponId)
		if not model then
			return nil
		end
		local handle = model.PrimaryPart :: BasePart

		-- Sleeved forearms. Without hands a viewmodel reads as a floating prop,
		-- and the arms are also what sells the reload and the melee swing.
		for _, side in { -1, 1 } do
			local isRight = side > 0
			local arm = prop(
				if isRight then "RightArm" else "LeftArm",
				V(0.5, 0.5, 2.3),
				CFrame.new(side * 0.34, if isRight then -0.55 else -0.30, if isRight then 1.05 else -1.15)
					* CFrame.Angles(math.rad(if isRight then -6 else 14), math.rad(side * 8), 0),
				UITheme.Color.PanelRaised,
				Enum.Material.Fabric
			)
			arm.Massless = true
			arm.Parent = model
			weldTo(handle, arm)
		end

		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				-- A viewmodel is drawn, never hit: it must not answer a raycast,
				-- cast a shadow into the world, or collide with anything.
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
				part.Anchored = part == handle
			end
		end
		return model
	end)
	return if source then source:Clone() else nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  Pickups
-- ════════════════════════════════════════════════════════════════════════════

local PICKUP_BUILDERS: { [string]: (Model) -> () } = {}

local function pickupPart(model: Model, name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material?)
	local part = prop(name, size, CFrame.new(offset), color, material)
	part.Parent = model
	return part
end

PICKUP_BUILDERS[Enums.HealthItem.Medkit] = function(model)
	pickupPart(model, "Case", V(2.2, 1.4, 1.2), V(0, 0.7, 0), UITheme.Color.TextPrimary)
	pickupPart(model, "CrossV", V(0.32, 0.9, 0.06), V(0, 0.75, -0.63), UITheme.Color.Danger)
	pickupPart(model, "CrossH", V(0.9, 0.32, 0.06), V(0, 0.75, -0.63), UITheme.Color.Danger)
	pickupPart(model, "Strap", V(2.24, 0.24, 1.24), V(0, 1.1, 0), UITheme.Color.TextDim)
end

PICKUP_BUILDERS[Enums.HealthItem.Defibrillator] = function(model)
	pickupPart(model, "Case", V(2.0, 1.0, 1.4), V(0, 0.5, 0), UITheme.Color.Warning)
	pickupPart(model, "PaddleLeft", V(0.6, 0.5, 0.5), V(-0.6, 1.2, 0), UITheme.Color.Panel)
	pickupPart(model, "PaddleRight", V(0.6, 0.5, 0.5), V(0.6, 1.2, 0), UITheme.Color.Panel)
	pickupPart(model, "Readout", V(0.7, 0.4, 0.06), V(0, 0.6, -0.72), UITheme.Color.AccentBright, Enum.Material.Neon)
end

PICKUP_BUILDERS[Enums.PillItem.PainPills] = function(model)
	pickupPart(model, "Bottle", V(0.7, 1.0, 0.7), V(0, 0.5, 0), UITheme.Color.TextPrimary)
	pickupPart(model, "Cap", V(0.72, 0.24, 0.72), V(0, 1.1, 0), UITheme.Color.Danger)
	pickupPart(model, "Label", V(0.72, 0.44, 0.02), V(0, 0.5, -0.36), UITheme.Color.Accent)
end

PICKUP_BUILDERS[Enums.PillItem.Adrenaline] = function(model)
	pickupPart(model, "Barrel", V(0.34, 1.3, 0.34), V(0, 0.75, 0), UITheme.Color.TextPrimary)
	pickupPart(model, "Plunger", V(0.5, 0.16, 0.5), V(0, 1.46, 0), UITheme.Color.Accent)
	pickupPart(model, "Needle", V(0.1, 0.5, 0.1), V(0, 0.15, 0), UITheme.Color.BorderBright)
	pickupPart(model, "Fluid", V(0.24, 0.9, 0.24), V(0, 0.72, 0), UITheme.Color.AccentBright, Enum.Material.Neon)
end

PICKUP_BUILDERS[Enums.Throwable.PipeBomb] = function(model)
	pickupPart(model, "Pipe", V(0.5, 1.6, 0.5), V(0, 0.8, 0), UITheme.Color.BorderBright)
	pickupPart(model, "TapeLower", V(0.58, 0.3, 0.58), V(0, 0.4, 0), UITheme.Color.AccentDim)
	pickupPart(model, "TapeUpper", V(0.58, 0.3, 0.58), V(0, 1.2, 0), UITheme.Color.AccentDim)
	pickupPart(model, "Light", V(0.18, 0.18, 0.18), V(0, 1.68, 0), UITheme.Color.Danger, Enum.Material.Neon)
end

PICKUP_BUILDERS[Enums.Throwable.Molotov] = function(model)
	pickupPart(model, "Bottle", V(0.6, 1.2, 0.6), V(0, 0.6, 0), UITheme.Color.Warning)
	pickupPart(model, "Neck", V(0.28, 0.4, 0.28), V(0, 1.35, 0), UITheme.Color.Warning)
	pickupPart(model, "Rag", V(0.22, 0.5, 0.22), V(0, 1.75, 0), UITheme.Color.TextSecondary, Enum.Material.Fabric)
end

PICKUP_BUILDERS[Enums.Throwable.BileJar] = function(model)
	pickupPart(model, "Jar", V(0.8, 1.1, 0.8), V(0, 0.55, 0), UITheme.Color.Bile, Enum.Material.Neon)
	pickupPart(model, "Lid", V(0.86, 0.2, 0.86), V(0, 1.2, 0), UITheme.Color.Border)
end

--[[
	A pickup: a small readable object, lying on the floor, glowing just enough to
	be found in a dark room without becoming a lamp. The outline controller adds
	the highlight — what matters here is that the model has a PrimaryPart to
	adorn, stays queryable so the interact raycast can find it, and never collides
	with anybody who walks over it.

	The "Handle" is an invisible root at the centre of the model's own bounding
	box, and that is not cosmetic: ItemPlacer places a pickup by pivoting it to
	`ground + halfHeight`, which only rests the object on the floor if the pivot
	really is the middle of it. A grip-shaped Handle would bury every dropped gun.
]]
function PlaceholderFactory:buildPickup(slot: string, itemId: string): Model?
	if typeof(slot) ~= "string" or typeof(itemId) ~= "string" then
		return nil
	end

	local source = template("Pickups", slot .. "_" .. itemId, function()
		local model: Model
		if WeaponConfig.get(itemId) then
			-- A dropped gun is the gun, lying on its side. Nothing else reads as
			-- clearly as the silhouette the player is about to be holding.
			local built = self:buildWeaponModel(itemId)
			if not built then
				return nil
			end
			model = built
			model.PrimaryPart = nil
			for _, part in model:GetChildren() do
				if part:IsA("BasePart") then
					part.CFrame = CFrame.Angles(0, 0, math.rad(90)) * part.CFrame
					if part.Name == "Handle" then
						part.Name = "Grip"
					end
				end
			end
		else
			model = Instance.new("Model")
			local builder = PICKUP_BUILDERS[itemId]
			if builder then
				builder(model)
			else
				-- An unknown id still has to become something a player can pick
				-- up: a plain crate is better than a nil return.
				pickupPart(
					model,
					"Crate",
					V(1.4, 1.2, 1.4),
					V(0, 0.6, 0),
					UITheme.Color.AccentDim,
					Enum.Material.WoodPlanks
				)
			end
		end

		if not model:FindFirstChildWhichIsA("BasePart") then
			model:Destroy()
			return nil
		end

		local box, extents = model:GetBoundingBox()
		local handle = prop("Handle", V(0.4, 0.4, 0.4), CFrame.new(box.Position), UITheme.Outline.ItemColor)
		handle.Transparency = 1
		handle.CanQuery = false
		handle.Parent = model
		model.PrimaryPart = handle

		-- The marker ring, flat on the floor under the item. Non-queryable so it
		-- can never eat the interact ray aimed at the thing standing on it.
		local ring = prop(
			"Marker",
			V(2.6, 0.06, 2.6),
			CFrame.new(box.Position - Vector3.new(0, extents.Y * 0.5 - 0.04, 0)),
			UITheme.Outline.ItemColor,
			Enum.Material.Neon
		)
		ring.CanQuery = false
		ring.Transparency = 0.4
		ring.Parent = model

		local glow = Instance.new("PointLight")
		glow.Color = UITheme.Outline.ItemColor
		glow.Brightness = 1.1
		glow.Range = 10
		glow.Shadows = false
		glow.Parent = handle

		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				-- Anchored: a pickup sitting where the level designer put it is
				-- worth far more than one that rolls under a car, and a few dozen
				-- anchored props cost nothing.
				part.Anchored = true
				part.CanCollide = false
				part.CastShadow = false
				if part ~= handle then
					part.Massless = true
					weldTo(handle, part)
				end
			end
		end
		return model
	end)

	if not source then
		return nil
	end
	local clone = source:Clone()
	clone.Name = itemId
	return clone
end
