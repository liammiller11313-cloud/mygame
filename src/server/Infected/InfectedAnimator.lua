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
}

-- Speed at which a body is considered to be moving at all, and the speed above
-- which it switches from the walk cycle to the run cycle. Read from the rig's
-- own configured speeds rather than a constant, so a sprinting Common and a
-- lumbering Tank each cross the line at the right moment for their own gait.
local MOVING_EPSILON = 0.1
local RUN_FRACTION = 0.62

--[[ How fast a track's playback is scaled to match the body's actual speed. A
     zombie moving at 21 studs/sec playing a 16 studs/sec walk cycle is the
     "moonwalking" look; matching the rate fixes it for free. ]]
local BASE_WALK_SPEED = 16
local MIN_RATE = 0.5
local MAX_RATE = 2.4

local FADE = 0.18

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

	local store = model:FindFirstChild(ANIMATION_FOLDER)
	if not store then
		warnOnce(
			"nostore:" .. kind,
			string.format("%s rigs carry no %s folder — they will not animate", kind, ANIMATION_FOLDER)
		)
		return nil
	end

	local self = setmetatable({
		model = model,
		kind = kind,
		humanoid = humanoid,
		tracks = {},
		current = "",
		oneShotUntil = 0,
	}, InfectedAnimator)

	for role, candidates in ROLE_FALLBACK do
		for _, name in candidates do
			local bucket = store:FindFirstChild(name)
			local animation = bucket and bucket:FindFirstChildOfClass("Animation")
			if animation then
				local ok, track = pcall(function()
					return animator:LoadAnimation(animation)
				end)
				if ok and track then
					track.Priority = if role == "attack" or role == "death"
						then Enum.AnimationPriority.Action
						else Enum.AnimationPriority.Movement
					track.Looped = role ~= "attack" and role ~= "death"
					self.tracks[role] = track
					break
				end
			end
		end
	end

	if next(self.tracks) == nil then
		warnOnce("empty:" .. kind, string.format("%s rigs harvested no usable animations", kind))
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

	if role == "idle" then
		track:AdjustSpeed(1)
	else
		track:AdjustSpeed(math.clamp(speed / BASE_WALK_SPEED, MIN_RATE, MAX_RATE))
	end
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
