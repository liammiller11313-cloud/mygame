--!strict
--[[
	PogoCore — the shared maths behind every pogo weapon in Brickbattler's Pack.

	── WHY THIS EXISTS ──────────────────────────────────────────────────────────
	The pogo used to live three times over: SlingshotPogo, PogoClient and
	PogoServer each carried their own copy of the tuning and their own copy of
	the launch maths. The copies had already drifted — the rocket's cooldown was
	0.28 on the client and 0.25 on the server, which means the server was the
	MORE permissive of the two and the client's limit was decoration.

	Both halves now call the same three functions with the same numbers, so a
	client prediction and the server's verdict cannot disagree by accident. When
	they do disagree it is because the server saw something the client did not,
	which is the only reason they ever should.

	── WHAT IS NOT CHANGED ──────────────────────────────────────────────────────
	The feel. Every constant below is the one from the original scripts, down to
	the 0.25 UP_BIAS. In particular the stacking still compounds on top of
	whatever upward velocity you already have, so a full twelve-stack chain still
	throws you most of a kilometre into the air. That is the mechanic, not a bug,
	and nothing here caps it — `maxUpSpeed` is 0 (off) on both profiles and is
	there only for a game that needs a ceiling for its own reasons.

	What changed is WHO IS ALLOWED to ask for one. See PogoServer.
]]

local PogoCore = {}

export type Profile = {
	name: string,

	baseBoost: number, -- the first launch of a chain
	stackStep: number, -- added per stack after the first
	maxStacks: number,
	stackTimeout: number, -- a chain this quiet resets to one stack
	cooldown: number,

	minDistance: number,
	maxRange: number,
	--[[ How far BELOW the player the hit has to be. The slingshot is a
	     stomp — you shoot the floor and go up — so it demands a downward hit.
	     The rocket is directional and takes any angle, so it asks for nothing. ]]
	requireBelow: number,

	--[[ Directional launch. The slingshot ignores these and goes straight up,
	     which is what `directional` selects between. ]]
	directional: boolean,
	horizontalMult: number,
	verticalMult: number,
	upBias: number,

	maxUpSpeed: number, -- 0 = uncapped, which is the pack default
	sfxId: number,
}

--[[ The server is deliberately LOOSER than the client on every bound it shares.

     The client predicts the launch so it feels instant, then asks the server to
     agree. If the server's window were the tighter one, a player who moved half
     a stud between raycasting and the packet arriving would be refused for
     playing correctly — and a refusal yanks them back down. Slack here is what
     keeps that from happening; it costs an exploiter nothing they did not
     already have, because the checks that matter are not bounds. ]]
PogoCore.ServerSlack = 1.35

PogoCore.Profiles = {
	Slingshot = {
		name = "Slingshot",
		baseBoost = 60,
		stackStep = 18,
		maxStacks = 12,
		stackTimeout = 1.75,
		cooldown = 0.12,
		minDistance = 0,
		maxRange = 60,
		requireBelow = 0.5,
		directional = false,
		horizontalMult = 0,
		verticalMult = 1.0,
		upBias = 0,
		maxUpSpeed = 0,
		sfxId = 9111926008,
	} :: Profile,

	Rocket = {
		name = "Rocket",
		baseBoost = 120,
		stackStep = 0, -- the rocket does not stack; its power is the whole shot
		maxStacks = 1,
		stackTimeout = 0,
		cooldown = 0.28,
		minDistance = 2,
		maxRange = 50,
		requireBelow = 0,
		directional = true,
		horizontalMult = 0.85,
		verticalMult = 1.0,
		upBias = 0.25,
		maxUpSpeed = 0,
		sfxId = 7106659874,
	} :: Profile,
}

--[[ Which profile a tool uses, read from a `PogoProfile` attribute so one pair
     of scripts serves every weapon in the pack. An unset or unknown attribute
     falls back to Rocket rather than erroring: a tool that pogos slightly wrong
     is a bug report, and a tool that throws on equip is a broken pack. ]]
function PogoCore.profileFor(tool: Instance): Profile
	local name = tool:GetAttribute("PogoProfile")
	if typeof(name) == "string" and PogoCore.Profiles[name] then
		return PogoCore.Profiles[name]
	end
	return PogoCore.Profiles.Rocket
end

--[[ Is this a direction a launch could legitimately come from?

     Separated out because it is the check both halves run and the one an
     exploiter's packet fails first. NaN is tested explicitly: `d ~= d` is the
     only reliable NaN test in Luau, and a NaN direction normalises to a NaN
     unit vector that puts a character at an undefined position. ]]
function PogoCore.validDirection(direction: any): boolean
	if typeof(direction) ~= "Vector3" then
		return false
	end
	local d = direction :: Vector3
	if d.X ~= d.X or d.Y ~= d.Y or d.Z ~= d.Z then
		return false
	end
	return d.Magnitude > 1e-3
end

--[[
	The ONE raycast. Both halves run it, from the character's own root, along a
	direction — never to a position.

	That distinction is the whole security model. The original scripts sent the
	client's HIT POSITION to the server, and the server's only question was
	whether that point was 2 to 50 studs away. A client that made the number up
	got launched, every time, with no weapon and no ground involved. A direction
	cannot be faked usefully, because the server casts it against its own copy of
	the world and finds out for itself what is there.

	Returns nil when nothing is hit. Nothing hit means no launch — there is no
	fallback that invents a point below the player, which is what the original
	`findBelowPoint` did on its third attempt and why it could fly with no floor
	anywhere in the map.
]]
function PogoCore.cast(root: BasePart, direction: Vector3, profile: Profile, slack: number?): Vector3?
	local character = root.Parent
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local reach = profile.maxRange * (slack or 1)
	local result = workspace:Raycast(root.Position, direction.Unit * reach, params)
	if not result then
		return nil
	end
	return result.Position
end

--[[ Whether a hit the cast actually found is one this profile launches from. ]]
function PogoCore.hitIsLegal(root: BasePart, hit: Vector3, profile: Profile, slack: number?): boolean
	local give = slack or 1
	local delta = hit - root.Position
	local distance = delta.Magnitude

	if distance < profile.minDistance / give or distance > profile.maxRange * give then
		return false
	end
	if profile.requireBelow > 0 and delta.Y > -(profile.requireBelow / give) then
		return false
	end
	return true
end

--[[ How hard this launch pushes, given how many are already in the chain. ]]
function PogoCore.boostFor(stacks: number, profile: Profile): number
	local n = math.clamp(stacks, 1, profile.maxStacks)
	return profile.baseBoost + (n - 1) * profile.stackStep
end

--[[
	Which way it throws you.

	Straight up for the slingshot. For the rocket, away from what you hit, which
	is what makes shooting the wall behind you a move: horizontal at 0.85 so the
	pushback reads without launching you across the map, vertical clamped at zero
	so a shot from above never drives you into the floor, and a flat 0.25 of up
	on top so every rocket jump gets off the ground.
]]
function PogoCore.launchDirection(root: BasePart, hit: Vector3, profile: Profile): Vector3
	if not profile.directional then
		return Vector3.yAxis
	end

	local delta = root.Position - hit
	if delta.Magnitude < 1e-3 then
		return Vector3.yAxis
	end
	local away = delta.Unit

	local flat = Vector3.new(away.X, 0, away.Z)
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zero

	local up = math.max(away.Y, 0) * profile.verticalMult + profile.upBias
	local final = Vector3.new(flat.X * profile.horizontalMult, up, flat.Z * profile.horizontalMult)
	if final.Magnitude < 1e-3 then
		return Vector3.yAxis
	end
	return final.Unit
end

--[[
	Applies the launch.

	`math.max(v.Y, 0)` is the line that makes the whole mechanic work and it is
	worth not losing: it throws away downward velocity before adding the boost,
	so a pogo caught on the way down launches exactly as hard as one from a
	standstill. Without it a chain fights its own fall and dies out.

	The Jumping state change comes first because a grounded Humanoid applies
	standing friction that eats a velocity write in the same frame.
]]
function PogoCore.apply(
	root: BasePart,
	humanoid: Humanoid,
	direction: Vector3,
	power: number,
	profile: Profile
)
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

	local v = root.AssemblyLinearVelocity
	local launch = direction * power
	local y = math.max(v.Y, 0) + launch.Y
	if profile.maxUpSpeed > 0 then
		y = math.min(y, profile.maxUpSpeed)
	end
	root.AssemblyLinearVelocity = Vector3.new(v.X + launch.X, y, v.Z + launch.Z)
end

return PogoCore
