--!nonstrict
--[[
	Become Walrus — three minutes as something with five thousand hit points.

	A birthday present, granted only by CodeConfig's DAVIS-13TH, and the only
	ability in this game that changes what the player IS rather than what they
	can do.

	── IT IS A SHIELD, NOT A HEALTH BAR ────────────────────────────────────────
	The five thousand is a POOL and never touches the survivor's own health. Every
	hit that would land on the player lands on it instead — through the same
	`absorb` funnel the Shield uses, so SurvivorService still has exactly one
	ability-shaped thing to know about — and when the walrus ends, the person
	inside comes back out at precisely the health they went in with.

	That is the answer to the only question this design really had. A transform
	that could get you killed would be a thing you used carefully; one that cannot
	is a thing you used JOYFULLY, and for a present the second is the right answer.
	Five thousand is more than three minutes of anything short of a finale, so the
	clock almost always ends it — the pool is there for the case where he walks a
	walrus into a Tank on purpose, which he will.

	── THE CHARACTER IS NOT REPLACED ───────────────────────────────────────────
	It is DRESSED. The survivor's own rig stays exactly where it is, keeps its
	physics, its camera, its controls and its network ownership; its parts are
	simply made invisible and the walrus model is welded to the root.

	Rebuilding the character would have been the obvious way and it is a trap. A
	swapped rig loses the Humanoid the whole game reads state off, breaks every
	service holding a reference to that character, and has to put a survivor back
	together afterwards with the right health, the right weapons and the right
	place to stand. This way, the only thing that changed is what it looks like —
	and reverting is deleting a model and setting some transparencies back.

	── WHAT A WALRUS CAN DO ────────────────────────────────────────────────────
	Bonk, by charging. Speed-gated so a stationary walrus is not an aura: the
	input is committing to a direction, which is the same thing the Charger asks
	of the player on the other side.

	Breathe, on the fire button. Held rather than pressed, resolved on the server
	on a tick, in a CONE — see WalrusInput, and see AbilityConfig's tuning for why
	the numbers are above the shop Flamethrower's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityAssets = require(Shared.Util.AbilityAssets)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local AbilitySupport = require(script.Parent.Parent.AbilitySupport)

local PA = Attributes.Player

local BecomeWalrus = {}

--[[ The Assets/Abilities model welded on. Named here rather than taken from the
     definition's `preview`, which is the GHOST an ability draws while choosing a
     spot — this one is untargeted and has no ghost, and borrowing that field
     would make the two mean different things on different abilities. ]]
local MODEL_NAME = "Become Walrus"

--[[ How often the walrus's own clock is looked at, and how often a charging one
     checks what it has run into. Tied to the ability step rather than to a frame:
     a bonk sweep is an allocation, and sixty of them a second per walrus is the
     thing this codebase spends its comments forbidding. ]]
local SWEEP_INTERVAL = 0.1

--[[ A little UP in every bonk, on top of the push away.

     Without it the impulse is flat along the ground, and a flat shove into a
     body standing on a floor is mostly eaten by friction — the zombie slides a
     foot and stops. The lift is what turns a bonk into something you watch
     happen, which is the entire reason this ability has one. ]]
local LIFT = 26

type Walrus = {
	player: Player,
	character: Model,
	root: BasePart,
	humanoid: Humanoid,
	tuning: any,
	slot: number,
	pool: number,
	expiresAt: number,
	model: Model?,
	--[[ What each part's transparency was before it was hidden, so reverting puts
	     back what was actually there rather than assuming zero. A survivor can be
	     part-way through something that made them translucent. ]]
	hidden: { [BasePart]: number },
	speedBefore: number,
	sweepAt: number,
	flameAt: number,
	-- When the hurt sample may next play. See HURT_INTERVAL.
	hurtAt: number,
	--[[ The held trigger, as last reported. Cleared by the client sending false,
	     by the walrus ending, and by the client going quiet — see stale. ]]
	firing: boolean,
	aim: Vector3,
	heardAt: number,
	-- Per TARGET, so a walrus crossing a crowd hits each body once on the way.
	bonkedAt: { [Model]: number },
}

--[[ Weak keys, like every other per-player table in the ability modules: a
     player who leaves mid-walrus must not hold their own record alive. ]]
local walruses: { [Player]: Walrus } = setmetatable({}, { __mode = "k" }) :: any

local function now(): number
	return os.clock()
end

--[[ How long a held trigger survives without being re-heard. The client sends at
     a fixed low rate; this is comfortably more than one interval and well under
     a second, so a client that stops sending stops breathing rather than
     breathing forever. ]]
local INPUT_GRACE = 0.4

--[[ How often the hurt sample may play, however often the walrus is hit.

     A walrus stood in a horde takes something about twice a second, and a grunt
     per hit would be a wall of noise on the one ability whose entire feeling is
     being unbothered by it. Long enough to read as "that hurt" and short enough
     that a Tank landing three in a row is audibly three. ]]
local HURT_INTERVAL = 0.55

--[[ Everything this ability says, in one place. Through AudioService so the
     walrus inherits the rolloff and the voice budget the rest of the game is
     mixed against, rather than being the one thing that ignores them. ]]
local function say(walrus: Walrus, key: string)
	local audio: any = Registry.find("AudioService")
	if audio and typeof(audio.play) == "function" then
		pcall(audio.play, audio, "Walrus", key, walrus.root.Position)
	end
end

local function publish(walrus: Walrus)
	local player = walrus.player
	if not player.Parent then
		return
	end
	player:SetAttribute(PA.WalrusHealth, math.max(walrus.pool, 0))
end

-- ── becoming, and stopping ──────────────────────────────────────────────────

--[[ Hides the survivor and welds the walrus on. Returns the model, or nil if
     there is nothing to dress — in which case the ability still runs and the
     player is simply an invisible five-thousand-point charge, which is a better
     failure than refusing a present because an asset is missing. ]]
--[[
	── ARTICULATED, OR ONE SOLID LUMP ──────────────────────────────────────────
	Every part of the walrus used to be welded to the character's root. That is
	correct for a prop and wrong for an animal: a WeldConstraint per part pins
	the whole model into one rigid body, so no joint can bend and any Animator
	inside it is over-constrained and drives nothing.

	It moved — the earlier Anchored fix saw to that — and it moved as a slab.
	From the outside that is a walrus gliding around in a fixed pose, which is
	what "frozen" looks like when the thing is not actually stationary.

	So: if the model is a rig, weld only its ROOT to the character and leave its
	own joints alone. The root carries it, the joints articulate it, and its own
	clips play over the top. A model with no joints falls back to the old rigid
	weld, because welding one part of a pile of loose parts would leave the rest
	on the floor.
]]
local reportedRig = false
local function reportRig(motors: number, carrier: BasePart?, clips: number)
	if reportedRig then
		return
	end
	reportedRig = true
	if not carrier then
		print(
			string.format(
				"[BecomeWalrus] %q has %d Motor6D(s), so it is welded rigid and will slide rather "
					.. "than move. Give the model joints (a Motor6D chain, or an R15/R6 rig) and it "
					.. "articulates; add an Animation inside it and the clip plays.",
				MODEL_NAME,
				motors
			)
		)
	elseif clips == 0 then
		print(
			string.format(
				"[BecomeWalrus] %q is a rig (%d joints) and is articulated on %q — but it carries no "
					.. "Animation, so nothing drives those joints. Put an Animation object inside the "
					.. "model with its AnimationId set and it plays on a loop.",
				MODEL_NAME,
				motors,
				carrier.Name
			)
		)
	else
		print(
			string.format(
				"[BecomeWalrus] %q articulated on %q — %d joint(s), %d clip(s) looping.",
				MODEL_NAME,
				carrier.Name,
				motors,
				clips
			)
		)
	end
end

local function motorsIn(model: Model): { Motor6D }
	local motors: { Motor6D } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			table.insert(motors, descendant)
		end
	end
	return motors
end

--[[ The part the joints hang from: the author's PrimaryPart if they set one,
     else whichever part the most Motor6Ds treat as Part0, else the biggest.
     Three answers because a supplied model is allowed to be any of them. ]]
local function rootOf(model: Model, motors: { Motor6D }): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local score: { [BasePart]: number } = {}
	local best, bestScore = nil, 0
	for _, motor in motors do
		local part = motor.Part0
		if part then
			score[part] = (score[part] or 0) + 1
			if score[part] > bestScore then
				best, bestScore = part, score[part]
			end
		end
	end
	if best then
		return best
	end
	local biggest, volume = nil, -1
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local size = part.Size.X * part.Size.Y * part.Size.Z
			if size > volume then
				biggest, volume = part, size
			end
		end
	end
	return biggest
end

--[[
	Something that can play a clip, without giving the character a second
	Humanoid.

	This model is parented INTO the character. A Humanoid inside it would make
	`FindFirstChildOfClass("Humanoid")` a coin toss for every system in the game
	that reads the player's state off exactly that call — damage, downs, revives,
	the HUD. So any Humanoid the author shipped is replaced with an
	AnimationController, which offers the Animator and none of the state machine.
]]
local function animatorFor(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end
	local controller = model:FindFirstChildOfClass("AnimationController")
	if not controller then
		controller = Instance.new("AnimationController")
		controller.Parent = model
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	return animator
end

--[[ Every clip the author put in the model, looped. Nothing is invented: a
     model with no Animation in it stays still and says so, because guessing an
     asset id is inventing content. ]]
local function playClips(model: Model, animator: Animator?): number
	if not animator then
		return 0
	end
	local played = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Animation") and descendant.AnimationId ~= "" then
			local ok, track = pcall(function()
				return animator:LoadAnimation(descendant)
			end)
			if ok and track then
				track.Looped = true
				track.Priority = Enum.AnimationPriority.Movement
				track:Play()
				played += 1
			end
		end
	end
	return played
end

local function dress(walrus: Walrus): Model?
	for _, part in walrus.character:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 then
			walrus.hidden[part] = part.Transparency
			part.Transparency = 1
		elseif part:IsA("Decal") or part:IsA("Texture") then
			part.Transparency = 1
		end
	end

	--[[ Through AbilityAssets, like the turret — it is the one place that knows
	     an ability model can be in ReplicatedStorage or, on the server's courtesy
	     pass, in ServerStorage. Cloned here because `find` deliberately does not:
	     a caller wanting two turrets needs two clones. ]]
	local template = AbilityAssets.find(MODEL_NAME)
	if not template then
		return nil
	end
	local model = template:Clone()

	model.Name = "FL_Walrus"
	model:PivotTo(walrus.root.CFrame)

	local motors = motorsIn(model)
	local carrier = if #motors > 0 then rootOf(model, motors) else nil
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			--[[
				── ANCHORED WAS THE WHOLE BUG, AND IT WAS AN OMISSION ────────────
				A weld does nothing to an anchored part. Anchored means "the engine
				does not move this", and it outranks every constraint attached to
				it — so a model built in Studio, where anchoring everything is the
				default habit, was nailed to the spot PivotTo had just put it.

				What that looked like: the player became a walrus, walked away, and
				left the walrus behind. Everybody else saw a motionless animal in an
				empty corridor. The player themselves saw nothing wrong, because
				they were in first person looking out of a rig that was still
				moving — which is why this survived being tested.

				It also explains the ghost. OutlineController adorns a Highlight to
				the character MODEL, the abandoned parts are still descendants of
				it, and the fill switches on when the teammate is occluded. The
				teammate genuinely was occluded: they were in the next room. So the
				engine drew a filled silhouette of a walrus that was not there.

				Unanchored FIRST, before the weld, so there is never a frame where
				a constraint is attached to something that cannot honour it.
			]]
			part.Anchored = false
			--[[ Massless and non-collidable, for the same reason a dressed
			     projectile's parts are: the rig underneath is still the physics,
			     and a walrus whose handling changed with its model would be a
			     walrus that handles differently from the one that was tuned.

			     CanQuery false as well — a walrus that stopped a teammate's
			     bullet meant for the Common behind it is the worst kind of
			     friendly fire, because it looks like the shooter missed. ]]
			part.Massless = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CollisionGroup = "Debris"
			--[[ Only the carrier when the model is a rig. Welding every part as
			     well would re-pin the joints this whole branch exists to keep
			     free — two constraints on one part and the stiffer wins. ]]
			if carrier == nil or part == carrier then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = walrus.root
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end

	local clips = 0
	if carrier then
		clips = playClips(model, animatorFor(model))
	end
	model.Parent = walrus.character

	--[[ Said once, because which of the three shapes the supplied model turned
	     out to be is the difference between a walrus that lives and a walrus
	     that slides, and it is not visible from anywhere else. ]]
	reportRig(#motors, carrier, clips)
	return model
end

local function undress(walrus: Walrus)
	if walrus.model then
		walrus.model:Destroy()
		walrus.model = nil
	end
	for part, transparency in walrus.hidden do
		if part.Parent then
			part.Transparency = transparency
		end
	end
	table.clear(walrus.hidden)
end

--[[
	Ends it, whichever of the three ways got here: the clock, the pool, or the
	player being taken out of the round under it.

	Everything this puts back is something `become` changed and nothing else. The
	survivor's health is not among them, and never was — see the header.
]]
local function revert(walrus: Walrus, early: boolean)
	local player = walrus.player
	walruses[player] = nil

	undress(walrus)

	if walrus.humanoid.Parent and walrus.humanoid.Health > 0 then
		walrus.humanoid.WalkSpeed = walrus.speedBefore
	end

	if player.Parent then
		player:SetAttribute(PA.IsWalrus, false)
		player:SetAttribute(PA.WalrusHealth, 0)
		player:SetAttribute(PA.WalrusUntil, 0)
	end

	--[[
		A walrus that ended EARLY pulls its cooldown forward.

		The definition's 480 is three minutes of walrus plus five of waiting,
		stamped at activation because that is when the service stamps. If the pool
		ran out at ninety seconds, the player has had half the ability and is owed
		the difference — so the cooldown is re-stamped to five minutes from NOW.

		Only ever earlier. The service's number is the ceiling and this can lower
		it; a version that could raise it would be a way for an ability to punish
		its own user for having been hit.
	]]
	if early then
		local abilities = Registry.find("AbilityService")
		if abilities and typeof(abilities.holdCooldown) == "function" then
			local definition = walrus.tuning
			local wait = if typeof(definition.CooldownAfter) == "number"
				then definition.CooldownAfter
				else 300
			pcall(abilities.holdCooldown, abilities, player, walrus.slot, wait)
		end
	end

	AbilitySupport.broadcast("WalrusEnded", { player = player })
end

function BecomeWalrus.activate(context: any): boolean
	local player = context.player
	local tuning = context.tuning
	if walruses[player] then
		-- Already one. Not a refusal worth a cooldown; they simply are one.
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and RigUtil.getRoot(character)
	if not character or not humanoid or not root or humanoid.Health <= 0 then
		return false
	end

	--[[ Only a survivor on their feet. A walrus that could be entered from the
	     floor would be a self-revive, which is a different ability and a much
	     bigger decision than this one. ]]
	local survivors = Registry.find("SurvivorService")
	if survivors and typeof(survivors.isIncapacitated) == "function" then
		local ok, down = pcall(survivors.isIncapacitated, survivors, player)
		if ok and down then
			return false
		end
	end

	local walrus: Walrus = {
		player = player,
		character = character,
		root = root,
		humanoid = humanoid,
		tuning = tuning,
		slot = if typeof(context.slot) == "number" then context.slot else 1,
		pool = tuning.Pool,
		expiresAt = now() + tuning.Duration,
		model = nil,
		hidden = {},
		speedBefore = humanoid.WalkSpeed,
		sweepAt = 0,
		flameAt = 0,
		hurtAt = 0,
		firing = false,
		aim = root.CFrame.LookVector,
		heardAt = 0,
		bonkedAt = setmetatable({}, { __mode = "k" }) :: any,
	}

	walruses[player] = walrus
	walrus.model = dress(walrus)
	humanoid.WalkSpeed = tuning.WalkSpeed

	player:SetAttribute(PA.IsWalrus, true)
	player:SetAttribute(PA.WalrusUntil, Workspace:GetServerTimeNow() + tuning.Duration)
	publish(walrus)

	AbilitySupport.broadcast("WalrusBegan", {
		player = player,
		position = root.Position,
		seconds = tuning.Duration,
	})
	return true
end

-- ── what a walrus does ──────────────────────────────────────────────────────

--[[
	Every hit that would have landed on the player, landing here instead.

	Returns the REMAINDER, the same contract the Shield's absorb has, so the two
	compose: a walrus with a hundred left against a five-hundred hit takes the
	hundred and hands three hundred back up the chain. In practice the pool is
	deep enough that the remainder is zero until the very last hit, which is the
	point — for three minutes, nothing reaches the person inside.
]]
function BecomeWalrus.absorb(player: Player, amount: number): number
	local walrus = walruses[player]
	if not walrus or amount <= 0 then
		return amount
	end

	local taken = math.min(walrus.pool, amount)
	walrus.pool -= taken
	publish(walrus)

	--[[ The RPG's own voice, throttled. See AudioConfig.Walrus for why the hurt
	     sound is the launcher's firing sample, and HURT_INTERVAL for why it is
	     not played on every hit. ]]
	local clock = now()
	if clock >= walrus.hurtAt then
		walrus.hurtAt = clock + HURT_INTERVAL
		say(walrus, "Hurt")
	end

	if walrus.pool <= 0 then
		revert(walrus, true)
	end
	return amount - taken
end

--[[ A charging walrus, and what it ran into. Speed-gated: `BonkSpeed` is below
     the walrus's own top speed and well above a shuffle, so the input is
     committing to a direction rather than standing in a crowd. ]]
local function bonk(walrus: Walrus, clock: number)
	local velocity = walrus.root.AssemblyLinearVelocity
	--[[ Flattened. A walrus falling off a roof is moving very fast downward and
	     has not charged anything; only ground speed is a charge. ]]
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if speed < walrus.tuning.BonkSpeed then
		return
	end

	local damageService = Registry.find("DamageService")
	if not damageService then
		return
	end

	local origin = walrus.root.Position
	local heading = if speed > 0 then Vector3.new(velocity.X, 0, velocity.Z).Unit else walrus.aim
	--[[ One bonk sound per SWEEP that connected, not one per body. A walrus
	     ploughing into six Commons makes one heavy noise, which is what a walrus
	     ploughing into six Commons sounds like; six copies of it inside a tenth
	     of a second is a burst of static. ]]
	local connected = false

	for _, target in AbilitySupport.infectedWithin(origin, walrus.tuning.BonkRadius) do
		local last = walrus.bonkedAt[target.model]
		if last and clock - last < walrus.tuning.BonkCooldown then
			continue
		end
		walrus.bonkedAt[target.model] = clock

		local away = target.root.Position - origin
		local push = if away.Magnitude > 0.001 then away.Unit else heading

		damageService:applyDamage(
			target.model,
			walrus.tuning.BonkDamage,
			Types.newDamageContext({
				attacker = walrus.player,
				weaponId = Enums.Ability.BecomeWalrus,
				damageType = Enums.DamageType.Melee,
				region = Enums.HitRegion.Torso,
				hitPart = target.root,
				hitPosition = target.root.Position,
				hitNormal = push,
				--[[ Away from the WALRUS rather than along its heading, so a body
				     clipped on the shoulder is thrown aside rather than dragged
				     forward through the charge that hit it. ]]
				direction = push,
				sourcePosition = origin,
			})
		)

		--[[
			And the shove, applied HERE rather than asked for in the context.

			DamageContext carries no knockback field, and the one on a weapon is
			read by GoreService when a body DIES — it is a death throw, so a
			zombie a walrus merely hurt would have stood there and a zombie it
			killed would have crumpled where it stood, since BecomeWalrus is not a
			WeaponConfig id and that lookup answers zero. Neither is a bonk.

			An impulse scaled by the body's own mass, which is the same thing a
			shove does and for the same reason: a fixed force throws a light body
			across the street and barely tips a heavy one, and the walrus should
			feel the same to charge into either.

			A stagger with it. A zombie that is thrown and keeps walking the
			instant it lands has not been bonked, it has been nudged.
		]]
		local push3 = push * walrus.tuning.BonkKnockback
		target.root:ApplyImpulse(
			Vector3.new(push3.X, math.abs(push3.Y) + LIFT, push3.Z) * target.root.AssemblyMass
		)

		local infected = Registry.find("InfectedService")
		if infected and typeof(infected.stagger) == "function" then
			pcall(infected.stagger, infected, target.model, push, walrus.tuning.BonkStumble)
		end
		connected = true
	end

	if connected then
		say(walrus, "Bonk")
	end
end

--[[ The breath. A cone in front rather than the Flamethrower's pellet spray,
     because this is not a weapon going through BallisticsService — see the
     header, and AbilityConfig for why the numbers are above the shop one's. ]]
local function breathe(walrus: Walrus, clock: number)
	if not walrus.firing or clock - walrus.heardAt > INPUT_GRACE then
		return
	end
	if clock < walrus.flameAt then
		return
	end
	walrus.flameAt = clock + walrus.tuning.FlameTick

	local origin = walrus.root.Position
	local facing = walrus.aim
	if facing.Magnitude <= 0.001 then
		return
	end
	facing = facing.Unit

	local damageService = Registry.find("DamageService")
	local infected = Registry.find("InfectedService")
	if not damageService then
		return
	end

	--[[ Every tick, hit or miss. The breath is a thing the player is DOING, and a
	     flamethrower that only makes a noise when it catches something would go
	     silent the moment you needed to know it was still running. ]]
	say(walrus, "Flame")

	local limit = math.cos(math.rad(walrus.tuning.FlameAngle))
	local burned = false

	for _, target in AbilitySupport.infectedWithin(origin, walrus.tuning.FlameRange) do
		local delta = target.root.Position - origin
		if delta.Magnitude <= 0.001 then
			continue
		end
		--[[ The cone. A dot against the facing rather than an angle computed per
		     body: the comparison is the same and the arccos is not free at the
		     rate this runs. ]]
		if delta.Unit:Dot(facing) < limit then
			continue
		end

		burned = true
		damageService:applyDamage(
			target.model,
			walrus.tuning.FlameDamage,
			Types.newDamageContext({
				attacker = walrus.player,
				weaponId = Enums.Ability.BecomeWalrus,
				damageType = Enums.DamageType.Fire,
				region = Enums.HitRegion.Torso,
				hitPart = target.root,
				hitPosition = target.root.Position,
				hitNormal = -facing,
				direction = facing,
				sourcePosition = origin,
			})
		)

		--[[ And it LIGHTS them, through the same ignite the molotov uses. The
		     breath is the push and the fire is what finishes whatever walked out
		     of it. ]]
		if walrus.tuning.FlameIgnites and infected and typeof(infected.ignite) == "function" then
			pcall(infected.ignite, infected, target.model, walrus.player)
		end
	end

	AbilitySupport.broadcast("WalrusFlame", {
		player = walrus.player,
		origin = origin,
		direction = facing,
		range = walrus.tuning.FlameRange,
		angle = walrus.tuning.FlameAngle,
		hit = burned,
	})
end

--[[ What the client says it is doing. Validated on arrival rather than trusted:
     the only thing this accepts is a direction and a held flag, and a player who
     is not a walrus is not one however often they say so. ]]
function BecomeWalrus.input(player: Player, aim: any, firing: any)
	local walrus = walruses[player]
	if not walrus then
		return
	end
	if typeof(aim) == "Vector3" and aim.Magnitude > 0.001 and aim.X == aim.X then
		walrus.aim = aim.Unit
	end
	walrus.firing = firing == true
	walrus.heardAt = now()
end

function BecomeWalrus.step(_dt: number)
	local clock = now()
	for player, walrus in walruses do
		--[[ Gone, one way or another. A character that was destroyed, a humanoid
		     that died, or a player who left — all of them end the walrus, and none
		     of them is early: the ability ran until something stopped the person
		     inside it, which is not the pool running out. ]]
		if
			not player.Parent
			or walrus.character.Parent == nil
			or not walrus.humanoid.Parent
			or walrus.humanoid.Health <= 0
		then
			revert(walrus, false)
			continue
		end

		if clock >= walrus.expiresAt then
			revert(walrus, false)
			continue
		end

		if clock >= walrus.sweepAt then
			walrus.sweepAt = clock + SWEEP_INTERVAL
			bonk(walrus, clock)
		end
		breathe(walrus, clock)
	end
end

--[[ Round over, or the service shutting down. Everything is put back: a walrus
     left dressed across a round boundary is a survivor who spawns into the next
     one invisible inside a model nothing is stepping any more. ]]
function BecomeWalrus.clear()
	for _, walrus in walruses do
		undress(walrus)
		if walrus.humanoid.Parent and walrus.humanoid.Health > 0 then
			walrus.humanoid.WalkSpeed = walrus.speedBefore
		end
		if walrus.player.Parent then
			walrus.player:SetAttribute(PA.IsWalrus, false)
			walrus.player:SetAttribute(PA.WalrusHealth, 0)
			walrus.player:SetAttribute(PA.WalrusUntil, 0)
		end
	end
	table.clear(walruses :: any)
end

--[[ Whether this player is currently one. Read by AbilityService so the walrus
     input remote has exactly one thing to ask, and by anything that needs to
     know a survivor is not currently shaped like a survivor. ]]
function BecomeWalrus.isWalrus(player: Player): boolean
	return walruses[player] ~= nil
end

return BecomeWalrus
