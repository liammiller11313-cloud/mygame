--!nonstrict
--[[
	AmmoFactory — builds the casings, magazines and pickups from real dimensions.

	Rather than shipping a list of models for someone to make, this builds them.
	Every cartridge below is proportioned from its actual case drawing — a 5.56
	really is a slender bottleneck next to a 7.62, a .357 case really is that long
	and thin next to a .45, and a 12 gauge hull really is that fat. Those relative
	proportions are the entire reason a player can tell at a glance which gun just
	fired without reading anything.

	── SCALE ────────────────────────────────────────────────────────────────────
	Not literal. A stud is roughly 28cm, so a real 9mm case is 0.068 studs long —
	about three pixels at arm's length, and invisible the moment it leaves the
	frame. Everything is built into the bounding box AmmoConfig already declares,
	which runs roughly 1.3-1.6x life size. The PROPORTIONS inside that box are
	accurate; the box itself is sized to be seen.

	── IT ONLY EVER FILLS GAPS ──────────────────────────────────────────────────
	Anything already sitting in ReplicatedStorage.Assets.Ammo is left completely
	alone. Drop a hand-made `Mag_AK` in and it wins; delete it and this one comes
	back. That is the same contract as every other asset in the game.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AmmoConfig = require(Shared.Config.AmmoConfig)
local Registry = require(Shared.Util.Registry)

local AmmoFactory = {}

-- ── palette ─────────────────────────────────────────────────────────────────
local BRASS = Color3.fromRGB(196, 156, 74)
local BRASS_DARK = Color3.fromRGB(150, 116, 52)
local NICKEL = Color3.fromRGB(196, 198, 202)
local COPPER = Color3.fromRGB(172, 108, 60)
local LEAD = Color3.fromRGB(152, 152, 158)
local HULL_RED = Color3.fromRGB(146, 32, 28)
local STEEL = Color3.fromRGB(48, 48, 52)
local POLYMER = Color3.fromRGB(40, 42, 40)
--[[ The rocket's warhead green. Matched to AmmoConfig.Magazines.Rocket rather
     than picked here, so the stand-in and a supplied model that follows the
     config's colour are the same object at a glance. ]]
local OLIVE = Color3.fromRGB(96, 104, 68)
local BAKELITE = Color3.fromRGB(124, 76, 38)
local CAN_GREEN = Color3.fromRGB(72, 82, 56)
local CARDBOARD = Color3.fromRGB(150, 120, 84)

-- ── primitives ──────────────────────────────────────────────────────────────

local function newPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	A cylinder whose axis runs along the model's Z.

	Roblox's cylinder primitive puts its flat faces on the X faces, so a cylinder
	"pointing forward" is a part sized (length, diameter, diameter) rotated a
	quarter turn about Y. Getting this wrong is why hand-built casings so often
	come out as discs.
]]
local function cylinderZ(
	parent: Instance,
	name: string,
	length: number,
	diameter: number,
	z: number,
	color: Color3,
	material: Enum.Material
): BasePart
	local part = newPart(
		parent,
		name,
		Vector3.new(length, diameter, diameter),
		CFrame.new(0, 0, z) * CFrame.Angles(0, math.pi / 2, 0),
		color,
		material
	)
	part.Shape = Enum.PartType.Cylinder
	return part
end

local function newBox(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): BasePart
	return newPart(parent, name, size, cf, color, material)
end

--[[ Wraps a set of parts into a Model, welds them to the largest one, and makes
     that the PrimaryPart. Everything downstream — the brass pool, the magazine
     drop, the floor pickup — treats a model as one rigid body, so the welds have
     to exist before it is ever unanchored. ]]
local function finish(model: Model): Model
	local root: BasePart? = nil
	local bestVolume = -1
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			if volume > bestVolume then
				bestVolume = volume
				root = part
			end
		end
	end
	if not root then
		return model
	end

	model.PrimaryPart = root
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			--[[ Belt and braces, and one line. Every caller does reach here with
			     an unanchored model today -- AmmoFactory builds its own parts and
			     CarryVisualService tames before it places -- but that is a
			     contract held three functions away and written down nowhere. An
			     anchored part silently ignores the weld below, so the invariant
			     belongs where the weld is made. audit.py check 39 agrees. ]]
			part.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end
	return model
end

-- ── casings ─────────────────────────────────────────────────────────────────

--[[
	A straight-walled pistol case: 9mm, .45 ACP, .357.

	`rimRatio` is how far the rim stands proud of the case wall. A .357 is a
	rimmed revolver cartridge and its rim is obvious; an autoloader's is a
	groove you would never see at this size, so it gets a much smaller number.
]]
local function buildStraightCase(name: string, box: Vector3, rimRatio: number, brass: Color3): Model
	local model = Instance.new("Model")
	model.Name = name

	local length = box.Z
	local diameter = box.X

	-- The case body, very slightly tapered by inset rather than by geometry.
	cylinderZ(model, "Case", length * 0.94, diameter * 0.94, 0, brass, Enum.Material.Metal)
	-- Rim and extractor groove at the base (+Z is toward the shooter).
	cylinderZ(model, "Rim", length * 0.07, diameter * rimRatio, length * 0.46, brass, Enum.Material.Metal)
	-- The primer, a shade darker so the base end reads as the base end.
	cylinderZ(model, "Primer", length * 0.03, diameter * 0.36, length * 0.49, BRASS_DARK, Enum.Material.Metal)

	return finish(model)
end

--[[
	A bottleneck rifle case: 5.56 and 7.62.

	Three stages — body, shoulder, neck — because a real bottleneck is exactly
	that, and three stacked cylinders read as a taper at any distance a player
	will ever see one from. `neckRatio` is neck diameter over base diameter:
	0.67 for 5.56, 0.76 for 7.62x39, which is why the 5.56 looks so much more
	sharply waisted.
]]
local function buildBottleneckCase(name: string, box: Vector3, neckRatio: number, bodyFraction: number): Model
	local model = Instance.new("Model")
	local length = box.Z
	local diameter = box.X
	model.Name = name

	local bodyLength = length * bodyFraction
	local neckLength = length * (1 - bodyFraction - 0.08)
	local shoulderLength = length * 0.08

	local bodyZ = length * 0.5 - bodyLength * 0.5
	local shoulderZ = bodyZ - bodyLength * 0.5 - shoulderLength * 0.5
	local neckZ = shoulderZ - shoulderLength * 0.5 - neckLength * 0.5

	cylinderZ(model, "Case", bodyLength, diameter * 0.94, bodyZ, BRASS, Enum.Material.Metal)
	-- The shoulder splits the difference, which is what sells the taper.
	cylinderZ(
		model,
		"Shoulder",
		shoulderLength,
		diameter * (0.94 + neckRatio) * 0.5,
		shoulderZ,
		BRASS,
		Enum.Material.Metal
	)
	cylinderZ(model, "Neck", neckLength, diameter * neckRatio, neckZ, BRASS, Enum.Material.Metal)
	cylinderZ(model, "Rim", length * 0.05, diameter, length * 0.47, BRASS, Enum.Material.Metal)
	cylinderZ(model, "Primer", length * 0.02, diameter * 0.34, length * 0.5, BRASS_DARK, Enum.Material.Metal)

	return finish(model)
end

--[[ A fired 12 gauge hull: red plastic tube on a brass head. The most
     recognisable piece of ammunition in any game, and the only casing a player
     consciously registers, so it gets its own builder. ]]
local function buildShotgunHull(name: string, box: Vector3, loaded: boolean): Model
	local model = Instance.new("Model")
	model.Name = name

	local length = box.Z
	local diameter = box.X

	local headLength = length * 0.24
	local tubeLength = length - headLength

	cylinderZ(
		model,
		"Head",
		headLength,
		diameter,
		length * 0.5 - headLength * 0.5,
		BRASS,
		Enum.Material.Metal
	)
	cylinderZ(
		model,
		"Hull",
		tubeLength,
		diameter * 0.96,
		length * 0.5 - headLength - tubeLength * 0.5,
		HULL_RED,
		Enum.Material.Plastic
	)
	cylinderZ(model, "Primer", length * 0.03, diameter * 0.3, length * 0.5, BRASS_DARK, Enum.Material.Metal)

	if loaded then
		-- An unfired shell is closed with a star crimp; a fired hull is open and
		-- slightly splayed. One short cap is the whole difference and it is worth
		-- having, because the loaded round is what the hand carries to the port.
		cylinderZ(
			model,
			"Crimp",
			length * 0.06,
			diameter * 0.9,
			-length * 0.5 + length * 0.03,
			HULL_RED,
			Enum.Material.Plastic
		)
	end

	return finish(model)
end

-- ── magazines ───────────────────────────────────────────────────────────────

--[[ A box magazine: body, floorplate, feed lips, and the top round showing.
     `curve` bends it into a banana by splitting the body into segments and
     rotating each one — which is the entire visual difference between a STANAG
     and an AK magazine at a glance. ]]
local function buildBoxMagazine(
	name: string,
	box: Vector3,
	color: Color3,
	material: Enum.Material,
	curve: number,
	showRound: boolean
): Model
	local model = Instance.new("Model")
	model.Name = name

	local width = box.X
	local height = box.Y
	local depth = box.Z

	local segments = if curve > 0 then 4 else 1
	local segmentHeight = height * 0.86 / segments

	for index = 1, segments do
		-- Each segment is rotated a little further than the one below it, and
		-- shifted so the stack stays joined rather than fanning apart.
		local t = (index - 1) / math.max(segments - 1, 1)
		local angle = -curve * t
		local y = -height * 0.43 + segmentHeight * (index - 0.5)
		local drift = curve * t * t * height * 0.22

		newBox(
			model,
			"Body" .. index,
			Vector3.new(width, segmentHeight * 1.02, depth),
			CFrame.new(0, y, drift) * CFrame.Angles(angle, 0, 0),
			color,
			material
		)
	end

	newBox(
		model,
		"Floorplate",
		Vector3.new(width * 1.12, height * 0.07, depth * 1.12),
		CFrame.new(0, -height * 0.46, 0),
		color,
		material
	)

	-- Feed lips: two thin walls at the top with a gap between them.
	local lipY = height * 0.45
	newBox(
		model,
		"LipL",
		Vector3.new(width * 0.16, height * 0.09, depth),
		CFrame.new(-width * 0.42, lipY, curve * height * 0.22),
		color,
		material
	)
	newBox(
		model,
		"LipR",
		Vector3.new(width * 0.16, height * 0.09, depth),
		CFrame.new(width * 0.42, lipY, curve * height * 0.22),
		color,
		material
	)

	if showRound then
		-- The top cartridge sitting under the lips. Small, but it is what makes a
		-- magazine read as loaded rather than as a black rectangle.
		newBox(
			model,
			"TopRound",
			Vector3.new(width * 0.66, height * 0.06, depth * 0.8),
			CFrame.new(0, lipY - height * 0.01, curve * height * 0.22),
			COPPER,
			Enum.Material.Metal
		)
	end

	return finish(model)
end

--[[ The PPSh drum: a flat cylinder with a short feed tower. Unmistakable, which
     is the point — the drum is half of what makes the PPSh the PPSh. ]]
--[[
	A rocket: warhead, body, and four fins.

	Built rather than left to the block fallback because this is the one round in
	the game a player looks at for four seconds at arm's length — the launcher's
	whole reload is this object going down a tube. A featureless green brick at
	that size and that duration reads as a missing model, which is the exact
	impression a stand-in is supposed to avoid.

	Fins are four thin plates rather than a cone, because a cone at this scale is
	several hundred triangles for a silhouette four rectangles already give.
]]
local function buildRocket(name: string, box: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name

	local calibre = box.X
	local length = box.Z

	--[[ The body is the PrimaryPart and the thing everything else is placed
	     against, so a supplied model swapped in later only has to agree about
	     which part is the tube. ]]
	local body = newPart(
		model,
		"Body",
		Vector3.new(calibre * 0.62, calibre * 0.62, length * 0.62),
		CFrame.identity,
		OLIVE,
		Enum.Material.Metal
	)
	body.Shape = Enum.PartType.Cylinder
	--[[ A cylinder's axis is X, and this one has to run along the round's LENGTH
	     — which is Z. Without the turn the rocket is a disc lying on its side,
	     which is what the drum magazine's own comment above is about from the
	     other direction. ]]
	body.CFrame = CFrame.Angles(0, math.rad(90), 0)

	-- The warhead: wider than the body and forward of it, which is the one
	-- feature that makes this read as a rocket rather than as a pipe.
	local head = newPart(
		model,
		"Warhead",
		Vector3.new(calibre, calibre, length * 0.34),
		CFrame.new(0, 0, -length * 0.42) * CFrame.Angles(0, math.rad(90), 0),
		OLIVE,
		Enum.Material.Metal
	)
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(calibre, calibre, calibre)

	for index = 0, 3 do
		local bearing = index * (math.pi * 0.5)
		local out = calibre * 0.34
		newPart(
			model,
			"Fin" .. index,
			Vector3.new(calibre * 0.06, calibre * 0.62, length * 0.2),
			CFrame.new(math.cos(bearing) * out, math.sin(bearing) * out, length * 0.38)
				* CFrame.Angles(0, 0, bearing),
			STEEL,
			Enum.Material.Metal
		)
	end

	model.PrimaryPart = body
	return model
end

local function buildDrumMagazine(name: string, box: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name

	local diameter = box.X
	local thickness = box.Z

	--[[ No rotation: a cylinder's axis is already X, and a drum magazine hangs
	     with its flat faces to the left and right, exactly as it sits on the gun.
	     Rotating it would stand the pan on edge like a wheel. ]]
	local drum = newPart(
		model,
		"Drum",
		Vector3.new(thickness, diameter, diameter),
		CFrame.identity,
		STEEL,
		Enum.Material.Metal
	)
	drum.Shape = Enum.PartType.Cylinder

	-- The pan's raised centre and the little wind key, both visible on the real
	-- drum from any angle you would ever see one falling.
	local hub = newPart(
		model,
		"Hub",
		Vector3.new(thickness * 1.15, diameter * 0.3, diameter * 0.3),
		CFrame.identity,
		STEEL,
		Enum.Material.Metal
	)
	hub.Shape = Enum.PartType.Cylinder

	-- The feed tower on top, which is how a drum attaches to the receiver.
	newBox(
		model,
		"Tower",
		Vector3.new(thickness * 0.9, diameter * 0.24, diameter * 0.2),
		CFrame.new(0, diameter * 0.55, 0),
		STEEL,
		Enum.Material.Metal
	)

	return finish(model)
end

--[[ A revolver speedloader: six cartridges in a ring under a knurled knob. ]]
local function buildSpeedloader(name: string, box: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name

	local diameter = box.X
	local ring = diameter * 0.3
	local roundLength = box.Z * 1.6
	local roundDiameter = diameter * 0.2

	for index = 1, 6 do
		local angle = (index - 1) * (math.pi * 2 / 6)
		local x = math.cos(angle) * ring
		local y = math.sin(angle) * ring

		local case = newPart(
			model,
			"Round" .. index,
			Vector3.new(roundLength * 0.7, roundDiameter, roundDiameter),
			CFrame.new(x, y, roundLength * 0.15) * CFrame.Angles(0, math.pi / 2, 0),
			BRASS,
			Enum.Material.Metal
		)
		case.Shape = Enum.PartType.Cylinder

		local bullet = newPart(
			model,
			"Bullet" .. index,
			Vector3.new(roundLength * 0.3, roundDiameter * 0.92, roundDiameter * 0.92),
			CFrame.new(x, y, -roundLength * 0.35) * CFrame.Angles(0, math.pi / 2, 0),
			LEAD,
			Enum.Material.Metal
		)
		bullet.Shape = Enum.PartType.Cylinder
	end

	local body = newPart(
		model,
		"Body",
		Vector3.new(box.Z * 0.4, diameter, diameter),
		CFrame.new(0, 0, roundLength * 0.42) * CFrame.Angles(0, math.pi / 2, 0),
		STEEL,
		Enum.Material.Metal
	)
	body.Shape = Enum.PartType.Cylinder

	local knob = newPart(
		model,
		"Knob",
		Vector3.new(box.Z * 0.35, diameter * 0.42, diameter * 0.42),
		CFrame.new(0, 0, roundLength * 0.6) * CFrame.Angles(0, math.pi / 2, 0),
		STEEL,
		Enum.Material.Metal
	)
	knob.Shape = Enum.PartType.Cylinder

	return finish(model)
end

-- ── pickups ─────────────────────────────────────────────────────────────────

--[[ A steel ammo can. Read from twenty studs away in a dark room by its
     silhouette — squat box, lid lip, folding handle — not by its detail. ]]
local function buildAmmoCan(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	newBox(model, "Body", Vector3.new(2.4, 1.5, 1.3), CFrame.new(0, 0.75, 0), CAN_GREEN, Enum.Material.Metal)
	newBox(model, "Lid", Vector3.new(2.5, 0.18, 1.4), CFrame.new(0, 1.58, 0), CAN_GREEN, Enum.Material.Metal)
	newBox(model, "Latch", Vector3.new(0.4, 0.3, 0.16), CFrame.new(1.0, 1.5, 0.7), STEEL, Enum.Material.Metal)
	-- The handle, folded flat the way one sits on a shelf.
	newBox(model, "Handle", Vector3.new(1.1, 0.1, 0.14), CFrame.new(0, 1.72, 0), STEEL, Enum.Material.Metal)
	newBox(
		model,
		"HandleL",
		Vector3.new(0.1, 0.1, 0.5),
		CFrame.new(-0.55, 1.68, 0),
		STEEL,
		Enum.Material.Metal
	)
	newBox(
		model,
		"HandleR",
		Vector3.new(0.1, 0.1, 0.5),
		CFrame.new(0.55, 1.68, 0),
		STEEL,
		Enum.Material.Metal
	)
	-- A stencilled panel, because every ammo can that ever existed has one.
	newBox(
		model,
		"Stencil",
		Vector3.new(1.3, 0.4, 0.04),
		CFrame.new(0, 0.85, 0.67),
		Color3.fromRGB(196, 190, 172),
		Enum.Material.SmoothPlastic
	)

	return finish(model)
end

--[[ The shared refill: several cans stacked badly, with loose boxes and a
     scatter of rounds. Deliberately untidy — a neat pile reads as scenery, and
     this is the thing everyone runs to. ]]
local function buildAmmoPile(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	newBox(model, "CanA", Vector3.new(2.3, 1.4, 1.25), CFrame.new(0, 0.7, 0), CAN_GREEN, Enum.Material.Metal)
	newBox(
		model,
		"CanB",
		Vector3.new(2.2, 1.35, 1.2),
		CFrame.new(0.45, 2.05, 0.25) * CFrame.Angles(0, math.rad(14), math.rad(4)),
		CAN_GREEN,
		Enum.Material.Metal
	)
	newBox(
		model,
		"BoxA",
		Vector3.new(1.1, 0.55, 0.75),
		CFrame.new(-1.5, 0.28, 0.5) * CFrame.Angles(0, math.rad(-22), 0),
		CARDBOARD,
		Enum.Material.Cardboard
	)
	newBox(
		model,
		"BoxB",
		Vector3.new(1.0, 0.5, 0.7),
		CFrame.new(-1.35, 0.8, 0.2) * CFrame.Angles(0, math.rad(9), math.rad(6)),
		CARDBOARD,
		Enum.Material.Cardboard
	)

	for index = 1, 5 do
		local angle = index * 1.7
		local round = newPart(
			model,
			"Loose" .. index,
			Vector3.new(0.34, 0.11, 0.11),
			CFrame.new(math.cos(angle) * 1.5, 0.06, math.sin(angle) * 1.1)
				* CFrame.Angles(0, angle, math.pi / 2),
			if index % 2 == 0 then BRASS else NICKEL,
			Enum.Material.Metal
		)
		round.Shape = Enum.PartType.Cylinder
	end

	return finish(model)
end

--[[ An open box of shotgun shells, seen from above: a grid of red tops. ]]
local function buildShellBox(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	newBox(
		model,
		"Box",
		Vector3.new(1.5, 0.62, 0.95),
		CFrame.new(0, 0.31, 0),
		CARDBOARD,
		Enum.Material.Cardboard
	)
	newBox(
		model,
		"Lid",
		Vector3.new(1.5, 0.5, 0.06),
		CFrame.new(0, 0.62, -0.55) * CFrame.Angles(math.rad(-58), 0, 0),
		CARDBOARD,
		Enum.Material.Cardboard
	)

	for row = 1, 2 do
		for column = 1, 5 do
			local shell = newPart(
				model,
				string.format("Shell%d_%d", row, column),
				Vector3.new(0.3, 0.24, 0.24),
				CFrame.new(-0.56 + (column - 1) * 0.28, 0.56, -0.2 + (row - 1) * 0.36)
					* CFrame.Angles(0, 0, math.pi / 2),
				HULL_RED,
				Enum.Material.Plastic
			)
			shell.Shape = Enum.PartType.Cylinder
		end
	end

	return finish(model)
end

-- ── assembly ────────────────────────────────────────────────────────────────

local function folder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

--[[ Places a model only if that name is free. This is what makes a hand-made
     asset always win over a generated one. ]]
local function place(parent: Folder, name: string, build: () -> Model): boolean
	if parent:FindFirstChild(name) then
		return false
	end
	local model = build()
	model.Name = name
	model.Parent = parent
	return true
end

function AmmoFactory:build(): number
	local assets = folder(ReplicatedStorage, "Assets")
	local ammo = folder(assets, AmmoConfig.FolderName)
	local casings = folder(ammo, AmmoConfig.CasingFolder)
	local magazines = folder(ammo, AmmoConfig.MagazineFolder)
	local pickups = folder(ammo, AmmoConfig.PickupFolder)

	local built = 0
	local function count(made: boolean)
		if made then
			built += 1
		end
	end

	local C = AmmoConfig.Casings
	local M = AmmoConfig.Magazines

	-- Straight-walled pistol cases. The .357's rim really is that proud; the two
	-- autoloader cases have effectively none.
	count(place(casings, C["9mm"].model, function()
		return buildStraightCase("9mm", C["9mm"].size, 1.0, BRASS)
	end))
	count(place(casings, C["45acp"].model, function()
		return buildStraightCase("45", C["45acp"].size, 1.0, BRASS)
	end))
	count(place(casings, C["357"].model, function()
		return buildStraightCase("357", C["357"].size, 1.16, NICKEL)
	end))

	-- Bottlenecks. 5.56 necks down to about two thirds of its base diameter and
	-- 7.62x39 to about three quarters, which is why one looks sharply waisted
	-- and the other looks merely tapered.
	count(place(casings, C["556"].model, function()
		return buildBottleneckCase("556", C["556"].size, 0.67, 0.72)
	end))
	count(place(casings, C["762"].model, function()
		return buildBottleneckCase("762", C["762"].size, 0.76, 0.68)
	end))

	count(place(casings, C["12ga"].model, function()
		return buildShotgunHull("12ga", C["12ga"].size, false)
	end))

	--[[ A flare shell is a shotgun hull that is fatter and shorter, so it is
	     built as one. `loaded` is what separates the pair: false is the fired
	     case that comes out of the gun, true is the live round that goes in, and
	     they are two models in two different folders because they are two
	     different objects a player sees at two different moments. ]]
	count(place(casings, C["flare"].model, function()
		return buildShotgunHull("FlareSpent", C["flare"].size, false)
	end))

	count(place(magazines, M.PistolMag.model, function()
		return buildBoxMagazine("PistolMag", M.PistolMag.size, STEEL, Enum.Material.Metal, 0, true)
	end))
	count(place(magazines, M.SmgMag.model, function()
		return buildBoxMagazine("SmgMag", M.SmgMag.size, STEEL, Enum.Material.Metal, 0, true)
	end))
	count(place(magazines, M.StanagMag.model, function()
		-- Barely curved: a STANAG is close enough to straight that any visible
		-- bend would read as an AK.
		return buildBoxMagazine("Stanag", M.StanagMag.size, POLYMER, Enum.Material.Plastic, 0.06, true)
	end))
	count(place(magazines, M.AkMag.model, function()
		-- The banana. This curve is the single most recognisable magazine
		-- silhouette there is, so it is exaggerated rather than measured.
		return buildBoxMagazine("AkMag", M.AkMag.size, BAKELITE, Enum.Material.Plastic, 0.34, true)
	end))
	count(place(magazines, M.MarksmanMag.model, function()
		return buildBoxMagazine("Marksman", M.MarksmanMag.size, STEEL, Enum.Material.Metal, 0.1, true)
	end))
	count(place(magazines, M.DrumMag.model, function()
		return buildDrumMagazine("Drum", M.DrumMag.size)
	end))
	count(place(magazines, M.RevolverSpeedloader.model, function()
		return buildSpeedloader("Speedloader", M.RevolverSpeedloader.size)
	end))
	count(place(magazines, M.ShotgunShell.model, function()
		return buildShotgunHull("Round12ga", M.ShotgunShell.size, true)
	end))
	count(place(magazines, M.FlareShell.model, function()
		return buildShotgunHull("FlareRound", M.FlareShell.size, true)
	end))
	count(place(magazines, M.Rocket.model, function()
		return buildRocket("Rocket", M.Rocket.size)
	end))

	count(place(pickups, AmmoConfig.Pickups.Box, function()
		return buildAmmoCan("AmmoBox")
	end))
	count(place(pickups, AmmoConfig.Pickups.Pile, function()
		return buildAmmoPile("AmmoPile")
	end))
	count(place(pickups, AmmoConfig.Pickups.ShellBox, function()
		return buildShellBox("ShellBox")
	end))

	return built
end

function AmmoFactory:init()
	local built = self:build()
	if built > 0 then
		print(
			string.format(
				"[AmmoFactory] built %d ammo model(s); any you supply yourself are left alone",
				built
			)
		)
	end
end

Registry.register("AmmoFactory", AmmoFactory)

return AmmoFactory
