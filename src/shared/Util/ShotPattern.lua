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

local GameConfig = require(script.Parent.Parent.Config.GameConfig)

local RECOIL = GameConfig.Recoil

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

	--[[ Where in the burst this shot is. WeaponController resets the index after
	     0.35s of not firing, so "shot 1" means "the first round of this burst"
	     rather than "the first round since you spawned". A melee swing passes 0
	     and is floored to 1. ]]
	local index = math.max(math.floor(shotIndex), 1)

	--[[ The ramp. See GameConfig.Recoil: this is what makes a burst a shape and
	     tapping worth doing, and it is the piece that was missing — the index was
	     being passed in and thrown away on the seed. ]]
	local climb = RECOIL.FirstShotScale
		+ (1 - RECOIL.FirstShotScale) * math.min((index - 1) / RECOIL.ClimbShots, 1)

	--[[
		And then it comes back down.

		The ramp alone was the whole curve, which meant a weapon kicked at full
		strength for every round after the seventh — a constant climb rate for as
		long as the trigger is held. Past SettleShots the vertical decays toward
		SustainScale, so a long spray flattens out and the horizontal sweep below
		becomes the thing that is actually moving.

		Only the VERTICAL settles. Horizontal keeps its full scale, which is what
		turns a plateau into a sideways walk rather than into a gun that has
		stopped doing anything.
	]]
	local settle = 1
	if index > RECOIL.SettleShots then
		local through = math.min((index - RECOIL.SettleShots) / RECOIL.SettleFalloff, 1)
		settle = 1 + (RECOIL.SustainScale - 1) * through
	end

	--[[ Vertical is mostly consistent so the pattern can be countered. The window
	     is tighter than it was because the climb now carries the character, and
	     wide per-shot noise on top of a ramp reads as the sight rattling rather
	     than as the gun pulling. ]]
	local verticalKick = vertical * climb * settle * random:NextNumber(0.88, 1.12)

	--[[ Horizontal is a slow sweep plus noise. The sweep is a pure function of the
	     burst index, so it is identical every burst and a player can learn to ride
	     it; the noise is what stops it being pre-aimable. ]]
	local drift = math.sin((index - 1) * (math.pi * 2 / RECOIL.DriftPeriod))
	local horizontalKick = horizontal
		* climb
		* (RECOIL.HorizontalDrift * drift + (1 - RECOIL.HorizontalDrift) * random:NextNumber(-1, 1))
	return verticalKick, horizontalKick
end

return ShotPattern
