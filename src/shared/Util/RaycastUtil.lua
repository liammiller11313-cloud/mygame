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
	Drops a point onto the ground beneath it, returning the surface position and
	normal. Spawn placement uses this so an infected never appears half-buried in
	a floor or hovering a stud above it.
]]
function RaycastUtil.groundAt(
	position: Vector3,
	searchHeight: number,
	ignoreList: { Instance }
): (Vector3?, Vector3?)
	local from = position + Vector3.new(0, searchHeight, 0)
	local result =
		workspace:Raycast(from, Vector3.new(0, -(searchHeight * 2), 0), RaycastUtil.excluding(ignoreList))
	if not result then
		return nil, nil
	end
	return result.Position, result.Normal
end

return RaycastUtil
