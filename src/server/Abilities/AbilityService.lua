--!nonstrict
--[[
	AbilityService — owns the cooldown clock, the validation, and nothing else.

	See Shared/Config/AbilityConfig for what an ability IS and how it differs
	from a requisition and from a modifier. This file is the gate: it decides
	whether a press is allowed to become an activation, charges the cooldown, and
	hands off to the one module that knows what the ability actually does.

	── EVERY ABILITY IS ITS OWN MODULE ─────────────────────────────────────────
	Abilities/<Id>.lua, found by id, with one required function:

	    activate(context) -> boolean

	Returning false means "did not fire" and NO cooldown is charged — a turret
	that found nowhere to stand costs the player nothing, which is the only
	honest answer when the game refused rather than the player wasted it.

	Two optional hooks: `step(dt)` for anything with a lifetime, and `clear()`
	for the end of a round. This service never looks inside an ability's tuning
	table. Adding a sixth ability is a definition, a module, and an enum row.

	── THE CLIENT ONLY EVER ASKS ───────────────────────────────────────────────
	RequestAbility carries a slot number and, for the two abilities that need
	one, a point. Everything else is read here: which ability is in that slot,
	whether the player owns it, whether it is off cooldown, whether they are
	alive, whether a round is running. A client that sends slot 7, an ability it
	has never bought, or a target on the other side of the map gets a refusal.

	── AND THE COOLDOWN IS AN ABSOLUTE STAMP ───────────────────────────────────
	Published to Attributes.Player.AbilityNReadyAt as a
	workspace:GetServerTimeNow() value rather than as seconds remaining. The HUD
	then renders a smooth countdown off a number that only changes when an
	ability is actually used: a cooldown costs one attribute write instead of one
	a second, it cannot drift, and a player watching a teammate's cooldown gets
	it for free.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game

--[[ The floor on how often one player may ASK, whatever the answer. Not a
     gameplay cooldown — that is per ability and much longer — but a bound on
     how much work a client can make this server do by holding a key down. ]]
local REQUEST_THROTTLE = 0.15

local REFUSED = table.freeze({
	Unknown = "No such ability.",
	Slot = "No such slot.",
	Empty = "Nothing equipped there.",
	Unowned = "You do not own that.",
	Cooling = "Still cooling down.",
	Dead = "Not while you are down.",
	Round = "Not right now.",
	Failed = "Could not deploy that here.",
})

local AbilityService = {}

local trove = Trove.new()

--[[ id -> the module that implements it. Loaded once at init from the folder
     beside this one; an ability with a definition and no module is a loud
     warning at boot rather than a silent no-op at the moment somebody presses
     the key. ]]
local modules: { [string]: any } = {}

--[[ [player][slot] = the server time it is next usable. Held here rather than
     on the profile because a cooldown is a property of THIS round, not of the
     account: leaving and rejoining should not preserve one, and dying should
     not clear one. ]]
local cooldowns: { [Player]: { [number]: number } } = {}
local lastRequestAt: { [Player]: number } = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function refuse(player: Player, slot: number, id: string, reason: string)
	Remotes.Event.AbilityResult:FireClient(player, {
		slot = slot,
		id = id,
		ok = false,
		reason = reason,
	})
end

--[[ Publishes what is equipped, so the HUD can draw it without asking. Called
     on spawn, on a loadout change and on join; the ids are read back off the
     profile every time rather than cached, so this cannot disagree with what
     the server would actually accept. ]]
local function publishSlots(player: Player)
	local profiles = Registry.find("ProfileService")
	local slots = if profiles and typeof(profiles.getAbilitySlots) == "function"
		then profiles:getAbilitySlots(player)
		else {}
	for index = 1, AbilityConfig.SlotCeiling do
		local idAttribute = AbilityConfig.attributesFor(index)
		if idAttribute then
			Attributes.set(player, idAttribute, slots[index] or "")
		end
	end
end

local function publishCooldown(player: Player, slot: number, readyAt: number)
	local _, readyAttribute = AbilityConfig.attributesFor(slot)
	if readyAttribute then
		Attributes.set(player, readyAttribute, readyAt)
	end
end

--[[ Every cooldown back to zero, or a player who used a turret in the last ten
     seconds of a round starts the next one still waiting for it. ]]
local function clearCooldowns(player: Player)
	cooldowns[player] = nil
	for index = 1, AbilityConfig.SlotCeiling do
		publishCooldown(player, index, 0)
	end
end

--[[
	Whether an ability may be used at all right now.

	Starting counts, and it did not — which made the fifteen seconds of prep the
	one window where an ability card says READY and every activation is refused.
	That is also the window a player most wants a turret in: the wave has not
	arrived, they are choosing a spot rather than defending one, and "set up
	before it starts" is the entire appeal of a deployable.

	Nothing is gained by refusing it. The cooldown is five minutes, so using it in
	prep is spending it, not duplicating it; the turret it leaves behind is the
	same turret placed fifteen seconds later; and the client already ends a
	placement the moment the round leaves either state.

	Both states, spelled out rather than borrowed from RoundService.isRunning:
	this is a rule about when a PLAYER may act, and it should not silently follow
	a helper that exists to answer a different question.
]]
local function roundIsRunning(): boolean
	local state = Workspace:GetAttribute(GA.RoundState)
	return state == Enums.RoundState.InProgress or state == Enums.RoundState.Starting
end

-- ── the gate ────────────────────────────────────────────────────────────────

local function onRequest(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local at = os.clock()
	if lastRequestAt[player] and at - lastRequestAt[player] < REQUEST_THROTTLE then
		return -- silently; a held key is not a thing worth answering
	end
	lastRequestAt[player] = at

	local slot = payload.slot
	if not AbilityConfig.isSlot(slot) then
		refuse(player, 0, "", REFUSED.Slot)
		return
	end

	local profiles = Registry.find("ProfileService")
	if not profiles or typeof(profiles.getAbilitySlots) ~= "function" then
		refuse(player, slot, "", REFUSED.Failed)
		return
	end

	local id = profiles:getAbilitySlots(player)[slot] or ""
	if id == "" then
		refuse(player, slot, "", REFUSED.Empty)
		return
	end

	local definition = AbilityConfig.get(id)
	if not definition then
		refuse(player, slot, id, REFUSED.Unknown)
		return
	end

	--[[ Asked even though the slot could only hold it if they owned it. The two
	     are set at different times by different code and this is the one that
	     matters, so it is checked rather than assumed. ]]
	if not profiles:ownsAbility(player, id) then
		refuse(player, slot, id, REFUSED.Unowned)
		return
	end

	if not roundIsRunning() then
		refuse(player, slot, id, REFUSED.Round)
		return
	end

	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.isAlive) ~= "function" or not survivors:isAlive(player) then
		refuse(player, slot, id, REFUSED.Dead)
		return
	end

	local ready = (cooldowns[player] and cooldowns[player][slot]) or 0
	if now() < ready then
		refuse(player, slot, id, REFUSED.Cooling)
		return
	end

	local character, root = player.Character, nil
	if character then
		root = RigUtil.getRoot(character)
	end
	if not root then
		refuse(player, slot, id, REFUSED.Dead)
		return
	end

	--[[
		The target, re-derived rather than trusted.

		An untargeted ability ignores whatever the client sent entirely. A
		targeted one is CLAMPED to its range rather than refused past it: a
		player who aimed a little too far gets the edge of what they are allowed,
		which is what they meant, and a player who sent a point across the map
		gets the same thing rather than an exploit.
	]]
	local origin = root.Position
	local target = origin
	if definition.targeted then
		local wanted = payload.target
		if typeof(wanted) ~= "Vector3" or wanted ~= wanted then
			refuse(player, slot, id, REFUSED.Failed)
			return
		end
		local delta = wanted - origin
		local distance = delta.Magnitude
		target = if distance > definition.range and distance > 0
			then origin + delta.Unit * definition.range
			else wanted
	end

	local module = modules[id]
	if not module then
		refuse(player, slot, id, REFUSED.Unknown)
		return
	end

	local ok, fired = pcall(module.activate, {
		player = player,
		definition = definition,
		tuning = definition.tuning,
		origin = origin,
		target = target,
	})
	if not ok then
		warn(string.format("[AbilityService] %s:activate failed: %s", id, tostring(fired)))
		refuse(player, slot, id, REFUSED.Failed)
		return
	end
	if fired == false then
		--[[ The ability declined. No cooldown: the player did not waste it, the
		     game refused it, and charging them ninety seconds for a spot the
		     turret could not stand on is how an ability stops being used. ]]
		refuse(player, slot, id, REFUSED.Failed)
		return
	end

	local readyAt = now() + definition.cooldown
	cooldowns[player] = cooldowns[player] or {}
	cooldowns[player][slot] = readyAt
	publishCooldown(player, slot, readyAt)

	Remotes.Event.AbilityResult:FireClient(player, { slot = slot, id = id, ok = true, reason = "" })
end

-- ── the shop and the loadout ────────────────────────────────────────────────

local function onPurchase(player: Player, id: any)
	local definition = AbilityConfig.get(id)
	local profiles = Registry.find("ProfileService")
	if not definition or not profiles or not profiles:isReady(player) then
		return
	end
	if profiles:ownsAbility(player, definition.id) then
		return
	end

	--[[ Priced from the server's own catalogue. The request carried an id and
	     nothing else, so there is no number here a client could have chosen —
	     the same rule EconomyService's weapon purchase follows. ]]
	if not profiles:trySpend(player, definition.price) then
		return
	end
	if not profiles:grantAbility(player, definition.id) then
		--[[ Spent but not granted, which is only reachable if the profile
		     vanished between the two calls. The money goes back rather than
		     staying gone. ]]
		profiles:addDollars(player, definition.price)
		return
	end

	--[[ Written immediately. A permanent unlock is the thing a player would be
	     most upset to lose to a crash, and it is rare enough that a DataStore
	     write per purchase costs nothing. Same reasoning as a weapon. ]]
	task.spawn(function()
		profiles:flush(player)
	end)
end

local function onSetSlot(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local profiles = Registry.find("ProfileService")
	if not profiles or typeof(profiles.setAbilitySlot) ~= "function" then
		return
	end
	--[[ Not during a round. Abilities are chosen BEFORE a match — that is what
	     makes the two slots a decision rather than a menu you open when you want
	     the other one. It is not an exploit guard: cooldowns are per SLOT, so
	     swapping never returned a fresh one anyway. ]]
	if roundIsRunning() then
		return
	end

	local id = if typeof(payload.id) == "string" then payload.id else ""
	if profiles:setAbilitySlot(player, payload.slot, id) then
		publishSlots(player)
	end
end

-- ── public ──────────────────────────────────────────────────────────────────

--[[
	How much of `amount` survives this player's shield, called from
	SurvivorService's damage funnel.

	Here rather than in the Shield module so that SurvivorService has exactly one
	ability-shaped thing to know about, and returns the REMAINDER rather than a
	boolean so a shield with 10 points left against a 40-point hit takes 10 and
	lets 30 through. An all-or-nothing block would make the last point of a
	shield worth as much as the first hundred.
]]
function AbilityService:absorb(player: Player, amount: number): number
	local shield = modules[Enums.Ability.Shield]
	if not shield or typeof(shield.absorb) ~= "function" then
		return amount
	end
	local ok, remaining = pcall(shield.absorb, player, amount)
	return if ok and typeof(remaining) == "number" then remaining else amount
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function AbilityService:init()
	local folder = script.Parent:FindFirstChild("Abilities")
	for _, definition in AbilityConfig.Definitions do
		local module = if folder then folder:FindFirstChild(definition.id) else nil
		if not module then
			warn(
				string.format(
					"[AbilityService] %s is in AbilityConfig but has no Abilities/%s module — "
						.. "it can be bought and equipped and will refuse to fire",
					definition.id,
					definition.id
				)
			)
			continue
		end
		local ok, loaded = pcall(require, module)
		if ok and typeof(loaded) == "table" and typeof(loaded.activate) == "function" then
			modules[definition.id] = loaded
		else
			warn(
				string.format(
					"[AbilityService] Abilities/%s did not load: %s",
					definition.id,
					tostring(loaded)
				)
			)
		end
	end
end

function AbilityService:start()
	trove:connect(Remotes.Event.RequestAbility.OnServerEvent, onRequest)
	trove:connect(Remotes.Event.PurchaseAbility.OnServerEvent, onPurchase)
	trove:connect(Remotes.Event.SetAbilitySlot.OnServerEvent, onSetSlot)

	--[[ Republished on every spawn, not just on join. The attributes live on the
	     Player rather than the Character so they survive a death, but a client
	     that joined before its profile finished loading read empty ones. ]]
	local function watch(player: Player)
		publishSlots(player)
		clearCooldowns(player)
		trove:connect(player.CharacterAdded, function()
			publishSlots(player)
		end)
	end
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	trove:connect(Players.PlayerAdded, watch)
	trove:connect(Players.PlayerRemoving, function(player: Player)
		cooldowns[player] = nil
		lastRequestAt[player] = nil
	end)

	--[[
		And every round STARTS everybody clean, which the roundEnded handler below
		does not cover on its own.

		That one fires from endRound — a wipe or a victory — and is the normal
		path. It is not the only one: a server that empties returns to the lobby
		without ending a round, a player can leave a match and come back to a
		fresh one, and a cooldown charged in either case survives into the next
		round with nothing to clear it.

		Cheap insurance while cooldowns were thirty seconds, and worth being sure
		about at five minutes: against a seventeen-minute round, carrying one over
		is a third of the next match spent waiting for something the player spent
		the last one on.
	]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		if Workspace:GetAttribute(GA.RoundState) ~= Enums.RoundState.Starting then
			return
		end
		for _, player in Players:GetPlayers() do
			clearCooldowns(player)
		end
	end)

	--[[ A profile finishing its load is what makes the slots real. Without this
	     a player who joins mid-round has empty ability attributes until they
	     next respawn, which for somebody who joined alive is never. ]]
	local profiles = Registry.find("ProfileService")
	if profiles and profiles.changed then
		trove:add(profiles.changed:connect(function(player: Player)
			publishSlots(player)
		end))
	end

	--[[ A round ending clears every cooldown and every live effect. A turret
	     from last round standing in the lobby is the kind of thing that survives
	     a hundred playtests and then ships. ]]
	local round = Registry.find("RoundService")
	if round and round.roundEnded then
		trove:add(round.roundEnded:connect(function()
			for _, player in Players:GetPlayers() do
				clearCooldowns(player)
			end
			for _, module in modules do
				if typeof(module.clear) == "function" then
					pcall(module.clear)
				end
			end
		end))
	end

	--[[ One heartbeat for every ability that has a lifetime, rather than one
	     each. Turrets, shields and cryo fields all expire; none of them is worth
	     its own connection. ]]
	trove:connect(RunService.Heartbeat, function(dt: number)
		for _, module in modules do
			if typeof(module.step) == "function" then
				local ok, err = pcall(module.step, dt)
				if not ok then
					warn("[AbilityService] step failed: " .. tostring(err))
				end
			end
		end
	end)
end

function AbilityService:destroy()
	for _, module in modules do
		if typeof(module.clear) == "function" then
			pcall(module.clear)
		end
	end
	table.clear(modules)
	table.clear(cooldowns)
	table.clear(lastRequestAt)
	trove:destroy()
end

Registry.register("AbilityService", AbilityService)

return AbilityService
