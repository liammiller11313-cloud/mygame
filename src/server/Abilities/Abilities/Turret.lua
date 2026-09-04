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

local AbilityAssets = require(Shared.Util.AbilityAssets)
local AbilitySupport = require(script.Parent.Parent.AbilitySupport)

--[[ The folder name under Assets/Abilities. The enum id, so a model named for
     the ability is found without a second table mapping one to the other. ]]
local TURRET_ASSET = Enums.Ability.Turret

local Turret = {}

--[[ How far above the ground the procedural barrel sits. Only the grey-box
     body uses it; a supplied model brings its own geometry. ]]
local BARREL_HEIGHT = 3.0

--[[ Half the procedural base's height, so its underside lands exactly on the
     floor deploy found. The supplied model matches it by bounding box rather
     than by this number — see buildSupplied — but both end up resting ON the
     ground rather than sunk into it or hovering over it. ]]
local GROUND_LIFT = 0.4

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
	--[[ What actually swings, which is NOT always `head`. A supplied `gun` can
	     be a Model of several parts; rotating the one BasePart `head` resolved
	     to would leave the rest of the barrel behind. Pivoted rather than
	     CFramed, so a PivotOffset set at the model's rotation joint is
	     honoured. ]]
	aim: PVInstance,
	--[[ Where shots leave from, or nil when the model did not supply one. See
	     `fire`: nil is a fallback rather than a fault. ]]
	muzzle: Attachment?,
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

--[[
	The supplied model, if there is one.

	ReplicatedStorage/Assets/Abilities/Turret, with `gun` as the part that swings
	and an Attachment named `Muzzle` at the end of the barrel. Both are optional
	and each degrades on its own: no `gun` and the model sits still, no `Muzzle`
	and shots leave from the gun's own position. A model that is only geometry
	still deploys and still shoots.

	Returns the same four things the procedural body below does — the model, the
	part it stands on, the part shots leave from, and the thing that swings — so
	nothing downstream knows which one it got. The last two are separate because
	a supplied `gun` can be a Model: the whole Model turns, while a single part
	inside it is where the muzzle and the line-of-sight test live.
]]
local function buildSupplied(position: Vector3, facing: Vector3): (Model?, BasePart?, BasePart?, PVInstance?)
	local template = AbilityAssets.find(TURRET_ASSET)
	if not template then
		return nil, nil, nil, nil
	end
	local clone = template:Clone()

	--[[ Anchored and non-colliding throughout. A turret that can be walked into
	     blocks the doorway it is defending, and an unanchored one gets shoved
	     down a stairwell by the first Charger. ]]
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
		end
	end

	local baseChild = clone:FindFirstChild("base", true)
	local gunChild = clone:FindFirstChild("gun", true)
	local root = if baseChild and baseChild:IsA("BasePart")
		then baseChild :: BasePart
		else clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
	if not root then
		--[[ No BasePart anywhere. Rather than guess, fall through to the
		     procedural body: this is not a model that can be placed. ]]
		clone:Destroy()
		return nil, nil, nil, nil
	end
	clone.PrimaryPart = root
	--[[ Renamed to match the grey-box body. Nothing looks a turret up by name,
	     but a Workspace with three things called "Turret" in it — the deployed
	     ones and whatever the model was dragged out of — is a Workspace nobody
	     can read. ]]
	clone.Name = "FL_Turret"

	--[[ Seated through the shared helper, which is the SAME call the placement
	     ghost makes — so where the preview stood is where the turret stands. A
	     supplied model can be any size and any of its parts can be the lowest
	     one, so its underside is measured rather than assumed. ]]
	AbilityAssets.seat(clone, position - Vector3.new(0, GROUND_LIFT, 0), facing)

	clone.Parent = Workspace

	--[[ Resolved once here so the step loop never has to ask what `gun` was.
	     `head` is a part — where the muzzle hangs and where sight lines are
	     traced from — and `aim` is whatever has to turn to point it, which for a
	     multi-part gun is the Model rather than the part. ]]
	local head: BasePart? = nil
	local aim: PVInstance? = nil
	if gunChild and gunChild:IsA("BasePart") then
		head = gunChild :: BasePart
		aim = gunChild :: BasePart
	elseif gunChild and gunChild:IsA("Model") then
		head = (gunChild :: Model).PrimaryPart or gunChild:FindFirstChildWhichIsA("BasePart", true)
		aim = gunChild :: Model
	end

	--[[ A model with no `gun` still deploys. It stands still and shoots from its
	     base, which looks wrong but plays correctly — better than refusing a
	     model somebody has already placed in the game. ]]
	return clone, root, head or root, aim or head or root
end

--[[ A procedural body, for a place where nobody has supplied a model. Same
     reason the specials have placeholder rigs: the ability has to be playable
     on a fresh install, and a supplied model is an upgrade rather than a
     prerequisite. ]]
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
	--[[ From the barrel, not from the middle of the gun. `Muzzle` is an
	     Attachment the model may supply; without one the gun's own position is
	     the honest fallback, and the tracer simply starts a little further back
	     than it should rather than not being drawn. ]]
	local origin = if turret.muzzle then turret.muzzle.WorldPosition else turret.head.Position

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

	--[[ Where the player put it. AbilityService has already validated the point
	     and clamped it to the ability's range, so this is a spot they chose
	     rather than a spot the game chose for them — which is the whole reason
	     the turret is a targeted ability. ]]
	local wanted = context.target

	--[[ Dropped to the floor rather than left at whatever height the ray hit.
	     groundAt is the same helper the Director uses to keep a spawn out of the
	     geometry, so a turret placed on a staircase sits on the stair. ]]
	local ground = RaycastUtil.groundAt(wanted, 12, { character })
	if not ground then
		return false
	end

	--[[ Facing away from the player who placed it. You put a turret down to
	     cover the direction you are looking, and turning it to face you would be
	     wrong every single time. ]]
	local heading = Vector3.new(ground.X - root.Position.X, 0, ground.Z - root.Position.Z)
	local facing = if heading.Magnitude > 0.05 then heading.Unit else root.CFrame.LookVector
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	facing = if flatFacing.Magnitude > 0.05 then flatFacing.Unit else Vector3.zAxis

	--[[ The player's model first, the grey box second. Nothing after this line
	     knows which one it got. ]]
	local at = ground + Vector3.new(0, GROUND_LIFT, 0)
	local model, base, head, aim = buildSupplied(at, facing)
	if not model or not base or not head or not aim then
		model, base, head = build(at, facing)
		aim = head
	end
	table.insert(turrets, {
		player = player,
		model = model,
		root = base,
		head = head,
		aim = aim,
		muzzle = head:FindFirstChild("Muzzle") :: Attachment?,
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

		--[[
			Aimed every frame even between shots, so the barrel tracks rather than
			snapping at the moment it fires. It is the only thing that makes a
			static box read as a machine paying attention.

			YAW ONLY. A supplied model's gun is a child sitting on a base, and
			pitching it at a Common's chest three studs away would tip the whole
			assembly onto its face. Real emplacements traverse; they do not roll
			over. The flat heading also keeps the muzzle at a sane height, which
			is what the tracer is drawn from.
		]]
		local flat = Vector3.new(
			targetRoot.Position.X - turret.head.Position.X,
			0,
			targetRoot.Position.Z - turret.head.Position.Z
		)
		if flat.Magnitude > 0.05 then
			local at = turret.aim:GetPivot().Position
			turret.aim:PivotTo(CFrame.lookAt(at, at + flat.Unit))
		end

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
