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

	── SIT IN IT AND IT IS YOURS ───────────────────────────────────────────────
	Empty, it picks the nearest thing it can see and shoots that. In the seat, you
	pick — and picking is the entire value, because the automatic gun will always
	shoot the Common two studs in front of it rather than the Smoker on the roof
	that has your teammate. Manned it also runs half again as fast.

	What it costs is everything a stationary player costs: your own weapon is put
	away, you cannot move, and every body in the map is walking toward the noise.

	── IT DIES TO THE HORDE, NOT TO A TIMER ALONE ──────────────────────────────
	A lifetime AND health, and the health is what makes placement a decision.

	The horde attacks it, properly: bodies within AggroRadius break off and swing
	at it with the same windup, the same cooldown and the same damage they would
	spend on a person. That is a real change to what the AI targets, and it is
	bounded on purpose — MaxAttackers caps how many bodies one turret can pull off
	the survivors, so a turret buys the team a corridor rather than deleting the
	wave. See InfectedBrain:_stepEmplacement, which is where the diversion lives;
	this file only answers "is there one near me" and "here is what it took".

	It used to be proximity damage instead — health that ticked down while a crowd
	stood near it, which got the same NUMBER without the horde ever looking at it.
	That reads as a turret rusting, not a turret being torn apart, and it meant
	standing next to your own turret in a crowd was free.

	── AND IT SHOOTS THROUGH THE REAL DAMAGE PATH ──────────────────────────────
	Every shot goes through DamageService with the owner as the attacker, so a
	turret kill is that player's kill, feeds their round tally, respects
	resistances, and gibs the way anything else does. It is not a special case
	anywhere downstream.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Attributes = require(Shared.Net.Attributes)
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

local TA = Attributes.Turret
local PA = Attributes.Player
local IA = Attributes.Infected

--[[ What the client watches for. A tag rather than a name sweep: the health bar
     over a turret is drawn by whoever is looking at it, and CollectionService
     hands them the model the frame it appears without anybody scanning
     Workspace. Same idiom as BarricadeConfig.Tag. ]]
local TURRET_TAG = AbilityConfig.TurretTag

--[[ How wide a manual shot's aim is, in studs of miss at any range.

     A cylinder around the aim line rather than a cone, because a cone that is
     generous at seventy studs is impossibly tight at five, and the horde a
     manned turret is actually shooting at is usually close. 2.5 is about a body
     across: point at a zombie and you hit it, point between two and you hit
     neither. ]]
local MANUAL_AIM_RADIUS = 2.5

--[[ How long a manned turret keeps firing on the last input it heard. A held
     trigger arrives as a repeating flag, so a client that stops sending — the
     player alt-tabbed, the network hiccuped — must stop shooting rather than
     hold the trigger down forever. Two input periods, so an ordinary dropped
     packet does not stutter the gun. ]]
local MANUAL_INPUT_GRACE = 0.35

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
	--[[ Every barrel the model supplied, in name order, or empty when it
	     supplied none. See `fire`: empty is a fallback rather than a fault, and
	     more than one is a twin gun that alternates. ]]
	muzzles: { Attachment },
	--[[ Which barrel fires next, as an index into the above. ]]
	nextMuzzle: number,
	health: number,
	maxHealth: number,
	expiresAt: number,
	nextShotAt: number,
	nextScanAt: number,
	target: Model?,
	ignore: { Instance },
	--[[ The seat. POLLED rather than connected: this module already ticks every
	     turret on Heartbeat, so a GetPropertyChangedSignal on Occupant would fire
	     between two reads of the same property and buy nothing — while adding a
	     connection to leak and a second path into setDriver that has to agree with
	     the first. One property read per turret per frame is the cheaper half. ]]
	seat: Seat?,
	--[[ Who is driving it, and the last thing they asked it to do. `manualAt` is
	     when that arrived — see MANUAL_INPUT_GRACE. ]]
	manual: Player?,
	manualDirection: Vector3?,
	manualFiring: boolean,
	manualAt: number,
}

--[[ This ability's own numbers, resolved once. The step below runs every frame
     for every live turret, and reaching back through the config on each of them
     is a table walk per turret per frame for a value that cannot change. ]]
local TUNING = AbilityConfig.get(Enums.Ability.Turret).tuning

local turrets: { Emplacement } = {}

--[[ Which body has committed to which turret, and when it last said so. See
     Turret.nearest for why this is a claim with a timestamp rather than a
     register/release pair, and `sweepClaims` for the one place it is tidied. ]]
type Claim = { turret: Model, at: number }
local claims: { [Model]: Claim } = {}
--[[ How many live claims each turret holds. Derived from the table above and
     rebuilt once a frame, so the cap test in `nearest` is a single lookup rather
     than a walk of every claim for every turret for every body that looks. ]]
local claimCount: { [Model]: number } = {}

--[[ How long a claim stands without being renewed. A body re-claims on every
     look, four times a second, so this is generous — it is sized to survive a
     stagger or a path recompute, not to expire during ordinary attacking. ]]
local CLAIM_TTL = 0.6

--[[ One pass, once a frame, doing both jobs: drop what has gone stale and count
     what has not. Separating them would be two walks of the same table. ]]
local function sweepClaims(now: number)
	table.clear(claimCount)
	for who, claim in claims do
		if now - claim.at > CLAIM_TTL or not who.Parent or not claim.turret.Parent then
			claims[who] = nil
		else
			claimCount[claim.turret] = (claimCount[claim.turret] or 0) + 1
		end
	end
end

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
	Every barrel on a supplied gun, in a stable order.

	ANY Attachment whose name starts with "Muzzle" counts, so a twin gun can
	name them "Muzzle" and "Muzzle 2" — or "Muzzle L" and "Muzzle R", or four of
	them — without this file being told how many to expect. Sorted by name so
	the alternation in `fire` is the same order every deploy rather than
	whatever order GetDescendants happened to return.

	Searched over DESCENDANTS rather than direct children, because where the
	attachments live depends on how the model was built: on the gun part itself
	when `gun` is a Part, and on some part inside it when `gun` is a Model. A
	direct-child lookup finds the first case and silently misses the second.
]]
local function findMuzzles(within: Instance): { Attachment }
	local found: { Attachment } = {}
	for _, child in within:GetDescendants() do
		if child:IsA("Attachment") and string.sub(child.Name, 1, 6) == "Muzzle" then
			table.insert(found, child :: Attachment)
		end
	end
	table.sort(found, function(a, b)
		return a.Name < b.Name
	end)
	return found
end

--[[
	The supplied model, if there is one.

	ReplicatedStorage/Assets/Abilities/Turret, with `gun` as the part that swings
	and one Attachment per barrel, each named starting with "Muzzle". Both are
	optional and each degrades on its own: no `gun` and the model sits still, no
	muzzles and shots leave from the gun's own position. A model that is only
	geometry still deploys and still shoots.

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

--[[
	The seat you sit in to drive it.

	A real Roblox Seat, which means you man the turret by WALKING INTO IT and
	leave it by jumping. No prompt, no key to learn, and — the part that decides
	it — no ProximityPrompt, which MapService.sanitise strips out of anything it
	loads and which this game therefore does not use anywhere.

	CanCollide is off. A collidable pad behind the gun is a thing to trip over in
	a doorway you are trying to defend, and a Seat seats you on TOUCH rather than
	on collision, so turning it off costs nothing.

	Placed BEHIND the gun's facing, because that is where a person stands to fire
	one, and low, because the alternative is a player floating at barrel height.
]]
local SEAT_SIZE = Vector3.new(1.9, 0.35, 1.9)
local SEAT_BACK = 2.2

local function buildSeat(model: Model, root: BasePart, facing: Vector3, visible: boolean): Seat
	--[[ The artist's own, if they built one. Any Seat inside a supplied model is
	     taken as the place to sit — so somebody who has modelled a gunner's stool
	     gets theirs rather than a grey pad hovering behind it. ]]
	local supplied = model:FindFirstChildWhichIsA("Seat", true)
	if supplied then
		supplied.Anchored = true
		supplied.CanCollide = false
		return supplied
	end

	local seat = Instance.new("Seat")
	seat.Name = "FL_TurretSeat"
	seat.Size = SEAT_SIZE
	seat.Anchored = true
	seat.CanCollide = false
	seat.CanQuery = false
	seat.CastShadow = false
	--[[ Drawn on the grey-box and invisible under a supplied model. The stand-in
	     has to SHOW you there is somewhere to stand, because nothing else about a
	     box on a tripod says so; a model somebody built has its own idea of where
	     a gunner goes and a grey pad hovering behind it would be wrong. ]]
	seat.Transparency = if visible then 0.35 else 1
	seat.Color = UITheme.Color.AccentDim
	seat.Material = Enum.Material.Metal
	seat.CFrame = CFrame.lookAt(root.Position - facing * SEAT_BACK, root.Position)
	seat.Parent = model
	return seat
end

--[[
	The player in a seat, or nil — and it EJECTS whatever it refuses.

	A Roblox Seat seats any Humanoid that touches it, and the thing most likely to
	touch a turret is a zombie. Without the eject, the first Common to wander into
	the seat sits down in it, is refused as a driver, and stays there for the rest
	of the turret's life: welded in place, out of the fight, sitting in the gun.
	Funny once.

	Survivors only, and the test is the BODY rather than the player. RigUtil's
	isSurvivor asks whether a Player owns this character, which is true of a
	Versus player driving a Boomer — they would be handed the trigger of the other
	team's gun. Anything wearing the infected kind attribute is refused instead,
	which covers the AI horde and a player inside one of it with the same line.
]]
local function occupantOf(seat: Seat): Player?
	local humanoid = seat.Occupant
	if not humanoid then
		return nil
	end
	local character = humanoid.Parent
	if character and character:IsA("Model") and character:GetAttribute(IA.Kind) == nil then
		local player = Players:GetPlayerFromCharacter(character)
		if player then
			return player
		end
	end
	humanoid.Sit = false
	return nil
end

--[[ Publishes what the client's health bar reads. One write per change, never
     per frame: `health` is a float that moves on every swing, so it is rounded
     before the compare — a bar cannot show a tenth of a point and an attribute
     write per frame for one is a packet per frame for nothing. ]]
local function publish(turret: Emplacement)
	local model = turret.model
	if not model.Parent then
		return
	end
	local shown = math.max(math.floor(turret.health + 0.5), 0)
	if model:GetAttribute(TA.Health) ~= shown then
		model:SetAttribute(TA.Health, shown)
	end
	local manned = turret.manual ~= nil
	if model:GetAttribute(TA.Manned) ~= manned then
		model:SetAttribute(TA.Manned, manned)
	end
end

--[[ Hands the gun to somebody, or takes it back.

     The player's own attribute is what stops their weapon firing and takes the
     viewmodel off their screen — see WeaponController.canAct. Written from here
     rather than from the client, so the same fact reaches every machine and a
     client cannot simply decide it is not manning a turret. ]]
local function setDriver(turret: Emplacement, player: Player?)
	local previous = turret.manual
	if previous == player then
		return
	end
	if previous then
		previous:SetAttribute(PA.ManningTurret, false)
	end
	turret.manual = player
	turret.manualFiring = false
	turret.manualDirection = nil
	turret.manualAt = 0
	if player then
		player:SetAttribute(PA.ManningTurret, true)
	end
	publish(turret)
end

local function retire(turret: Emplacement, index: number, destroyed: boolean)
	--[[ Read BEFORE the destroy. A destroyed part still answers .Position today,
	     which is why this worked, but it is reading a locked instance to find out
	     where a thing that no longer exists used to be — and the broadcast below
	     is the only reason the position is wanted at all. ]]
	local at = turret.root.Position

	--[[ The driver first, and BEFORE the model goes. Destroying a model with an
	     occupied Seat in it does unseat the player — but it does not clear the
	     attribute that has their weapon put away, and a survivor who cannot shoot
	     for the rest of the round because their turret expired underneath them is
	     the worst bug this feature could have. ]]
	setDriver(turret, nil)

	if turret.model.Parent then
		turret.model:Destroy()
	end
	table.remove(turrets, index)
	AbilitySupport.broadcast("TurretDown", {
		player = turret.player,
		position = at,
		destroyed = destroyed,
	})
end

local function fire(turret: Emplacement, target: Model, targetRoot: BasePart, damage: number)
	--[[
		From a barrel, not from the middle of the gun.

		Alternating when the model supplied more than one, so a twin gun visibly
		fires left, right, left rather than pouring everything out of whichever
		barrel happened to sort first. It costs one integer and it is the
		difference between a model with two guns and a model with two guns and
		one of them decorative.

		With no muzzles at all the gun's own position is the honest fallback: the
		tracer starts a little further back than it should rather than not being
		drawn.
	]]
	local origin = turret.head.Position
	local count = #turret.muzzles
	if count > 0 then
		local muzzle = turret.muzzles[turret.nextMuzzle]
		--[[ Guarded because an Attachment can be deleted out from under this at
		     any time — a model streamed out, or somebody editing in a live
		     session. A destroyed one keeps its Parent as nil rather than
		     erroring, so the check is on the parent. ]]
		if muzzle and muzzle.Parent then
			origin = muzzle.WorldPosition
		end
		turret.nextMuzzle = (turret.nextMuzzle % count) + 1
	end

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

--[[
	What a manual shot hits: the nearest body inside a cylinder around the aim.

	NOT a raycast, and that is a decision rather than a shortcut. Every part of an
	infected rig is on the Infected collision group and half of them are
	CanQuery-off for the ballistics path; a raw ray down the barrel would miss
	bodies the player is plainly pointing at and there would be no way to tell
	from the seat why. A radius around the line asks the question the player
	thinks they are asking — "is there a zombie where I am pointing" — and answers
	it the same way at five studs and at seventy.

	Line of sight is still required, from the barrel, so a manned turret cannot
	shoot through the wall it is parked behind any more than an automatic one can.
]]
local function manualTarget(turret: Emplacement, direction: Vector3, range: number): (Model?, BasePart?)
	local origin = turret.head.Position
	local best: Model? = nil
	local bestRoot: BasePart? = nil
	local bestAlong = math.huge

	for _, entry in AbilitySupport.infectedWithin(origin, range) do
		local delta = entry.root.Position - origin
		--[[ How far down the barrel it is, and how far off it. A body BEHIND the
		     gun has a negative `along` and is refused by the same compare that
		     keeps the nearest one — no separate check needed. ]]
		local along = delta:Dot(direction)
		if along <= 0 or along >= bestAlong then
			continue
		end
		if (delta - direction * along).Magnitude > MANUAL_AIM_RADIUS then
			continue
		end
		turret.ignore[2] = entry.model
		local clear = RaycastUtil.hasLineOfSight(origin, entry.root.Position, turret.ignore)
		turret.ignore[2] = nil
		if clear then
			best, bestRoot, bestAlong = entry.model, entry.root, along
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
	local greyBoxed = model == nil
	if not model or not base or not head or not aim then
		model, base, head = build(at, facing)
		aim = head
		greyBoxed = true
	end
	local emplacement: Emplacement = {
		player = player,
		model = model,
		root = base,
		head = head,
		aim = aim,
		muzzles = findMuzzles(aim),
		nextMuzzle = 1,
		health = tuning.Health,
		maxHealth = tuning.Health,
		expiresAt = os.clock() + tuning.Lifetime,
		nextShotAt = 0,
		nextScanAt = 0,
		target = nil,
		ignore = { model },
		seat = nil,
		manual = nil,
		manualDirection = nil,
		manualFiring = false,
		manualAt = 0,
	}
	table.insert(turrets, emplacement)

	emplacement.seat = buildSeat(model, base, facing, greyBoxed)

	--[[ What the client's health bar reads, written before the tag so the bar is
	     never built against a model with no numbers on it yet. ]]
	model:SetAttribute(TA.MaxHealth, tuning.Health)
	model:SetAttribute(TA.Health, tuning.Health)
	model:SetAttribute(TA.Manned, false)
	model:SetAttribute(TA.Owner, player.UserId)
	CollectionService:AddTag(model, TURRET_TAG)

	AbilitySupport.broadcast("TurretUp", {
		id = context.definition.id,
		player = player,
		position = base.Position,
		lifetime = tuning.Lifetime,
	})
	return true
end

--[[ `dt` is unused now that the horde does the damage rather than proximity
     doing it — every deadline here is an absolute stamp compared against `now`.
     Kept in the signature because AbilityService calls every module's step the
     same way. ]]
function Turret.step(_dt: number)
	local now = os.clock()
	sweepClaims(now)

	for index = #turrets, 1, -1 do
		local turret = turrets[index]

		if now >= turret.expiresAt or not turret.model.Parent then
			retire(turret, index, false)
			continue
		end

		--[[
			Who is in the seat, asked fresh every frame.

			One read covers every way in and every way out at once — walking into
			it, jumping out, dying in it, respawning, and the one an Occupant
			signal would have missed entirely: a player LEAVING THE GAME, whose
			Player instance goes without the seat's property ever changing. The
			extra `.Parent` test is for exactly that case, in the frame before the
			character is torn down.
		]]
		local seat = turret.seat
		local occupant = if seat then occupantOf(seat) else nil
		if occupant and not occupant.Parent then
			occupant = nil
		end
		if occupant ~= turret.manual then
			setDriver(turret, occupant)
		end

		local driver = turret.manual
		local target: Model? = nil
		local targetRoot: BasePart? = nil
		--[[ Where the barrel wants to point, as a flat heading. Both modes end up
		     here; only the way they arrive at it differs. ]]
		local heading: Vector3? = nil
		local wantsShot = false
		local rate = TUNING.FireRate

		if driver then
			--[[
				MANNED. The player's aim, and their trigger.

				The barrel still traverses in YAW ONLY, for the reason the automatic
				branch below gives — a supplied gun pitched at somebody's feet tips
				the whole assembly over — but the SHOT goes down the full
				three-dimensional aim. So a player leaning the crosshair onto a
				rooftop hits the rooftop while the model stays upright, which is
				exactly the compromise every emplacement in every shooter makes.
			]]
			local direction = turret.manualDirection
			if direction then
				local flat = Vector3.new(direction.X, 0, direction.Z)
				heading = if flat.Magnitude > 0.05 then flat.Unit else nil
				--[[ Behind the fire-rate gate on purpose, not just behind the
				     trigger. manualTarget walks every living body and traces a
				     sight line to each candidate; doing that on every frame a
				     player holds the button would be sixty of those a second for
				     the four or five shots it produces. Here it runs once per
				     shot, which is what the answer is for. ]]
				if
					turret.manualFiring
					and now - turret.manualAt <= MANUAL_INPUT_GRACE
					and now >= turret.nextShotAt
				then
					target, targetRoot = manualTarget(turret, direction, TUNING.Range)
					wantsShot = true
				end
			end
			rate = TUNING.ManualFireRate
			--[[ Dropped on the way in. A gun that keeps its automatic target while
			     a person is driving it would snap back to whatever was nearest the
			     moment they stood up, mid-burst. ]]
			turret.target = nil
		else
			if now >= turret.nextScanAt then
				turret.nextScanAt = now + SCAN_INTERVAL
				turret.target = acquire(turret, TUNING.Range)
			end

			target = turret.target
			if target and (not target.Parent or not RigUtil.isAlive(target)) then
				target = nil
				turret.target = nil
			end
			targetRoot = if target then RigUtil.getRoot(target) else nil
			if target and not targetRoot then
				target = nil
				turret.target = nil
			end
			if target and targetRoot then
				--[[
					Aimed every frame even between shots, so the barrel tracks rather
					than snapping at the moment it fires. It is the only thing that
					makes a static box read as a machine paying attention.

					YAW ONLY. A supplied model's gun is a child sitting on a base, and
					pitching it at a Common's chest three studs away would tip the
					whole assembly onto its face. Real emplacements traverse; they do
					not roll over. The flat heading also keeps the muzzle at a sane
					height, which is what the tracer is drawn from.
				]]
				local flat = Vector3.new(
					targetRoot.Position.X - turret.head.Position.X,
					0,
					targetRoot.Position.Z - turret.head.Position.Z
				)
				heading = if flat.Magnitude > 0.05 then flat.Unit else nil
				wantsShot = true
			end
		end

		if heading then
			local at = turret.aim:GetPivot().Position
			turret.aim:PivotTo(CFrame.lookAt(at, at + heading))
		end

		--[[
			The cooldown is paid on the SHOT, not on the tick.

			A manned turret whose player is holding the trigger with nothing in
			front of it must not bank up rounds: `nextShotAt` only moves when a
			bullet actually leaves, so pointing at a wall for five seconds and then
			swinging onto a horde fires once, not fifteen times. The automatic
			branch has always worked this way because it never reaches here without
			a target; this keeps the manned one honest about the same rule.
		]]
		if wantsShot and target and targetRoot and now >= turret.nextShotAt then
			turret.nextShotAt = now + 1 / math.max(rate, 0.01)
			fire(turret, target, targetRoot, TUNING.Damage)
		end

		publish(turret)
	end
end

--[[
	The nearest turret worth attacking, for a body standing at `origin`.

	Answered from here rather than by the brain walking Workspace, because this
	file is the only thing that knows which models are live turrets and how much
	of one is left. See InfectedBrain:_stepEmplacement for the diversion itself.

	── THE CAP IS A CLAIM, NOT A HEAD COUNT ────────────────────────────────────
	The obvious version — refuse a turret that already has MaxAttackers bodies
	NEAR it — cannot be made to work, and it fails in the one situation the whole
	feature is for. Count within a small radius and ten bodies converging from
	fifteen studs all see an empty turret on the same tick and all commit. Count
	within the aggro radius instead and a horde pushing past a turret puts twenty
	bodies inside it, the cap is permanently exceeded, and nothing ever diverts at
	all. "Near it" and "attacking it" are not the same question and no radius
	turns one into the other.

	So a body CLAIMS the turret it is going to, and claims are counted. The
	subtlety is that nobody ever releases one: a claim carries a timestamp and is
	swept when it goes stale, so a zombie that dies mid-swing, gets shoved off, or
	simply changes its mind leaks nothing, and there is no release call for a
	future code path to forget. A body that is still attacking re-claims on every
	look, which is four times a second — comfortably inside CLAIM_TTL.

	The counting is O(1) here because `step` builds the per-turret totals in one
	sweep per frame; this only reads them, and adjusts them as it grants.
]]
function Turret.nearest(origin: Vector3, range: number, claimant: Model?): (Model?, BasePart?, number)
	local best: Model? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = math.huge

	local held = if claimant then claims[claimant] else nil

	for _, turret in turrets do
		if not turret.model.Parent or turret.health <= 0 then
			continue
		end
		local distance = (turret.root.Position - origin).Magnitude
		if distance > range or distance >= bestDistance then
			continue
		end
		--[[ A body that already holds this one is never turned away by its own
		     claim. Without this the fifth attacker would be refused on its next
		     look and walk off mid-fight. ]]
		if not (held and held.turret == turret.model) then
			if (claimCount[turret.model] or 0) >= TUNING.MaxAttackers then
				continue
			end
		end
		best, bestRoot, bestDistance = turret.model, turret.root, distance
	end

	--[[ Granted immediately rather than at the next sweep, so several bodies
	     looking on the same frame see each other's claims and the cap holds
	     against a simultaneous rush. ]]
	if claimant then
		if held and held.turret ~= best then
			claimCount[held.turret] = math.max((claimCount[held.turret] or 1) - 1, 0)
		end
		if best then
			if not (held and held.turret == best) then
				claimCount[best] = (claimCount[best] or 0) + 1
			end
			claims[claimant] = { turret = best, at = os.clock() }
		else
			claims[claimant] = nil
		end
	end

	return best, bestRoot, bestDistance
end

--[[ Takes a swing out of a turret, and returns what is left — or nil when the
     model is not one, which is the answer a brain wants when the thing it lined
     up on turned out to be scenery. Retired the moment it reaches zero, so a
     second body swinging into the same frame cannot damage a wreck. ]]
function Turret.damage(model: Instance, amount: number): number?
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return nil
	end
	for index = #turrets, 1, -1 do
		local turret = turrets[index]
		if turret.model ~= model then
			continue
		end
		turret.health -= amount
		if turret.health <= 0 then
			retire(turret, index, true)
			return 0
		end
		publish(turret)
		return turret.health
	end
	return nil
end

--[[
	One frame of what the person in the seat is asking for.

	Everything here is checked rather than believed. The player must be the
	CURRENT occupant of a live turret — a stale client that keeps sending after
	standing up drives nothing — and the point becomes a direction FROM THE BARREL
	rather than being used as sent, so nothing downstream cares how far away the
	client claimed to be looking. `firing` is a flag; the rate of fire is the
	server's, in step above.
]]
function Turret.input(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local point = payload.point
	if typeof(point) ~= "Vector3" then
		return
	end
	--[[ NaN and infinity both arrive as a Vector3 and both poison every CFrame
	     downstream. A NaN vector fails its own equality test; an infinite one
	     fails the magnitude bound below, once it is a delta. ]]
	if point ~= point then
		return
	end

	for _, turret in turrets do
		if turret.manual == player then
			local delta = point - turret.head.Position
			local magnitude = delta.Magnitude
			--[[ Aiming AT the barrel is not an aim. Refused rather than clamped:
			     there is no sensible direction to invent, and the last one the
			     player sent is a better answer than a made-up one. ]]
			if magnitude < 0.5 or magnitude > 1e6 then
				return
			end
			turret.manualDirection = delta / magnitude
			turret.manualFiring = payload.firing == true
			turret.manualAt = os.clock()
			return
		end
	end
end

function Turret.clear()
	table.clear(claims)
	table.clear(claimCount)
	for index = #turrets, 1, -1 do
		--[[ Through retire rather than by hand, so a round ending on somebody
		     sitting in a turret still gives them their weapon back. That was the
		     shape of the bug this whole path exists to avoid — see retire. ]]
		retire(turrets[index], index, false)
	end
end

return Turret
