--!nonstrict
--[[
	BarricadeService — the wood the horde eats through.

	Set a part's Material to Wood in Studio and the infected can break it down.
	That is the entire authoring contract, and it is a material rather than a tag
	because a designer boarding up a window reaches for planks anyway: the thing
	they were already going to do is the thing that arms it. BarricadeConfig owns
	which materials count and what disqualifies a part on size or anchoring.

	── IT HIDES, IT DOES NOT DESTROY ────────────────────────────────────────────
	A broken barricade has its collisions and its visibility taken away and stays
	exactly where it is. That looks like the same thing from the inside of a
	round and is very much not the same thing across two of them, because
	MapService.ensure is a NO-OP when the team votes to replay the map they are
	already on — nothing is reloaded, so anything a round destroys is still
	destroyed at the start of the next one. This is the same lesson the vault's
	flamethrower taught, learned once and applied before it could bite twice.

	So: three properties are snapshotted when a part is armed and put back when
	the next round arms. A replayed Clinton gets its doors back.

	── WHY THE BRAIN ASKS THIS AND NOT THE OTHER WAY AROUND ─────────────────────
	InfectedBrain calls `blocking` to ask whether something breakable is between
	it and whoever it is chasing. The alternative — this service watching bodies
	and telling them what to hit — would put a second thing in charge of what an
	infected is doing, and the brain already owns that decision entirely. One
	raycast per body per swing window, against an include-list of the armed parts
	only, which cannot be confused by a teammate standing in the doorway.

	── WHAT DOES NOT DAMAGE A BARRICADE ─────────────────────────────────────────
	Bullets. This is the horde's tool, not the team's, and a survivor who can
	shoot through the map's carpentry is a survivor who opens the flanks the
	level designer closed. If that turns out to be wanted it belongs behind a
	config flag and a deliberate decision, not as a side effect of every wall in
	the game becoming shootable.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local BarricadeConfig = require(Shared.Config.BarricadeConfig)
local Enums = require(Shared.Enums)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

local BA = Attributes.Barricade
local GA = Attributes.Game

local BarricadeService = {}

local serviceTrove = Trove.new()

--[[ What a part looked like before it was armed. Kept for every armed part, not
     only broken ones: restoring unconditionally is one branch instead of two,
     and putting back a value that never changed costs nothing. ]]
type Snapshot = {
	part: BasePart,
	transparency: number,
	canCollide: boolean,
	canQuery: boolean,
	broken: boolean,
	lastHitAt: number,
}

local armed: { Snapshot } = {}
local byPart: { [BasePart]: Snapshot } = {}

--[[ The include-list the probe raycasts against, rebuilt whenever the set
     changes. Held as an array because RaycastParams wants one, and rebuilt
     rather than mutated because a stale entry is a raycast against a destroyed
     instance. ]]
local probeParams = RaycastParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Include
probeParams.IgnoreWater = true
probeParams.RespectCanCollide = false

--[[ The floor between two splinter bursts on ONE part. Six bodies on a door is
     six swings a second and six bursts a second is a fog, so the particles are
     rate-limited even though the damage is not. ]]
local SPLINTER_INTERVAL = 0.12

local SPLINTER_COLOUR = ColorSequence.new(Color3.fromRGB(146, 108, 66), Color3.fromRGB(74, 52, 30))

local function refreshProbeList()
	local live = table.create(#armed)
	for _, entry in armed do
		if not entry.broken and entry.part.Parent then
			table.insert(live, entry.part)
		end
	end
	probeParams.FilterDescendantsInstances = live
end

--[[ A part's splinter emitter, made the first time it is hit rather than when it
     is armed. Most barricades in a map are never touched, and an attachment and
     an emitter each is a cost worth paying only for the ones that are. ]]
local function splinters(part: BasePart): ParticleEmitter?
	local existing = part:FindFirstChild("FL_Splinters")
	if existing and existing:IsA("Attachment") then
		local emitter = existing:FindFirstChildOfClass("ParticleEmitter")
		return emitter
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "FL_Splinters"
	attachment.Parent = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = SPLINTER_COLOUR
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.32),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.4, BarricadeConfig.SplinterLifetime)
	emitter.Speed = NumberRange.new(6, 22)
	emitter.SpreadAngle = Vector2.new(180, 180)
	--[[ Splinters fall. Without this they drift like smoke, which is the single
	     thing that would stop them reading as wood. ]]
	emitter.Acceleration = Vector3.new(0, -60, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-220, 220)
	emitter.Rate = 0
	emitter.Parent = attachment

	return emitter
end

local function playSound(key: string, part: BasePart)
	local audio = Registry.find("AudioService")
	if audio then
		audio:play("Barricade", key, part)
	end
end

--[[ Health from bulk. See BarricadeConfig: paying per stud cubed is the only
     version of this that stays sensible on a map this code has never seen. ]]
local function healthFor(part: BasePart): number
	local size = part.Size
	local volume = size.X * size.Y * size.Z
	return math.clamp(
		math.floor(volume * BarricadeConfig.HealthPerStud),
		BarricadeConfig.MinHealth,
		BarricadeConfig.MaxHealth
	)
end

--[[
	Whether a slab is lying down.

	The clause that stops the horde eating the ground, and the only one here that
	needs geometry rather than a property read. A plank FLOOR is not one big part
	the volume window catches — it is forty door-sized ones, anchored, colliding
	and wooden, and every other test passes them.

	Which way the part is THIN is what tells them apart. A floor is thin
	vertically; a door, a wall and a board nailed across a window are thin
	horizontally, whatever their other dimensions do. So: find the smallest of
	the three local axes, take it into world space, and look at how much of it
	points up.

	Skipped for anything that is not slab-shaped. A crate is thin in no
	particular direction and its "thinnest axis" is whichever way the modeller
	happened to draw it — an answer that would flip on a rebuild.
]]
local function isFloorLike(part: BasePart): boolean
	local size = part.Size
	local thinnest, axis = size.X, Vector3.xAxis
	if size.Y < thinnest then
		thinnest, axis = size.Y, Vector3.yAxis
	end
	if size.Z < thinnest then
		thinnest, axis = size.Z, Vector3.zAxis
	end

	local others = (size.X + size.Y + size.Z - thinnest) * 0.5
	if others <= 0 or thinnest / others > BarricadeConfig.SlabRatio then
		return false
	end

	local worldAxis = part.CFrame:VectorToWorldSpace(axis)
	return math.abs(worldAxis.Y) >= BarricadeConfig.FloorNormalDot
end

--[[
	Whether a part in the map is one of these at all.

	Every clause here is a thing that would otherwise be a bug report. Material
	is the contract; the volume window keeps the trim and the whole-building
	slabs out; anchored and colliding is what separates a boarded window from a
	chair and a decorative plank; and isFloorLike is what keeps the ground under
	the team's feet. Transparent parts go for the same reason as non-colliding
	ones — an invisible barricade is a body stopping to swing at nothing.
]]
local function qualifies(part: BasePart): boolean
	if not BarricadeConfig.Materials[part.Material] then
		return false
	end
	if not part.Anchored or not part.CanCollide then
		return false
	end
	if part.Transparency >= 1 then
		return false
	end
	local size = part.Size
	local volume = size.X * size.Y * size.Z
	if volume < BarricadeConfig.MinVolume or volume > BarricadeConfig.MaxVolume then
		return false
	end
	return not isFloorLike(part)
end

-- ── arming ──────────────────────────────────────────────────────────────────

--[[ Past this many the scan has almost certainly armed scenery, and says so.
     Chosen against what a map WANTS rather than what it can afford: a level
     with forty breakable things in it is a level, and one with two hundred is a
     material that got applied to the furniture. ]]
local SCAN_WARN_COUNT = 60

--[[ A map's explicit barricade folder, matched the way every other map folder in
     this game is. Nil is the normal case — most maps will never have one. ]]
local function findBarricadeFolder(root: Instance): Instance?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Folder") or descendant:IsA("Model") then
			if MapConfig.folderMatches(descendant.Name, BarricadeConfig.FolderName) then
				return descendant
			end
		end
	end
	return nil
end

--[[ What counts inside that folder: anything solid. No material test, no size
     window, no floor test — somebody put it there on purpose, and overruling
     that would make the escape hatch another thing to argue with. ]]
local function explicit(part: BasePart): boolean
	return part.Anchored and part.CanCollide
end

--[[ Puts every armed part back the way it was found. Called before a fresh scan
     rather than at round end, because the round that ends is not necessarily
     followed by one on the same map — and a scan that begins by restoring is
     correct in both cases without having to know which it is in. ]]
function BarricadeService:restore()
	for _, entry in armed do
		local part = entry.part
		if part.Parent then
			part.Transparency = entry.transparency
			part.CanCollide = entry.canCollide
			part.CanQuery = entry.canQuery
			part:SetAttribute(BA.Health, nil)
			part:SetAttribute(BA.MaxHealth, nil)
			CollectionService:RemoveTag(part, BarricadeConfig.Tag)
		end
	end
	table.clear(armed)
	table.clear(byPart)
	refreshProbeList()
end

--[[ Finds and arms the map's wood. Driven from the round-state attribute rather
     than from a map-changed signal, for the reason MapService's own header
     gives: `ensure` does nothing when the map is already the one that is live,
     so a replay never fires a change and a service that waits for one arms
     exactly once and then never again. ]]
function BarricadeService:arm(): number
	self:restore()

	if not BarricadeConfig.Enabled then
		return 0
	end

	local mapService = Registry.find("MapService")
	local root = mapService and mapService:getCurrentRoot()
	if not root then
		return 0
	end

	--[[ An explicit folder wins outright, and nothing in it is second-guessed:
	     a part somebody dragged in there is a barricade because they said so,
	     material and size included. The scan is the good default, not the law. ]]
	local folder = findBarricadeFolder(root)
	local scope: Instance = folder or root

	for _, descendant in scope:GetDescendants() do
		--[[ The IsA guard comes FIRST and has to: both predicates read BasePart
		     properties, and asking a Folder whether it is Anchored is not a false,
		     it is an error that would take the whole scan down on the map's first
		     child. ]]
		if
			descendant:IsA("BasePart") and (if folder then explicit(descendant) else qualifies(descendant))
		then
			local entry: Snapshot = {
				part = descendant,
				transparency = descendant.Transparency,
				canCollide = descendant.CanCollide,
				canQuery = descendant.CanQuery,
				broken = false,
				lastHitAt = 0,
			}
			table.insert(armed, entry)
			byPart[descendant] = entry

			local health = healthFor(descendant)
			descendant:SetAttribute(BA.MaxHealth, health)
			descendant:SetAttribute(BA.Health, health)
			CollectionService:AddTag(descendant, BarricadeConfig.Tag)
		end
	end

	refreshProbeList()

	--[[ Said out loud, once a round, because the count is the only way a designer
	     can tell "my door is breakable" from "so is the entire building". A
	     number in the hundreds means the volume window is wrong for this map, and
	     the message is where that gets noticed. ]]
	if #armed > 0 then
		print(
			string.format(
				"[BarricadeService] armed %d barricade(s) in %s (%s)",
				#armed,
				mapService:getCurrentId(),
				if folder
					then string.format("everything in the %q folder", folder.Name)
					else "wooden parts, found by material"
			)
		)
	end

	--[[ The scan finding a crowd is the one failure this cannot detect on its
	     own, so it says so instead. A map with this many breakable things in it
	     is a map where the trim and the furniture got armed along with the doors,
	     and the fix is the folder rather than a fight with the numbers. ]]
	if not folder and #armed > SCAN_WARN_COUNT then
		warn(
			string.format(
				"[BarricadeService] %d wooden parts armed in %s, which is more than a map "
					.. "usually wants. If the horde is chewing on the furniture, put the "
					.. "parts that should be breakable in a folder called %q and only those "
					.. "will be armed.",
				#armed,
				mapService:getCurrentId(),
				BarricadeConfig.FolderName
			)
		)
	end

	return #armed
end

-- ── breaking ────────────────────────────────────────────────────────────────

local function breakDown(entry: Snapshot)
	local part = entry.part
	entry.broken = true

	local emitter = splinters(part)
	if emitter then
		emitter:Emit(BarricadeConfig.SplinterCount * 3)
		--[[ The attachment goes once the last splinter has. Left behind it is an
		     instance per broken barricade for the rest of the round, on a part
		     nobody can see. ]]
		Debris:AddItem(emitter.Parent, BarricadeConfig.SplinterLifetime + 0.5)
	end
	playSound("Break", part)

	part.CanCollide = false
	part.CanQuery = false
	part.Transparency = BarricadeConfig.HiddenTransparency
	part:SetAttribute(BA.Health, 0)
	CollectionService:RemoveTag(part, BarricadeConfig.Tag)

	refreshProbeList()
end

--[[
	Takes health off a barricade, and breaks it when there is none left.

	Returns what is left, or nil if the part was not an armed barricade — which
	is the answer the brain wants when the thing it swung at turned out to be
	scenery.
]]
function BarricadeService:damage(part: BasePart, amount: number): number?
	local entry = byPart[part]
	if not entry or entry.broken or not part.Parent then
		return nil
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return part:GetAttribute(BA.Health)
	end

	local health = math.max((part:GetAttribute(BA.Health) or 0) - amount, 0)
	part:SetAttribute(BA.Health, health)

	if health <= 0 then
		breakDown(entry)
		return 0
	end

	--[[ Sound and splinters are throttled together and the damage is not. Six
	     bodies on one door still take six bites out of it; they just do not each
	     get their own puff of wood. ]]
	local now = os.clock()
	if now - entry.lastHitAt >= SPLINTER_INTERVAL then
		entry.lastHitAt = now
		local emitter = splinters(part)
		if emitter then
			emitter:Emit(BarricadeConfig.SplinterCount)
		end
		playSound("Hit", part)
	end

	return health
end

function BarricadeService:isBarricade(instance: Instance): boolean
	if not instance:IsA("BasePart") then
		return false
	end
	local entry = byPart[instance]
	return entry ~= nil and not entry.broken
end

--[[
	The barricade between one point and another, if there is one.

	An INCLUDE list of the armed parts rather than an exclude list of everything
	else, which is what makes this immune to the case that would otherwise ruin
	it: a body, a teammate or a corpse standing in the doorway is not in the
	list, so it cannot be mistaken for the door it is standing in front of.

	The trade is that this cannot tell a barricade three rooms away through two
	walls from one directly ahead — which is why BarricadeConfig.ProbeRange is
	short. Nothing at nine studs is around a corner.
]]
function BarricadeService:blocking(origin: Vector3, towards: Vector3, range: number?): BasePart?
	if #armed == 0 then
		return nil
	end
	local delta = towards - origin
	local distance = delta.Magnitude
	if distance < 1e-3 then
		return nil
	end

	local reach = math.min(range or BarricadeConfig.ProbeRange, distance)
	local hit = Workspace:Raycast(origin, delta.Unit * reach, probeParams)
	if not hit then
		return nil
	end
	local part = hit.Instance
	return if part and self:isBarricade(part) then part else nil
end

function BarricadeService:getArmedCount(): number
	return #armed
end

function BarricadeService:init() end

function BarricadeService:start()
	--[[ Armed on the round starting and put back when it is over, off the same
	     attribute PuzzleService arms from. Round state rather than map state for
	     the reason `arm` gives: a replayed map never announces itself. ]]
	serviceTrove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		local round = Workspace:GetAttribute(GA.RoundState)
		if round == Enums.RoundState.Starting then
			self:arm()
		elseif round == Enums.RoundState.Lobby then
			self:restore()
		end
	end)
end

function BarricadeService:destroy()
	serviceTrove:destroy()
	self:restore()
end

Registry.register("BarricadeService", BarricadeService)

return BarricadeService
