--!nonstrict
--[[
	LedgeService — the drops that do not kill you.

	A survivor who walks off a ledge a designer marked catches the lip instead of
	dying. They hang there on a clock, bleeding slowly, and the only way back is a
	teammate who stops shooting and pulls them up.

	Everything about that beat already existed: the state, the pull-up prompt, the
	drain, the countdown, the HUD line, the crosshair and ability lockouts. What
	did not exist was anything that put a survivor into it — SurvivorService's
	`ledgeHang` was written, complete, and called by nothing at all, so in the
	whole history of the game nobody has ever hung off anything. This is the
	trigger, and it is the only thing this file does.

	── WHY ARITHMETIC AND NOT A RAYCAST ────────────────────────────────────────
	The obvious build is an invisible part you raycast against. It is also a trap:
	an invisible part a ray can hit is an invisible part a BULLET can hit, and a
	wall that eats shots fired over a balcony is a worse bug than the one this
	feature fixes. Shoves, the interact ray and the Director's sight-line checks
	would all find it too.

	So the volumes are made completely inert on load — no collision, no queries —
	and the test is done in Lua against their cached box. Nothing in the physics
	world can touch a catch volume, and nothing has to remember to filter it out.

	── AND WHY IT SAMPLES THE PATH ─────────────────────────────────────────────
	A body at terminal velocity moves further between two ticks than a shallow
	catch volume is deep, so asking "is the survivor inside one right now" misses
	exactly the falls that most need catching. The check walks the line from where
	each body WAS to where it is, which turns the volume into a net rather than a
	tripwire — and means a designer can draw a sensible box instead of a tall one.

	── WHAT IT DELIBERATELY DOES NOT DO ────────────────────────────────────────
	It does not decide where you land, how long you last, or what happens when you
	let go. Those are SurvivorService's, and the split is the point: this file
	knows about geometry and nothing about survivors, and that one knows about
	survivors and nothing about the map.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

local LEDGE = MapConfig.Ledges

local LedgeService = {}

local serviceTrove = Trove.new()

--[[ One catch volume, measured once. The CFrame and size are cached rather than
     read per test: they do not change — the parts are anchored on load — and the
     inner loop runs over every survivor several times a second. ]]
type Catch = {
	part: BasePart,
	cframe: CFrame,
	inverse: CFrame,
	half: Vector3,
	top: number, -- world height of the lip
	outward: Vector3, -- the part's own facing, flattened; the fallback hang direction
}

local catches: { Catch } = {}

--[[ Where each survivor's body was on the previous tick, so the check has a line
     to walk rather than a point to test. Weak keys: a player who leaves takes
     their entry with them. ]]
local lastPosition = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: Vector3 }

--[[ Absolute os.clock() stamps. A survivor just put back on the lip is standing
     inside the volume that caught them, and without this one step in the wrong
     direction is a second hang before the first has finished replicating. ]]
local caughtUntil = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: number }

local accumulator = 0

--[[ Ten times a second. The sampling below is what makes a fast fall safe, not
     the tick rate, so this only has to be often enough that the line between two
     ticks is a line and not a leap across the map. ]]
local TICK_INTERVAL = 0.1

-- ── geometry ────────────────────────────────────────────────────────────────

--[[ The world height of a box's highest point, which is the lip.

     Through the basis vectors rather than `Position.Y + Size.Y / 2`, so a ramp
     lip laid at an angle measures its actual top instead of its centre plus half
     its thickness. Designers place these flat almost always; this costs three
     multiplications and removes the almost. ]]
local function topOf(cframe: CFrame, size: Vector3): number
	local half = 0.5
		* (
			math.abs(cframe.RightVector.Y) * size.X
			+ math.abs(cframe.UpVector.Y) * size.Y
			+ math.abs(cframe.LookVector.Y) * size.Z
		)
	return cframe.Position.Y + half
end

local function insideCatch(catch: Catch, point: Vector3): boolean
	local localPoint = catch.inverse * point
	return math.abs(localPoint.X) <= catch.half.X
		and math.abs(localPoint.Y) <= catch.half.Y
		and math.abs(localPoint.Z) <= catch.half.Z
end

--[[ The first catch volume the segment from `from` to `to` passes through.

     Endpoints included, and the interior sampled at SampleStep, so a fall that
     began above a volume and ended below it is caught by one of the samples in
     between rather than missed by both ends. ]]
local function catchAlong(from: Vector3, to: Vector3): (Catch?, Vector3?)
	local delta = to - from
	local distance = delta.Magnitude
	local steps = math.max(1, math.ceil(distance / LEDGE.SampleStep))

	for step = 0, steps do
		local point = from + delta * (step / steps)
		for _, catch in catches do
			--[[ Below the LIP, not merely inside the box.

			     A catch volume laid along an edge overlaps the walkway beside it,
			     and a survivor standing there has their origin about three studs
			     up — so the top of the box is a place people stand, jump and land.
			     The falling-speed gate alone lets a jump through: an eighth of a
			     second after leaving the ground you are descending at more than
			     fourteen studs a second and still entirely on the ledge, and the
			     modelled result was that hopping near an edge grabbed you.

			     Dipping below the lip is the thing that actually means you are off
			     it, and it costs one comparison. ]]
			if point.Y < catch.top and insideCatch(catch, point) then
				return catch, point
			end
		end
	end
	return nil, nil
end

--[[
	Solid ground behind the lip, for a survivor who is about to stop hanging.

	Searched from above and downward rather than measured off the lip, because the
	ground behind a ledge is not reliably level with it — a lip is often the top
	of a wall with a walkway a step below. Nothing found means the geometry is not
	what anybody expected, and the lip itself is the honest answer: standing on the
	edge is at least somewhere the team can walk to.
]]
local function recoveryFor(catch: Catch, hang: Vector3, inland: Vector3): Vector3
	local lip = Vector3.new(hang.X, catch.top, hang.Z)
	local back = lip + inland * LEDGE.RecoveryInset + Vector3.new(0, LEDGE.RecoveryRise, 0)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local exclude: { Instance } = {}

	local survivors: any = Registry.find("SurvivorService")
	if survivors and typeof(survivors.getSurvivorCharacters) == "function" then
		for _, character in survivors:getSurvivorCharacters() do
			table.insert(exclude, character)
		end
	end
	--[[ The horde as well. A Common standing where somebody is about to be pulled
	     up is a floor made of zombie, and the survivor would arrive on its head. ]]
	local horde = Workspace:FindFirstChild("Infected")
	if horde then
		table.insert(exclude, horde)
	end
	params.FilterDescendantsInstances = exclude

	local hit =
		Workspace:Raycast(back, Vector3.new(0, -(LEDGE.RecoveryRise + LEDGE.RecoveryProbe), 0), params)
	if hit then
		--[[ Clear of the floor by about the height a root sits at, so they arrive
		     standing rather than inside it. ]]
		return hit.Position + Vector3.new(0, 3, 0)
	end
	return lip + Vector3.new(0, 3, 0)
end

-- ── the catch ───────────────────────────────────────────────────────────────

--[[
	Which way a hanging survivor faces: back the way they came.

	Walk north off a north-facing edge and you hang facing south, at the lip you
	just left. It needs no authoring at all, which is the point — the alternative
	is a convention about which way to point the part, and a convention about
	part orientation is a convention somebody gets backwards on the one ledge
	they built last.

	The part's own facing is the fallback, for the survivor who was standing still
	and had the floor taken out from under them.
]]
local function facingFor(catch: Catch, velocity: Vector3): Vector3
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	if flat.Magnitude > 1 then
		return -flat.Unit
	end
	if catch.outward.Magnitude > 0.05 then
		return -catch.outward
	end
	return Vector3.zAxis
end

--[[ Upright, which here means on your feet and able to walk off something.
     Asked of the state rather than of the record, because the record is
     SurvivorService's and this file has no business inside it. ]]
local UPRIGHT = table.freeze({
	[Enums.SurvivorState.Healthy] = true,
	[Enums.SurvivorState.Hurt] = true,
})

local function tryCatch(player: Player, now: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		lastPosition[player] = nil
		return
	end

	local position = root.Position
	local previous = lastPosition[player]
	lastPosition[player] = position

	if not previous or (caughtUntil[player] or 0) > now then
		return
	end

	--[[ Falling, not merely walking through. A catch volume laid along a lip
	     usually overlaps the walkway beside it, and grabbing somebody who strolled
	     across it would make the ledge a trap rather than a rescue. ]]
	if root.AssemblyLinearVelocity.Y > -LEDGE.MinFallSpeed then
		return
	end

	local catch, point = catchAlong(previous, position)
	if not catch or not point then
		return
	end

	local survivors: any = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.ledgeHang) ~= "function" then
		return
	end

	local inland = facingFor(catch, root.AssemblyLinearVelocity)
	local hang = Vector3.new(point.X, catch.top - LEDGE.HangDrop, point.Z)
	local pose = CFrame.lookAt(hang, hang + inland)

	caughtUntil[player] = now + LEDGE.Grace
	survivors:ledgeHang(player, pose, recoveryFor(catch, hang, inland))
end

-- ── the map ─────────────────────────────────────────────────────────────────

--[[ Makes a catch volume what it has to be: invisible, and untouchable by
     anything in the physics world. See the header — a queryable trigger in front
     of a drop is an invisible wall that eats bullets. ]]
local function dressCatch(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.CastShadow = false
	part.Locked = true
end

--[[ Rediscovers every catch volume in whatever map is live. Called on boot and
     on every map swap; the previous map's parts went with the map, so this starts
     from nothing rather than trying to reconcile. ]]
function LedgeService:rebuild(): number
	table.clear(catches)

	for _, tagged in CollectionService:GetTagged(LEDGE.Tag) do
		if not tagged:IsA("BasePart") or not tagged:IsDescendantOf(Workspace) then
			continue
		end
		dressCatch(tagged)

		local cframe, size = tagged.CFrame, tagged.Size
		local look = cframe.LookVector
		table.insert(catches, {
			part = tagged,
			cframe = cframe,
			inverse = cframe:Inverse(),
			half = size * 0.5,
			top = topOf(cframe, size),
			outward = Vector3.new(look.X, 0, look.Z),
		})
	end

	if #catches > 0 then
		print(string.format("[LedgeService] %d survivable ledge(s) in the live map", #catches))
	end
	return #catches
end

function LedgeService:getCatchCount(): number
	return #catches
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function LedgeService:init()
	-- Nothing to do until a map is live; rebuild() is driven from start().
end

function LedgeService:start()
	local mapService = Registry.find("MapService")
	if mapService and mapService.mapChanged then
		serviceTrove:add(mapService.mapChanged:connect(function()
			self:rebuild()
		end))
	end

	--[[ A tag added or removed while the round is live, which is how somebody
	     building a map in Studio works. Cheap to re-measure and it means a ledge
	     can be tested without restarting the place. ]]
	serviceTrove:connect(CollectionService:GetInstanceAddedSignal(LEDGE.Tag), function()
		self:rebuild()
	end)
	serviceTrove:connect(CollectionService:GetInstanceRemovedSignal(LEDGE.Tag), function()
		self:rebuild()
	end)

	--[[ The grace starts when the hang ENDS, not when it begins. A survivor put
	     back on the lip is standing inside the volume that caught them. ]]
	local survivors: any = Registry.find("SurvivorService")
	if survivors and survivors.stateChanged then
		serviceTrove:add(survivors.stateChanged:connect(function(player, _new, previous)
			if previous == Enums.SurvivorState.LedgeHanging then
				caughtUntil[player] = os.clock() + LEDGE.Grace
				--[[ And the trail is dropped: the body was just moved several
				     studs by the release, and a line drawn from where it hung to
				     where it stands now crosses the volume it was hanging in. ]]
				lastPosition[player] = nil
			end
		end))
	else
		warn("[LedgeService] no SurvivorService; ledges will never catch anybody")
	end

	self:rebuild()

	serviceTrove:connect(RunService.Heartbeat, function(dt: number)
		accumulator += dt
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		if #catches == 0 then
			return
		end

		local survivorService: any = Registry.find("SurvivorService")
		if not survivorService then
			return
		end

		local now = os.clock()
		for _, player in survivorService:getAliveSurvivors() do
			--[[ Upright only. Somebody already down, pinned or hanging cannot walk
			     off anything, and one already hanging must not be caught by the
			     volume they are hanging in. ]]
			if UPRIGHT[survivorService:getState(player)] then
				tryCatch(player, now)
			else
				--[[ The trail is dropped rather than left to go stale. A survivor
				     carried across the map by a Charger and put down would
				     otherwise have their next tick draw a line from where they were
				     grabbed to where they landed, through everything in between. ]]
				lastPosition[player] = nil
			end
		end
	end)
end

function LedgeService:destroy()
	serviceTrove:destroy()
	table.clear(catches)
end

Registry.register("LedgeService", LedgeService)

return LedgeService
