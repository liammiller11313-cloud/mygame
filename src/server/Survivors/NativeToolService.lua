--!nonstrict
--[[
	NativeToolService — the weapons that run their own code.

	Four weapons in this game are not this game's weapons. The Classic Sword,
	Slingshot, Rocket Launcher and Paintball Gun are the real Tools out of
	Brickbattle Ultimate, and they arrive complete: ServerLauncher and
	LocalLauncher, PogoServer and PogoClient, SwordScript, the Slingshot pair,
	the Explosion and Swoosh sounds, the fire and MouseLoc remotes. All of it
	written to work, and all of it pointless if this game reimplements it
	alongside.

	So for those four, this game gets out of the way. The Tool goes into the
	player's Backpack exactly as its author built it and Roblox equips it; its
	scripts fire the shots, play the sounds and throw the rockets. Everything
	this game would normally do for a weapon — the viewmodel, the carried world
	model, BallisticsService — is switched off for the slot, because two systems
	doing one job is worse than either doing it alone.

	── WHY THE TOOL IS NOT SANITISED ───────────────────────────────────────────
	Every other supplied asset has its scripts destroyed on the way in, and
	PlaceholderFactory's header is right about why: a Script inside a downloaded
	model runs on our server with full permissions.

	The difference is not that these scripts are safe. It is that they are the
	POINT, and that they are the author's own — placed in Assets.Weapons by the
	person who owns the place, which is the same trust boundary as the game's own
	source. A weapon can only take this path by being named in WeaponConfig with
	`nativeTool = true`, so the set is a closed list in source control rather than
	whatever happens to be sitting in a folder.

	── WHAT IT COSTS ───────────────────────────────────────────────────────────
	Ammo and reload are the Tool's own business, so this game's magazine HUD does
	not describe these four. That is not a bug to be fixed later; a brickbattle
	tool has no magazine.

	Kill credit does need bridging, and does not come free. Their scripts tag a
	victim's Humanoid with a `creator` ObjectValue — the classic Roblox
	convention — which DamageService has never heard of. Without the bridge below
	every zombie killed with these four counts for nobody: no XP, no stats, no
	progression. See `_bridgeCredit`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local LA = Attributes.Player

--[[ Marks a Tool this service put there, so cleanup never touches a Tool that
     arrived some other way. Named rather than tracked in a table because the
     Tool can be destroyed by the engine — on death, on reset — and a table of
     references would outlive the things in it. ]]
local OWNED_TAG = "FL_NativeTool"

local NativeToolService = {}

local serviceTrove = Trove.new()
-- What each player is currently holding, by weapon id, so an unchanged slot
-- does not re-clone a Tool the player is in the middle of using.
local held: { [Player]: string } = {}

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[NativeToolService] " .. message)
end

--[[ The definition, or nil for anything this service has no business touching.
     Every entry point goes through here, so "is this one of the four" is asked
     in exactly one place and cannot drift between them. ]]
local function nativeDefinition(weaponId: string?): any?
	if typeof(weaponId) ~= "string" or weaponId == "" then
		return nil
	end
	local definition = WeaponConfig.get(weaponId)
	if definition and definition.nativeTool then
		return definition
	end
	return nil
end

--[[ Public, because CarryVisualService and BallisticsService both have to ask
     it and neither should be reaching into WeaponConfig for a rule this service
     owns. ]]
function NativeToolService:isNative(weaponId: string?): boolean
	return nativeDefinition(weaponId) ~= nil
end

local function assetFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild("Weapons")
end

--[[ The author's Tool, untouched. Not through PlaceholderFactory: everything in
     that pipeline exists to turn a supplied asset into a Model this game can
     weld and measure, and every step of it — sanitise most of all — is the
     opposite of what this weapon needs. ]]
local function findTool(definition: any): Tool?
	local folder = assetFolder()
	if not folder then
		return nil
	end
	for _, name in { definition.modelName, definition.id } do
		local entry = if typeof(name) == "string" then folder:FindFirstChild(name) else nil
		if entry and entry:IsA("Tool") then
			return entry
		end
	end
	return nil
end

local function clearTools(player: Player)
	held[player] = nil
	local character = player.Character
	for _, container in { player:FindFirstChildOfClass("Backpack"), character } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") and child:GetAttribute(OWNED_TAG) then
					child:Destroy()
				end
			end
		end
	end
end

--[[
	── THE KILL CREDIT BRIDGE ──────────────────────────────────────────────────
	Classic Roblox weapons claim a kill by parenting an ObjectValue called
	`creator` onto the victim's Humanoid, whose Value is the killing Player. It
	is how every one of these four scripts does it and it is not going to change,
	because changing it would be editing the author's code.

	Nothing else in this game reads that. DamageService owns kills, and it learns
	about one by being told. So the bridge: when a `creator` tag lands on an
	infected rig and that rig dies, tell StatsService the same thing it would
	have been told had the shot gone through DamageService.

	Watched per rig rather than polled, and only while the tag exists — a tag
	expires on a Debris timer in every one of those scripts, so a listener that
	outlived it would be a leak per zombie per shot.
]]
function NativeToolService:_bridgeCredit(humanoid: Humanoid, creator: ObjectValue)
	local player = creator.Value
	if not player or not player:IsA("Player") then
		return
	end
	local model = humanoid.Parent
	if not model or not model:IsA("Model") then
		return
	end

	local connection: RBXScriptConnection? = nil
	connection = humanoid.Died:Connect(function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		local stats = Registry.find("StatsService")
		if stats and typeof(stats.recordKill) == "function" then
			pcall(function()
				stats:recordKill(player, model)
			end)
		end
	end)

	--[[ The tag going away takes the listener with it. Debris removes it a
	     second or two after the shot in every one of these scripts, so this is
	     the normal path and not the exceptional one. ]]
	creator.AncestryChanged:Connect(function(_, parent)
		if not parent and connection then
			connection:Disconnect()
			connection = nil
		end
	end)
end

--[[ Brings the player's Backpack in line with what they have selected. Cheap to
     call repeatedly: holding the same weapon does nothing at all, which matters
     because this runs on every slot change of every kind. ]]
function NativeToolService:refresh(player: Player)
	local inventory = Registry.find("InventoryService")
	if not inventory then
		return
	end

	local active = player:GetAttribute(LA.ActiveSlot)
	local slot = if typeof(active) == "string" then active else Enums.Slot.Secondary
	local loadout = inventory:getLoadout(player)
	local entry = loadout and loadout[slot]
	local weaponId = entry and entry.itemId or ""

	local definition = nativeDefinition(weaponId)
	if not definition then
		if held[player] then
			clearTools(player)
		end
		return
	end

	if held[player] == weaponId then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local source = findTool(definition)
	if not source then
		warnOnce(
			"missing:" .. weaponId,
			string.format(
				"%q is nativeTool, so its behaviour is meant to come from a real Tool in "
					.. "Assets.Weapons — and there is no Tool of that name there. It will be "
					.. "carried and will do nothing. Put the Tool in, or drop nativeTool from "
					.. "its WeaponConfig entry.",
				weaponId
			)
		)
		return
	end

	clearTools(player)

	local tool = source:Clone()
	tool:SetAttribute(OWNED_TAG, true)
	tool.Parent = backpack
	held[player] = weaponId

	--[[ Equipped for them. The player chose this weapon in this game's own UI,
	     so making them then pick it out of Roblox's hotbar would be asking twice
	     for one decision. ]]
	humanoid:EquipTool(tool)
end

function NativeToolService:init() end

function NativeToolService:start()
	local function watch(player: Player)
		serviceTrove:connect(player:GetAttributeChangedSignal(LA.ActiveSlot), function()
			self:refresh(player)
		end)
		--[[ A new body has a new Backpack and an empty one, so the Tool has to be
		     put back. The slot attribute did not change, so nothing else here
		     would have noticed. ]]
		serviceTrove:connect(player.CharacterAdded, function()
			held[player] = nil
			task.defer(function()
				if player.Parent then
					self:refresh(player)
				end
			end)
		end)
		self:refresh(player)
	end

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	serviceTrove:connect(Players.PlayerAdded, watch)
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		held[player] = nil
	end)

	--[[ The credit bridge, hung on the whole workspace rather than on each rig:
	     a `creator` tag is parented onto a Humanoid by somebody else's script at
	     a moment this service has no signal for, and DescendantAdded is the only
	     thing that sees it happen. ]]
	serviceTrove:connect(workspace.DescendantAdded, function(instance: Instance)
		if not instance:IsA("ObjectValue") or instance.Name ~= "creator" then
			return
		end
		local humanoid = instance.Parent
		if humanoid and humanoid:IsA("Humanoid") then
			self:_bridgeCredit(humanoid, instance)
		end
	end)
end

function NativeToolService:destroy()
	for player in held do
		clearTools(player)
	end
	table.clear(held)
	serviceTrove:clean()
end

return NativeToolService
