--!strict
--[[
	RaycastUtil — shared raycasting for the combat path.

	Bullets in this game are hitscan, but "hitscan" is not one raycast. A round
	has to pass through the things it should pass through (other zombies, when
	the weapon has penetration) and stop on the things it should not (walls), and
	it must never be blocked by the shooter's own body, a corpse, or a gib.

	`pierce` below does that with a single, reusable loop so no two weapons can
	drift into disagreeing about what a bullet ignores.
]]

local RaycastUtil = {}

export type PierceHit = {
	instance: BasePart,
	position: Vector3,
	normal: Vector3,
	material: Enum.Material,
	distance: number,
	model: Model?,
}

--[[ Params that ignore a list of instances. The default for almost every cast. ]]
function RaycastUtil.excluding(ignoreList: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList
	params.IgnoreWater = true
	params.RespectCanCollide = false
	return params
end

--[[ Params that hit ONLY a list of instances. Used by melee arcs and the shove
     cone, which want to sweep for bodies and genuinely not care about walls. ]]
function RaycastUtil.including(includeList: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = includeList
	params.IgnoreWater = true
	params.RespectCanCollide = false
	return params
end

--[[
	Casts a ray that passes through up to `maxPierces` bodies before stopping,
	and stops immediately on anything that is not a body.

	`isPierceable` decides, per hit, whether the round continues. Returning false
	adds the hit and ends the cast — that is a wall. Returning true adds the hit
	and keeps going, spending one pierce — that is a zombie.

	Returns hits in the order they were struck, which is what damage falloff and
	penetration falloff both need.
]]
function RaycastUtil.pierce(
	origin: Vector3,
	direction: Vector3,
	maxDistance: number,
	maxPierces: number,
	ignoreList: { Instance },
	isPierceable: (RaycastResult) -> boolean
): { PierceHit }
	local hits: { PierceHit } = {}
	local ignore = table.clone(ignoreList)
	local params = RaycastUtil.excluding(ignore)

	local currentOrigin = origin
	local unit = direction.Unit
	local remaining = maxDistance
	local pierced = 0

	-- +1 because the final cast is allowed to land on the wall that stops us.
	for _ = 1, maxPierces + 1 do
		if remaining <= 0 then
			break
		end

		local result = workspace:Raycast(currentOrigin, unit * remaining, params)
		if not result then
			break
		end

		local travelled = (result.Position - currentOrigin).Magnitude
		local model = result.Instance:FindFirstAncestorOfClass("Model")

		table.insert(hits, {
			instance = result.Instance,
			position = result.Position,
			normal = result.Normal,
			material = result.Material,
			distance = (result.Position - origin).Magnitude,
			model = model,
		})

		if not isPierceable(result) then
			break
		end

		pierced += 1
		if pierced > maxPierces then
			break
		end

		-- Step slightly past the surface so the next cast does not re-hit it.
		remaining -= travelled + 0.1
		currentOrigin = result.Position + unit * 0.1

		-- Whatever we just pierced must not be hit twice by the same round.
		table.insert(ignore, if model then model else result.Instance)
		params.FilterDescendantsInstances = ignore
	end

	return hits
end

--[[
	The one RaycastParams every line-of-sight test reuses.

	hasLineOfSight is the most-called cast in the game — every brain retarget and
	re-path, every Director spawn visibility check, every melee sweep candidate —
	and at SustainPeak that is well over a thousand calls a second. Allocating a
	fresh RaycastParams for each of them is pure garbage.

	Reusing one looks unsafe and is not: Luau is single-threaded, and nothing
	between the filter assignment and the cast below yields, so no other caller
	can observe or overwrite the filter mid-cast. Only touch this from
	hasLineOfSight, and only in those two adjacent lines.
]]
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.IgnoreWater = true
sightParams.RespectCanCollide = false

--[[
	True when nothing solid sits between two points. The Director uses this to
	keep spawns out of sight, and hit validation uses it to reject a claimed hit
	through a wall.
]]
function RaycastUtil.hasLineOfSight(from: Vector3, to: Vector3, ignoreList: { Instance }): boolean
	local delta = to - from
	local distance = delta.Magnitude
	if distance < 0.1 then
		return true
	end
	sightParams.FilterDescendantsInstances = ignoreList
	local result = workspace:Raycast(from, delta.Unit * distance, sightParams)
	return result == nil
end

--[[
	Drops a point onto the ground BENEATH it, returning the surface position and
	normal. Spawn placement uses this so an infected never appears half-buried in
	a floor or hovering a stud above it.

	── IT USED TO START THE RAY 80 STUDS IN THE AIR ────────────────────────────
	`searchHeight` was used for both halves: the cast began at `position + up *
	searchHeight` and ran down `searchHeight * 2`. So with the 80 the Director
	passes, "the ground beneath this point" was answered by the first surface
	found on the way down from eighty studs overhead — which, anywhere near a
	building, is its ROOF.

	That is not an edge case, it is most of a city map. A ring sample taken at a
	survivor's own height beside a two-storey building resolved to the top of the
	building, the body was placed there, and the players saw zombies standing in
	the air on rooftops that then never reached them. It also explains a Jockey
	steering toward a ledge overhead and a Spitter pooling acid on a roof: every
	one of the seven callers wants the floor under a point, and every one of them
	could be handed something above it instead.

	So the parameter now means what its callers always assumed: how far DOWN to
	look. The rise above is a separate, small clearance — enough that a point
	sunk into a kerb or a node a designer pushed into the floor still finds the
	surface it is sitting in, and far too little to reach a roof.

	── WHAT THIS CANNOT DO ─────────────────────────────────────────────────────
	It still cannot tell a street from the roof of a low shed the point happens
	to be standing on, because from a downward ray those are the same reading.
	Nothing about a raycast can. That question is "can a body walk from here to
	the team", and it belongs to the caller — SpawnPlacement answers a cheap
	approximation of it with a height band against the nearest survivor.

	Reuses one params object, on the same reasoning as sightParams above: every
	spawn attempt in the placement ladder calls this — three relaxation passes
	times a dozen candidates each — and a fresh RaycastParams per call is garbage
	generated at exactly the moment a horde is being placed.
]]
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = false

--[[ How far above the point the cast begins when the caller does not say. Sized
     for a point embedded in the surface it belongs to — a kerb, a sunk part, a
     node dragged a little into the floor — and deliberately far below one
     storey, so a roof can never answer a question about a street. ]]
local DEFAULT_RISE = 10

function RaycastUtil.groundAt(
	position: Vector3,
	searchDepth: number,
	ignoreList: { Instance },
	riseAbove: number?
): (Vector3?, Vector3?)
	local rise = riseAbove or DEFAULT_RISE
	local from = position + Vector3.new(0, rise, 0)
	groundParams.FilterDescendantsInstances = ignoreList
	local result = workspace:Raycast(from, Vector3.new(0, -(rise + searchDepth), 0), groundParams)
	if not result then
		return nil, nil
	end
	return result.Position, result.Normal
end

return RaycastUtil
