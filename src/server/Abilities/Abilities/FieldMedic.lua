--!nonstrict
--[[
	Field Medic — patches up everybody standing near you, including you.

	The shortest module here, and deliberately so: it heals through
	SurvivorService rather than touching a Humanoid, so every rule about what
	healing means in this game — the cap, the hurt threshold, the state the HUD
	draws — is applied by the one place that owns them.

	── WHY IT IS NOT A WORSE MEDKIT ────────────────────────────────────────────
	A medkit heals ONE person for most of a bar and costs five seconds standing
	still in the open. This heals FOUR people for a third of one, instantly, from
	behind cover. They are the same verb solving different problems, and a team
	carrying one of each is better off than a team carrying two of either.

	It is permanent health rather than the draining kind pills give, which is the
	other half of that: a Field Medic that handed out temporary health would be a
	pill bottle with a radius, and this game already has pills.

	── AND IT NEVER MISSES ─────────────────────────────────────────────────────
	No line of sight test, no cone. It is the one ability with no way to aim it
	badly, because a support button that can be fumbled is a support button
	nobody presses under pressure — which is the only time it matters.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)

local AbilitySupport = require(script.Parent.Parent.AbilitySupport)

local FieldMedic = {}

function FieldMedic.activate(context: any): boolean
	local survivors: any = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getAliveSurvivors) ~= "function" then
		return false
	end

	local radius = context.tuning.Radius
	local amount = context.tuning.HealAmount
	local healed: { Player } = {}

	for _, other in survivors:getAliveSurvivors() do
		local character = other.Character
		local root = if character then RigUtil.getRoot(character) else nil
		if not root then
			continue
		end
		if (root.Position - context.origin).Magnitude > radius then
			continue
		end
		--[[ `false` is the temporary flag: this is real health. SurvivorService
		     owns the cap, so somebody already at full simply gains nothing and
		     still counts as in range — the effect plays on them either way,
		     because "I healed you" and "you did not need it" should look the
		     same to the person who pressed the button. ]]
		survivors:heal(other, amount, false)
		table.insert(healed, other)
	end

	--[[ Fired even when the list is only the caster. An ability that silently
	     did nothing when the team had scattered would read as broken rather than
	     as badly timed. ]]
	AbilitySupport.broadcast("Heal", {
		id = context.definition.id,
		player = context.player,
		position = context.origin,
		radius = radius,
		healed = healed,
	})
	return true
end

return FieldMedic
