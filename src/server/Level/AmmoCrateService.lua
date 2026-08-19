--!nonstrict
--[[
	AmmoCrateService — the resupply crates.

	Six per map, found by NAME rather than by tag: a folder called "Ammo Crate"
	holding models called "Ammo Crate 1" through "Ammo Crate 6". Nothing has to
	be tagged by hand — this service tags them itself when a map loads, which
	means a level designer only has to name things.

	── WHY ONE USE AND A LONG RESPAWN ───────────────────────────────────────────
	A crate refills you completely and then vanishes for nearly three minutes.
	That single rule does most of the work of spreading a team across a map: the
	crate you just burned is a hole in your plan for the next two waves, so the
	team cannot camp one corner and has to move to where the next one is. An
	infinite resupply pile would make ammunition a non-decision, and ammunition
	pressure is most of what makes a horde frightening rather than tedious.

	The spent crate leaves a translucent ghost behind rather than disappearing
	outright, so the SPOT still reads as "a crate lives here" — a player who
	learns the map should be able to plan around a crate that is not there yet.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local CRATE = MapConfig.AmmoCrates

local AmmoCrateService = {}

local serviceTrove = Trove.new()

-- Every crate currently known, and the appearance it had before it was spent.
type CrateRecord = {
	model: Model,
	index: number,
	spentUntil: number,
	looks: { [BasePart]: { transparency: number, color: Color3 } },
}

local crates: { CrateRecord } = {}
local byModel: { [Model]: CrateRecord } = {}
local accumulator = 0

local TICK_INTERVAL = 0.5

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

--[[ Remembers what a crate looked like so the ghost can be undone exactly.
     Stored per part rather than assumed, because a hand-modelled crate may
     already have transparent glass or a coloured decal panel in it. ]]
local function captureLooks(model: Model): { [BasePart]: { transparency: number, color: Color3 } }
	local looks = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			looks[part] = { transparency = part.Transparency, color = part.Color }
		end
	end
	return looks
end

local function setGhost(record: CrateRecord, ghost: boolean)
	for part, look in record.looks do
		if part.Parent then
			if ghost then
				part.Transparency = CRATE.GhostTransparency
				part.Color = CRATE.GhostColor
				part.CanCollide = false
			else
				part.Transparency = look.transparency
				part.Color = look.color
				part.CanCollide = true
			end
		end
	end
end

local function setSpent(record: CrateRecord, spent: boolean)
	local model = record.model
	if not model.Parent then
		return
	end

	model:SetAttribute(Attributes.Crate.Spent, spent)

	if spent then
		record.spentUntil = serverNow() + CRATE.RespawnSeconds
		model:SetAttribute(Attributes.Crate.RespawnAt, record.spentUntil)
		if CRATE.LeaveGhost then
			setGhost(record, true)
		else
			model.Parent = nil
		end
	else
		record.spentUntil = 0
		model:SetAttribute(Attributes.Crate.RespawnAt, 0)
		setGhost(record, false)
	end
end

--[[
	Finds the crates in whatever map is live.

	Deliberately forgiving about naming: the folder is matched case-insensitively
	with spaces stripped, and a crate's index is read from any trailing digits in
	its name. "Ammo Crate 3", "AmmoCrate3" and "ammo crate 3" all work, because
	the alternative is a level designer losing an hour to a missing space.
]]
local function findCrateFolder(root: Instance): Instance?
	local wanted = string.lower(string.gsub(CRATE.FolderName, "%s+", ""))
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Folder") or descendant:IsA("Model") then
			if string.lower(string.gsub(descendant.Name, "%s+", "")) == wanted then
				return descendant
			end
		end
	end
	return nil
end

function AmmoCrateService:rebuild()
	for _, record in crates do
		CollectionService:RemoveTag(record.model, CRATE.Tag)
	end
	table.clear(crates)
	table.clear(byModel)

	local mapService = Registry.find("MapService")
	local root = mapService and mapService:getCurrentRoot() or Workspace

	local folder = findCrateFolder(root)
	if not folder then
		warn(
			string.format(
				"[AmmoCrateService] no %q folder in the live map — there will be no resupply. "
					.. "Add one holding models named %q through %q.",
				CRATE.FolderName,
				CRATE.FolderName .. " 1",
				CRATE.FolderName .. " 6"
			)
		)
		return 0
	end

	for _, child in folder:GetChildren() do
		if not child:IsA("Model") and not child:IsA("BasePart") then
			continue
		end

		-- A crate can be a Model or a single Part; wrap a lone part so everything
		-- downstream only ever deals with a Model.
		local model: Model
		if child:IsA("Model") then
			model = child
		else
			local wrapper = Instance.new("Model")
			wrapper.Name = child.Name
			wrapper.Parent = folder
			child.Parent = wrapper
			wrapper.PrimaryPart = child
			model = wrapper
		end

		local index = tonumber(string.match(model.Name, "(%d+)%s*$") or "") or (#crates + 1)

		local record: CrateRecord = {
			model = model,
			index = index,
			spentUntil = 0,
			looks = captureLooks(model),
		}

		model:SetAttribute(Attributes.Crate.Index, index)
		model:SetAttribute(Attributes.Crate.Spent, false)
		model:SetAttribute(Attributes.Crate.RespawnAt, 0)
		CollectionService:AddTag(model, CRATE.Tag)

		table.insert(crates, record)
		byModel[model] = record
	end

	print(string.format("[AmmoCrateService] %d crate(s) armed", #crates))
	return #crates
end

--[[ True when this crate can be used right now. The client asks the same
     question to decide whether to draw a prompt, but the server's answer is the
     one that counts. ]]
function AmmoCrateService:isAvailable(model: Instance): boolean
	local record = byModel[model]
	if not record then
		return false
	end
	return record.spentUntil <= 0 or serverNow() >= record.spentUntil
end

function AmmoCrateService:isCrate(instance: Instance): boolean
	return byModel[instance] ~= nil
end

--[[
	Resupplies a player from a crate and spends it.

	Returns false without consuming the crate if there was nothing to give, so
	walking into a crate at full ammo does not waste it — that would be a
	genuinely infuriating way to lose a resupply.
]]
function AmmoCrateService:consume(player: Player, model: Instance): boolean
	local record = byModel[model]
	if not record or not self:isAvailable(model) then
		return false
	end

	local inventory = Registry.find("InventoryService")
	if not inventory then
		return false
	end

	local given = inventory:refillReserve(player, CRATE.RefillFraction, CRATE.RefillMagazine)
	if given <= 0 then
		return false
	end

	setSpent(record, true)

	Remotes.Event.AmmoCrateUsed:FireAllClients({
		player = player,
		crate = record.model,
		index = record.index,
		respawnAt = record.spentUntil,
		given = given,
	})

	local audio = Registry.find("AudioService")
	if audio then
		local root = record.model.PrimaryPart or record.model:FindFirstChildWhichIsA("BasePart")
		if root then
			audio:playAt(AudioConfig.UI.Pickup, root.Position)
		end
	end

	return true
end

--[[ Every crate back, immediately. RoundService calls this between rounds so a
     new round never starts with three crates still on cooldown from the last. ]]
function AmmoCrateService:resetAll()
	for _, record in crates do
		if record.spentUntil > 0 then
			setSpent(record, false)
		end
	end
end

function AmmoCrateService:getCrates(): { Model }
	local list = {}
	for _, record in crates do
		table.insert(list, record.model)
	end
	return list
end

function AmmoCrateService:_step()
	local now = serverNow()
	for _, record in crates do
		if record.spentUntil > 0 and now >= record.spentUntil then
			setSpent(record, false)
		end
	end
end

function AmmoCrateService:start()
	local mapService = Registry.find("MapService")
	if mapService and mapService.mapChanged then
		serviceTrove:add(mapService.mapChanged:connect(function()
			self:rebuild()
		end))
	end

	self:rebuild()

	--[[ Half a second is plenty: the respawn is measured in minutes, and a crate
	     coming back a quarter-second late is not something anybody can perceive.
	     Polling here rather than one task.delay per crate means six crates cost
	     one timer instead of six. ]]
	serviceTrove:connect(RunService.Heartbeat, function(dt)
		accumulator += dt
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		self:_step()
	end)
end

function AmmoCrateService:destroy()
	serviceTrove:destroy()
end

Registry.register("AmmoCrateService", AmmoCrateService)

return AmmoCrateService
