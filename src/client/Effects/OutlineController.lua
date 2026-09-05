--!nonstrict
--[[
	OutlineController — the single most important piece of the L4D interface.

	You do not learn where your team is from a HUD bar. You learn it from their
	silhouette through the wall, in their colour, and you learn that somebody is
	in trouble because their silhouette starts pulsing. That is the entire
	reason the HUD can afford to be four small panels in a corner.

	Three things are outlined and nothing else:
	  TEAMMATES  in their identity colour from UITheme.getSurvivorColor, at
	             UITheme.Outline.TeammateTransparency
	  TROUBLE    an incapacitated teammate is ALWAYS fully visible and pulses at
	             IncapPulseSpeed; a pinned one turns PinnedColor. Both cut
	             through everything, because both are requests for help that the
	             team has seconds to answer.
	  PICKUPS    ItemColor within ItemMaxDistance, so a medkit on a shelf is
	             findable without a search

	── "SOLID ONLY WHEN THEY ARE ACTUALLY HIDDEN" ──────────────────────────────
	UITheme.Outline.TeammateOccludedOnly asks for the L4D behaviour: a filled
	silhouette when a teammate is behind geometry, a bare rim when they are in
	plain sight. Roblox's Highlight cannot express that on its own —
	HighlightDepthMode.Occluded means "not visible through walls at all", which
	is the exact opposite of what this system exists for. So every Highlight
	here is AlwaysOnTop, and the FILL is switched off for teammates the camera
	can actually see, by one raycast per teammate on the throttled tick. Set
	TeammateOccludedOnly = false and the fill stays on always.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	Highlights are not free — the engine renders them in one pass with a soft
	limit in the low thirties, past which they silently stop appearing. So:
	  * MAX_HIGHLIGHTS live instances, recycled from a pool keyed by target
	  * candidates are scored and sorted, so the cap always spends itself on the
	    teammates in trouble first and the furthest pickup last
	  * the scan runs at SCAN_HZ, not every frame; only the incap pulse is
	    per-frame, and only for the one or two highlights that are pulsing
	  * the pickup list is kept by CollectionService's tag signals rather than
	    rescanned, so a horde adding several children a second to Workspace costs
	    nothing at all — none of them are ever a pickup
	  * every reusable table is module-level; a tick allocates nothing
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Device = require(Shared.Util.Device)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local RequisitionConfig = require(Shared.Config.RequisitionConfig)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local OUTLINE = UITheme.Outline
local PA = Attributes.Player
local IA = Attributes.Infected
local STATE = Enums.SurvivorState

--[[
	The ceiling on live Highlight instances.

	Roblox stops rendering them somewhere in the low thirties with no warning, so
	this stays well under that: four survivors and a room full of pickups never
	needs more.

	A Highlight is a full-screen post pass per instance — the most expensive
	per-frame render feature this client uses — and this number was the same on
	every device. The ordering in `sort` already puts teammates and downed
	survivors above pickups, so a smaller ceiling drops PICKUP outlines first and
	keeps every person: on a phone you still see who is down and where the team
	is, and you find the pipe bomb by looking at it rather than through a wall.

	Eight, not four, because four survivors plus one downed marker is five before
	a single item, and a phone player needs the team read most of all.
]]
local MAX_HIGHLIGHTS = 14

local function adoptHighlightCap()
	MAX_HIGHLIGHTS = Device.pick({ Mobile = 8, Tablet = 11 }, 14)
end

-- Ten times a second is faster than a player can act on and eight times
-- cheaper than every frame.
local SCAN_HZ = 10
local SCAN_INTERVAL = 1 / SCAN_HZ

--[[
	Pickups are found by TAG, and the list is kept by the tag's own signals
	rather than rebuilt on a clock.

	It used to walk Workspace:GetChildren() once a second looking for the
	Attributes.Pickup.Slot attribute. That is where ItemPlacer and
	InventoryService put theirs, so it worked — and it silently missed every item
	standing in the MAP, because a map's items live three levels down inside the
	map model rather than at the top of Workspace. The pickups a level designer
	placed by hand were the only ones in the game with no outline on them, which
	is exactly backwards: a pill bottle on a dark floor has no glow of its own and
	needs the outline far more than a pad item sitting on a lit marker ring does.

	Walking the whole of Workspace instead would be thousands of instances a
	second to find a dozen things. GetTagged is a lookup, and its two signals mean
	the periodic rescan does not have to exist at all — a pickup joins the list
	the instant it is stood up rather than up to a second later.
]]

--[[ Sort keys. Lower goes first, and the cap is spent from the top: a downed
     teammate outranks a healthy one, and any teammate outranks a medkit. ]]
local RANK_TROUBLE = 0
local RANK_TEAMMATE = 1
--[[ Above pickups, below teammates. A special coming for you matters more than
     a medkit on a shelf and less than the person bleeding out at your feet —
     and the cap is spent from the top, so when the screen is full it is the
     ammo box that stops being outlined and not the Hunter. ]]
local RANK_THREAT = 2
local RANK_ITEM = 3

--[[ How far a spotted special is drawn from. Shorter than the teammate range on
     purpose: this is meant to answer "what is about to reach me", not to hand
     the team a map of every special on the level, which would turn the horde
     into a to-do list and delete the tension the specials exist to create. ]]
local THREAT_MAX_DISTANCE = 140

-- Sub-frame transparency changes are invisible and are not worth a write.
local TRANSPARENCY_EPSILON = 0.01

local OutlineController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local folder: Folder
local enabled = true

type Record = {
	highlight: Highlight,
	target: Instance,
	rank: number,
	color: Color3,
	pulsing: boolean,
	fill: number,
}

type Candidate = {
	target: Instance,
	rank: number,
	distance: number,
	color: Color3,
	fill: number,
	pulsing: boolean,
}

-- Live records keyed by the instance they adorn, so a teammate keeps the same
-- Highlight across ticks and never flickers from being rebuilt.
local records: { [Instance]: Record } = {}
local recordCount = 0
local free: { Highlight } = {}

-- Every table below is reused between ticks. A scan allocates nothing.
local candidates: { Candidate } = {}
local candidateCount = 0
local pulsing: { Record } = {}
local pulsingCount = 0
--[[ Every special and boss currently alive, kept by ChildAdded rather than
     rescanned. See collectThreats: the Infected folder is mostly Commons and
     filtering it every tick would be the most expensive thing in this file. ]]
local threats: { [Model]: true } = {}

local pickups: { Instance } = {}
local pickupCount = 0
local seen: { [Instance]: boolean } = {}

local scanAccumulator = SCAN_INTERVAL

local losParams = RaycastParams.new()
local losFilter: { Instance } = {}

local hud: any = nil

-- ── helpers ─────────────────────────────────────────────────────────────────

--[[ The colour that identifies a survivor everywhere in the interface. Read
     back out of HudController rather than derived here: a teammate whose
     outline and HUD panel disagree about which one they are is worse than no
     colour at all. The fallback is join order, which is what HudController
     itself assigns from. ]]
local function survivorColor(target: Player): Color3
	if hud == nil then
		hud = Registry.find("HudController") or false
	end
	if hud and typeof(hud.getSurvivorColor) == "function" then
		local ok, color = pcall(hud.getSurvivorColor, hud, target)
		if ok and typeof(color) == "Color3" then
			return color
		end
	end
	local roster = Players:GetPlayers()
	local index = table.find(roster, target) or 1
	return UITheme.getSurvivorColor(index)
end

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

--[[ True when something solid sits between the camera and a teammate. One
     RaycastParams and one filter table for the whole session: assigning the
     property copies the list, so reusing the table costs nothing and allocates
     nothing. ]]
local function isOccluded(from: Vector3, target: BasePart, character: Model?): boolean
	local delta = target.Position - from
	local distance = delta.Magnitude
	if distance < 1 then
		return false
	end

	local count = 0
	local ownCharacter = player.Character
	if ownCharacter then
		count += 1
		losFilter[count] = ownCharacter
	end
	if character then
		count += 1
		losFilter[count] = character
	end
	for index = #losFilter, count + 1, -1 do
		losFilter[index] = nil
	end
	losParams.FilterDescendantsInstances = losFilter

	return Workspace:Raycast(from, delta, losParams) ~= nil
end

local function pushCandidate(
	target: Instance,
	rank: number,
	distance: number,
	color: Color3,
	fill: number,
	pulse: boolean
)
	candidateCount += 1
	local entry = candidates[candidateCount]
	if not entry then
		entry = {
			target = target,
			rank = rank,
			distance = distance,
			color = color,
			fill = fill,
			pulsing = pulse,
		}
		candidates[candidateCount] = entry
		return
	end
	entry.target = target
	entry.rank = rank
	entry.distance = distance
	entry.color = color
	entry.fill = fill
	entry.pulsing = pulse
end

--[[ Rank first, then distance. A comparator declared here rather than inline so
     table.sort is not handed a fresh closure ten times a second. ]]
local function byUrgency(a: Candidate, b: Candidate): boolean
	if a.rank ~= b.rank then
		return a.rank < b.rank
	end
	return a.distance < b.distance
end

-- ── highlight pool ──────────────────────────────────────────────────────────

local function acquire(): Highlight
	local count = #free
	if count > 0 then
		local highlight = free[count]
		free[count] = nil
		return highlight
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "FL_Outline"
	--[[ Always on top, always. Occluded would mean "not visible through walls",
	     which would delete the only reason this system exists; the fill is what
	     gets switched instead. See the header. ]]
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.OutlineTransparency = 0
	highlight.FillTransparency = 1
	highlight.Enabled = false
	highlight.Parent = folder
	trove:add(highlight)
	return highlight
end

local function release(record: Record)
	local highlight = record.highlight
	highlight.Enabled = false
	highlight.Adornee = nil
	table.insert(free, highlight)
	records[record.target] = nil
	recordCount -= 1
end

local function releaseAll()
	for _, record in records do
		release(record)
	end
	table.clear(records)
	recordCount = 0
	pulsingCount = 0
end

-- ── scanning ────────────────────────────────────────────────────────────────

--[[ Every direct child of Workspace carrying the pickup contract. Direct
     children only, because that is where both ItemPlacer and a dropped weapon
     put them, and walking the whole descendant tree once a second during a
     horde would not be free. ]]
--[[ Rebuilds the list from the tag. Called once when the controller starts and
     never again on a clock — the signals below keep it current. ]]
local function rescanPickups()
	pickupCount = 0
	for _, tagged in CollectionService:GetTagged(Attributes.PickupTag) do
		pickupCount += 1
		pickups[pickupCount] = tagged
	end
	for index = #pickups, pickupCount + 1, -1 do
		pickups[index] = nil
	end
end

--[[ One removal. A linear search rather than a map, because the list is a dozen
     entries and collectPickups walks it by index every frame — the array is the
     shape that matters and a second structure to keep in step with it would cost
     more than the search. ]]
local function forgetPickup(instance: Instance)
	for index = 1, pickupCount do
		if pickups[index] == instance then
			pickups[index] = pickups[pickupCount]
			pickups[pickupCount] = nil
			pickupCount -= 1
			return
		end
	end
end

local function collectTeammates(eye: Vector3)
	local maxDistance = OUTLINE.TeammateMaxDistance
	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		local character = other.Character
		local root = if character then rootOf(character) else nil
		if not character or not root then
			continue
		end

		local survivorState = Attributes.get(other, PA.State, STATE.Spectating)
		if survivorState == STATE.Dead or survivorState == STATE.Spectating then
			continue
		end

		local distance = (root.Position - eye).Magnitude
		if distance > maxDistance then
			continue
		end

		local pinnedBy = Attributes.get(other, PA.PinnedBy, "")
		local pinned = survivorState == STATE.Pinned or (typeof(pinnedBy) == "string" and pinnedBy ~= "")
		local down = survivorState == STATE.Incapacitated or survivorState == STATE.LedgeHanging

		if down then
			--[[ A downed teammate is a distress signal, and a distress signal
			     that can be hidden by a doorway is not one. Always solid,
			     always pulsing. ]]
			pushCandidate(
				character,
				RANK_TROUBLE,
				distance,
				survivorColor(other),
				OUTLINE.IncapTransparency,
				true
			)
		elseif pinned then
			pushCandidate(
				character,
				RANK_TROUBLE,
				distance,
				OUTLINE.PinnedColor,
				OUTLINE.IncapTransparency,
				true
			)
		else
			local fill = OUTLINE.TeammateTransparency
			if OUTLINE.TeammateOccludedOnly and not isOccluded(eye, root, character) then
				-- In plain sight: the rim is enough, and a filled teammate you
				-- are looking at is a teammate you cannot shoot past.
				fill = 1
			end
			pushCandidate(character, RANK_TEAMMATE, distance, survivorColor(other), fill, false)
		end
	end
end

--[[
	Specials and bosses, when the team has bought SPOTTER.

	The only requisition with no gameplay effect at all — it changes nothing
	about damage, speed, health or ammunition, and that is exactly why it is the
	one that most changes how a round is played. Knowing there is a Hunter above
	you and to the left is not power, it is the information the whole special
	roster is built on withholding, and buying it back is a real decision.

	The watched set is maintained on ChildAdded rather than rescanned like the
	pickups are, because during a horde the Infected folder holds sixty bodies
	and fifty-eight of them are Commons that must never be outlined. Filtering
	that list once a second would be the most expensive thing in this file.
]]
local function collectThreats(eye: Vector3)
	if not RequisitionConfig.isActive(Workspace, "Spotter") then
		return
	end
	for model in threats do
		if not model.Parent or Attributes.get(model, IA.IsDead, false) == true then
			continue
		end
		local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			continue
		end
		local distance = (root.Position - eye).Magnitude
		if distance > THREAT_MAX_DISTANCE then
			continue
		end
		local definition = InfectedConfig.get(Attributes.get(model, IA.Kind, "") :: string)
		local color = if definition then definition.outlineColor else OUTLINE.PinnedColor
		pushCandidate(model, RANK_THREAT, distance, color, OUTLINE.TeammateTransparency, false)
	end
end

local function collectPickups(eye: Vector3)
	local maxDistance = OUTLINE.ItemMaxDistance
	for index = 1, pickupCount do
		local model = pickups[index]
		if not model or not model.Parent then
			continue
		end
		local pivot: Vector3
		if model:IsA("Model") then
			pivot = model:GetPivot().Position
		elseif model:IsA("BasePart") then
			pivot = model.Position
		else
			continue
		end

		local distance = (pivot - eye).Magnitude
		if distance <= maxDistance then
			pushCandidate(model, RANK_ITEM, distance, OUTLINE.ItemColor, OUTLINE.TeammateTransparency, false)
		end
	end
end

local function applyCandidates()
	table.sort(candidates, byUrgency)

	local limit = math.min(candidateCount, MAX_HIGHLIGHTS)
	table.clear(seen)
	pulsingCount = 0

	for index = 1, limit do
		local entry = candidates[index]
		local target = entry.target
		seen[target] = true

		local record = records[target]
		if not record then
			record = {
				highlight = acquire(),
				target = target,
				rank = entry.rank,
				color = entry.color,
				pulsing = entry.pulsing,
				fill = -1,
			}
			records[target] = record
			recordCount += 1

			-- A recycled Highlight still wears the last target's colour, so a
			-- fresh record always writes both, never only on a change.
			local fresh = record.highlight
			fresh.FillColor = entry.color
			fresh.OutlineColor = entry.color
			fresh.FillTransparency = 1
			fresh.Adornee = target
			fresh.Enabled = true
		end

		record.rank = entry.rank
		record.pulsing = entry.pulsing

		local highlight = record.highlight
		if record.color ~= entry.color then
			record.color = entry.color
			highlight.FillColor = entry.color
			highlight.OutlineColor = entry.color
		end
		if not entry.pulsing and math.abs(record.fill - entry.fill) > TRANSPARENCY_EPSILON then
			record.fill = entry.fill
			highlight.FillTransparency = entry.fill
		end

		if entry.pulsing then
			pulsingCount += 1
			pulsing[pulsingCount] = record
		end
	end

	for index = #pulsing, pulsingCount + 1, -1 do
		pulsing[index] = nil
	end

	-- Anything that fell off the list, went out of range, died or was picked up.
	for target, record in records do
		if not seen[target] or not target.Parent then
			release(record)
		end
	end
end

local function scan()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position

	candidateCount = 0
	collectTeammates(eye)
	collectThreats(eye)
	collectPickups(eye)

	-- Trailing entries keep stale instance references alive; clear them so a
	-- dead character can be collected.
	for index = #candidates, candidateCount + 1, -1 do
		candidates[index] = nil
	end

	applyCandidates()
end

--[[ The pulse, and the only thing in this file that runs every frame. It
     touches at most a couple of Highlights — the ones asking for help — and it
     runs at frame rate because a distress signal that steps at 10Hz reads as a
     rendering fault rather than as urgency. ]]
local function updatePulse()
	if pulsingCount == 0 then
		return
	end
	--[[ Between fully solid and the ordinary teammate transparency, so the pulse
	     is a change in weight rather than a flicker. Both ends are UITheme's. ]]
	local wave = (math.sin(os.clock() * OUTLINE.IncapPulseSpeed * math.pi * 2) + 1) * 0.5
	local fill = OUTLINE.IncapTransparency + (OUTLINE.TeammateTransparency - OUTLINE.IncapTransparency) * wave

	for index = 1, pulsingCount do
		local record = pulsing[index]
		if math.abs(record.fill - fill) > TRANSPARENCY_EPSILON then
			record.fill = fill
			record.highlight.FillTransparency = fill
		end
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Turned off during a cinematic or a chapter card, where a silhouette through
     the wall is a hole in the shot. ]]
function OutlineController:setEnabled(value: boolean)
	local wanted = value == true
	if wanted == enabled then
		return
	end
	enabled = wanted
	if not enabled then
		releaseAll()
	else
		scanAccumulator = SCAN_INTERVAL
	end
end

function OutlineController:isEnabled(): boolean
	return enabled
end

--[[ Forces the next frame to rescan the roster. Anything that changes who is on
     the team can call this instead of waiting out the tick. Pickups are not part
     of it: they are kept by tag signals and are already current. ]]
function OutlineController:refresh()
	scanAccumulator = SCAN_INTERVAL
end

function OutlineController:getCount(): number
	return recordCount
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function update(deltaTime: number)
	if not enabled then
		return
	end

	scanAccumulator += deltaTime
	if scanAccumulator >= SCAN_INTERVAL then
		scanAccumulator = 0
		scan()
	end

	updatePulse()
end

function OutlineController:init()
	folder = Instance.new("Folder")
	folder.Name = "FL_Outlines"
	folder.Parent = Workspace
	trove:add(folder)

	losParams.FilterType = Enum.RaycastFilterType.Exclude
	losParams.IgnoreWater = true
	-- Decoration is not cover. A gib, an effect part or a trigger volume must
	-- never read as a wall and switch a teammate's fill on behind it.
	losParams.RespectCanCollide = true

	adoptHighlightCap()
	trove:add(Device.changed:connect(adoptHighlightCap))
end

--[[ Adds a body to the spotted set if it is one of the things worth spotting.
     Read off the definition rather than a list of kind names, so a special added
     to InfectedConfig is spotted without anybody remembering to come here. ]]
local function considerThreat(child: Instance)
	if not child:IsA("Model") then
		return
	end
	local definition = InfectedConfig.get(Attributes.get(child, IA.Kind, "") :: string)
	if definition and (definition.isSpecial or definition.isBoss) then
		threats[child] = true
	end
end

local function watchInfected(infectedFolder: Instance)
	table.clear(threats)
	for _, child in infectedFolder:GetChildren() do
		considerThreat(child)
	end
	trove:connect(infectedFolder.ChildAdded, considerThreat)
	trove:connect(infectedFolder.ChildRemoved, function(child: Instance)
		if child:IsA("Model") then
			threats[child :: Model] = nil
		end
	end)
end

function OutlineController:start()
	--[[ The pickup list, and then the two signals that keep it that way. Built
	     once here rather than on a clock — see the note on Attributes.PickupTag
	     for the bug that came of scanning for them instead. ]]
	rescanPickups()
	trove:connect(CollectionService:GetInstanceAddedSignal(Attributes.PickupTag), function(instance: Instance)
		pickupCount += 1
		pickups[pickupCount] = instance
	end)
	trove:connect(CollectionService:GetInstanceRemovedSignal(Attributes.PickupTag), forgetPickup)

	--[[ The Infected folder is made by InfectedService on the first spawn, which
	     on a fresh server is after the client has booted. One connection, dropped
	     the moment it fires. ]]
	local infectedFolder = Workspace:FindFirstChild("Infected")
	if infectedFolder then
		watchInfected(infectedFolder)
	else
		local connection: RBXScriptConnection
		connection = Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == "Infected" then
				connection:Disconnect()
				watchInfected(child)
			end
		end)
		trove:add(connection)
	end

	trove:connect(Players.PlayerRemoving, function(leaving: Player)
		local character = leaving.Character
		local record = if character then records[character] else nil
		if record then
			release(record)
		end
	end)

	trove:connect(RunService.RenderStepped, update)
end

function OutlineController:destroy()
	releaseAll()
	trove:destroy()
	table.clear(free)
	table.clear(candidates)
	table.clear(threats)
	table.clear(pulsing)
	--[[ The count with the list. It used to be left behind, which was harmless
	     only because the next tick's rescan reset it a fraction of a second
	     later — and the rescan is gone now that the list is kept by tag
	     signals, so a stale count would outlive the teardown that emptied it. ]]
	table.clear(pickups)
	pickupCount = 0
	table.clear(seen)
end

Registry.register("OutlineController", OutlineController)

return OutlineController
