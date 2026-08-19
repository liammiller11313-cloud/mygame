--!nonstrict
--[[
	CarryVisualService — what a survivor is carrying, on the survivor.

	In Left 4 Dead the single most useful thing you know about a teammate is
	whether they still have a medkit, and you learn it by LOOKING at them. There
	is no menu, no roster panel, no callout — the kit is on their back, and a
	glance down a corridor tells you whether the person in front of you can save
	you. That read is worth more than any HUD element could be, because it comes
	for free while you are already looking where you were going to look.

	So this service does one thing: it mirrors the Health slot onto the character.
	Take a kit, it appears between your shoulder blades. Spend it, drop it, or go
	down and lose it, and it is gone — for everybody, at the same moment, because
	the model lives on the server's copy of the character and replicates like any
	other part of it.

	── WHY THE MODEL IS WELDED, NOT PARENTED ────────────────────────────────────
	A prop parented into a character and left alone falls off it: the parts are
	simulated, the character moves, and physics resolves the disagreement by
	putting the kit on the floor twenty studs back. Every part is welded to one
	root, that root is welded to the torso, and everything is made massless so a
	kit cannot change how a survivor moves. Massless matters more than it sounds:
	a supplied prop built at map scale can weigh more than the person wearing it.

	── WHY IT IS SIZED FROM THE MODEL ───────────────────────────────────────────
	The medkits are props built to be read from three studs away on the floor, not
	to be worn. Scaling by a fixed factor works for a kit that happens to be about
	the right size and turns a large one into a wardrobe, so anything over
	MapConfig.Medkits.CarryMaxSize is scaled to fit that instead.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)

local KIT = MapConfig.Medkits

local CarryVisualService = {}

local serviceTrove = Trove.new()

-- The prop currently on each survivor's back, and what it is showing.
local worn: { [Player]: { model: Model, itemId: string } } = {}

local CARRY_NAME = "FL_Carried"

--[[ Anything that would make the prop behave like a scripted object rather than
     like a decal you can see from across a room. Mirrors PlaceholderFactory's
     own list: a supplied model routinely arrives with a ProximityPrompt still on
     it, and a prompt on somebody's back is an interact target the player can
     never reach and the prompt system has to keep evaluating. ]]
local STRIPPED = { "LuaSourceContainer", "BodyMover", "ProximityPrompt", "ClickDetector", "Sound" }

--[[ The part to hang things off. R15 keeps the chest in UpperTorso and R6 calls
     the whole thing Torso; falling back to the root means an unusual rig gets a
     kit in roughly the right place rather than no kit at all. ]]
local function carryAnchor(character: Model): BasePart?
	return character:FindFirstChild("UpperTorso") :: BasePart?
		or character:FindFirstChild("Torso") :: BasePart?
		or RigUtil.getRoot(character)
end

local function strip(model: Model)
	for _, descendant in model:GetDescendants() do
		for _, className in STRIPPED do
			if descendant:IsA(className) then
				descendant:Destroy()
				break
			end
		end
	end
end

--[[ The longest side of a model's bounding box. What decides whether a supplied
     prop needs scaling down to something a person could wear. ]]
local function longestSide(model: Model): number
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

--[[ Uniform scale about the model's own pivot. Roblox's Model:ScaleTo only
     exists for models with a scale-aware rig, so this does it the explicit way:
     every part's size and its offset from the pivot move together. ]]
local function scaleModel(model: Model, factor: number)
	if math.abs(factor - 1) < 0.01 then
		return
	end
	local origin = model:GetPivot()
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local offset = origin:ToObjectSpace(part.CFrame)
			part.Size *= factor
			part.CFrame = origin * CFrame.new(offset.Position * factor) * (offset - offset.Position)
		end
	end
end

--[[ Welds every part to one root and returns it, so the whole prop moves as a
     single rigid body. Done before the prop touches the character: welding
     across a reparent is what leaves one screw floating in the air. ]]
local function consolidate(model: Model): BasePart?
	local root = model.PrimaryPart
	if not root then
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				root = part
				break
			end
		end
	end
	if not root then
		return nil
	end
	model.PrimaryPart = root

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end
	return root
end

local function removeWorn(player: Player)
	local entry = worn[player]
	if entry then
		if entry.model then
			entry.model:Destroy()
		end
		worn[player] = nil
	end

	--[[ Also sweep the character itself. A respawn hands us a NEW character
	     model, so the table can be empty while an old prop is still parented to
	     a rig somewhere — and a duplicate kit on one back reads as a bug even
	     though it is only a leak. ]]
	local character = player.Character
	if character then
		for _, child in character:GetChildren() do
			if child.Name == CARRY_NAME then
				child:Destroy()
			end
		end
	end
end

--[[ Builds the prop and attaches it. Returns false when there is nothing
     sensible to show, which is not an error: a Health slot holding a
     defibrillator has no supplied model, and no prop beats a wrong one. ]]
local function attach(player: Player, itemId: string): boolean
	local character = player.Character
	if not character or not character.Parent then
		return false
	end
	local anchor = carryAnchor(character)
	if not anchor then
		return false
	end

	local medkits = Registry.find("MedkitService")
	local template = medkits and medkits:getCarryTemplate()
	if not template then
		return false
	end

	local model = template:Clone()
	model.Name = CARRY_NAME
	strip(model)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
		end
	end

	local size = longestSide(model)
	local factor = KIT.CarryScale
	if size * factor > KIT.CarryMaxSize then
		factor = KIT.CarryMaxSize / math.max(size, 0.01)
	end
	scaleModel(model, factor)

	local root = consolidate(model)
	if not root then
		model:Destroy()
		return false
	end

	-- Placed before parenting, so the prop never exists for a frame at the origin
	-- with a physics step in between.
	model:PivotTo(anchor.CFrame * KIT.CarryOffset)
	model.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = root
	weld.Parent = root

	worn[player] = { model = model, itemId = itemId }
	return true
end

--[[ Brings the prop in line with the slot. Cheap to call repeatedly: showing the
     same item twice does nothing, which matters because `changed` fires for
     every slot and this only cares about one. ]]
function CarryVisualService:refresh(player: Player)
	local inventory = Registry.find("InventoryService")
	if not inventory then
		return
	end

	local loadout = inventory:getLoadout(player)
	local entry = loadout and loadout[Enums.Slot.Health]
	local itemId = entry and entry.itemId or ""

	local current = worn[player]
	if current and current.itemId == itemId then
		return
	end

	removeWorn(player)
	if itemId == "" then
		return
	end
	attach(player, itemId)
end

function CarryVisualService:init() end

function CarryVisualService:start()
	local inventory = Registry.find("InventoryService")
	if inventory and inventory.changed then
		serviceTrove:add(inventory.changed:connect(function(player: Player, slot: string)
			if slot == Enums.Slot.Health then
				self:refresh(player)
			end
		end))
	else
		warn("[CarryVisualService] no InventoryService; nothing will appear on anybody's back")
	end

	--[[ A respawn replaces the character, and the new one arrives bare even though
	     the slot never changed. CharacterAdded rather than a SurvivorService
	     signal on purpose: the thing that invalidates the prop is the character
	     model being swapped, which is exactly what this event means and nothing
	     else does.

	     The table entry is cleared first because the prop it names belongs to a
	     rig that is on its way to being destroyed — leaving it would make refresh
	     believe the right kit is already on the right back. ]]
	local function watch(player: Player)
		serviceTrove:connect(player.CharacterAdded, function()
			worn[player] = nil
			--[[ The loadout is restored a moment after the character exists, so
			     reading it on this frame gets the slot as it was mid-respawn.
			     One deferred pass, not a poll. ]]
			task.defer(function()
				if player.Parent then
					self:refresh(player)
				end
			end)
		end)
	end

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	serviceTrove:connect(Players.PlayerAdded, watch)
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		worn[player] = nil
	end)

	local survivors = Registry.find("SurvivorService")
	if survivors and survivors.died then
		serviceTrove:add(survivors.died:connect(function(player: Player)
			removeWorn(player)
		end))
	end
end

function CarryVisualService:destroy()
	for player in worn do
		removeWorn(player)
	end
	serviceTrove:destroy()
end

Registry.register("CarryVisualService", CarryVisualService)

return CarryVisualService
