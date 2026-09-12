--!strict
--[[
	MeleeService — the machete and the shove.

	Two verbs in one file because they are the same motion from the game's point
	of view: a short arc in front of a survivor, resolved against everything
	standing in it. What separates them is what they leave behind. The machete
	deletes bodies. The shove costs nothing, buys a second, and gives it away.

	── THE ARC IS GENEROUS ON PURPOSE ──────────────────────────────────────────
	Neither verb uses a single ray. A machete that whiffs because the crosshair
	was a degree off a shambling target is the worst feeling a melee game has to
	offer, and the shove is a panic button — it has to work while you are being
	mobbed from three sides and looking at the wrong one of them. So both sweep a
	cone, both count a body's own width as extra arc, and both let the real
	limiter be the target cap: WeaponConfig `penetration` for the swing,
	GameConfig.Shove.MaxTargets for the shove. Generous about WHAT you connect
	with and strict about HOW MANY is what keeps this a weapon rather than a
	room-clearing button.

	── THE APEX IS THE SERVER'S HEAD, NOT THE CLIENT'S ORIGIN ──────────────────
	HitValidation.PositionTolerance is 18 studs of slack and the machete's entire
	range is 16. Sweeping from the claimed origin would therefore let a client
	more than double its reach while passing every check BallisticsService
	applies. The claimed origin is still validated — a swing from across the map
	is a lie worth dropping — but the cone is swept from the character's actual
	head position. A rifle does not care about 18 studs of slop at 900 studs of
	range; melee cares about nothing else.

	── PINS ────────────────────────────────────────────────────────────────────
	A shove frees a pinned teammate, whether you shove the teammate or the thing
	holding them. Both paths exist because a pin the team cannot answer is a bug,
	not difficulty, and the player under a Hunter cannot tell you which of the two
	you are aiming at. Nothing on this path deals damage to anyone — Shove's
	SelfDamageToPinned is 0 and this file never calls applyDamage at all.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	Targets come from InfectedService's live list rather than a spatial query:
	during a horde that list is exactly the set we care about, and walking it is
	cheaper than sifting several hundred rig parts out of GetPartBoundsInRadius.
	One line-of-sight ray plus one body probe per candidate that survives the cone
	test, and no RunService connection anywhere — both entry points are driven
	entirely by client intent and cost nothing when nobody is swinging.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)
local WeaponConfig = require(Shared.Config.WeaponConfig)

--[[ One body inside the swept cone, already measured. `isSurvivor` is decided
     here rather than re-derived later, because the shove treats the two kinds of
     body as completely different events. ]]
type Candidate = {
	model: Model,
	root: BasePart,
	distance: number,
	isSurvivor: boolean,
}

--[[ The validated actor behind one swing or shove. Built once per accepted
     request so no downstream helper has to re-check any of it. ]]
type Actor = {
	character: Model,
	apex: Vector3,
	unit: Vector3,
}

--[[ Per-player cooldown bookkeeping. Fixed size: the fatigue ring never grows
     and never sorts, so a player spamming the shove remote costs four number
     compares and nothing else. ]]
type AttackerState = {
	lastSwingAt: number,
	--[[ When the sword may next be swung at all, which is only ever moved by a
	     LUNGE — see WeaponConfig.LungeProfile. Kept apart from lastSwingAt
	     because the two answer different questions: one is "how long since you
	     attacked", which decides whether the next swing lunges, and this is "are
	     you still committed to the last one", which decides whether there is a
	     next swing yet. Folding them would make a lunge shorten its own window. ]]
	lockedUntil: number,
	lastShoveAt: number,
	shoveTimes: { number },
	shoveCursor: number,
}

local MeleeService = {}

local VALIDATION = GameConfig.HitValidation
local SHOVE = GameConfig.Shove

-- Same distance gore and ballistics use, for the same reason: a fight across the
-- map must not cost a distant client anything.
local EFFECT_RADIUS = GoreConfig.Budget.CullDistance

--[[
	Half-angle of the machete's cone, in radians.

	No config owns this — WeaponConfig's spread fields are a bullet cone and the
	machete's are all 0 — so it lives here with its reasoning attached. 45 degrees
	either side is deliberately wide: the arc's job is to forgive aim, and the
	swing is already limited to `penetration` bodies and one hit per body per
	swing, so widening it cannot raise the damage a single swing does. It only
	changes WHICH three of the six zombies around you eat it.
]]
local SWING_HALF_ANGLE = math.rad(45)

--[[ GameConfig.Shove.Arc is "degrees of cone in front of the player", i.e. the
     full width of the arc, so the test is against half of it. ]]
local SHOVE_HALF_ANGLE = math.rad(SHOVE.Arc * 0.5)

--[[
	How far off the head the swing line may pass and still count as a head hit,
	as a multiple of the head part's own radius.

	The machete's identity is that it takes heads off (dismemberPower 1.0, and a
	300-damage hit through the 4x head multiplier), and that identity is worth
	being loose about. Sweeping a wide cone and then demanding pixel-accurate
	head contact would produce a weapon that decapitates by accident and never on
	purpose, which is exactly backwards.
]]
local HEAD_BIAS_SCALE = 1.7

-- Matches BallisticsService: a client firing at exactly 60/rpm will sometimes
-- have two packets arrive bunched by jitter, and silently eating a legitimate
-- swing is a far worse bug than letting a cheater gain 15%.
local FIRE_DELAY_LENIENCY = 0.85

local FATIGUE_SLOTS = math.max(math.floor(SHOVE.FatigueShoves), 1)

--[[
	Camera kick for the player who shoved. Nothing in the configs owns this —
	WeaponConfig's recoil belongs to the gun in your hands and a shove is the
	other arm — so the numbers are here.

	Units follow the rest of the codebase: `rotation` is degrees of camera kick
	(pitch, yaw, roll), `position` is studs in camera space (+X right, +Y up, -Z
	forward), `decay` is the per-second rate the impulse settles at. Kept small
	on purpose: the shove is a constant verb, and a big kick every 0.55 seconds
	is nausea rather than feedback.

	Both tables are module-level constants and are fired as-is. The client gets a
	serialised copy, so there is nothing here for a listener to corrupt and
	nothing to allocate per shove.
]]
local SHOVE_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.04, 0.18),
	rotation = Vector3.new(-1.6, 0, 0),
	decay = 9,
})

--[[ The jolt for the teammate who was just freed. Harder than the shover's,
     because something was physically knocked off them and the moment needs to
     read as a rescue rather than as the pin timing out. ]]
local FREED_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, 0.08, -0.3),
	rotation = Vector3.new(-3.4, 0, 0),
	decay = 7,
})

--[[ States in which neither verb is available. Incapacitated is included where
     BallisticsService excludes it: being down means the pistol and nothing else,
     and a pinned survivor cannot shove their own way free — answering a pin is
     what the second player is for. ]]
local CANNOT_ACT_STATES: { [string]: boolean } = {
	[Enums.SurvivorState.Dead] = true,
	[Enums.SurvivorState.Spectating] = true,
	[Enums.SurvivorState.LedgeHanging] = true,
	[Enums.SurvivorState.Incapacitated] = true,
	[Enums.SurvivorState.Pinned] = true,
}

local EPSILON = 1e-4

local attackers: { [Player]: AttackerState } = {}
local trove = Trove.new()
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[MeleeService] " .. message)
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)
end

local function stateFor(player: Player): AttackerState
	local state = attackers[player]
	if not state then
		state = {
			lastSwingAt = -math.huge,
			lockedUntil = 0,
			lastShoveAt = -math.huge,
			-- Seeded so far in the past that a player's first four shoves can
			-- never read as fatigued, however few seconds old the server is.
			shoveTimes = table.create(FATIGUE_SLOTS, -math.huge),
			shoveCursor = 0,
		}
		attackers[player] = state
	end
	return state :: AttackerState
end

--[[
	True when FatigueShoves shoves have already landed inside FatigueWindow.

	The ring slot about to be overwritten holds the Nth-most-recent shove; if that
	one was less than a window ago, N shoves fit inside the window and the next
	costs FatigueCooldown instead of Cooldown. With the shipped numbers four
	shoves at 0.55s each occupy 1.65s of a 3s window, so a spammer hits the wall
	on the fifth and then has to wait 1.6s per shove until the window clears —
	which is the entire point. Without it, shove-spam trivialises a horde.
]]
local function isFatigued(state: AttackerState, now: number): boolean
	local slot = (state.shoveCursor % FATIGUE_SLOTS) + 1
	return now - state.shoveTimes[slot] < SHOVE.FatigueWindow
end

local function recordShove(state: AttackerState, now: number)
	local slot = (state.shoveCursor % FATIGUE_SLOTS) + 1
	state.shoveTimes[slot] = now
	state.shoveCursor = slot
	state.lastShoveAt = now
end

local function headPositionOf(character: Model): Vector3?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	local root = RigUtil.getRoot(character)
	return if root then root.Position else nil
end

--[[
	Everything both verbs need before they may touch the world, cheapest first.
	Nil means the request is dropped — silently, like every other rejection in the
	combat path, because an error tells a cheater exactly which check they tripped.

	The last check is a line-of-sight raycast, and it is the only expensive thing
	in here. Both callers therefore admit the request against their per-player
	cooldown BEFORE calling this, so the number of casts a client can buy is
	capped by its fire rate rather than by its packet rate.
]]
local function validateActor(player: Player, origin: any, direction: any): Actor?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	if not isFiniteVector(origin) or not isFiniteVector(direction) then
		return nil
	end

	local claimed = origin :: Vector3
	local aim = direction :: Vector3
	if aim.Magnitude < EPSILON then
		return nil
	end

	local character = player.Character
	if not character or not character.Parent then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	-- find(), not get(): melee has to keep working in a test place that never
	-- loaded SurvivorService.
	local survivors = Registry.find("SurvivorService")
	--[[
		── NOT WHILE YOU ARE THE WALRUS ────────────────────────────────────────
		BecomeWalrus hands you a second body to drive and leaves your own
		standing there. Firing your loadout out of a survivor you are not looking
		through is a free second set of guns for the duration, which is not what
		the ability is — it is a trade, and the trade is that the walrus is what
		you have until it dies or its clock runs out.

		Server side and attribute-driven, because IsWalrus is the server's own
		flag: the client is told, it does not decide. See BecomeWalrus.
	]]
	if player:GetAttribute(Attributes.Player.IsWalrus) == true then
		return nil
	end
	if survivors and CANNOT_ACT_STATES[survivors:getState(player)] then
		return nil
	end

	local apex = headPositionOf(character)
	if not apex then
		return nil
	end
	if (claimed - apex).Magnitude > VALIDATION.PositionTolerance then
		return nil
	end

	--[[
		── NO LINE-OF-SIGHT TEST HERE, AND THAT IS DELIBERATE ────────────────────
		BallisticsService runs one, and it is right to: a bullet leaves from the
		claimed origin, so an origin the head cannot see is a muzzle pushed into
		the room next door and the shot has to be dropped.

		Melee does not use the claimed origin for anything. Both paths below sweep
		their cone from `apex` — the character's own head, on the server — and the
		claim is only ever checked for distance, to reject a swing from across the
		map. Testing sight to a point that is then thrown away rejects swings that
		would have been resolved from a position the test never looked at.

		It was not hypothetical. The claim is the CLIENT'S CAMERA, and any screen
		that releases the mouse pushes the camera several studs behind the
		survivor — which indoors means through the wall behind them more often
		than not. Every swing in that state was dropped in silence: no hit, no
		damage, no reason. Backing into a corner did the same thing on its own.

		The distance tolerance is what actually bounds this, and it survives.
	]]

	return { character = character, apex = apex, unit = aim.Unit }
end

local function byDistance(a: Candidate, b: Candidate): boolean
	return a.distance < b.distance
end

--[[
	Appends every live body from `models` that stands inside the cone.

	A body's own width is added to both tests, which is what makes the arc feel
	honest rather than mathematically correct: a Tank standing beside you has its
	root outside a 45-degree cone and its shoulder very much inside it, and the
	player swinging at the shoulder is right. atan() of radius over distance is
	the angle the body subtends, clamped at 45 degrees of slack for anything
	close enough that the maths would otherwise explode.
]]
local function gatherCone(
	apex: Vector3,
	unit: Vector3,
	range: number,
	halfAngle: number,
	models: { Model },
	isSurvivor: boolean,
	out: { Candidate }
)
	for _, model in models do
		if not RigUtil.isAlive(model) then
			continue
		end
		local root = RigUtil.getRoot(model)
		if not root then
			continue
		end

		local delta = root.Position - apex
		local distance = delta.Magnitude
		local radius = root.Size.Magnitude * 0.5
		if distance - radius > range then
			continue
		end

		if distance > EPSILON then
			local angle = math.acos(math.clamp(delta.Unit:Dot(unit), -1, 1))
			if angle > halfAngle + math.atan(radius / math.max(distance, radius)) then
				continue
			end
		end

		table.insert(out, {
			model = model,
			root = root,
			distance = distance,
			isSurvivor = isSurvivor,
		})
	end
end

--[[
	Bodies never shield each other, in melee least of all: the machete's whole
	selling point is cleaving three deep, and a teammate who steps into the
	doorway must never be the reason your swing stopped short. Built once per
	swing so the per-candidate sight check can only ever fail on geometry.
]]
local function buildIgnoreList(character: Model, candidates: { Candidate }, extra: { Model }?): { Instance }
	local ignore: { Instance } = table.create(#candidates + 1)
	ignore[1] = character
	for index, candidate in candidates do
		ignore[index + 1] = candidate.model
	end
	if extra then
		for _, model in extra do
			table.insert(ignore, model)
		end
	end
	return ignore
end

--[[
	Which part the swing is aimed at, and whether that is a head.

	The test is the perpendicular distance from the head's centre to the swing
	line, so "did the arc pass through the head" rather than "was the head the
	nearest thing to the crosshair". Looking over a crowd and swinging takes the
	front rank's heads off; swinging at waist height does not.
]]
local function chooseAimPart(apex: Vector3, unit: Vector3, candidate: Candidate): (BasePart, boolean)
	local head = candidate.model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local toHead = head.Position - apex
		local along = toHead:Dot(unit)
		if along > 0 then
			local offset = (toHead - unit * along).Magnitude
			if offset <= head.Size.Magnitude * 0.5 * HEAD_BIAS_SCALE then
				return head, true
			end
		end
	end
	return candidate.root, false
end

--[[
	Where on the body the blade actually lands. One include-filtered ray at the
	aim point — the params hit ONLY this model, so walls, teammates and corpses
	cannot deflect it and the result is always a part of the thing we already
	decided to hit. The surface position and normal are what GoreService needs to
	throw blood in the right direction.

	When the swing was aimed at the head, the head stays the reported hit part
	even if the ray landed on a hat welded in front of it: RigUtil deliberately
	scores accessories as Torso so cosmetics cannot widen a hitbox, and a machete
	arc that passed through the skull should not be demoted by a baseball cap.
]]
local function probeBody(
	apex: Vector3,
	unit: Vector3,
	model: Model,
	aimPart: BasePart,
	aimedAtHead: boolean
): (BasePart, Vector3, Vector3)
	local delta = aimPart.Position - apex
	if delta.Magnitude > EPSILON then
		local result = workspace:Raycast(apex, delta, RaycastUtil.including({ model }))
		if result then
			local part = if aimedAtHead then aimPart else result.Instance :: BasePart
			return part, result.Position, result.Normal
		end
	end
	return aimPart, aimPart.Position, -unit
end

--[[
	Knocks one infected off balance. Returns false when the target is immovable,
	which is InfectedConfig.stumbleResistance at 1.0 — a Tank and a Witch do not
	budge, and shoving one must not silently eat a slot of MaxTargets that the
	commons swarming the same doorway needed.

	The stumble duration and the physical push both scale by (1 - resistance), so
	one number in InfectedConfig decides both halves of how a body reacts.

	The impulse is applied here rather than inside stagger() because stagger's
	signature carries no force and GameConfig.Shove.Force is a shove number, not
	a general stumble number. root.AssemblyMass is read directly instead of via
	RigUtil.getMass so that Force reads as a velocity change in studs/second and
	lands identically on a Common and a Tank — see the report.
]]
local function staggerInfected(model: Model, root: BasePart, pushDirection: Vector3): boolean
	local kind = model:GetAttribute(Attributes.Infected.Kind)
	local definition = if typeof(kind) == "string" then InfectedConfig.get(kind) else nil
	if not definition then
		return false
	end

	local scale = 1 - math.clamp(definition.stumbleResistance, 0, 1)
	if scale <= 0 then
		return false
	end

	local infected = Registry.find("InfectedService")
	if infected and typeof(infected.stagger) == "function" then
		infected:stagger(model, pushDirection, SHOVE.StumbleDuration * scale)
	end
	root:ApplyImpulse(pushDirection * (SHOVE.Force * scale * root.AssemblyMass))
	return true
end

--[[
	Releases one pinned survivor and knocks whatever was holding them away.

	setPinned(player, nil) is the documented way to clear a pin. getPinnedBy is
	not in the architecture's public list for SurvivorService, so it is used only
	when it exists: without it the survivor is still freed, they just do not get
	the special thrown off them as well.
]]
local function releasePin(survivors: any, victim: Player, pushDirection: Vector3)
	local pinner: Model? = nil
	if typeof(survivors.getPinnedBy) == "function" then
		pinner = survivors:getPinnedBy(victim)
	end

	survivors:setPinned(victim, nil)
	Remotes.Event.CameraImpulse:FireClient(victim, FREED_CAMERA_IMPULSE)

	if pinner and pinner.Parent and RigUtil.isAlive(pinner) then
		local root = RigUtil.getRoot(pinner)
		if root then
			-- Staggering it matters as much as clearing the state: a special that
			-- is free to act on the next frame simply re-pins, and the rescue
			-- reads as a bug.
			staggerInfected(pinner, root, pushDirection)
		end
	end
end

--[[ Frees anyone this model has pinned. Only specials pin, so the survivor walk
     is skipped entirely for the commons that make up almost every shove. ]]
local function releasePinsBy(model: Model)
	local kind = model:GetAttribute(Attributes.Infected.Kind)
	local definition = if typeof(kind) == "string" then InfectedConfig.get(kind) else nil
	if not definition or not definition.isSpecial then
		return
	end

	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getPinnedBy) ~= "function" then
		return
	end

	for _, victim in survivors:getAliveSurvivors() do
		if survivors:getPinnedBy(victim) == model then
			survivors:setPinned(victim, nil)
			Remotes.Event.CameraImpulse:FireClient(victim, FREED_CAMERA_IMPULSE)
		end
	end
end

--[[ Horizontal push away from the shover. Flattened on purpose: a shove that
     launches a body upward reads as an explosion, and a Common that lands on a
     ledge it could not otherwise reach is a pathing problem nobody will trace
     back to here. ]]
local function pushDirectionFor(apex: Vector3, unit: Vector3, target: Vector3): Vector3
	local flat = Vector3.new(target.X - apex.X, 0, target.Z - apex.Z)
	if flat.Magnitude > EPSILON then
		return flat.Unit
	end
	local fallback = Vector3.new(unit.X, 0, unit.Z)
	return if fallback.Magnitude > EPSILON then fallback.Unit else Vector3.zAxis
end

function MeleeService:init()
	trove:add(Players.PlayerRemoving:Connect(function(player: Player)
		attackers[player] = nil
	end))
end

function MeleeService:start()
	trove:add(Remotes.Event.SwingMelee.OnServerEvent:Connect(function(player: Player, payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		-- clientTime rides along in the payload and is ignored for the same
		-- reason BallisticsService ignores it: nothing in this build records a
		-- position history to rewind against.
		MeleeService:swing(player, payload.origin, payload.direction, payload.lunge == true)
	end))

	trove:add(Remotes.Event.Shove.OnServerEvent:Connect(function(player: Player, payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		MeleeService:shove(player, payload.origin, payload.direction)
	end))
end

--[[
	One machete swing. Returns the hits it resolved, so a caller can read the
	outcome without listening for anything; the remote handler ignores it.

	Damage goes through DamageService like everything else in the game — this
	file never touches a Humanoid. Friendly fire is not a special case here
	either: survivors are simply never gathered as swing targets, which both
	honours FriendlyFireMeleeMultiplier being 0 and stops a teammate in a doorway
	from consuming one of the three bodies the swing may cleave.
]]
function MeleeService:swing(
	player: Player,
	origin: Vector3,
	direction: Vector3,
	--[[ The client saying this swing came from a fresh press rather than from
	     holding the trigger down — see swingMelee's own note. Checked, never
	     trusted: the window below is still the gate, so the most a client can win
	     by always claiming it is the cadence an honest double-tap already gets.
	     What it carries is the one fact the server has no way to see. ]]
	claimsLunge: boolean?
): { Types.HitRecord }
	local records: { Types.HitRecord } = {}

	-- Cheapest first, and the rate check ahead of everything that touches the
	-- world: a client firing SwingMelee at packet rate would otherwise buy a
	-- cone gather and a cast per body per packet, however fast it sent them.
	-- Everything above that is table lookups and number compares.
	-- BallisticsService admits a shot in exactly this order.
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return records
	end

	local inventory = Registry.find("InventoryService")
	if not inventory then
		warnOnce("inventory", "InventoryService is not registered; every swing is being dropped")
		return records
	end

	local weaponId, definition = inventory:getActiveWeapon(player)
	if typeof(weaponId) ~= "string" or typeof(definition) ~= "table" then
		return records
	end
	-- A swing that arrives while a gun is out is a confused client, not an
	-- attack: shove is the gun-holder's melee and it has its own remote.
	if definition.fireMode ~= "Melee" then
		return records
	end
	--[[ The Classic Sword is Melee AND a native tool, so it reaches here and
	     must not be swung twice. Its own SwordScript owns the slash, the lunge,
	     the damage window and both sounds; resolving the same swing here as well
	     would double every hit and play the sample over itself. See
	     NativeToolService, and BallisticsService for the shooting half. ]]
	if definition.nativeTool then
		return records
	end

	-- Consumed on ADMISSION, not on success. A swing that is then thrown out by
	-- validateActor still costs its cooldown, which is what makes the remote
	-- unspammable; a client swinging at its real fire rate never notices.
	local now = os.clock()
	local state = stateFor(player)
	if now - state.lastSwingAt < WeaponConfig.getFireDelay(definition) * FIRE_DELAY_LENIENCY then
		return records
	end
	--[[ And the lunge's own hold, which is longer than any fire delay. Only a
	     weapon that HAS a lunge can be held by one: a player who swaps to a
	     machete mid-lock is swinging a different weapon, and the sword's
	     commitment is not something the machete inherited. ]]
	if definition.lunge and now < state.lockedUntil then
		return records
	end

	--[[
		Whether this swing is the classic's second click.

		BOTH halves have to agree. The client's claim is the half about intent —
		a fresh press rather than a held trigger, which this side cannot observe —
		and isLunge is the half about timing, which this side measures on its own
		clock and does not take anybody's word for. A client claiming a lunge it
		has not earned the timing for gets an ordinary swing.

		Read BEFORE lastSwingAt is overwritten, which is the whole reason these
		lines are in this order — the delta this needs is the one that is about to
		be destroyed.

		The client has already played the lunge's animation and set its own longer
		cooldown by the time this runs; see LungeProfile for why the two clocks
		agree about the window.
	]]
	local lunging = claimsLunge == true and WeaponConfig.isLunge(definition, now - state.lastSwingAt)
	state.lastSwingAt = now
	if lunging and definition.lunge then
		--[[
			LENIENT, and for the same reason FIRE_DELAY_LENIENCY is.

			The client holds itself for the full cooldown and then swings the
			instant it expires. If the server held for exactly as long, whether
			that swing landed would come down to whether this packet's jitter
			happened to be larger than the lunge packet's — a coin flip, on every
			single lunge, and the losing side is a player who pressed attack,
			watched the animation play, and took no damage off anything.

			Measured rather than guessed. Simulated at 120,000 swings per jitter
			level: holding for the full cooldown ate 16% of the swings that follow
			a lunge at only ±20ms of jitter, every one of them on this check. At
			0.85 the server's hold ends 180ms before the client's, and the same
			simulation eats none at ±20ms and none at ±50ms. What is left above
			that is the fire-delay check on the line before, which every melee
			weapon in the game has always been subject to.

			The cost is that a client could lunge 15% faster than intended. That
			is the same trade the fire-delay leniency above already made, and
			losing legitimate swings is still the worse bug.
		]]
		state.lockedUntil = now + definition.lunge.cooldown * FIRE_DELAY_LENIENCY
	end

	--[[ What the swing is worth and how far it reaches. A lunge is a thrust: it
	     hits harder and further than the arc, and it still only takes the one
	     body an arc does — `penetration` is untouched, because a lunge that
	     cleaved would be a better Machete rather than a different weapon. ]]
	local swingDamage = definition.damage
	local swingRange = definition.maxRange
	if lunging and definition.lunge then
		swingDamage *= definition.lunge.damageMultiplier
		swingRange *= definition.lunge.rangeMultiplier
	end

	local actor = validateActor(player, origin, direction)
	if not actor then
		return records
	end

	local apex, unit = actor.apex, actor.unit

	-- Melee consumes no ammo (magSize is 0), so InventoryService is asked for the
	-- definition and nothing else. Out before a single ray is cast, exactly as
	-- BallisticsService does: the swing animation and the whoosh are how a
	-- teammate knows you engaged, and they should not wait on the resolution.
	-- seed and spread ride along so a remote WeaponFired handler stays uniform
	-- across every weapon; the machete's tracerWidth and muzzleFlashSize are 0,
	-- so a handler that draws them anyway draws nothing.
	Remotes.fireAllExcept("WeaponFired", player, {
		shooter = player,
		weaponId = weaponId,
		origin = apex,
		direction = unit,
		seed = 1,
		spread = 0,
	})

	--[[ Everyone but the swinger, who heard it locally on the frame they swung.
	     Same reasoning as the gunshot in BallisticsService, and the same reason
	     the WeaponFired remote above excludes them. ]]
	local audio = Registry.find("AudioService")
	if audio then
		--[[ A lunge has its own sample, pitched down and carrying further — see
		     AudioConfig.WeaponLunge. The classic plays two different sounds for
		     its two attacks, and it is right to: a lunge is over a second of
		     standing still, and a teammate who can hear one coming knows not to
		     step into the doorway you just committed to. ]]
		audio:playAt(AudioConfig.meleeSwing(weaponId, lunging), apex, nil, player)
	end

	local candidates: { Candidate } = {}
	local infectedService = Registry.find("InfectedService")
	if infectedService then
		gatherCone(apex, unit, swingRange, SWING_HALF_ANGLE, infectedService:getAlive(), false, candidates)
	end

	-- Nearest first: cleaving is a line of bodies, and the one in your face has
	-- to be the one that dies.
	table.sort(candidates, byDistance)

	local damageService = Registry.get("DamageService")
	-- Teammates join the ignore list without ever becoming targets. Melee cannot
	-- hurt them (FriendlyFireMeleeMultiplier is 0) so it must not be stopped by
	-- them either; a machete that a teammate can body-block is a machete nobody
	-- swings in the doorway it exists for.
	local survivors = Registry.find("SurvivorService")
	local ignore = buildIgnoreList(
		actor.character,
		candidates,
		if survivors then survivors:getSurvivorCharacters() else nil
	)
	local maxTargets = math.max(math.floor(definition.penetration), 1)

	for _, candidate in candidates do
		if #records >= maxTargets then
			break
		end

		local aimPart, aimedAtHead = chooseAimPart(apex, unit, candidate)
		if not RaycastUtil.hasLineOfSight(apex, aimPart.Position, ignore) then
			continue
		end

		local hitPart, hitPosition, hitNormal = probeBody(apex, unit, candidate.model, aimPart, aimedAtHead)
		local region = if aimedAtHead then Enums.HitRegion.Head else RigUtil.getHitRegion(hitPart)

		local result = damageService:applyDamage(
			candidate.model,
			swingDamage,
			Types.newDamageContext({
				attacker = player,
				weaponId = weaponId,
				damageType = Enums.DamageType.Melee,
				region = region,
				hitPart = hitPart,
				hitPosition = hitPosition,
				hitNormal = hitNormal,
				direction = unit,
				distance = (hitPosition - apex).Magnitude,
				-- Every body the arc already went through. DamageService turns
				-- this into penetrationFalloff, which is 0.9 for the machete:
				-- the third zombie in a cleave still dies, it just does not get
				-- the same spectacular overkill as the first.
				piercedCount = #records,
			})
		)

		if not result.blocked then
			table.insert(records, {
				model = candidate.model,
				part = hitPart,
				position = hitPosition,
				normal = hitNormal,
				distance = (hitPosition - apex).Magnitude,
				region = region,
				result = result,
			})
		end
	end

	--[[
		A swing that connects makes a noise, and the noise says what hit.

		One sound for the whole arc rather than one per body, for the same reason
		the shove has one: five overlapping thuds from a single swing is noise, and
		AudioConfig.Mix would spend five voices on it. It plays at the FIRST body —
		the one in your face, since the candidates are sorted nearest-first — which
		is where the player is looking.

		This did not exist at all before there were five melee weapons. The swing
		whooshed, the body took damage, and the only thing you heard on contact was
		whatever the bullet impact path happened to produce.
	]]
	if records[1] then
		local audio = Registry.find("AudioService")
		if audio then
			audio:playAt(AudioConfig.meleeImpact(weaponId), records[1].position)
		end
	end

	-- A swing that meets a wall should mark the wall. One ray, only on a whiff,
	-- and only for geometry — blood on flesh belongs to GoreService.
	if #records == 0 then
		local wall = workspace:Raycast(apex, unit * swingRange, RaycastUtil.excluding({ actor.character }))
		-- Geometry only. A body that survived the sweep but stopped this ray is
		-- flesh, and flesh is GoreService's to decorate.
		local struck = if wall then (RigUtil.getCharacterFromPart(wall.Instance :: BasePart)) else nil
		if wall and not struck then
			Remotes.fireInRange("ImpactEffect", wall.Position, EFFECT_RADIUS, {
				position = wall.Position,
				normal = wall.Normal,
				material = wall.Material,
				damageType = Enums.DamageType.Melee,
			})
		end
	end

	return records
end

--[[
	The shove. Returns how many bodies it moved, for tests and debug overlays.

	Deals no damage to anything, ever. It staggers what it connects with, frees
	pinned teammates, and costs the player a cooldown that balloons if they lean
	on it. That is the whole verb, and it is the answer to being surrounded.
]]
function MeleeService:shove(player: Player, origin: Vector3, direction: Vector3): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return 0
	end

	-- Same order as the swing, for the same reason: the cooldown is the only
	-- thing standing between a client spamming the Shove remote and an unbounded
	-- number of cone gathers and casts. The shove is admitted here and pays for
	-- itself here, whatever happens next.
	local now = os.clock()
	local state = stateFor(player)
	local cooldown = if isFatigued(state, now) then SHOVE.FatigueCooldown else SHOVE.Cooldown
	if now - state.lastShoveAt < cooldown then
		return 0
	end
	recordShove(state, now)

	local actor = validateActor(player, origin, direction)
	if not actor then
		return 0
	end

	local apex, unit = actor.apex, actor.unit

	-- Fired before any resolution and regardless of whether the shove connects.
	-- A shove that produces no feedback until it hits something teaches the
	-- player that the button is unreliable, which is fatal for a panic button.
	Remotes.Event.CameraImpulse:FireClient(player, SHOVE_CAMERA_IMPULSE)

	local candidates: { Candidate } = {}
	local infectedService = Registry.find("InfectedService")
	if infectedService then
		gatherCone(apex, unit, SHOVE.Range, SHOVE_HALF_ANGLE, infectedService:getAlive(), false, candidates)
	end

	local survivors = Registry.find("SurvivorService")
	if survivors then
		gatherCone(
			apex,
			unit,
			SHOVE.Range,
			SHOVE_HALF_ANGLE,
			survivors:getSurvivorCharacters(),
			true,
			candidates
		)
	end

	table.sort(candidates, byDistance)

	local ignore = buildIgnoreList(actor.character, candidates)
	local maxTargets = math.max(math.floor(SHOVE.MaxTargets), 1)
	local staggered = 0
	local firstContact: Vector3? = nil

	for _, candidate in candidates do
		-- The budget check comes first so a spent shove stops paying for sight
		-- rays, but survivors keep being examined: freeing a pin does not spend
		-- the budget and must not be cut short by the commons ahead of it.
		if not candidate.isSurvivor and staggered >= maxTargets then
			continue
		end
		if not RaycastUtil.hasLineOfSight(apex, candidate.root.Position, ignore) then
			continue
		end

		local push = pushDirectionFor(apex, unit, candidate.root.Position)

		if candidate.isSurvivor then
			-- Freeing a teammate never spends the target budget. A pin has to be
			-- answerable while the commons that arrived with it are still in the
			-- arc, or the Hunter's counter stops working exactly when it matters.
			local victim = Players:GetPlayerFromCharacter(candidate.model)
			if
				victim
				and victim ~= player
				and survivors
				and survivors:getState(victim) == Enums.SurvivorState.Pinned
			then
				releasePin(survivors, victim, push)
			end
			continue
		end

		if not staggerInfected(candidate.model, candidate.root, push) then
			-- A Tank does not budge, and it does not cost you a slot either.
			continue
		end

		staggered += 1
		if not firstContact then
			firstContact = candidate.root.Position
		end
		releasePinsBy(candidate.model)
	end

	-- One sound for the shove, not one per body: six overlapping thuds from a
	-- single arm is noise, and AudioConfig.Mix would spend six voices on it.
	-- Deliberately the generic flesh hit rather than a melee impact — a shove is
	-- an open hand, and it is the one melee verb with no weapon behind it.
	if firstContact then
		local audio = Registry.find("AudioService")
		if audio then
			audio:playAt(AudioConfig.Impact.Flesh, firstContact)
		end
	end

	return staggered
end

Registry.register("MeleeService", MeleeService)

return MeleeService
