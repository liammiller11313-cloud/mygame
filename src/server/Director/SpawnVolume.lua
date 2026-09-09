--!strict
--[[
	SpawnVolume — will a body of this size actually FIT here?

		local size = SpawnVolume.sizeFor(Enums.Infected.Tank)
		if SpawnVolume.fits(groundPoint, size, ignoreList) then ... end

	── THE PROBLEM THIS EXISTS FOR ──────────────────────────────────────────────
	SpawnPlacement tested headroom with a single upward ray, three studs long,
	from the point the body's feet would land on. That answers "is there a
	ceiling directly overhead" and nothing else. It says nothing about WIDTH, so
	a point one stud from a wall passed it cleanly and the rig materialised with
	its torso inside the wall — a zombie that shoves against geometry forever and
	never reaches anybody.

	It was also one constant for every kind, and a Tank is scaled 2.35: over
	eleven studs tall and three across. The test that cleared a Common was
	telling a Tank it fit through the same gap.

	── WHY A BOX AND NOT MORE RAYS ─────────────────────────────────────────────
	Rays are how you end up with this bug again in a year. Four corner rays miss
	a pillar in the middle, eight miss a thinner one, and every added ray is
	another guess about which direction the geometry comes from.
	GetPartBoundsInBox asks the actual question — is anything solid inside the
	space this body needs — in one call, and gets it right for shapes nobody
	thought about.

	── WHAT IT DELIBERATELY DOES NOT DO ────────────────────────────────────────
	It does not check reachability. A sealed room with a floor is somewhere a
	body FITS, and this will say yes. Whether the horde can walk out of it is a
	different question, and it belongs to whatever is choosing candidate points
	rather than to the test that keeps bodies out of walls.

	For a long time nothing picked that question up, and a Tank arrived on the
	roof of the Backrooms — a flat surface with an upward normal, inside the
	height band because an interior ceiling is low, and with plenty of room for a
	body. Every test in this file passed it, correctly. SpawnPlacement owns the
	question now: see OVERHEAD COVER and belongsToMap there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DirectorConfig = require(Shared.Config.DirectorConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)

local SPAWNING = DirectorConfig.Spawning

local SpawnVolume = {}

--[[ One params object, refiltered per call. Building one per test would be an
     allocation inside the Director's hottest loop, and this module is asked the
     question dozens of times for a single spawn. ]]
local params = OverlapParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
--[[ Decoration is not a wall. A body may stand inside a bush, an effect volume
     or a trigger part; refusing those would reject most of a dressed map. ]]
params.RespectCanCollide = true
params.MaxParts = 1

--[[
	The box a body of this kind stands in.

	`scale` is the same number RigUtil.scaleRig and PlaceholderFactory's geometry
	scaling use, so this box tracks whatever size the rig is actually built at
	rather than restating it.
]]
--[[ What a definition's body occupies, as a multiplier on the reference above.

     Usually its `scale`, which is exactly that. A definition may instead state a
     `targetHeight` — a finished size in studs, for a kind whose rig is supplied
     and whose real proportions are therefore not known here — and then `scale`
     builds only the grey-box fallback and is the wrong number to reserve space
     with. Converting the height back through the reference keeps this box
     tracking the body that will actually stand in it, which is the whole
     property this file exists for. ]]
local function bodyScale(definition, referenceHeight: number): number
	if definition then
		local target = definition.targetHeight
		if typeof(target) == "number" and target > 0 and referenceHeight > 0 then
			return target / referenceHeight
		end
		if typeof(definition.scale) == "number" then
			return definition.scale
		end
	end
	return 1
end

--[[
	How tall this kind really is, preferring the measurement over the arithmetic.

	PlaceholderFactory is holding the prepared template and can simply look; both
	branches below are estimates of the same number and both were wrong for the
	same reason. `scale` times the grey-box's 5.2 describes a body built out of
	SHAPES, and every rig in a real place is the artist's — a Tank at 2.35 works
	out to 12.2 and measures 13.6, so the spawner reserved a space a stud and a
	half shorter than the thing it put in it.

	The config answer is kept as a fallback rather than deleted, because it is
	the right answer for a kind whose rig has not been built yet — during the
	boot prewarm, or on a place with an empty Infected folder — and because
	SpawnVolume must not be able to fail for want of another service.
]]
local function finishedHeight(kind: string?, definition, referenceHeight: number): number
	if typeof(kind) == "string" then
		local factory = Registry.find("PlaceholderFactory")
		if factory and typeof(factory.measuredHeight) == "function" then
			local ok, measured = pcall(factory.measuredHeight, factory, kind)
			if ok and typeof(measured) == "number" and measured > 0 then
				return measured
			end
		end
	end
	return referenceHeight * math.max(bodyScale(definition, referenceHeight), 0.1)
end

--[[
	The box to reserve for one body of this kind.

	Height is the measured one. WIDTH AND DEPTH ARE NOT, and that is deliberate
	twice over: the measurement cannot supply them honestly — a T-posed rig
	measures arm span, and this file's own reference size is narrower than arm
	span on purpose, because testing the full span rejects most doorways — so
	they stay proportions of the height, which is the only part of the shape the
	grey-box gets right.
]]
function SpawnVolume.sizeFor(kind: string?): Vector3
	local base = SPAWNING.SpawnBodySize
	local definition = if typeof(kind) == "string" then InfectedConfig.get(kind) else nil
	local height = finishedHeight(kind, definition, base.Y)
	local ratio = height / math.max(base.Y, 0.1)
	return Vector3.new(base.X * ratio, height, base.Z * ratio)
end

--[[
	Whether a body of `size` standing with its FEET at `footPosition` is clear of
	the world.

	The box is lifted by half its height, because the caller has a ground point
	and a body stands on top of one rather than centred on it. It is then shrunk
	by SpawnBodyTolerance: GetPartBoundsInBox tests axis-aligned bounding boxes,
	which for an angled wall are bigger than the wall, and without a little slack
	no ground next to a diagonal surface would ever pass.

	`ignore` is the caller's list — survivors, existing infected, gore. Passed in
	rather than rebuilt here because SpawnPlacement already maintains exactly
	that list for its raycasts and two copies would drift.
]]
function SpawnVolume.fits(footPosition: Vector3, size: Vector3, ignore: { Instance }?): boolean
	local slack = 1 - SPAWNING.SpawnBodyTolerance
	local box = Vector3.new(size.X * slack, size.Y * slack, size.Z * slack)

	--[[ Half a stud of extra lift on top of the half-height, so a body standing
	     ON the floor is not reported as intersecting it. The ground point comes
	     from a raycast that hit that floor, so the two touch by definition. ]]
	local centre = footPosition + Vector3.new(0, box.Y * 0.5 + 0.5, 0)

	params.FilterDescendantsInstances = ignore or {}
	local hits = Workspace:GetPartBoundsInBox(CFrame.new(centre), box, params)
	return #hits == 0
end

--[[ The same question for a named kind, which is what callers usually have. ]]
function SpawnVolume.fitsKind(footPosition: Vector3, kind: string?, ignore: { Instance }?): boolean
	return SpawnVolume.fits(footPosition, SpawnVolume.sizeFor(kind), ignore)
end

--[[ The tallest body the game can spawn, for a caller that wants one answer
     good for every kind — a shared walkable map, say, rather than a specific
     spawn. Computed once: the roster does not change at runtime. ]]
local widest: Vector3? = nil

function SpawnVolume.largestSize(): Vector3
	if widest then
		return widest :: Vector3
	end
	local biggest = 1
	local base = SPAWNING.SpawnBodySize
	for _, definition in InfectedConfig.all() do
		local scale = bodyScale(definition, base.Y)
		if scale > biggest then
			biggest = scale
		end
	end
	widest = base * biggest
	return widest :: Vector3
end

return SpawnVolume
