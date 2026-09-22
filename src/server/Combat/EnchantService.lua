--!strict
--[[
	EnchantService — what a boss drops, and what it does to the gun you put it on.

	The whole feature, minus two hooks it cannot own: the damage multiplier and
	the on-hit effects live in DamageService, because that is the one funnel every
	bullet, swing, blast and flame already passes through, and re-deciding "who
	fired this and what were they holding" anywhere else would be a second
	authority on a question that is already answered. This file owns the STATE —
	who has what, on which weapon — and DamageService asks it.

	── THE THREE THINGS IT DOES ───────────────────────────────────────────────
	  1. A boss dies, and the first one in each wave leaves a book on the floor.
	  2. A player walks into the book, and it goes onto the weapon in their hands.
	  3. DamageService asks what is on the weapon that just hit something.

	── WHY AN ENCHANTMENT BELONGS TO THE GUN, NOT THE PLAYER ──────────────────
	It is stored per SLOT and stamped with the weapon id that was in that slot
	when it was applied. Swap the gun out and the enchantment goes with it.

	That is the rule that makes the pickup a decision. If it followed the player,
	the correct play would always be to put it on whatever you are holding and
	then buy a better gun, and the choice at the moment of pickup would be no
	choice at all. Because it belongs to the gun, "which of my three weapons gets
	this" is a real question with a real cost — and a team that finds a book
	while holding the wrong thing has a reason to switch before taking it.

	It also means the weapon-conservation rules the inventory already enforces
	suddenly matter: dropping a gun used to cost money, and now it costs the boss
	you killed for it.

	── ROUND-SCOPED, AND NOTHING IS PERSISTED ─────────────────────────────────
	Cleared on every round start. Nothing in here reaches a profile, a purchase
	or a saved loadout, which is the entire reason the feature is safe to add to
	a game with five overlapping ownership systems. See EnchantConfig's header.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local EnchantConfig = require(Shared.Config.EnchantConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local LA = Attributes.Loadout
local DROP = EnchantConfig.Drop

--[[ Which slot's enchantment lives on which attribute. This table IS the list of
     slots that may carry one — a slot with no row here is refused, which is how
     a throwable and a medkit are kept out without a second rule to forget. See
     the note on the attributes themselves. ]]
local SLOT_ATTRIBUTE: { [string]: string } = {
	[Enums.Slot.Primary] = LA.PrimaryEnchant,
	[Enums.Slot.Secondary] = LA.SecondaryEnchant,
	[Enums.Slot.Melee] = LA.MeleeEnchant,
}

--[[ How often the books on the floor are turned and bobbed. Twenty a second
     rather than per frame: this is a prop rotating, nobody is aiming at it, and
     a Heartbeat that does nothing 40 times a second is 40 wakeups a second for
     an effect measured in degrees. ]]
local SPIN_INTERVAL = 1 / 20

--[[ How close you have to be to take one.

     The same range every other pickup uses, asked of the same config, because a
     book on the floor is a thing on the floor and a second number for it would
     be a second number to keep in step. ]]
local CLAIM_RANGE = GameConfig.Interaction.PickupRange

local EnchantService = {}

local serviceTrove = Trove.new()

--[[ Per player, per slot: what is on it, and WHICH WEAPON it was put on.

     The weapon id is the load-bearing half. Without it an enchantment would
     survive a swap, which is the one rule this whole design rests on — see the
     header. With it, `enchantFor` compares the stored id against what is in the
     slot now and a mismatch simply reads as unenchanted.

     Weak-keyed so a player who leaves takes their table with them. ]]
type Grant = { enchantId: string, weaponId: string }
local grants: { [Player]: { [string]: Grant } } = setmetatable({}, { __mode = "k" }) :: any

--[[ Books currently on the floor, and the wave each was dropped for. ]]
type Book = { model: Model, home: CFrame, phase: number, enchantId: string, expiresAt: number }
local books: { Book } = {}

--[[ The last wave that produced a book. See EnchantConfig.Drop.OnePerWave: waves
     11 and 15 can release three Tanks, and a book each would hand a full team
     eight of them in a round. ]]
local lastDropWave = -1

local spinAccumulator = 0

--[[ Its own stream rather than math.random, for the reason RoundService's
     bossRng gives: a shared global means anything else in the round that rolls a
     number changes which enchantment a boss drops, and a drop table nobody can
     reproduce is a drop table nobody can test. ]]
local random = Random.new()

local function warnOnce(key: string, message: string)
	local seen = (EnchantService :: any)._warned
	if not seen then
		seen = {};
		(EnchantService :: any)._warned = seen
	end
	if seen[key] then
		return
	end
	seen[key] = true
	warn("[EnchantService] " .. message)
end

-- ════════════════════════════════════════════════════════════════════════════
--  State
-- ════════════════════════════════════════════════════════════════════════════

--[[ Writes the slot's attribute so the HUD can recolour the tile and a late
     joiner reads the truth. "" for nothing, which is what every reader treats
     as unenchanted. ]]
local function publish(player: Player, slot: string, enchantId: string)
	local attribute = SLOT_ATTRIBUTE[slot]
	if attribute then
		player:SetAttribute(attribute, enchantId)
	end
end

--[[
	What is on the weapon that just hit something.

	DamageService's entry point, and it takes a weapon id rather than a slot
	because that is what a DamageContext carries. Asking the inventory which slot
	that weapon is in would be a lookup per pellet; walking three slots is three
	table reads and no service call.

	A weapon in two slots at once cannot happen — the inventory refuses it — so
	the first match is the only match.
]]
function EnchantService:forWeapon(player: Player, weaponId: string): EnchantConfig.Enchant?
	if typeof(player) ~= "Instance" or typeof(weaponId) ~= "string" or weaponId == "" then
		return nil
	end
	local bySlot = grants[player]
	if not bySlot then
		return nil
	end
	for _, grant in bySlot do
		if grant.weaponId == weaponId then
			return EnchantConfig.get(grant.enchantId)
		end
	end
	return nil
end

--[[
	Puts an enchantment on whatever is in a slot. Returns false when there is
	nothing there to put it on.

	One per weapon, and a second book REPLACES the first rather than stacking.
	Stacking is the easy version and the wrong one: two damage multipliers
	multiply, four books on one shotgun by wave 15 is a number nobody tuned, and
	the interesting question — which of these do I want — disappears the moment
	the answer can be "both".
]]
function EnchantService:apply(player: Player, slot: string, enchantId: string): boolean
	if not SLOT_ATTRIBUTE[slot] then
		return false
	end
	if not EnchantConfig.get(enchantId) then
		return false
	end

	local inventory = Registry.find("InventoryService")
	if not inventory or typeof(inventory.getItem) ~= "function" then
		return false
	end
	--[[ What is in that slot, asked of the inventory rather than read off the
	     loadout attribute. The attribute is a MIRROR the inventory publishes and
	     it is one _publish behind a pickup; enchanting the gun somebody just
	     dropped is exactly the race that would produce. ]]
	local ok, weaponId = pcall(inventory.getItem, inventory, player, slot)
	if not ok or typeof(weaponId) ~= "string" or weaponId == "" then
		return false
	end

	local bySlot = grants[player]
	if not bySlot then
		bySlot = {}
		grants[player] = bySlot
	end
	bySlot[slot] = { enchantId = enchantId, weaponId = weaponId }
	publish(player, slot, enchantId)

	Remotes.Event.EnchantApplied:FireClient(player, {
		slot = slot,
		weaponId = weaponId,
		enchantId = enchantId,
	})
	return true
end

--[[
	The weapon in a slot changed. If it is not the one that was enchanted, the
	enchantment is gone.

	DROPPED, not parked. The grant could just as easily be left in place to
	reactivate if the same weapon id came back, and `enchantFor` already compares
	ids so the mechanics would have been correct either way — but that would make
	swapping free, and the cost is the point. An enchantment is what you got for
	killing a boss; putting the gun down has to spend it, or "which of my three
	weapons gets this" stops being a question with anything at stake.

	It also keeps the HUD honest, which the parked version did not: the tile is
	painted off the attribute, so a grant that was merely dormant left a slot
	glowing in an enchantment colour for a gun that did not have one.
]]
local function onSlotChanged(player: Player, slot: string)
	if not SLOT_ATTRIBUTE[slot] then
		return
	end
	local bySlot = grants[player]
	local grant = bySlot and bySlot[slot]
	if not grant then
		return
	end

	local inventory = Registry.find("InventoryService")
	if not inventory or typeof(inventory.getItem) ~= "function" then
		return
	end
	local ok, weaponId = pcall(inventory.getItem, inventory, player, slot)
	if ok and weaponId == grant.weaponId then
		return -- same gun, still enchanted
	end

	bySlot[slot] = nil
	publish(player, slot, "")
	Remotes.Event.EnchantApplied:FireClient(player, {
		slot = slot,
		weaponId = if typeof(weaponId) == "string" then weaponId else "",
		--[[ "" is how the client reads "this went away" — see the note on the
		     remote. It draws no toast for it; the tile going dark is the whole
		     message, and a line announcing a loss the player caused on purpose
		     would be nagging. ]]
		enchantId = "",
	})
end

--[[ Everything this player has, gone. Called on a round start and when they
     leave; the attributes are cleared too, or a HUD tile would stay lit for a
     weapon that is no longer enchanted. ]]
function EnchantService:clear(player: Player)
	grants[player] = nil
	for slot in SLOT_ATTRIBUTE do
		publish(player, slot, "")
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  The book on the floor
-- ════════════════════════════════════════════════════════════════════════════

--[[
	The prop itself.

	Grey-boxed here, with an artist's escape hatch: a model under
	Assets/Enchantments named after the enchantment wins over this, exactly the
	way a supplied weapon model wins over a built gun. Until somebody makes one,
	a small glowing slab in the enchantment's own colour is honest and readable
	at the distance it needs to be readable from.
]]
local function buildBook(enchant: EnchantConfig.Enchant): Model
	local factory = Registry.find("PlaceholderFactory")
	if factory and typeof(factory.buildSuppliedModel) == "function" then
		local ok, supplied = pcall(factory.buildSuppliedModel, factory, "Enchantments", enchant.displayName)
		if ok and typeof(supplied) == "Instance" and supplied:IsA("Model") then
			return supplied
		end
	end

	local model = Instance.new("Model")
	model.Name = "FL_EnchantBook"

	local slab = Instance.new("Part")
	slab.Name = "Handle"
	slab.Size = Vector3.new(1.6, 2.1, 0.45)
	slab.Color = enchant.color
	slab.Material = Enum.Material.Neon
	slab.Anchored = true
	slab.CanCollide = false
	--[[
		QUERYABLE, and on the Debris group. Both halves matter and they pull in
		opposite directions.

		It has to answer a raycast, because that is how PromptController finds
		anything — CanQuery off is the setting a gib and a corpse use precisely so
		they are invisible to queries, and a book nobody can look at is a book with
		no prompt and no way to take it.

		But a queryable part in the open is a part that can stop a bullet meant for
		the next zombie, which would make the reward cost a kill. The Debris group
		is the existing answer: BallisticsService's isPierceable returns true for
		it unconditionally, the same way it does for a severed limb, so a round
		passes straight through and still hits what is behind.
	]]
	slab.CanQuery = true
	slab.CollisionGroup = "Debris"
	slab.CanTouch = false
	slab.CastShadow = false
	slab.Parent = model
	model.PrimaryPart = slab

	--[[ A dark spine down one edge, so the slab reads as a BOOK at a glance
	     rather than as a glowing brick. One part, and it is most of the read. ]]
	local spine = Instance.new("Part")
	spine.Name = "Spine"
	spine.Size = Vector3.new(0.3, 2.2, 0.55)
	spine.Color = Color3.fromRGB(28, 24, 22)
	spine.Material = Enum.Material.SmoothPlastic
	spine.Anchored = true
	spine.CanCollide = false
	--[[ The spine is decoration and does not need to be found: the slab answers
	     the query, and classifyInstance walks up to the model either way. Off, so
	     it is one less thing in the open for a round to consider. ]]
	spine.CanQuery = false
	spine.CanTouch = false
	spine.CastShadow = false
	spine.CFrame = slab.CFrame * CFrame.new(-0.85, 0, 0)
	spine.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = slab
	weld.Part1 = spine
	weld.Parent = spine

	local light = Instance.new("PointLight")
	light.Color = enchant.color
	light.Range = 14
	light.Brightness = 2
	light.Shadows = false
	light.Parent = slab

	return model
end

--[[ Drops one where a boss died. Public so a designer or a future mode can hand
     one out deliberately; the round's own drops come through onInfectedDied. ]]
function EnchantService:dropBook(position: Vector3, enchantId: string): Model?
	local enchant = EnchantConfig.get(enchantId)
	if not enchant or typeof(position) ~= "Vector3" then
		return nil
	end

	local model = buildBook(enchant)

	--[[
		Floated above the FLOOR under the body, not above the body's own root.

		A HumanoidRootPart sits at the middle of whatever it belongs to, and a
		Tank is over thirteen studs tall — so "the root plus a few studs" put the
		reward about ten studs up, which is the whole of PickupRange and out of
		reach of anybody standing under it. It worked perfectly on a Common and
		failed on three of the four bosses, which is the worst possible way for
		it to fail.

		So the ground is found first and the rise is measured from there,
		regardless of what died. A body with no floor under it — off a ledge,
		over a pit — falls back to its own position, which is at least somewhere
		the fight happened.
	]]
	local ignore: { Instance } = {}
	--[[ The corpse and its gibs are what the body LEFT, and a book resting on a
	     Tank's chest is a book nobody can see. Asked of GoreService rather than
	     found by folder name, so renaming the folder cannot silently stop this
	     working. ]]
	local gore: any = Registry.find("GoreService")
	if gore and typeof(gore._folder) == "Instance" then
		table.insert(ignore, gore._folder)
	end
	local ground = RaycastUtil.groundAt(position, 60, ignore)
	local base = if ground then ground else position
	local home = CFrame.new(base + Vector3.new(0, DROP.Rise, 0))
	model:PivotTo(home)

	--[[ Both halves of what the client needs: the tag is how PromptController
	     and the outline finder see it at all, and the id is how the prompt names
	     it before anybody touches it. ]]
	model:SetAttribute(Attributes.EnchantBook.Id, enchantId)
	CollectionService:AddTag(model, Attributes.EnchantBookTag)
	CollectionService:AddTag(model, Attributes.PickupTag)

	model.Parent = Workspace

	--[[ Debris as well as the sweep below. The sweep is what normally removes it
	     and what fires the cleanup; this is the backstop for a service that is
	     torn down mid-round, because a book nobody can claim sitting in the world
	     forever is worse than one that vanished early. ]]
	Debris:AddItem(model, DROP.Lifetime + 5)

	table.insert(books, {
		model = model,
		home = home,
		expiresAt = os.clock() + DROP.Lifetime,
		--[[ Staggered by how many are already out, so two books dropped in the
		     same second do not bob in lockstep like a pair of machines. ]]
		phase = #books * 0.7,
		enchantId = enchantId,
	})

	local audio = Registry.find("AudioService")
	if audio and typeof(audio.playAt) == "function" then
		pcall(audio.playAt, audio, AudioConfig.UI.ObjectiveChange, position)
	end

	return model
end

local function removeBook(index: number)
	local book = books[index]
	if not book then
		return
	end
	table.remove(books, index)
	if book.model.Parent then
		book.model:Destroy()
	end
end

--[[ The book on the floor for this model, or nil. Linear because there are at
     most four of these in a round and usually one. ]]
local function bookFor(model: Instance): (number?, Book?)
	for index, book in books do
		if book.model == model then
			return index, book
		end
	end
	return nil, nil
end

--[[
	Takes one book, for one player. SurvivorService's entry point.

	The slot is whatever they are HOLDING. Not a menu and not a best guess: the
	weapon in your hands when you press the key is a thing you chose, and it is
	the only reading that makes "switch before you take it" a play rather than a
	wish. The prompt names the enchantment from interact range precisely so that
	choice can be made on the way in.

	A player holding something that cannot carry one — a medkit, a pipe bomb, an
	empty slot — is refused and THE BOOK STAYS. Consuming it would spend a boss
	on nothing, and the player would have no way to know what they had lost.

	Range is re-checked here rather than trusted from the caller, for the
	ordinary reason: a client asks and a server decides. SurvivorService checks
	it too, against the same number, because it checks it for everything.
]]
function EnchantService:claimBook(player: Player, model: Instance): boolean
	if typeof(player) ~= "Instance" or typeof(model) ~= "Instance" then
		return false
	end
	local index, book = bookFor(model)
	if not index or not book then
		return false
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	if (root.Position - book.home.Position).Magnitude > CLAIM_RANGE then
		return false
	end

	local slot = player:GetAttribute(LA.ActiveSlot)
	if typeof(slot) ~= "string" or not SLOT_ATTRIBUTE[slot] then
		return false
	end
	if not self:apply(player, slot, book.enchantId) then
		return false
	end

	removeBook(index)
	return true
end

-- ════════════════════════════════════════════════════════════════════════════
--  The sweep
-- ════════════════════════════════════════════════════════════════════════════

local function stepBooks(now: number)
	for index = #books, 1, -1 do
		local book = books[index]
		if not book.model.Parent then
			table.remove(books, index)
			continue
		end

		--[[ It gives up eventually. A book that waited out the round would let a
		     team bank four of them and apply them all at once on wave 15, which
		     is the pacing this system exists to create thrown away in one go. ]]
		if now >= book.expiresAt then
			removeBook(index)
			continue
		end

		--[[ Turning and bobbing. Both off the HOME CFrame rather than accumulated
		     onto the current one, so a thousand ticks of floating-point error
		     cannot walk the book off its own spot — which is also what lets
		     claimBook measure its range against `home` rather than against a
		     position that is moving under it. ]]
		local spin = CFrame.Angles(0, math.rad(now * DROP.SpinSpeed), 0)
		local lift = math.sin((now + book.phase) * DROP.BobSpeed) * DROP.BobHeight
		book.model:PivotTo(book.home * CFrame.new(0, lift, 0) * spin)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

--[[
	A boss died. Drop a book, at most one per wave.

	The wave index is read rather than counted so it cannot drift: RoundService
	is the authority on which wave this is, and a local counter would disagree
	with it the first time a round was restarted.
]]
local function onInfectedDied(model: Model, ctx: any)
	if typeof(model) ~= "Instance" then
		return
	end

	local kind = model:GetAttribute(Attributes.Infected.Kind)
	local pool = EnchantConfig.dropsFor(kind)
	if not pool or #pool == 0 then
		return -- not a boss, or a boss with nothing authored for it
	end

	local round = Registry.find("RoundService")
	local wave = -1
	if round and typeof(round.getWaveIndex) == "function" then
		local ok, index = pcall(round.getWaveIndex, round)
		if ok and typeof(index) == "number" then
			wave = index
		end
	end

	--[[
		A Harbinger — the rare finale — pays everyone, and is the one thing that
		steps over the per-wave rule. See EnchantConfig.Drop.HarbingerPaysEveryone
		for why that is not the pacing hole the rule exists to close.

		Read off the body's own Elite attribute rather than asked of the round:
		the creature that died is the authority on what it was, and a round that
		has already ticked past wave 15 would answer the wrong question.
	]]
	local harbinger = DROP.HarbingerPaysEveryone
		and model:GetAttribute(Attributes.Infected.Elite) == DROP.HarbingerTier

	if DROP.OnePerWave and not harbinger and wave >= 0 and wave == lastDropWave then
		return -- the pack's second and third Tank give nothing
	end

	--[[ Where the body actually is, falling back to where the damage came from.
	     A boss killed by a rocket can be a long way from its own root by the
	     time this fires, and a book inside a wall is a book nobody gets. ]]
	local position: Vector3? = nil
	local primary = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if primary and primary:IsA("BasePart") then
		position = primary.Position
	elseif typeof(ctx) == "table" and typeof(ctx.hitPosition) == "Vector3" then
		position = ctx.hitPosition
	end
	if not position then
		return
	end

	--[[ One book, or one per survivor still standing. `getSurvivorCharacters`
	     rather than the player list on purpose: a book for somebody spectating a
	     wipe is a book nobody can reach, and counting the lobby would print four
	     of them for a team of one. ]]
	local count = 1
	if harbinger then
		local survivors = Registry.find("SurvivorService")
		if survivors and typeof(survivors.getSurvivorCharacters) == "function" then
			local ok, characters = pcall(survivors.getSurvivorCharacters, survivors)
			if ok and typeof(characters) == "table" then
				count = math.max(#characters, 1)
			end
		end
	end

	--[[ Laid out in a ring rather than stacked on the death point: four books on
	     one spot are four overlapping props, and the prompt would only ever name
	     whichever one the raycast reached first. One book still goes exactly
	     where the body fell. ]]
	--[[ A Harbinger deals one of each out of the whole catalogue instead of
	     drawing twice from its kind's two-entry row — see
	     EnchantConfig.Drop.HarbingerDealsDistinct. Shuffled in place on a COPY:
	     EnchantConfig.All is frozen and shared, and shuffling the real one would
	     reorder it for every later read in the server's life. ]]
	local deal: { string }? = nil
	if harbinger and DROP.HarbingerDealsDistinct then
		deal = table.clone(EnchantConfig.All)
		local list = deal :: { string }
		for index = #list, 2, -1 do
			local swap = random:NextInteger(1, index)
			list[index], list[swap] = list[swap], list[index]
		end
	end

	local dropped = 0
	for index = 1, count do
		local at = position
		if count > 1 then
			local bearing = (index - 1) / count * math.pi * 2
			at = position + Vector3.new(math.cos(bearing), 0, math.sin(bearing)) * DROP.RingRadius
		end
		--[[ Past the end of the deal — more survivors than there are
		     enchantments — falls back to the ordinary draw rather than dropping
		     nothing. A fifth player would otherwise be the one person who got no
		     reward for the hardest fight in the game. ]]
		local id = deal and deal[index] or pool[random:NextInteger(1, #pool)]
		if EnchantService:dropBook(at, id) then
			dropped += 1
		end
	end

	--[[ The wave is marked only once a book actually exists. Marking it before
	     the drop meant a boss whose body had already been cleaned up — no
	     primary part, no hit position — burned the wave's only book without
	     producing one, and the team got nothing for a Tank with no way to know
	     why. ]]
	if dropped > 0 then
		lastDropWave = wave
	end
end

--[[ A new round wipes the slate: every grant, every book on the floor, and the
     per-wave gate. Round-scoped means round-scoped. ]]
local function resetRound()
	lastDropWave = -1
	for index = #books, 1, -1 do
		removeBook(index)
	end
	for _, player in Players:GetPlayers() do
		EnchantService:clear(player)
	end
end

function EnchantService:init()
	--[[ Written for everybody already here, so a client that reads the attribute
	     before the first round starts gets "" rather than nil. Every reader
	     treats both the same; this is so the Studio explorer shows the field. ]]
	for _, player in Players:GetPlayers() do
		self:clear(player)
	end
end

function EnchantService:start()
	local infected = Registry.find("InfectedService")
	if infected and infected.died then
		serviceTrove:add(infected.died:connect(onInfectedDied))
	else
		warnOnce("nodied", "no InfectedService.died; bosses will never drop enchantments")
	end

	local round = Registry.find("RoundService")
	if round and round.waveChanged then
		serviceTrove:add(round.waveChanged:connect(function(index: number)
			if index <= 1 then
				resetRound()
			end
		end))
	else
		warnOnce("nowave", "no RoundService.waveChanged; enchantments will not clear between rounds")
	end
	if round and round.roundEnded then
		serviceTrove:add(round.roundEnded:connect(resetRound))
	end

	local inventory = Registry.find("InventoryService")
	if inventory and inventory.changed then
		serviceTrove:add(inventory.changed:connect(onSlotChanged))
	else
		warnOnce(
			"nochanged",
			"no InventoryService.changed; an enchantment will outlive the weapon it was put on"
		)
	end

	serviceTrove:connect(Players.PlayerAdded, function(player: Player)
		EnchantService:clear(player)
	end)
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		grants[player] = nil
	end)

	serviceTrove:connect(RunService.Heartbeat, function(dt: number)
		if #books == 0 then
			return
		end
		spinAccumulator += dt
		if spinAccumulator < SPIN_INTERVAL then
			return
		end
		spinAccumulator = 0
		stepBooks(os.clock())
	end)
end

function EnchantService:destroy()
	for index = #books, 1, -1 do
		removeBook(index)
	end
	serviceTrove:destroy()
end

Registry.register("EnchantService", EnchantService)

return EnchantService
