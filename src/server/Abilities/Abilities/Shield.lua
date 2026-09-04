--!nonstrict
--[[
	Shield — a bubble that eats damage for you, briefly.

	It ends on whichever comes first: the clock or the pool. That is the whole
	design. A shield that only ran on a timer would be strictly better the more
	trouble you were in, and a shield that only ran on damage would be a free
	extra health bar you could carry across a whole wave. Ending on either makes
	it a decision about WHEN, which is the only interesting thing a defensive
	button can be about.

	── IT ABSORBS, IT DOES NOT BLOCK ───────────────────────────────────────────
	`absorb` returns the REMAINDER of a hit rather than a yes or no. A shield
	with ten points left against a forty-point Tank swing takes ten and lets
	thirty through. All-or-nothing would have made the last point of a shield
	worth as much as the first hundred, and would have let a player tank a Tank
	with a sliver.

	── AND IT IS NOT A HEALTH BAR ──────────────────────────────────────────────
	Nothing here touches health, temporary or otherwise. SurvivorService's damage
	funnel asks this what is left of a hit before it applies one; a shield that
	granted health would have to be un-granted on expiry, and un-granting health
	from somebody who has since been healed is a bug generator.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RigUtil = require(Shared.Util.RigUtil)
local UITheme = require(Shared.Config.UITheme)

local AbilitySupport = require(script.Parent.Parent.AbilitySupport)

local Shield = {}

type Bubble = {
	player: Player,
	remaining: number,
	expiresAt: number,
	part: BasePart?,
}

--[[ Weak keys: a player who leaves mid-shield must not keep this table alive,
     and the step below drops anything whose character has gone anyway. ]]
local bubbles: { [Player]: Bubble } = setmetatable({}, { __mode = "k" }) :: any

local function destroyBubble(bubble: Bubble)
	if bubble.part then
		bubble.part:Destroy()
		bubble.part = nil
	end
end

--[[ The visible half. A single unanchored, uncollidable sphere welded to the
     torso rather than a particle system: it has to read instantly at forty
     studs through a horde, and a sphere is the one shape that says "shield"
     without a texture. ]]
local function buildBubble(character: Model, root: BasePart, radius: number): BasePart?
	local part = Instance.new("Part")
	part.Name = "FL_Shield"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	part.Color = UITheme.Color.Accent
	part.Material = Enum.Material.ForceField
	part.Transparency = 0.55
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.CFrame = root.CFrame

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part
	weld.Part1 = root
	weld.Parent = part

	part.Parent = character
	return part
end

function Shield.activate(context: any): boolean
	local player = context.player
	local character = player.Character
	local root = if character then RigUtil.getRoot(character) else nil
	if not character or not root then
		return false
	end

	--[[ Re-raising replaces rather than stacks. Two shields at once would be two
	     pools and two clocks on one body, and the second one would silently
	     inherit the first's bubble. ]]
	local existing = bubbles[player]
	if existing then
		destroyBubble(existing)
	end

	bubbles[player] = {
		player = player,
		remaining = context.tuning.DamageAbsorption,
		expiresAt = os.clock() + context.tuning.Duration,
		part = buildBubble(character, root, context.tuning.Radius),
	}

	AbilitySupport.broadcast("ShieldUp", {
		id = context.definition.id,
		player = player,
		duration = context.tuning.Duration,
	})
	return true
end

--[[ What survives this player's shield. Called from SurvivorService's damage
     funnel through AbilityService:absorb — see the note there on why the
     indirection exists. ]]
function Shield.absorb(player: Player, amount: number): number
	local bubble = bubbles[player]
	if not bubble or typeof(amount) ~= "number" or amount <= 0 then
		return amount
	end
	if os.clock() >= bubble.expiresAt then
		--[[ Expired but not yet swept. Cleared here rather than left for the
		     step, because a hit landing in that gap must not be absorbed by a
		     shield that has visually already gone. ]]
		destroyBubble(bubble)
		bubbles[player] = nil
		return amount
	end

	local taken = math.min(bubble.remaining, amount)
	bubble.remaining -= taken

	if bubble.remaining <= 0 then
		destroyBubble(bubble)
		bubbles[player] = nil
		AbilitySupport.broadcast("ShieldDown", { player = player, broke = true })
	end

	return amount - taken
end

function Shield.step(_dt: number)
	local now = os.clock()
	for player, bubble in bubbles do
		--[[ A character that has gone takes its bubble with it: the part was
		     parented to it and is already destroyed, and leaving the record would
		     let a respawned player be shielded by a shield that ended. ]]
		if now >= bubble.expiresAt or not player.Parent or not player.Character then
			destroyBubble(bubble)
			bubbles[player] = nil
			AbilitySupport.broadcast("ShieldDown", { player = player, broke = false })
		end
	end
end

function Shield.clear()
	for player, bubble in bubbles do
		destroyBubble(bubble)
		bubbles[player] = nil
	end
end

return Shield
