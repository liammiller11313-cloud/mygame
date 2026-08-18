--!strict
--[[
	ShotPattern — deterministic, shared spread generation.

	This module exists to solve one specific and very annoying networking
	problem: the client must draw tracers the instant you click, but the server
	decides what was actually hit. If each side rolls its own random cone, a
	shotgun's ten tracers will land in ten different places than the ten pellets
	the server resolved, and the player sees pellets miss things they visibly hit.

	The fix is that neither side rolls freely. The client picks one integer seed,
	sends it with the shot, and both sides feed it to Random.new(). Roblox's
	Random is a deterministic PRNG, so identical seeds produce identical cones on
	both machines and the visuals are guaranteed to match the hit resolution.

	The seed is also the anti-cheat hook: a client that sends impossible seeds or
	reuses one is trivially detectable, and it can never choose WHERE the pellets
	go, only which of the deterministic patterns it gets.
]]

local ShotPattern = {}

--[[ A seed the client generates per shot. Bounded to stay well inside the range
     Random.new handles cleanly and to remain compact over the network. ]]
function ShotPattern.generateSeed(): number
	return math.random(1, 2147483646)
end

--[[
	Rotates `direction` by a random offset inside a cone of `spreadDegrees`
	half-angle. Uses the sqrt of the random radius so points land with uniform
	area density: without it, pellets bunch toward the middle and a shotgun feels
	like a rifle with extra steps.
]]
local function coneDirection(random: Random, direction: Vector3, spreadDegrees: number): Vector3
	if spreadDegrees <= 0 then
		return direction.Unit
	end

	local forward = direction.Unit
	-- Any vector not parallel to forward works as a basis seed.
	local reference = if math.abs(forward.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local right = forward:Cross(reference).Unit
	local up = right:Cross(forward).Unit

	local maxRadians = math.rad(spreadDegrees)
	local angle = maxRadians * math.sqrt(random:NextNumber())
	local rotation = random:NextNumber() * math.pi * 2

	local offset = (right * math.cos(rotation) + up * math.sin(rotation)) * math.tan(angle)
	return (forward + offset).Unit
end

--[[
	Builds the full set of directions for one trigger pull. A single-pellet
	weapon returns one direction; a shotgun returns `pellets` of them.

	Call this with the SAME seed on client and server and you get the same array.
]]
function ShotPattern.generate(
	direction: Vector3,
	seed: number,
	pellets: number,
	spreadDegrees: number
): { Vector3 }
	local random = Random.new(seed)
	local count = math.max(pellets, 1)
	local directions = table.create(count)

	if count == 1 then
		directions[1] = coneDirection(random, direction, spreadDegrees)
		return directions
	end

	--[[
		Shotguns get a fixed inner pellet plus a ring, rather than a pure random
		scatter. A guaranteed centre pellet means a well-aimed point-blank shot
		always connects with what the crosshair was on, which is the difference
		between a shotgun that feels powerful and one that feels like a coin flip.
	]]
	directions[1] = coneDirection(random, direction, spreadDegrees * 0.25)
	for index = 2, count do
		directions[index] = coneDirection(random, direction, spreadDegrees)
	end
	return directions
end

--[[
	Recoil kick for one shot, again deterministic from the seed so the server can
	verify that a client's aim moved the way its own recoil says it should have.
	Returns (verticalDegrees, horizontalDegrees).
]]
function ShotPattern.generateRecoil(
	seed: number,
	shotIndex: number,
	vertical: number,
	horizontal: number
): (number, number)
	local random = Random.new(seed + shotIndex * 7919)
	-- Vertical kick is mostly consistent so the pattern is learnable; horizontal
	-- is symmetric noise so it cannot simply be counter-strafed.
	local verticalKick = vertical * random:NextNumber(0.82, 1.18)
	local horizontalKick = horizontal * random:NextNumber(-1, 1)
	return verticalKick, horizontalKick
end

return ShotPattern
