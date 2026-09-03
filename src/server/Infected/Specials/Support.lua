--!strict
--[[
	Support — the parts every special infected does the same way.

	Five specials grew up side by side and converged on the same ten helpers,
	character for character: how you stand the common AI down before scripting a
	body, how you yaw toward a point without cheating the definition's turn
	speed, how you ask whether a shove has already answered you, how you deal
	damage as a special rather than as a bullet. Ten functions across five files
	is forty copies of the same decision, and the copies had already started to
	drift — `playSound` existed in two spellings that did the same thing.

	Everything here is the version that was IDENTICAL in every file it appeared
	in. Nothing has been generalised on the way through and nothing has grown a
	parameter to serve a caller that did not need one: this is a move, not a
	redesign, so a special that behaved a certain way yesterday behaves that way
	today. Where files genuinely disagreed — `ensure`, `pickTarget`, `launch`,
	`backToStalk` — the function stays private to each of them, because those
	differences ARE the creature.

	── WHAT HAS BEEN ADDED SINCE ───────────────────────────────────────────────
	The rule above still holds for the moves. What has grown here is the shared
	READ: how a special decides who to go for. Every one of them was doing that
	alone with some flavour of "nearest", which is how four specials ended up
	committed to the same survivor while the one who had wandered off stood
	untouched. `isolationOf`, `crowdAround`, `claim`/`claimBias` and `blindBias`
	are that decision, factored out — the scoring is shared, and what each
	creature DOES with the score is still its own.

	── THE BRAIN IS AN OPAQUE HANDLE ───────────────────────────────────────────
	InfectedService owns the brain and hands it here as `any`. Every call into it
	is guarded, so a special still behaves like an ordinary infected when a hook
	it expects is missing rather than erroring out mid-pounce and leaving a body
	frozen in a scripted phase forever. That rule is the reason these are worth
	sharing: it is easy to forget once per file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local Support = {}

-- ── the brain ───────────────────────────────────────────────────────────────

--[[ Stands the common AI down so a scripted phase can drive the body. ]]
function Support.pauseBrain(brain: any)
	if not brain then
		return
	end
	if typeof(brain.pause) == "function" then
		brain:pause()
	end
	-- pause() stands the common AI down but does not cancel a Humanoid:MoveTo it
	-- already issued, and a stale walk order keeps steering the body for several
	-- seconds. stop() is the brain's own way to drop it.
	if typeof(brain.stop) == "function" then
		brain:stop()
	end
end

function Support.resumeBrain(brain: any)
	if brain and typeof(brain.resume) == "function" then
		brain:resume()
	end
end

function Support.setBrainTarget(brain: any, target: Model?)
	if brain and typeof(brain.setTarget) == "function" then
		brain:setTarget(target)
	end
end

--[[ A shove has to answer a special the way it answers a Common: whatever it was
     doing stops. InfectedService:stagger freezes the body through the brain but
     cannot interrupt a scripted phase from outside, so the phase has to ask. ]]
function Support.isStaggered(brain: any): boolean
	return brain ~= nil and typeof(brain.isStaggered) == "function" and brain:isStaggered() == true
end

--[[ Yaw toward a point at the definition's turnSpeed.

     Always deferred to the brain, which applies the definition honestly. This is
     the field that makes a Charger dodgeable — 95 degrees a second is
     deliberately clumsy — and a special that turned instantly here would be
     quietly ignoring the number that balances it. The direct write is only the
     fallback for a body with no brain attached. ]]
function Support.faceTowards(brain: any, root: BasePart, position: Vector3, dt: number)
	if brain and typeof(brain.faceTowards) == "function" then
		brain:faceTowards(position, dt)
		return
	end
	local flat = Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z)
	if flat.Magnitude > 0.05 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
	end
end

-- ── who is going for whom ───────────────────────────────────────────────────

--[[
	── THE PROBLEM ─────────────────────────────────────────────────────────────
	Every special picked its victim alone, and they all used some flavour of
	"nearest". Four survivors, three specials, and all three would commit to the
	same person — the one at the front — while the survivor who had wandered off
	on their own, the one the whole special roster exists to punish, stood
	untouched. Worse, two of the three were wasted by definition: a survivor
	already pinned by a Hunter cannot be ridden by a Jockey, so the Jockey spent
	its life and its spawn cost arriving at a fight that was already over.

	── THE FIX IS A BIAS, NOT A LOCK ───────────────────────────────────────────
	A special about to commit says so, and everybody else's scoring quietly
	prefers somebody else. Deliberately a multiplier and not a filter: with two
	survivors and four specials alive, a hard lock would leave half the roster
	standing around with nobody legal to attack, which is a worse failure than
	two Hunters going for the same person. So a claimed survivor is not
	forbidden, only expensive — CLAIM_BIAS worth of expensive, which across a
	room is far enough to send the second Hunter at the other guy.

	── AND IT EXPIRES ──────────────────────────────────────────────────────────
	A claim is renewed while a special is actually committed and times out on its
	own. Nothing here may depend on a special remembering to let go: a body that
	dies mid-pounce, is staggered into a different phase, or is despawned by a
	round ending must not leave a survivor permanently unattractive to the whole
	roster. The table is weak-keyed for the same reason.
]]
local CLAIM_TTL = 10
local CLAIM_BIAS = 3.0

local claims = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: { player: Player, until_: number } }

--[[ Says "I am going for this one", and renews it. Safe to call every frame:
     the entry is rewritten rather than accumulated. ]]
function Support.claim(model: Model, player: Player?)
	if not player then
		claims[model] = nil
		return
	end
	claims[model] = { player = player, until_ = os.clock() + CLAIM_TTL }
end

function Support.unclaim(model: Model)
	claims[model] = nil
end

--[[
	How much worse this survivor is as a target because somebody else is already
	going for them: 1 for nobody, CLAIM_BIAS when another live special has
	committed. Multiply a distance-style score by it — lower being better is the
	convention every pickTarget in this folder already uses.

	Walks the table rather than keeping a reverse index. There are at most a
	dozen specials alive on the whole server (the sum of every kind's maxAlive)
	and this runs on a quarter-second scan, so an index would be a second thing
	to keep correct in exchange for nothing measurable.
]]
function Support.claimBias(model: Model, player: Player): number
	local now = os.clock()
	for other, entry in claims do
		if other == model then
			continue
		end
		if entry.player ~= player then
			continue
		end
		--[[ A dead or despawned claimant releases its claim here rather than in a
		     death handler, so there is no path that leaks one. ]]
		if now >= entry.until_ or not other.Parent then
			claims[other] = nil
			continue
		end
		return CLAIM_BIAS
	end
	return 1
end

--[[
	How much BETTER a target somebody is because they cannot see.

	A biled survivor's screen is covered. They cannot see a Hunter crouch, they
	cannot see a Charger's lane, they cannot see which direction a tongue came
	from — every tell this whole roster is built around telegraphing is, for
	those few seconds, not being received. That is the best moment in the round
	to commit, and until now no special knew it existed: the Boomer covered
	somebody and the rest of the roster carried on picking whoever was closest.

	Wiring it up is what turns the Boomer from a creature with one trick into the
	setup for everything else. It is the only real coordination the infected have
	and it costs one attribute read.

	Returned as a multiplier on a distance-style score, so it composes with
	isolation and with claimBias in the same expression: less than 1, meaning
	"treat them as nearer than they are".
]]
local BLIND_BIAS = 0.55

function Support.blindBias(survivors: any, player: Player): number
	if typeof(survivors.isBiled) == "function" and survivors:isBiled(player) then
		return BLIND_BIAS
	end
	return 1
end

--[[
	How alone a survivor is: the distance to their nearest teammate, capped.

	The single most useful thing a special can know, and it was written out
	longhand inside the Hunter and nowhere else. A survivor sixty studs from
	anybody is the one a pounce, a ride or a tongue actually takes out of the
	fight, because nobody is close enough to answer it; a survivor standing in
	the middle of their team is three seconds of pin and a free special kill.

	Capped rather than unbounded so that "very alone" and "on another map" score
	the same — past the cap the distinction stops meaning anything and an
	uncapped value would let one straggler across the level outweigh every other
	consideration in the scoring.
]]
function Support.isolationOf(candidates: { Player }, subject: Player, position: Vector3, cap: number): number
	local nearest = cap
	for _, other in candidates do
		if other == subject then
			continue
		end
		local otherCharacter = other.Character
		local otherRoot = if otherCharacter then RigUtil.getRoot(otherCharacter) else nil
		if otherRoot then
			nearest = math.min(nearest, (otherRoot.Position - position).Magnitude)
		end
	end
	return nearest
end

--[[ How many survivors are within `radius` of a point. What a Boomer wants
     (bile the cluster) and what a Charger wants (a lane through it) are the
     same question asked from two places. ]]
function Support.crowdAround(candidates: { Player }, position: Vector3, radius: number): number
	local count = 0
	for _, other in candidates do
		local otherCharacter = other.Character
		local otherRoot = if otherCharacter then RigUtil.getRoot(otherCharacter) else nil
		if otherRoot and (otherRoot.Position - position).Magnitude <= radius then
			count += 1
		end
	end
	return count
end

-- ── elite bodies ────────────────────────────────────────────────────────────

--[[
	The per-SPAWN modifier this body carries, or nil for an ordinary one.

	InfectedService writes InfectedConfig.EliteTiers's id onto the model at spawn
	and scales the Humanoid's health from it there. Everything else the modifier
	touches has to be asked for, because a special's scripted attacks do not go
	through the brain's claw: a Tank's swing and its rock both read
	`definition.attack.damage` straight off the config, so an Apex Tank with a
	1.35 damage multiplier would have hit for exactly as much as an ordinary one
	and the multiplier would have been a number in a table that did nothing.

	Read off the model rather than threaded through, for the same reason the
	Common tiers are: one source, and the two halves cannot disagree about which
	body this is.
]]
function Support.eliteOf(model: Model): any?
	return InfectedConfig.elite(model:GetAttribute(Attributes.Infected.Elite) :: string?)
end

function Support.scaledDamage(model: Model, base: number): number
	local elite = Support.eliteOf(model)
	return if elite then base * elite.damage else base
end

function Support.scaledSpeed(model: Model, base: number): number
	local elite = Support.eliteOf(model)
	return if elite then base * elite.speed else base
end

-- ── survivors ───────────────────────────────────────────────────────────────

function Support.rootOf(player: Player?): (Model?, BasePart?)
	if not player then
		return nil, nil
	end
	local character = player.Character
	if not character or not character.Parent then
		return nil, nil
	end
	return character, RigUtil.getRoot(character)
end

--[[ True while SurvivorService still names this model as the pin's owner.

     A shove clears a pin through SurvivorService rather than through the special
     holding it, so polling is how a pinning special learns it has been answered
     — and polling rather than being told is deliberate. The counter must never
     depend on the special agreeing to let go. ]]
function Support.stillPinnedBy(survivors: any, player: Player, model: Model): boolean
	if typeof(survivors.getPinnedBy) == "function" then
		return survivors:getPinnedBy(player) == model
	end
	return Attributes.get(player, Attributes.Player.PinnedBy, "") ~= ""
end

--[[ Damage dealt BY a special, as a special. The damage type is what separates a
     pounce from a bullet everywhere downstream — friendly fire rules, gore
     scoring, the hitmarker — so it is not a field a caller gets to choose. ]]
function Support.damage(model: Model, character: Model, victimRoot: BasePart, origin: Vector3, amount: number)
	local damageService: any = Registry.find("DamageService")
	if not damageService then
		return
	end

	local delta = victimRoot.Position - origin
	local distance = delta.Magnitude
	local direction = if distance > 0.05 then delta.Unit else Vector3.yAxis

	damageService:applyDamage(
		character,
		amount,
		Types.newDamageContext({
			attackerModel = model,
			damageType = Enums.DamageType.Special,
			region = Enums.HitRegion.Torso,
			hitPosition = victimRoot.Position,
			hitNormal = -direction,
			direction = direction,
			distance = distance,
		})
	)
end

-- ── the world ───────────────────────────────────────────────────────────────

--[[ Whether a leap from `from` to `to` has room to happen.

     Two rays, not one: straight up out of the crouch, then across from the
     raised point to the target's chest. A single flat ray from a crouching body
     hits the lip of whatever it is standing behind, and a Hunter that refuses to
     pounce over a car is a Hunter that never pounces.

     `ignore` slot 2 is borrowed for the target and handed back, so the caller's
     list keeps whatever it had. ]]
function Support.hasClearArc(
	ignore: { Instance },
	from: Vector3,
	to: Vector3,
	targetCharacter: Model,
	clearance: number
): boolean
	ignore[2] = targetCharacter
	local raised = from + Vector3.new(0, clearance, 0)
	local clear = RaycastUtil.hasLineOfSight(from, raised, ignore)
		and RaycastUtil.hasLineOfSight(raised, to, ignore)
	ignore[2] = nil
	return clear
end

--[[ One positional cue, through AudioService so it obeys AudioConfig's voice
     limits. Specials own their own vocalisations because those are the game's
     early-warning system, and a cue that gets dropped by a budget is a warning
     that did not arrive. ]]
function Support.playSound(key: string, part: BasePart)
	local audio: any = Registry.find("AudioService")
	if audio and typeof(audio.play) == "function" then
		audio:play("Infected", key, part)
	end
end

return Support
