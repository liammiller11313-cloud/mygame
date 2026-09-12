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
local Types = require(Shared.Types)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local LA = Attributes.Loadout

--[[ Marks a Tool this service put there, so cleanup never touches a Tool that
     arrived some other way. Named rather than tracked in a table because the
     Tool can be destroyed by the engine — on death, on reset — and a table of
     references would outlive the things in it. ]]
local OWNED_TAG = "FL_NativeTool"

local NativeToolService = {}

local serviceTrove = Trove.new()
--[[ Connections that belong to the Tool currently in a hand, not to the
     service. Cleaned when that Tool goes, because the next one is a different
     instance and its Activated is a different signal — leaving the old one
     connected would spend a round per shot per weapon ever equipped. ]]
local toolTrove = Trove.new()
-- What each player is currently holding, by weapon id, so an unchanged slot
-- does not re-clone a Tool the player is in the middle of using.
local held: { [Player]: string } = {}
--[[ Rigs already claimed this life, so a second tag cannot overwrite the first.
     Cleared when the tag that set it is removed, which every one of these
     scripts does on a Debris timer. ]]
local _lastTagged: { [Model]: boolean } = {}
--[[ Live only while at least one player holds a native tool. Held outside the
     trove because it is connected and disconnected repeatedly through a round,
     which is not what a trove is for. ]]
local creditWatch: RBXScriptConnection? = nil

--[[ Which of the four the player is holding, for the damage context's weaponId.
     Read at credit time rather than stored with the tag: the tag carries only a
     player, and the alternative is guessing. ]]
local function _heldWeapon(player: Player): string
	return held[player] or ""
end

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

--[[ Both places a Tool can be: the Backpack when stowed, the character when
     equipped. Written out rather than looped over `{ backpack, character }`,
     because a generic for over a table literal halts at the first nil — and a
     player with no Backpack yet would have made that literal `{ nil, character }`
     and cleaned NEITHER, leaving the equipped Tool in their hand forever. ]]
local function sweepTools(container: Instance?)
	if not container then
		return
	end
	for _, child in container:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute(OWNED_TAG) then
			child:Destroy()
		end
	end
end

--[[
	── FITTING THE TOOL TO THIS GAME'S HAND, WITHOUT TOUCHING ITS CODE ─────────
	Three properties, none of them behaviour, all of them things a brickbattle
	tool never had to care about and this game does.

	MASSLESS. A Tool's Handle is welded into the arm, and its mass is added to
	the character's. In brickbattle that was a slab of a gun on a default rig and
	nobody noticed; here walkspeed, jump height and the shove all read off a mass
	that would now change depending on which weapon is out. A weapon you can feel
	in your legs is a weapon that has changed the movement, and movement is not
	the Tool's to change.

	CANCOLLIDE. An equipped Handle that collides is a solid object attached to
	your arm: it catches on door frames, shoves teammates, and in first person it
	pushes the camera. Touched still fires without it — which matters, because
	Touched is exactly how SwordScript does its damage — so nothing in their code
	notices.

	CANBEDROPPED. Backspace drops a Tool on the floor. This game's inventory has
	no idea the Tool exists, so a dropped one is a weapon gone from a slot that
	still says it is there, and a live Tool lying in the map for anyone to pick
	up. The slot is chosen in this game's own UI; dropping is not one of the
	choices it offers.

	Nothing here reads or edits a line of their scripts, and CanQuery and CanTouch
	are deliberately left alone — their scripts raycast and use Touched, and those
	are the two flags that would break if guessed at.
]]
local function conditionTool(tool: Tool)
	tool.CanBeDropped = false
	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Massless = true
			descendant.CanCollide = false
		end
	end
end

local function clearTools(player: Player)
	held[player] = nil
	toolTrove:clean()
	sweepTools(player:FindFirstChildOfClass("Backpack"))
	sweepTools(player.Character)
end

--[[
	── THE KILL CREDIT BRIDGE ──────────────────────────────────────────────────
	Classic Roblox weapons claim a kill by parenting an ObjectValue called
	`creator` onto the victim's Humanoid, whose Value is the killing Player. It
	is how every one of these four scripts does it and it is not going to change,
	because changing it would be editing the author's code.

	Nothing in this game reads that. Kills are credited off `InfectedService.died`
	and its `ctx.attacker`, which is set inside `damage` — and these Tools never
	reach `damage`, they call `Humanoid:TakeDamage` straight. The rig still dies
	properly, because InfectedService's Humanoid.Died connection was written for
	precisely this case. It just dies with no attacker, and a kill with no
	attacker is worth nothing: no stat, no XP, no quest, no leaderboard entry.

	So the tag is turned into the context the rest of the game already speaks.
	The first `creator` to land is the one that counts — a rig shot by two people
	carries two tags, and a later one must not steal a claim the first made,
	which is the same first-come rule the original scripts have by accident
	because theirs expire.

	`_lastTagged` is not a cache of rigs; it is a guard against that overwrite,
	and it is keyed on the tag's own lifetime. Every one of these scripts removes
	its tag on a Debris timer within a second or two, so the entry goes when the
	tag goes and nothing accumulates.
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

	local infected = Registry.find("InfectedService")
	if not infected or typeof(infected.creditPending) ~= "function" then
		return
	end
	-- Only rigs this game is running. A creator tag on a PLAYER — which the
	-- sword places every time somebody hits a teammate — is not a kill credit
	-- question and is handled by SurvivorService's own path.
	if typeof(infected.isTracked) == "function" and not infected:isTracked(model) then
		return
	end
	if _lastTagged[model] then
		return
	end
	_lastTagged[model] = true

	--[[ Bullet rather than a truer type, and deliberately: every consumer
	     switches on damageType, and inventing a fifth kind for these would mean
	     touching each of them for a weapon they otherwise need no opinion on.
	     The weaponId is the real one, so anything reading THAT still sees which
	     gun it was. ]]
	infected:creditPending(
		model,
		Types.newDamageContext({
			attacker = player,
			weaponId = _heldWeapon(player),
			damageType = Enums.DamageType.Bullet,
		})
	)

	creator.AncestryChanged:Connect(function(_, parent)
		if not parent then
			_lastTagged[model] = nil
		end
	end)
end

--[[
	── THE CREDIT WATCH, AND WHY IT IS NOT ALWAYS ON ───────────────────────────
	A `creator` tag is parented onto a Humanoid by somebody else's script at a
	moment this service has no signal for, so DescendantAdded on the whole
	workspace is the only thing that sees it happen.

	That is a very hot signal in this game. Forty-six rigs, every gib and limb
	GoreService makes, every projectile, every effect part — all of it goes
	through this listener, all round, on the server. The handler is two
	comparisons, but two comparisons on every instance added to the world is a
	cost paid continuously for a tag that is only ever placed while somebody is
	holding one of four weapons.

	So it is connected only while somebody is. In a round where nobody took a
	Brickbattle weapon — which is most of them — the listener does not exist.
]]
function NativeToolService:_syncCreditWatch()
	local wanted = next(held) ~= nil
	if wanted == (creditWatch ~= nil) then
		return
	end
	if not wanted then
		if creditWatch then
			creditWatch:Disconnect()
			creditWatch = nil
		end
		return
	end
	creditWatch = workspace.DescendantAdded:Connect(function(instance: Instance)
		if not instance:IsA("ObjectValue") or instance.Name ~= "creator" then
			return
		end
		local humanoid = instance.Parent
		if humanoid and humanoid:IsA("Humanoid") then
			self:_bridgeCredit(humanoid, instance)
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
			self:_syncCreditWatch()
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
	conditionTool(tool)
	--[[
		── THE MAGAZINE, WHICH IS THIS GAME'S AND NOT THE TOOL'S ────────────────
		Their scripts carry no ammo and no reload — a classic brickbattle weapon
		never ran out — and a weapon in this game that never runs out is one the
		loadout cannot be balanced around. So the magazine is ours: the HUD count
		is real, R reloads it, and the client will not activate an empty one.

		Spent HERE, off the Tool's own Activated on the server, because that
		signal IS the weapon firing. The alternative was a packet on FireWeapon,
		which would only ever be the client claiming it fired — and the client
		does not send one for these, it activates the Tool.

		The Tool still decides everything a shot DOES: what it spawns, what it
		sounds like, what it damages. This is the count, and nothing else.
	]]
	toolTrove:connect(tool.Activated, function()
		local inv = Registry.find("InventoryService")
		if inv and typeof(inv.consumeAmmo) == "function" then
			inv:consumeAmmo(player, 1)
		end
	end)
	tool.Parent = backpack
	held[player] = weaponId
	self:_syncCreditWatch()

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

	--[[
		The loadout signal as well as the attribute, because they are not the same
		event and only one of them covers a swap.

		ActiveSlot changing is "the player selected a different slot". A weapon
		being put INTO the slot they already have selected — picking one up,
		buying one, the round handing out a starting loadout — never touches that
		attribute, so watching it alone would leave the old Tool in their hand
		while the game believed they were holding the new one.

		CarryVisualService takes `changed` for exactly this reason; the two now
		wake on the same events, which is what stops the model in the hand and the
		Tool in the hand disagreeing. refresh is idempotent and returns on the
		first line when nothing moved, so hearing both is free.
	]]
	local inventory = Registry.find("InventoryService")
	if inventory and inventory.changed then
		serviceTrove:add(inventory.changed:connect(function(player: Player)
			self:refresh(player)
		end))
	else
		warn("[NativeToolService] no InventoryService; native tools will not be handed out")
	end

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	serviceTrove:connect(Players.PlayerAdded, watch)
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		held[player] = nil
		self:_syncCreditWatch()
	end)

	self:_syncCreditWatch()
end

function NativeToolService:destroy()
	for player in held do
		clearTools(player)
	end
	table.clear(held)
	toolTrove:destroy()
	if creditWatch then
		creditWatch:Disconnect()
		creditWatch = nil
	end
	serviceTrove:clean()
end

Registry.register("NativeToolService", NativeToolService)

return NativeToolService
