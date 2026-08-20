--!nonstrict
--[[
	InfectedAnimator — makes the horde walk instead of slide.

	Rigs arrive from the Toolbox with an `Animate` script, and PlaceholderFactory
	strips every script out of them before they enter the world, because a
	free-model rig with a `require(<id>)` in it runs with full server permissions.
	Stripping that script also removes the walk cycle, so the bodies moved around
	the map in a fixed T-pose. PlaceholderFactory now lifts the ids into an inert
	`FL_Animations` folder first; this plays them.

	Why not just put the Animate script back: Animate is a LocalScript-shaped
	thing designed for one player character, it re-reads Humanoid state every
	frame, and forty-six copies of it is forty-six scripts competing for the
	scheduler during exactly the moment the frame budget matters most. This drives
	every infected from InfectedService's single existing loop instead, and it
	picks a track by reading MoveDirection, which is one vector compare per body.

	The whole thing degrades to silence: a rig with no ids animates nothing and
	warns once, rather than erroring per zombie per frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationCache = require(Shared.Util.AnimationCache)
local AnimationConfig = require(Shared.Config.AnimationConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)

local InfectedAnimator = {}
InfectedAnimator.__index = InfectedAnimator

local ANIMATION_FOLDER = "FL_Animations"

--[[
	Which harvested role to prefer for each state, in order.

	Roblox's own Animate names them "walk"/"run"/"idle", custom zombie rigs
	commonly use "Zombie"/"attack"/"death", and some packs only ship a single
	"walk". Each list falls through until something exists, so a rig with one
	animation still moves — it just moves the same way all the time, which reads
	far better than not moving at all.
]]
local ROLE_FALLBACK = {
	idle = { "idle", "stand", "zombieidle", "wait" },
	walk = { "walk", "walkanim", "zombie", "run", "idle" },
	run = { "run", "runanim", "sprint", "walk", "zombie" },
	attack = { "attack", "swipe", "slash", "toolslash", "punch" },
	death = { "death", "die", "dead" },
	--[[ Airborne and climbing. Reached from the humanoid's own state rather than
	     from its speed, because a body falling off a catwalk has plenty of speed
	     and none of it is walking. A rig without these keeps whatever ground
	     state it was in, which is the old behaviour. ]]
	jump = { "jump", "jumpanim" },
	fall = { "fall", "freefall", "falling" },
	climb = { "climb", "climbanim" },
}

--[[ Humanoid states that are not "on the ground moving", and the role each one
     wants. Checked before speed, since speed cannot tell them apart. ]]
local STATE_ROLE: { [Enum.HumanoidStateType]: string } = {
	[Enum.HumanoidStateType.Freefall] = "fall",
	[Enum.HumanoidStateType.Jumping] = "jump",
	[Enum.HumanoidStateType.Climbing] = "climb",
}

-- Speed at which a body is considered to be moving at all, and the speed above
-- which it switches from the walk cycle to the run cycle. Read from the rig's
-- own configured speeds rather than a constant, so a sprinting Common and a
-- lumbering Tank each cross the line at the right moment for their own gait.
local MOVING_EPSILON = 0.1
local RUN_FRACTION = 0.62

--[[
	How fast a track's playback is scaled to match the body's actual speed.

	A zombie moving at 21 studs/sec playing a 16 studs/sec walk cycle is the
	"moonwalking" look; matching the rate fixes it for free.

	── AND BY THE BODY'S SIZE, WHICH IS THE HALF THAT WAS MISSING ──────────────
	Stride length goes with LEG length. A rig scaled 2.35x covers 2.35x the
	ground per cycle of the same clip, so the speed it should be measured against
	is 16 * 2.35, not 16.

	Dividing by the bare 16 was not a small error. The Tank walks at 16 studs —
	faster than a Common shambling at 9 — so it played its walk at 1.0x while the
	Common played at 0.56x: the heaviest thing in the game had the briskest gait
	in it, and its feet slipped 2.35x on every step. Now it plays at 0.43x, which
	is both slower than any Common and the rate its own legs actually imply.

	Every kind gets this, not just the Tank: the Jockey at 0.82x scale takes
	quicker steps for the same ground, the Rusher at 1.25x takes longer ones.
]]
local BASE_WALK_SPEED = 16
--[[
	The floor is a fraction of a body's NATURAL gait, so it scales with the body.
	A flat 0.5 sat above the Tank's correct 0.43 and would have clamped away the
	entire fix above.

	0.25 rather than the 0.5 it was, because the job it was written for is now
	done elsewhere. It was there to stop a STATIONARY body playing at half rate —
	but a stationary body is in the `idle` role now, which is not rate-matched at
	all, so the floor never sees one. What it still guards is the band between
	MOVING_EPSILON and a real walk, where the raw ratio approaches zero and
	AdjustSpeed(0) would freeze the clip into a statue mid-step.

	At 0.5 it was also clamping a body that genuinely walks slowly: the Witch
	shambles at 5 studs, wants 0.30x, got 0.50x, and slipped 60% on every step.
	The floor now sits below her, and above only speeds too small to read.

	The ceiling does not scale. It is about the clip becoming an unreadable blur,
	and 2.4x looks the same on any size of body.
]]
local MIN_RATE = 0.25
local MAX_RATE = 2.4

--[[ A body's scale, from its kind. Falls back to 1 for a kind with no
     definition, which is the same thing the old fixed divisor assumed. ]]
local function bodyScaleOf(kind: string): number
	local definition = InfectedConfig.get(kind)
	local scale = definition and definition.scale
	return if typeof(scale) == "number" and scale > 0 then scale else 1
end

--[[ The roles whose playback rate follows the body's speed. See setState. ]]
local RATE_MATCHED: { [string]: boolean } = {
	walk = true,
	run = true,
}

--[[ An idle has no stride to match, so it is not rate-matched — but a big body
     still should not breathe at a small body's tempo. A pendulum's period goes
     with the square root of its length, which is why this is sqrt and not the
     scale itself: a 2.35x Tank idles at 0.65x, not 0.43x. ]]
local IDLE_WEIGHTED: { [string]: boolean } = {
	idle = true,
}

local FADE = 0.18

--[[ One generator for the whole module. Each body draws its idle variant from
     it at spawn, so the choice differs per zombie without every zombie paying
     for its own Random. ]]
local random = Random.new()

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[InfectedAnimator] " .. message)
end

--[[ Loads one track per role. Tracks are loaded ONCE at spawn: Animator:LoadAnimation
     yields on first use for an id the client has never seen, and doing that lazily
     in the middle of a horde is a frame spike per new zombie. ]]
function InfectedAnimator.new(model: Model, kind: string)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end

	--[[ No longer fatal. A rig with no harvested folder can still be animated
	     from AnimationConfig, and if that produces nothing either the client's
	     procedural poser picks it up. Absence here is a fallback, not a failure. ]]
	local store = model:FindFirstChild(ANIMATION_FOLDER)

	local self = setmetatable({
		model = model,
		kind = kind,
		--[[ Resolved once at spawn rather than looked up per state change: this is
		     read on every gait switch of every body in the round, and a body's
		     scale cannot change once it is this kind. ]]
		bodyScale = bodyScaleOf(kind),
		humanoid = humanoid,
		tracks = {},
		current = "",
		oneShotUntil = 0,
	}, InfectedAnimator)

	--[[ Loads one Animation instance and keeps the track. Shared by both sources
	     so priority and looping are decided once: an attack or a death is an
	     Action played over the top of whatever is moving, everything else is
	     Movement and loops. ]]
	local function adopt(role: string, animation: Animation): boolean
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if not ok or not track then
			return false
		end
		track.Priority = if role == "attack" or role == "death"
			then Enum.AnimationPriority.Action
			else Enum.AnimationPriority.Movement
		track.Looped = role ~= "attack" and role ~= "death"
		self.tracks[role] = track
		return true
	end

	-- ── 1. what the rig brought with it ─────────────────────────────────────
	if store then
		for role, candidates in ROLE_FALLBACK do
			for _, name in candidates do
				local bucket = store:FindFirstChild(name)
				local animation = bucket and bucket:FindFirstChildOfClass("Animation")
				if animation and adopt(role, animation) then
					--[[ Warmed even though the instance is the rig's own and
					     outlives the load. Keeping the instance is only half the
					     problem: a track whose asset has not arrived plays
					     nothing either way, and this is the first spawn of this
					     rig, so nothing has fetched it yet. ]]
					AnimationCache.preload({ animation.AnimationId })
					break
				end
			end
		end
	end

	--[[ ── 2. what this game supplies ────────────────────────────────────────

	     Only for roles the rig did not already fill, so a model that shipped its
	     own walk keeps it — it knows its own proportions better than a generic
	     package does.

	     The rig check is the important part. A Roblox animation addresses NAMED
	     joints, so an R6 clip on an R15 rig loads, reports itself as playing, and
	     moves nothing — and because InfectedPoseController stands down for any
	     body with tracks playing, the result is a rig animated by neither. That
	     is a T-pose that looks exactly like the bug this all exists to fix. ]]
	local rig = AnimationConfig.rigOf(model)
	local set = AnimationConfig.forInfected(kind, rig)

	if not set then
		warnOnce(
			string.format("norig:%s", kind),
			string.format(
				"%s is an %s rig and AnimationConfig has no set that addresses those joint names. "
					.. "The client's procedural poser will drive it instead. Add an entry under "
					.. "AnimationConfig.ByRig to give it real clips.",
				kind,
				rig
			)
		)
	else
		for role, ids in set :: any do
			if role == "rig" or self.tracks[role] or typeof(ids) ~= "table" then
				continue
			end
			--[[ One id per body, chosen at spawn and kept. Two Commons in the
			     same doorway get different idles, which costs nothing and is most
			     of what stops a crowd reading as one animation. ]]
			local id = ids[random:NextInteger(1, #ids)]

			--[[
				From the cache, and NOT destroyed afterwards.

				This used to build an Animation, load it, and destroy it on the
				next line. A track resolves its asset fetch through the instance
				it was given, so destroying it left the track pointing at nothing
				— which works when the id happened to already be cached and
				silently never plays when it was not. That was the whole of
				"sometimes my animations do not load".

				AnimationCache keeps one instance per id for the life of the
				server and preloads it. See its header.
			]]
			local animation = AnimationCache.get(id)
			if not animation then
				warnOnce(
					"badid:" .. tostring(id),
					string.format("%s is not a usable animation id (%s/%s)", tostring(id), kind, role)
				)
			elseif not adopt(role, animation) then
				warnOnce(
					"refused:" .. tostring(id),
					string.format("the Animator refused animation %d for %s/%s", id, kind, role)
				)
			elseif AnimationCache.hasFailed(id) then
				--[[ LoadAnimation does not throw for an id that does not exist or
				     is not owned by this place — it hands back an ordinary track
				     that never plays. The cache's preload is what actually knows,
				     and it says so by id rather than leaving a silent rig. ]]
				warnOnce(
					"unfetchable:" .. tostring(id),
					string.format(
						"animation %d loaded but its asset could not be fetched, so %s/%s will not "
							.. "move. Roblox only plays animations owned by this place's creator or "
							.. "by Roblox itself.",
						id,
						kind,
						role
					)
				)
			end
		end
	end

	if next(self.tracks) == nil then
		warnOnce(
			"empty:" .. kind,
			string.format(
				"%s has no usable animations from its rig or from AnimationConfig — the client's "
					.. "procedural poser will drive it",
				kind
			)
		)
		return nil
	end

	return self
end

--[[ Switches the looping track, matching playback rate to the body's real speed
     so a fast zombie does not appear to skate. Called from the shared brain tick;
     it does nothing at all when the state has not changed. ]]
function InfectedAnimator.setState(self, role: string, speed: number)
	local track = self.tracks[role] or self.tracks.walk or self.tracks.idle
	if not track then
		return
	end

	if self.current ~= role then
		for name, other in self.tracks do
			if name ~= role and other.IsPlaying and other.Looped then
				other:Stop(FADE)
			end
		end
		if not track.IsPlaying then
			track:Play(FADE)
		end
		self.current = role
	end

	--[[ Only a GAIT is rate-matched. Walking and running are clips whose feet
	     have to keep up with the ground, and scaling them to the body's real
	     speed is what stops the moonwalk. Nothing else is: an idle, a fall or a
	     climb has no stride to match, and they arrive here with a speed of zero —
	     which the clamp would turn into half-rate playback, so a zombie would
	     drop off a catwalk in slow motion. ]]
	local rate = 1
	if RATE_MATCHED[role] then
		local stride = BASE_WALK_SPEED * self.bodyScale
		rate = math.clamp(speed / stride, MIN_RATE / self.bodyScale, MAX_RATE)
	elseif IDLE_WEIGHTED[role] then
		rate = 1 / math.sqrt(self.bodyScale)
	end
	track:AdjustSpeed(rate)
end

--[[ Reads the body and picks a state. This is the only thing the brain has to
     call; everything above is bookkeeping. ]]
function InfectedAnimator.update(self, runSpeed: number)
	if os.clock() < self.oneShotUntil then
		return
	end

	local humanoid = self.humanoid
	if humanoid.Health <= 0 then
		return
	end

	--[[ Airborne first. A zombie dropping off a catwalk is moving fast in a
	     direction, and asking its speed would put it into a run cycle mid-air. ]]
	local ok, humanoidState = pcall(humanoid.GetState, humanoid)
	if ok then
		local role = STATE_ROLE[humanoidState]
		if role and self.tracks[role] then
			self:setState(role, 0)
			return
		end
	end

	local speed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
	if speed <= MOVING_EPSILON then
		self:setState("idle", 0)
	elseif speed >= runSpeed * RUN_FRACTION then
		self:setState("run", speed)
	else
		self:setState("walk", speed)
	end
end

--[[ Plays a non-looping track over the top of whatever is moving. Used for the
     attack swing, so the telegraph the config asks for is actually visible. ]]
function InfectedAnimator.playOnce(self, role: string, holdFor: number?)
	local track = self.tracks[role]
	if not track then
		return
	end
	track:Play(0.08)
	self.oneShotUntil = os.clock() + (holdFor or track.Length)
end

--[[ True when a role has a real clip behind it. InfectedBrain asks about
     "attack" before posing the arms by hand: its C0 telegraph and a real swing
     both rotate the same shoulders, and doing both rotates them twice. ]]
function InfectedAnimator.has(self, role: string): boolean
	return self.tracks[role] ~= nil
end

function InfectedAnimator.stopAll(self)
	for _, track in self.tracks do
		if track.IsPlaying then
			track:Stop(0.1)
		end
	end
	self.current = ""
end

function InfectedAnimator.destroy(self)
	self:stopAll()
	for name, track in self.tracks do
		pcall(function()
			track:Destroy()
		end)
		self.tracks[name] = nil
	end
end

return InfectedAnimator
