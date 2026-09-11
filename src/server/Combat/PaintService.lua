--!strict
--[[
	PaintService — the paintball gun's other half.

	The classic paintball gun is remembered for exactly one thing, and it is not
	the five damage: it repaints whatever it hits. This game's version shipped
	with the damage and none of the paint, which left an SMG with a silly name
	and a green tracer.

	WeaponConfig's PaintProfile holds the palette and the limits. This holds the
	rules about what a shot is ALLOWED to recolour, which is the part the classic
	never had to think about.

	── WHY A WHOLE FILE FOR ONE PROPERTY ────────────────────────────────────────
	    hit.BrickColor = ball.BrickColor

	That is the entire classic implementation, and it is correct there. A
	brickbattle server is a field of loose bricks; recolouring one costs nothing
	and means nothing.

	Here a shot can land on a fuse box whose colour says whether it has been
	thrown, on a beacon whose light is the only readout a puzzle has, on a
	barricade, on an ammo crate somebody is looking for, or on a survivor's
	dropped weapon. Repainting any of those is not vandalism, it is DELETING
	INFORMATION the round depends on — and the player doing it would have no idea
	they had, because from their side a paintball gun painted something.

	So the refusals below are the feature. The colour change is one line.

	── AND WHY IT COUNTS ────────────────────────────────────────────────────────
	Every repaint is a replicated property change. One classic gun on a
	brickbattle server is a handful; a 1000rpm version of it, held down by four
	players across a map of several thousand parts, is a different quantity. The
	budget bounds the number of DISTINCT parts a round may recolour. Painting
	over something already painted is free and never refused, so the cap costs
	traffic and never costs the player holding the gun anything.

	── THE CLASSIC PAINTED PEOPLE, AND THIS DELIBERATELY DOES NOT ───────────────
	    if hit:GetMass() < 1.2 * 200 then

	A character's limb is well under that, so the classic repaints whoever it
	hits as readily as it repaints a brick. Left out here, and it is the one
	place this knowingly departs from the original.

	A special infected is told apart from six paces by its SILHOUETTE AND ITS
	COLOUR, and a team that cannot tell a Boomer from a Common until it is close
	enough to burst is a team that has lost the fight the colour was there to
	warn them about. Painting one is the same failure as painting a beacon — it
	does not deface the information, it replaces it with a convincing wrong
	answer — and it would arrive by accident, from a player spraying a corridor.

	Nothing enforces this separately: BallisticsService only offers paint the
	scenery branch of its hit loop, and anything with a Humanoid took the branch
	above it. Written down because the absence is a decision.

	── NOTHING IS RESTORED, AND NOTHING NEEDS TO BE ─────────────────────────────
	The classic is permanent. So is this, and it cleans itself up for free:
	MapService destroys the map clone at the end of a round and clones a fresh
	one from storage, for reasons that have nothing to do with paint — see its
	unload, which says the same thing about blood decals and burned crates. A
	painted map cannot outlive the round that painted it, so this keeps no undo
	list and schedules no restore.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Attributes = require(Shared.Net.Attributes)
local BarricadeConfig = require(Shared.Config.BarricadeConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local MapConfig = require(Shared.Config.MapConfig)
local PuzzleConfig = require(Shared.Config.PuzzleConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local PaintService = {}

--[[
	Anything wearing one of these, or sitting inside something that does, keeps
	the colour it was built in.

	Every entry is here because its COLOUR carries meaning, not because it would
	look untidy painted. A beacon on Crossroads is lit or unlit and the only way
	to tell is the colour of its light; a fuse box in the Backrooms is thrown or
	not on the same basis. Recolouring one of those does not deface a puzzle, it
	answers it wrongly — and silently, to the four people trying to solve it.

	Checked against the part AND its ancestors, because these tags sit on the
	MODEL. A beacon is a model with a Light part inside it, and a rule that only
	looked at what the ray struck would refuse to paint the beacon and happily
	repaint its light.
]]
local PROTECTED: { string } = {
	PuzzleConfig.KeypadTag,
	PuzzleConfig.ClueTag,
	PuzzleConfig.GeneratorTag,
	PuzzleConfig.StockpileTag,
	PuzzleConfig.FuseTag,
	PuzzleConfig.DoorwayTag,
	PuzzleConfig.BeaconTag,
	BarricadeConfig.Tag,
	MapConfig.AmmoCrates.Tag,
	MapConfig.Ledges.Tag,
	Attributes.PickupTag,
	InfectedConfig.HazardTag,
	AbilityConfig.TurretTag,
}

--[[
	Materials that are not surfaces.

	Neon and ForceField are how this game draws LIGHT — a beacon's column, a
	Tesla arc, a muzzle flash, an effect part left over from a pool. Their colour
	is the effect rather than a coat of paint on one, and recolouring them turns
	a readable signal into a differently-coloured readable signal that now means
	something else.
]]
local SKIP_MATERIAL: { [Enum.Material]: boolean } = {
	[Enum.Material.Neon] = true,
	[Enum.Material.ForceField] = true,
}

--[[ Below this a part is not really on screen, and painting it spends budget on
     something nobody will ever see. Collision volumes and trigger boxes live
     here, and there are a lot of them in a hand-built map. ]]
local MAX_TRANSPARENCY = 0.9

--[[
	What has been painted this round, and how much of the budget is left.

	Weak-keyed so a part destroyed mid-round — a crate blown apart, a prop a Tank
	threw — drops out of here on its own rather than holding a destroyed instance
	alive until the map unloads.

	The set is what makes repaints free: a part already in it has already been
	counted, so recolouring it costs nothing and is never refused. That is the
	difference between a budget that bounds TRAFFIC and one that would stop a
	player's gun working halfway through a corridor they were painting.
]]
local painted = (setmetatable({}, { __mode = "k" }) :: any) :: { [BasePart]: boolean }
local spent = 0

--[[
	Verdicts that cannot change while this map is loaded, remembered so they are
	worked out once per part rather than once per shot.

	The walk this saves is not free: isProtected climbs a part's ancestors asking
	thirteen tag questions at each level, and at a thousand rounds a minute —
	which this gun is the only weapon in the game to reach — most of those shots
	land on a wall whose answer was settled the first time somebody hit it.

	Only the STATIC half is stored. Whether a part is protected, invisible, made
	of light, outside the map or too heavy are all facts about the part; whether
	the round has budget left is not, so that one is re-asked every time and a
	part is never cached as refused for a reason that could expire. Cleared with
	the map, like everything else here.
]]
local decided = (setmetatable({}, { __mode = "k" }) :: any) :: { [BasePart]: any }

local serviceTrove = Trove.new()

--[[ Whether this part is inside the map that is currently loaded.

     The cheapest exclusion in the file and the broadest: it rules out every
     survivor, every infected, every dropped weapon, every gore part, every
     pooled effect and everything a future system parents straight to Workspace,
     in one ancestry walk. Scenery is the only thing a paintball gun has any
     business recolouring, and scenery is what is in here. ]]
local function inLiveMap(part: BasePart): boolean
	local folder = Workspace:FindFirstChild(MapConfig.LiveFolder)
	return folder ~= nil and part:IsDescendantOf(folder)
end

local function isProtected(part: BasePart): boolean
	local node: Instance? = part
	while node and node ~= Workspace do
		for _, tag in PROTECTED do
			if CollectionService:HasTag(node, tag) then
				return true
			end
		end
		node = node.Parent
	end
	return false
end

--[[
	── TWO REFUSALS, NOT ONE ────────────────────────────────────────────────────

	"Do not recolour this" and "do not put paint here at all" are different
	answers, and collapsing them is what would make this gun feel broken.

	Most of what anybody shoots in a hand-built map is a floor, a street or the
	side of a warehouse — all of them far past the mass limit, because that limit
	exists precisely to stop a paintball gun recolouring a building. If those
	shots produced nothing, the gun would appear to work on the handful of crates
	in a level and do nothing at all everywhere else, which reads as a bug rather
	than as a rule.

	So a part too big to repaint can still be MARKED: the client draws a splat at
	the hit point and the wall keeps its colour. That is the classic's own
	compromise, made visible instead of silent — and it is what the budget
	running out does too, so a round that has spent its recolours keeps its
	paintball gun rather than losing it halfway through.

	A PROTECTED part gets neither. A beacon with a splat drawn on it is a beacon
	somebody has to look twice at, and the whole reason it is on the list is that
	looking once has to be enough.
]]
export type Verdict = {
	recolour: boolean, -- may the part itself change colour
	mark: boolean, -- may a splat be drawn here at all
	charge: boolean, -- does the recolour cost budget (false for a second coat)
}

local NOTHING: Verdict = table.freeze({ recolour = false, mark = false, charge = false })
local MARK_ONLY: Verdict = table.freeze({ recolour = false, mark = true, charge = false })
local REPAINT: Verdict = table.freeze({ recolour = true, mark = true, charge = false })
local FRESH: Verdict = table.freeze({ recolour = true, mark = true, charge = true })

--[[ Everything about the PART, worked out once and remembered. NOTHING, or
     MARK_ONLY for a surface too big to recolour, or FRESH for one that is fair
     game if the round can still afford it. ]]
local function classify(part: BasePart, profile: WeaponConfig.PaintProfile): Verdict
	local known = decided[part]
	if known then
		return known
	end

	local verdict = FRESH
	if part.Transparency > MAX_TRANSPARENCY or SKIP_MATERIAL[part.Material] then
		verdict = NOTHING
	elseif not inLiveMap(part) or isProtected(part) then
		verdict = NOTHING
	--[[ The classic's own test, and after the others because it is the only one
	     that touches the physics engine. GetMass is volume times material
	     density, so this is a size rule wearing a mass rule's clothes: props and
	     panels pass, the warehouse wall does not. See PaintProfile. ]]
	elseif part:GetMass() >= profile.maxMass then
		verdict = MARK_ONLY
	end

	decided[part] = verdict
	return verdict
end

local function admits(part: BasePart, profile: WeaponConfig.PaintProfile): Verdict
	--[[ Already ours. A second coat is free and never refused — see `painted`. ]]
	if painted[part] then
		return REPAINT
	end
	local verdict = classify(part, profile)
	--[[ The one question that is about the ROUND rather than the part, so the one
	     that is asked every time. A part refused here is refused for now; the
	     same part is still FRESH as far as `decided` is concerned, which is what
	     stops a cache from outliving the reason it was written. ]]
	if verdict == FRESH and spent >= profile.budget then
		return MARK_ONLY
	end
	return verdict
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[
	Paints one part, as far as that part allows.

	Returns the colour the CLIENT should splat with, or nil if this surface gets
	no paint at all. The part itself is recoloured here when it may be; the
	return value is only about what is drawn on top, which is why a wall too big
	to repaint still answers with a colour. See Verdict.
]]
function PaintService:splash(part: BasePart, color: Color3, profile: WeaponConfig.PaintProfile): Color3?
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		return nil
	end
	if typeof(color) ~= "Color3" or typeof(profile) ~= "table" then
		return nil
	end

	local verdict = admits(part, profile)
	if not verdict.mark then
		return nil
	end
	if verdict.recolour then
		if verdict.charge then
			painted[part] = true
			spent += 1
		end
		part.Color = color
	end
	return color
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PaintService:init() end

function PaintService:start()
	--[[ A new map is a new, unpainted world. The clone that was painted has been
	     destroyed — see the header — so the set and the budget are about a map
	     that no longer exists, and carrying either into the next round would mean
	     a team's second run at Crossroads started with its paint already spent. ]]
	local maps: any = Registry.find("MapService")
	if maps and maps.mapChanged then
		serviceTrove:add(maps.mapChanged:connect(function()
			table.clear(painted)
			table.clear(decided)
			spent = 0
		end))
	end
end

function PaintService:destroy()
	serviceTrove:destroy()
	table.clear(painted)
	table.clear(decided)
	spent = 0
end

Registry.register("PaintService", PaintService)

return PaintService
