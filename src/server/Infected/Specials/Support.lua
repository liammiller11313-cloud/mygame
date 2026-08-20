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
