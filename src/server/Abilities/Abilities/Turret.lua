--!nonstrict
--[[
	Turret — drops a gun that watches an angle you cannot.

	── WHAT IT IS FOR ──────────────────────────────────────────────────────────
	14 damage three times a second is 42 a second: a Common in just over a
	second, and almost nothing to a Tank. That is deliberate and it is the whole
	shape of the ability — a turret holds a corridor against the horde and is
	never the answer to a boss. A team that drops one to solve a Tank has spent
	forty-five seconds of cooldown on a distraction, which is a fair thing to
	learn once.

	── IT DIES TO THE HORDE, NOT TO A TIMER ALONE ──────────────────────────────
	A lifetime AND health, and the health is what makes placement a decision. It
	is chewed by anything standing next to it rather than by the infected AI
	targeting it: the brain is built to chase survivors and teaching forty
	zombies to path to a new kind of object would be a change to the horde for
	the sake of one ability. Proximity damage gets the same outcome — a turret in
	the middle of a crowd does not last — without touching a system the whole
	game rests on.

	── AND IT SHOOTS THROUGH THE REAL DAMAGE PATH ──────────────────────────────
	Every shot goes through DamageService with the owner as the attacker, so a
	turret kill is that player's kill, feeds their round tally, respects
	resistances, and gibs the way anything else does. It is not a special case
	anywhere downstream.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Enums = require(Shared.Enums)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)
local UITheme = require(Shared.Config.UITheme)

local AbilitySupport = require(script.Parent.Parent.AbilitySupport)

local Turret = {}

--[[ How far in front of the player it lands, and how far above the ground the
     barrel sits. Placed rather than dropped at the feet so it never spawns
     inside the person deploying it. ]]
local PLACE_AHEAD = 5.5
local BARREL_HEIGHT = 3.0

--[[ How far a body has to be to start chewing on it, and how fast. 14 a second
     means four Commons take it apart in about four seconds, which is roughly
     how long a badly placed turret deserves. ]]
local MAUL_RADIUS = 7.0
local MAUL_PER_SECOND = 14

--[[ How often it looks for something to shoot, as opposed to how often it
     FIRES. Re-scanning per shot would make its rate of fire the rate it does
     work at; four times a second is faster than anything can cross its range. ]]
local SCAN_INTERVAL = 0.25

type Emplacement = {
	player: Player,
	model: Model,
	root: BasePart,
	head: BasePart,
	health: number,
	maxHealth: number,
	expiresAt: number,
	nextShotAt: number,
	nextScanAt: number,
	target: Model?,
	ignore: { Instance },
}

--[[ This ability's own numbers, resolved once. The step below runs every frame
     for every live turret, and reaching back through the config on each of them
     is a table walk per turret per frame for a value that cannot change. ]]
local TUNING = AbilityConfig.get(Enums.Ability.Turret).tuning

local turrets: { Emplacement } = {}

local function countFor(player: Player): number
	local total = 0
	for _, turret in turrets do
		if turret.player == player then
			total += 1
		end
	end
	return total
end

--[[ A procedural body rather than an asset, for the same reason the specials
     have placeholder rigs: it must exist and be readable on a server where
     nobody has uploaded a turret model, and a supplied one can be dressed over
     it later. ]]
local function build(position: Vector3, facing: Vector3): (Model, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = "FL_Turret"

	local base = Instance.new("Part")
	base.Name = "Base"
	base.Size = Vector3.new(2.6, 0.8, 2.6)
	base.Color = UITheme.Color.Border
	base.Material = Enum.Material.Metal
	base.Anchored = true
	base.CanCollide = true
	base.CanQuery = false
	base.CastShadow = false
	base.CFrame = CFrame.new(position)
	base.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.1, 1.1, 3.2)
	head.Color = UITheme.Color.Accent
	head.Material = Enum.Material.Metal
	head.Anchored = true
	head.CanCollide = false
	head.CanQuery = false
	head.CastShadow = false
	head.CFrame = CFrame.lookAt(position + Vector3.new(0, BARREL_HEIGHT, 0), position + facing)
	head.Parent = model

	local light = Instance.new("PointLight")
	light.Color = UITheme.Color.Accent
	light.Range = 12
	light.Brightness = 1.2
	light.Shadows = false
	light.Parent = head

	model.PrimaryPart = base
	model.Parent = Workspace
	return model, base, head
end

local function retire(turret: Emplacement, index: number, destroyed: boolean)
	if turret.model.Parent then
		turret.model:Destroy()
	end
	table.remove(turrets, index)
	AbilitySupport.broadcast("TurretDown", {
		player = turret.player,
		position = turret.root.Position,
		destroyed = destroyed,
	})
end

local function fire(turret: Emplacement, target: Model, targetRoot: BasePart, damage: number)
	local origin = turret.head.Position
	turret.head.CFrame = CFrame.lookAt(origin, targetRoot.Position)

	local infected: any = Registry.find("InfectedService")
	if infected and typeof(infected.damage) == "function" then
		local delta = targetRoot.Position - origin
		local distance = delta.Magnitude
		infected:damage(
			target,
			damage,
			Types.newDamageContext({
				--[[ The OWNER, not the turret. A turret kill is that player's
				     kill everywhere downstream: their round tally, their quest
				     progress, their kill feed. ]]
				attacker = turret.player,
				damageType = Enums.DamageType.Bullet,
				region = Enums.HitRegion.Torso,
				hitPosition = targetRoot.Position,
				hitNormal = -(if distance > 0.05 then delta.Unit else Vector3.zAxis),
				direction = if distance > 0.05 then delta.Unit else Vector3.zAxis,
				distance = distance,
			})
		)
	end

	--[[ It sounds like the LMG, because that is what it is: a belt-fed gun on a
	     tripod. Borrowing a real WeaponFire row rather than adding one means the
	     turret inherits the rolloff and the voice budget every other gun in the
	     game is mixed against, instead of being the one thing that ignores
	     them. ]]
	local audio: any = Registry.find("AudioService")
	if audio and typeof(audio.play) == "function" then
		pcall(audio.play, audio, "WeaponFire", Enums.Weapon.M249, turret.head)
	end

	AbilitySupport.broadcast("TurretShot", { origin = origin, hit = targetRoot.Position })
end

--[[ The nearest living infected this turret can actually see. Line of sight
     tested from the barrel, so a turret behind a wall does not shoot through
     it — placement being a real decision depends on that being true. ]]
local function acquire(turret: Emplacement, range: number): (Model?, BasePart?)
	local best: Model? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = math.huge

	for _, entry in AbilitySupport.infectedWithin(turret.head.Position, range) do
		if entry.distance >= bestDistance then
			continue
		end
		turret.ignore[2] = entry.model
		local clear = RaycastUtil.hasLineOfSight(turret.head.Position, entry.root.Position, turret.ignore)
		turret.ignore[2] = nil
		if clear then
			best, bestRoot, bestDistance = entry.model, entry.root, entry.distance
		end
	end
	return best, bestRoot
end

function Turret.activate(context: any): boolean
	local player = context.player
	local tuning = context.tuning

	if countFor(player) >= tuning.MaximumActiveTurrets then
		--[[ False rather than replacing the old one. Silently deleting a turret
		     the player is standing behind is worse than telling them no, and the
		     refusal costs them no cooldown — see AbilityService. ]]
		return false
	end

	local character = player.Character
	local root = if character then RigUtil.getRoot(character) else nil
	if not root then
		return false
	end

	local facing = root.CFrame.LookVector
	local flat = Vector3.new(facing.X, 0, facing.Z)
	facing = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis

	--[[ Dropped to the floor in front of the player rather than placed at their
	     eye height. groundAt is the same helper the Director uses to keep a
	     spawn out of the geometry, so a turret on a staircase sits on the stair. ]]
	local wanted = root.Position + facing * PLACE_AHEAD
	local ground = RaycastUtil.groundAt(wanted, 12, { character })
	if not ground then
		return false
	end

	local model, base, head = build(ground + Vector3.new(0, 0.4, 0), facing)
	table.insert(turrets, {
		player = player,
		model = model,
		root = base,
		head = head,
		health = tuning.Health,
		maxHealth = tuning.Health,
		expiresAt = os.clock() + tuning.Lifetime,
		nextShotAt = 0,
		nextScanAt = 0,
		target = nil,
		ignore = { model },
	})

	AbilitySupport.broadcast("TurretUp", {
		id = context.definition.id,
		player = player,
		position = base.Position,
		lifetime = tuning.Lifetime,
	})
	return true
end

function Turret.step(dt: number)
	local now = os.clock()

	for index = #turrets, 1, -1 do
		local turret = turrets[index]

		if now >= turret.expiresAt or not turret.model.Parent then
			retire(turret, index, false)
			continue
		end

		--[[ Chewed by anything standing on it. See the header: this is what
		     gives Health a meaning without teaching the horde a new target. ]]
		local crowd = #AbilitySupport.infectedWithin(turret.root.Position, MAUL_RADIUS)
		if crowd > 0 then
			turret.health -= MAUL_PER_SECOND * crowd * dt
			if turret.health <= 0 then
				retire(turret, index, true)
				continue
			end
		end

		if now >= turret.nextScanAt then
			turret.nextScanAt = now + SCAN_INTERVAL
			turret.target = acquire(turret, TUNING.Range)
		end

		local target = turret.target
		if not target or not target.Parent or not RigUtil.isAlive(target) then
			turret.target = nil
			continue
		end
		local targetRoot = RigUtil.getRoot(target)
		if not targetRoot then
			turret.target = nil
			continue
		end

		--[[ Aimed every frame even between shots, so the barrel tracks rather
		     than snapping at the moment it fires. It is the only thing that makes
		     a static box read as a machine that is paying attention. ]]
		turret.head.CFrame = CFrame.lookAt(turret.head.Position, targetRoot.Position)

		if now >= turret.nextShotAt then
			turret.nextShotAt = now + 1 / math.max(TUNING.FireRate, 0.01)
			fire(turret, target, targetRoot, TUNING.Damage)
		end
	end
end

function Turret.clear()
	for index = #turrets, 1, -1 do
		local turret = turrets[index]
		if turret.model.Parent then
			turret.model:Destroy()
		end
		table.remove(turrets, index)
	end
end

return Turret
