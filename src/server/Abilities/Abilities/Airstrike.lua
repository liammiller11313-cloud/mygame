--!nonstrict
--[[
	Airstrike — marks a spot, and everything standing on it stops standing.

	── THE WARNING IS THE BALANCE ──────────────────────────────────────────────
	Two and a half seconds of a marker on the ground before the first shell
	lands, and that window is the whole of what makes 260 damage fair. It is long
	enough that a Tank walks out of it, which is why the answer to a Tank is
	still a Tank's answer; long enough that a Common horde walks INTO it, which
	is what it is actually for; and long enough that a team standing on the spot
	has been told.

	── AND THE SHELLS WALK ─────────────────────────────────────────────────────
	Five explosions over SpreadTime rather than five at once. One big blast is a
	number appearing; five landing across a second is a thing happening to a
	place, and the stagger means something that survived the first has a moment
	to be somewhere worse for the second.

	── TEAMMATES ARE SAFE BECAUSE THE CALLER IS THE ATTACKER ───────────────────
	Every explosion carries `attacker = the player who called it`. DamageService
	refuses survivor damage from another survivor unless
	GameConfig.Survivor.FriendlyFireEnabled says otherwise — so friendly fire is
	governed by the one switch that already governs it everywhere else, and this
	file does not get an opinion. Turn that on and an airstrike hurts the team,
	which is correct.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Types = require(Shared.Types)

local AbilitySupport = require(script.Parent.Parent.AbilitySupport)

local Airstrike = {}

--[[ How far off the marked point a shell may land, as a fraction of the blast
     radius. The pattern is a scatter rather than a stack: five craters in the
     same hole is one crater. ]]
local SCATTER = 0.75

type Pending = {
	player: Player,
	position: Vector3,
	radius: number,
	damage: number,
	remaining: number,
	nextAt: number,
	interval: number,
	random: Random,
}

local pending: { Pending } = {}

local function detonate(shot: Pending)
	local offset = Vector3.new(shot.random:NextNumber(-1, 1), 0, shot.random:NextNumber(-1, 1))
		* shot.radius
		* SCATTER
	local at = shot.position + offset

	local damage: any = Registry.find("DamageService")
	if damage and typeof(damage.applyExplosion) == "function" then
		damage:applyExplosion(
			at,
			shot.radius,
			shot.damage,
			Types.newDamageContext({
				--[[ The caller, and this is what keeps the team safe: see the
				     header. It is also what makes the kills theirs, which is the
				     other half of paying three thousand dollars for it. ]]
				attacker = shot.player,
				damageType = Enums.DamageType.Explosive,
				region = Enums.HitRegion.Torso,
				hitPosition = at,
				direction = Vector3.yAxis,
			})
		)
	end

	AbilitySupport.broadcast("Explosion", {
		id = Enums.Ability.Airstrike,
		position = at,
		radius = shot.radius,
	})
end

function Airstrike.activate(context: any): boolean
	local tuning = context.tuning
	local count = math.max(math.floor(tuning.NumberOfExplosions), 1)

	table.insert(pending, {
		player = context.player,
		position = context.target,
		radius = tuning.Radius,
		damage = tuning.Damage,
		remaining = count,
		nextAt = os.clock() + tuning.WarningTime,
		--[[ Spread across SpreadTime, or all at the same instant if somebody
		     tunes it to one shell. Dividing by count-1 rather than count so the
		     last shell lands ON the end of the window rather than before it. ]]
		interval = if count > 1 then tuning.SpreadTime / (count - 1) else 0,
		random = Random.new(),
	})

	--[[ The marker goes out NOW, which is the point of the ability. Everything
	     after this is on a clock the whole server can see coming. ]]
	AbilitySupport.broadcast("Marker", {
		id = context.definition.id,
		player = context.player,
		position = context.target,
		radius = tuning.Radius,
		warning = tuning.WarningTime,
	})
	return true
end

function Airstrike.step(_dt: number)
	local now = os.clock()
	for index = #pending, 1, -1 do
		local shot = pending[index]
		--[[ A caller who left mid-strike still gets their strike. The shells are
		     already in the air as far as the fiction is concerned, and cancelling
		     them would be a way to un-kill a horde by disconnecting. ]]
		while shot.remaining > 0 and now >= shot.nextAt do
			detonate(shot)
			shot.remaining -= 1
			shot.nextAt += shot.interval
			--[[ With interval 0 every remaining shell is due on this same frame,
			     which is correct — but the loop would then spin through all of
			     them here, which is also correct and is why the guard is on
			     `remaining` rather than on time alone. ]]
		end
		if shot.remaining <= 0 then
			table.remove(pending, index)
		end
	end
end

function Airstrike.clear()
	table.clear(pending)
end

return Airstrike
