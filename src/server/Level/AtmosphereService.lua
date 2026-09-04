--!nonstrict
--[[
	AtmosphereService — the round clock, written on the sky.

	The game is called Fading Light. This is the file where that stops being a
	title.

	── THE SKY IS THE TIMER ────────────────────────────────────────────────────
	The round opens under a low orange sun and is pitch dark by the finale, and the
	light level is a pure function of RoundService:getElapsed() over
	GameModeConfig.Classic.TotalDuration — never a free-running clock, never a
	timer of its own. That single decision is the reason this module exists: a
	player who glances at the sky knows roughly how long they have left. The dark
	is a HUD element that nobody has to look away from the fight to read.

	It also means the look cannot drift. A server that hitched, a round that
	restarted, a player who joined during wave 4 — all of them see exactly the sky
	the round clock says they should, because there is nothing else for it to be.

	── ONE SET OF KEYFRAMES, ONE ALPHA ─────────────────────────────────────────
	Seventeen lighting properties are interpolated out of five keyframes, together,
	on one alpha — not tweened independently. Independent tweens are how you get a
	green sky at 60% blend: Ambient arriving at midnight while FogColor is still
	at sunset. A keyframe here is a complete look, so every intermediate frame is
	also a look somebody chose.

	The keyframes are anchored to the START OF WAVES 3, 5 AND 7 rather than to
	fixed fractions of the clock, so retuning the wave schedule in GameModeConfig
	re-anchors the light along with it and the sun still goes down on the beat.

	── FOG IS THE BUDGET ───────────────────────────────────────────────────────
	FogEnd does two jobs at once: it hides how little map there is, and it makes
	the far end of a street genuinely unreadable, which is the entire tension. It
	is floored at DirectorConfig.Spawning.MaxDistanceFromSurvivor plus a margin,
	because fog that ends nearer than the furthest legal spawn means the horde
	walks out of solid grey with no warning at all. At that floor a Tank
	(InfectedConfig runSpeed 24) needs about eleven seconds to cross the visible
	distance, which is exactly the amount of warning that fight is supposed to
	give you: enough to choose a corner, not enough to leave.

	A Roblox Atmosphere instance SUPERSEDES Lighting's FogStart/FogEnd/FogColor
	outright. Both are driven here from the same keyframes, with Density chosen to
	bite at roughly the distance FogEnd names, so the place reads the same whether
	or not an Atmosphere is in the tree. (PlaceholderFactory's map lights itself
	with fixtures only and notes that an Atmosphere would override its fog — it
	would, and now one system owns both halves instead of two owning one each.)

	── THE USER'S PLACE IS NOT OURS ────────────────────────────────────────────
	Their place already has an Atmosphere, a Sky, Bloom, DepthOfField and SunRays.
	Anything already in Lighting is adopted and its properties captured first;
	only what is missing gets created. When the round ends the captured values go
	back and only the instances this service created are destroyed. Nothing the
	user placed is ever destroyed.

	── DEGRADING ───────────────────────────────────────────────────────────────
	With no RoundService registered — a developer loading the place alone, or a
	bootstrap that has not been taught about it yet — the whole thing holds
	STATIC_PROGRESS: the intended look, just not moving. Pressing Play must never
	drop you into flat Roblox noon.

	API:
		AtmosphereService:setPhaseFromRound(elapsed: number, total: number)
		AtmosphereService:flash(duration: number, intensity: number)
		AtmosphereService:setBossMood(active: boolean)
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local ModifierConfig = require(Shared.Config.ModifierConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

--[[ 10Hz. ClockTime travels about five and a half hours across a seventeen
     minute round — 0.0005 of an hour per tick — so the sun moves far below the
     threshold of a visible step and the whole pass costs a dozen property
     compares. A flash is the only thing in here that runs at frame rate. ]]
local TICK_INTERVAL = 0.1

--[[ Where the look sits when nothing is driving it. Past blue hour: dark enough
     to be the game, bright enough to build a map in. ]]
local STATIC_PROGRESS = 0.62

--[[ RoundService may register after this service starts. Wait this long before
     concluding it does not exist, or every boot flickers through the static
     preset on its way to the lobby. ]]
local BOOT_GRACE = 3

local TOTAL_DURATION = math.max(GameModeConfig.Classic.TotalDuration, 1)

--[[ Never let the fog close nearer than the furthest point the Director is
     allowed to spawn from. Inside that distance, "the horde arrived" and "the
     horde appeared" become the same event. ]]
--[[ The fog can never close nearer than this. Tied to the Director's spawn band
     so that anything it puts in the world is visible from the moment it starts
     walking at you — fog that hides a Tank until it is on top of you is not
     tension, it is an ambush the player had no way to read. ]]
local MIN_FOG_END = DirectorConfig.Spawning.MaxDistanceFromSurvivor * 2.4

-- Property writes below this delta are skipped; smaller than any of these
-- properties can express on screen.
local EPSILON = 1e-4

--[[
	ClockTime gets a coarser gate than the rest, and it is the only one that does.

	Every other property here is a shader uniform: writing it costs a uniform
	upload. ClockTime MOVES THE SUN, which dirties the cached static half of the
	ShadowMap cascade for every shadow-casting instance in the map. At a 0.1s
	tick over a seventeen-minute round the clock travels 17.2 -> 22.6 hours, so a
	tick moves it by about 0.0005 hours — a hundredth of a degree of sun, well
	under EPSILON's ability to notice it is pointless, and a shadow rebuild every
	tenth of a second for the whole round.

	A hundredth of an hour is 0.15 degrees, which is far below what anyone can
	see in a single step and turns the rebuild into roughly one every twenty
	seconds. The ramp still lands on exactly the same value at the end; it just
	gets there in visible steps rather than invisible ones.
]]
local CLOCK_QUANTUM = 0.01

-- ── flash ───────────────────────────────────────────────────────────────────

local FLASH_MIN_DURATION = 0.04
local FLASH_MAX_DURATION = 2.0
local FLASH_MAX_INTENSITY = 4.0

-- What one unit of flash intensity is worth in each property. Bloom carries most
-- of it: raising Brightness alone washes the world flat, while bloom blowing out
-- around every light source is what a real close strike looks like.
local FLASH_TO_LIGHT = 1.15
local FLASH_TO_GRADE = 0.40
local FLASH_TO_BLOOM = 1.70

-- Resting bloom for the one we build ourselves. Streetlamps and neon are the only
-- light left by the finale, so they are allowed to bleed.
local BLOOM_BASE_INTENSITY = 0.9

-- ── distant lightning ───────────────────────────────────────────────────────

--[[ Long, irregular gaps. A storm on a metronome stops registering after the
     second strike; one you cannot predict keeps the sky alive for free. ]]
local STRIKE_MIN_GAP = 38
local STRIKE_MAX_GAP = 110
local STRIKE_DURATION = 0.16
local STRIKE_INTENSITY = 0.62
-- Real lightning almost never strikes once. The second, weaker flick is most of
-- what sells it.
local DOUBLE_STRIKE_CHANCE = 0.45
local DOUBLE_STRIKE_GAP = 0.11
local DOUBLE_STRIKE_SCALE = 0.7

-- ── the gutter, and the breath ──────────────────────────────────────────────

--[[
	A rare, brief FAILURE of the light. Not lightning — the opposite of it. A
	flash is a spike up and every horror game has one; this is a spike down, like
	a streetlamp losing its ballast for a second, and it is far more unpleasant,
	because the dark is where the thing you cannot see already is.

	It is deliberately not a smooth dip. Real failing light stutters: it drops,
	half-recovers, drops harder, then comes back reluctantly. The envelope below
	is that shape, and it is the whole difference between "a light went out" and
	"something is wrong with this place".

	Only once the sun is mostly gone. A streetlamp guttering at golden hour is not
	an event, it is a rendering artefact.
]]
local GUTTER_MIN_GAP = 55
local GUTTER_MAX_GAP = 150
local GUTTER_DURATION = 0.95
local GUTTER_DEPTH = 0.62 -- fraction of the light taken at the deepest point
local GUTTER_MIN_PROGRESS = 0.35

--[[ Sampled linearly across the event. 0 is full light, 1 is fully guttered. The
     asymmetry matters: the tail is longer than any of the drops, so the light
     comes back slowly rather than snapping on. ]]
local GUTTER_ENVELOPE = { 0.0, 0.85, 0.30, 1.0, 0.95, 0.55, 0.70, 0.25, 0.10, 0.0 }

--[[
	The fog is never quite still. Two sines at periods that do not divide into
	each other, so the pattern never repeats across a seventeen-minute round,
	moving the far plane by a few percent and the density by a hair.

	Every individual frame of this is below the threshold anybody could point at.
	That is exactly what it is for. A world that holds perfectly still reads as a
	photograph; one that moves slightly, for a reason you cannot name, reads as a
	place — and a place can have something in it.
]]
local BREATH_PERIOD_A = 37.0
local BREATH_PERIOD_B = 53.0
local BREATH_FOG_AMOUNT = 0.07 -- +/- fraction of the far plane
local BREATH_DENSITY_AMOUNT = 0.022

-- ── boss mood ───────────────────────────────────────────────────────────────

--[[ Slow in, slower out. The point is that the room is already wrong by the time
     you work out what changed; a snap would just read as a lighting bug. ]]
local BOSS_EASE_IN = 2.6
local BOSS_EASE_OUT = 4.5

--[[ What a Tank or the Witch does to the look, at full blend. Every number here
     is small on purpose — this is unease, not a filter. ]]
local BOSS = table.freeze({
	Brightness = 0.90, -- multiplier
	Ambient = 0.88, -- multiplier on both ambient terms
	Exposure = -0.06,
	FogEnd = 0.86, -- multiplier: the street closes in
	FogStart = 0.80,
	Density = 0.05,
	Haze = 0.55,
	Glare = -0.04,
	Saturation = -0.09,
	Contrast = 0.05,
	Tint = Color3.fromRGB(196, 213, 236), -- cold, slightly cyan
	TintBlend = 0.5,
})

--[[
	VISIBILITY — the one number to turn if the game is too dark or too bright.

	Everything below is tuned to be moody but FIGHTABLE: you should be able to
	pick a Common out of the gloom at the far end of a street and see a Tank
	coming with time to react. That readability floor beats atmosphere every
	time — a horror light you cannot shoot in is just a broken game.

	Raise this to brighten the whole ramp at once; lower it to make the night
	bite harder. 1.0 is the tuned default. It scales the light terms and opens
	the fog to match, so the look stays coherent instead of turning into a bright
	room seen through thick soup.

	  0.75  grim. You are relying on the map's own lamps.
	  1.00  tuned default.
	  1.35  comfortably readable everywhere; less atmospheric.
]]
local VISIBILITY = 1.0

--[[ How much of VISIBILITY each term takes. Fog opens more slowly than the light
     comes up, because a bright scene with the fog still at your feet reads as a
     bug rather than as weather. ]]
local VIS_AMBIENT = 1.0
local VIS_BRIGHTNESS = 0.75
local VIS_FOG = 0.55
local VIS_DENSITY = 0.7 -- inverted: more visibility means less atmosphere

-- ── keyframes ───────────────────────────────────────────────────────────────

--[[
	Five complete looks. `anchor` is the wave whose start the keyframe sits on;
	"start" and "end" are the ends of the round.

	The shape of the round in light: waves 1-4 are a long orange evening where you
	can still see a street. Wave 5 — the first Tank — puts the sun on the horizon.
	Wave 10 lands in blue hour, when everything is legible but nothing is
	coloured. By the finale the sun is gone, the fog is at its floor, and the only
	reason you can see anything at all is the map's own fixtures.

	── THESE ANCHORS ARE WAVE NUMBERS, AND THAT IS A TRAP ──────────────────────
	They were 3, 5 and 7 for a seven-wave round, which put them at 0.24, 0.51 and
	0.82 of the way through. When the schedule became fifteen waves the same three
	numbers landed at 0.11, 0.21 and 0.33 — the whole evening collapsed into the
	first third of the round and the remaining eleven minutes were one flat
	interpolation to black.

	Nothing failed. The guard below only catches keyframes that land out of ORDER,
	which these did not; they were merely all at the start. The round simply got
	dark early and then stopped changing, which is the arc this file exists to
	produce being quietly deleted by an edit in another file.

	5, 10 and 14 put them back at 0.21, 0.51 and 0.78. scripts/audit.py check 17
	fails the build if they ever bunch up again.
]]
local KEYFRAMES = {
	{
		anchor = "start",
		-- Low sun, long shadows down the street. The one keyframe that is warm,
		-- so that losing it later actually costs something.
		clock = 17.2,
		brightness = 2.35,
		exposure = 0.16,
		ambient = Color3.fromRGB(54, 50, 48),
		outdoor = Color3.fromRGB(132, 106, 84),
		fogColor = Color3.fromRGB(118, 92, 70),
		fogStart = 150,
		fogEnd = 1150,
		density = 0.20,
		haze = 1.05,
		glare = 0.50,
		atmColor = Color3.fromRGB(148, 116, 86),
		tint = Color3.fromRGB(255, 247, 236),
		contrast = 0.05,
		saturation = -0.02,
		envDiffuse = 0.55,
		envSpecular = 0.60,
	},
	{
		anchor = 5,
		-- Sun on the horizon. Colour is draining out of everything but the sky.
		clock = 18.05,
		brightness = 2.0,
		exposure = 0.22,
		ambient = Color3.fromRGB(48, 46, 50),
		outdoor = Color3.fromRGB(108, 90, 84),
		fogColor = Color3.fromRGB(88, 66, 58),
		fogStart = 128,
		fogEnd = 960,
		density = 0.23,
		haze = 1.3,
		glare = 0.32,
		atmColor = Color3.fromRGB(126, 92, 72),
		tint = Color3.fromRGB(252, 242, 236),
		contrast = 0.08,
		saturation = -0.07,
		envDiffuse = 0.50,
		envSpecular = 0.55,
	},
	{
		anchor = 10,
		--[[ Blue hour, turning. Shapes without colour is the most useful horror
		     light there is — a silhouette at 200 studs could be anything — and
		     from here the sky stops being merely blue and starts being WRONG:
		     the ambient picks up green against a fog that keeps the cold, which
		     is the split that makes skin look ill. ]]
		clock = 18.9,
		brightness = 1.5,
		exposure = 0.28,
		ambient = Color3.fromRGB(38, 44, 47),
		outdoor = Color3.fromRGB(70, 84, 96),
		fogColor = Color3.fromRGB(30, 38, 46),
		fogStart = 88,
		fogEnd = 660,
		density = 0.29,
		haze = 1.65,
		glare = 0.15,
		atmColor = Color3.fromRGB(42, 55, 66),
		tint = Color3.fromRGB(232, 243, 248),
		contrast = 0.14,
		saturation = -0.16,
		envDiffuse = 0.47,
		envSpecular = 0.50,
	},
	{
		anchor = 14,
		-- Night. The finale opens here, already dark, so wave 15 does not have to
		-- announce itself twice.
		clock = 20.4,
		brightness = 1.18,
		exposure = 0.36,
		ambient = Color3.fromRGB(29, 36, 37),
		outdoor = Color3.fromRGB(54, 68, 74),
		fogColor = Color3.fromRGB(16, 21, 24),
		fogStart = 68,
		fogEnd = 560,
		density = 0.34,
		haze = 1.95,
		glare = 0.06,
		atmColor = Color3.fromRGB(18, 26, 30),
		tint = Color3.fromRGB(219, 236, 238),
		contrast = 0.19,
		saturation = -0.24,
		envDiffuse = 0.40,
		envSpecular = 0.43,
	},
	{
		anchor = "end",
		--[[ Last Light. The fog is at its floor and the saturation is nearly gone:
		     what is left is a grey-green cast that makes every surface look
		     damp, and whatever you can still see, the map's own lamps are paying
		     for.

		     The contrast is the highest of any keyframe, which is what turns the
		     remaining light hard — a scene this dark with soft contrast reads as
		     underexposed, and one with hard contrast reads as a place lit by
		     something failing. ]]
		clock = 22.6,
		brightness = 1.02,
		exposure = 0.40,
		ambient = Color3.fromRGB(25, 32, 32),
		outdoor = Color3.fromRGB(45, 58, 61),
		fogColor = Color3.fromRGB(12, 16, 17),
		fogStart = 58,
		-- Just clear of MIN_FOG_END with room for the breath to swing under it.
		-- Authoring a number below that floor would look like a decision and
		-- behave like nothing, since resolve() would clamp it straight back.
		fogEnd = 500,
		density = 0.38,
		haze = 2.1,
		glare = 0.03,
		atmColor = Color3.fromRGB(11, 17, 18),
		tint = Color3.fromRGB(210, 231, 230),
		contrast = 0.22,
		saturation = -0.30,
		envDiffuse = 0.35,
		envSpecular = 0.40,
	},
}

--[[ Multiplies a colour's channels, clamped. Used by the visibility bias, which
     brightens the ambient terms without shifting their hue. ]]
local function scaleColor(color: Color3, factor: number): Color3
	return Color3.new(
		math.clamp(color.R * factor, 0, 1),
		math.clamp(color.G * factor, 0, 1),
		math.clamp(color.B * factor, 0, 1)
	)
end

local AtmosphereService = {}

local serviceTrove = Trove.new()
local random = Random.new()

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[AtmosphereService] " .. message)
end

--[[ Resolve each keyframe's position on the round clock from the wave schedule.
     Done once, at load, so the tick never touches GameModeConfig. ]]
do
	local previous = -1
	for _, key in KEYFRAMES do
		local seconds
		if key.anchor == "start" then
			seconds = 0
		elseif key.anchor == "end" then
			seconds = TOTAL_DURATION
		else
			seconds = GameModeConfig.getWaveStartTime(key.anchor)
		end

		local t = math.clamp(seconds / TOTAL_DURATION, 0, 1)
		-- A retuned wave schedule must never produce an out-of-order keyframe:
		-- the search below assumes ascending t, and a backwards one would make
		-- the light jump instead of fade.
		if t <= previous then
			t = math.min(previous + 1e-3, 1)
			warnOnce(
				"keyframeOrder",
				"the wave schedule put two lighting keyframes at the same point; nudging one forward"
			)
		end
		key.t = t
		previous = t
	end
end

-- ── state ───────────────────────────────────────────────────────────────────

local MODE = table.freeze({
	Idle = "Idle", -- no round yet: hold the opening keyframe
	Round = "Round", -- driving from round progress
	Static = "Static", -- no RoundService at all: hold the dark preset
	Restored = "Restored", -- round over, the user's own lighting is back
})

local mode = MODE.Idle
local progress = 0
local resolved = false
local bootAt = 0
local accumulator = 0

-- Instances we drive. `owned` is the subset this service created, and is the
-- only subset it is ever allowed to destroy.
local atmosphere: Atmosphere? = nil
local grade: ColorCorrectionEffect? = nil
local bloom: BloomEffect? = nil
local owned: { [Instance]: boolean } = {}

-- Everything read off the place before the first write, so a round end can put
-- it back exactly. Instance baselines are captured at adoption, not at boot,
-- because an instance we created has no baseline worth keeping.
local baseline: { [string]: any } = {}

local bossExplicit = false
local bossDetected = false
local bossBlend = 0

local flashActive = false
local flashStartedAt = 0
local flashDuration = 0
local flashIntensity = 0
local pendingStrikeAt = 0
local pendingStrikeIntensity = 0
local nextStrikeAt = 0

local gutterActive = false
local gutterStartedAt = 0
local nextGutterAt = 0

--[[ The resolved look, reused every tick. Rebuilding this table 10 times a
     second would be 10 tables a second of garbage for no reason. ]]
local target = {
	clock = 0,
	brightness = 0,
	exposure = 0,
	fogStart = 0,
	fogEnd = 0,
	density = 0,
	haze = 0,
	glare = 0,
	contrast = 0,
	saturation = 0,
	envDiffuse = 0,
	envSpecular = 0,
	ambient = Color3.new(),
	outdoor = Color3.new(),
	fogColor = Color3.new(),
	atmColor = Color3.new(),
	tint = Color3.new(),
}

-- Last value actually written, per property. See writeNumber.
local applied: { [string]: any } = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

--[[ Smoothstep the alpha inside each segment. With five keyframes over
     seventeen minutes a linear blend would change slope at every joint, and a
     slope change in a sky is the one thing the eye does catch. ]]
local function smooth(alpha: number): number
	return alpha * alpha * (3 - 2 * alpha)
end

--[[ Writes a number only when it actually changed. ClockTime and the fog band
     move every tick, but Ambient is the same Color3 for a minute at a time, and
     a redundant property write still costs a replication check on every client
     in the server. ]]
local function writeNumber(instance: Instance?, property: string, value: number, key: string)
	if not instance then
		return
	end
	local previous = applied[key]
	if previous ~= nil and math.abs(previous - value) < EPSILON then
		return
	end
	applied[key] = value
	local holder: any = instance
	holder[property] = value
end

local function writeColor(instance: Instance?, property: string, value: Color3, key: string)
	if not instance then
		return
	end
	if applied[key] == value then
		return
	end
	applied[key] = value
	local holder: any = instance
	holder[property] = value
end

-- ── instances ───────────────────────────────────────────────────────────────

--[[
	Finds the user's instance of a class, or builds one.

	Order matters: our own name first (so a second round adopts the one we made
	last round), then any instance of that class the user placed, then a new one.
	A pre-existing instance has its properties captured on the way past — that
	capture is the only thing that makes the round-end restore honest.
]]
local function adopt(className: string, name: string, capture: { string }, skipName: string?): Instance
	local existing = Lighting:FindFirstChild(name)
	if not (existing and existing:IsA(className)) then
		existing = nil
		for _, child in Lighting:GetChildren() do
			if child:IsA(className) and child.Name ~= skipName then
				existing = child
				break
			end
		end
	end

	if existing then
		if not owned[existing] and baseline[name] == nil then
			local captured: { [string]: any } = {}
			local holder: any = existing
			for _, property in capture do
				captured[property] = holder[property]
			end
			baseline[name] = captured
		end
		return existing
	end

	local created = Instance.new(className)
	created.Name = name
	created.Parent = Lighting
	owned[created] = true
	return created
end

local ATMOSPHERE_PROPS = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }
local GRADE_PROPS = { "Enabled", "Brightness", "Contrast", "Saturation", "TintColor" }
local BLOOM_PROPS = { "Enabled", "Intensity", "Size", "Threshold" }

function AtmosphereService:_ensureInstances()
	if atmosphere and atmosphere.Parent and grade and grade.Parent and bloom and bloom.Parent then
		return
	end

	if not (atmosphere and atmosphere.Parent) then
		atmosphere = adopt("Atmosphere", "FL_Atmosphere", ATMOSPHERE_PROPS) :: Atmosphere
	end

	if not (grade and grade.Parent) then
		-- FL_Overlay belongs to the client's OverlayController: it owns the incap
		-- desaturation and the damage tint. Two systems writing one grade is how
		-- a screen ends up black, so ours is always a separate effect.
		grade =
			adopt("ColorCorrectionEffect", "FL_AtmosphereGrade", GRADE_PROPS, "FL_Overlay") :: ColorCorrectionEffect
		grade.Enabled = true
	end

	if not (bloom and bloom.Parent) then
		bloom = adopt("BloomEffect", "FL_AtmosphereBloom", BLOOM_PROPS) :: BloomEffect
		bloom.Enabled = true
		if owned[bloom] then
			-- Only tuned when it is ours. A bloom the user placed is a look they
			-- chose; we borrow its Intensity for flashes and give it back.
			bloom.Size = 24
			bloom.Threshold = 1.1
		end
	end

	-- Anything adopted may have been mid-value when we found it, so the change
	-- detector has to forget what it thinks is on screen.
	table.clear(applied)
end

--[[ Puts the place back the way the user built it. Their instances get their
     captured properties; ours — which did not exist before this round — are
     destroyed. This is the only place that destroys anything. ]]
function AtmosphereService:_restore()
	for _, entry in
		{
			{ instance = atmosphere, key = "FL_Atmosphere" },
			{ instance = grade, key = "FL_AtmosphereGrade" },
			{ instance = bloom, key = "FL_AtmosphereBloom" },
		}
	do
		local instance = entry.instance
		if not instance then
			continue
		end
		if owned[instance] then
			owned[instance] = nil
			instance:Destroy()
		else
			local captured = baseline[entry.key]
			if captured then
				local holder: any = instance
				for property, value in captured do
					holder[property] = value
				end
			end
		end
	end

	atmosphere, grade, bloom = nil, nil, nil

	local lightingBaseline = baseline.Lighting
	if lightingBaseline then
		for property, value in lightingBaseline do
			local holder: any = Lighting
			holder[property] = value
		end
	end

	table.clear(applied)
	resolved = false
	flashActive = false
	gutterActive = false
	pendingStrikeAt = 0
	bossBlend = 0
	mode = MODE.Restored
end

-- ── the look ────────────────────────────────────────────────────────────────

--[[ Resolves `progress` into `target`: one alpha, one pair of keyframes, every
     property moving together. Boss mood is folded in here rather than applied
     afterwards for the same reason — it has to arrive as one look, not as six
     properties drifting apart. ]]
local function resolve()
	local from = KEYFRAMES[1]
	local to = KEYFRAMES[#KEYFRAMES]
	for index = 1, #KEYFRAMES - 1 do
		if progress <= KEYFRAMES[index + 1].t then
			from = KEYFRAMES[index]
			to = KEYFRAMES[index + 1]
			break
		end
	end

	local span = to.t - from.t
	local alpha = span > 0 and smooth(math.clamp((progress - from.t) / span, 0, 1)) or 1

	target.clock = lerp(from.clock, to.clock, alpha)
	target.brightness = lerp(from.brightness, to.brightness, alpha)
	target.exposure = lerp(from.exposure, to.exposure, alpha)
	target.fogStart = lerp(from.fogStart, to.fogStart, alpha)
	target.fogEnd = lerp(from.fogEnd, to.fogEnd, alpha)
	target.density = lerp(from.density, to.density, alpha)
	target.haze = lerp(from.haze, to.haze, alpha)
	target.glare = lerp(from.glare, to.glare, alpha)
	target.contrast = lerp(from.contrast, to.contrast, alpha)
	target.saturation = lerp(from.saturation, to.saturation, alpha)
	target.envDiffuse = lerp(from.envDiffuse, to.envDiffuse, alpha)
	target.envSpecular = lerp(from.envSpecular, to.envSpecular, alpha)
	target.ambient = from.ambient:Lerp(to.ambient, alpha)
	target.outdoor = from.outdoor:Lerp(to.outdoor, alpha)
	target.fogColor = from.fogColor:Lerp(to.fogColor, alpha)
	target.atmColor = from.atmColor:Lerp(to.atmColor, alpha)
	target.tint = from.tint:Lerp(to.tint, alpha)

	if bossBlend > 0 then
		local blend = bossBlend
		target.brightness *= lerp(1, BOSS.Brightness, blend)
		target.exposure += BOSS.Exposure * blend
		target.fogStart *= lerp(1, BOSS.FogStart, blend)
		target.fogEnd *= lerp(1, BOSS.FogEnd, blend)
		target.density += BOSS.Density * blend
		target.haze += BOSS.Haze * blend
		target.glare += BOSS.Glare * blend
		target.saturation += BOSS.Saturation * blend
		target.contrast += BOSS.Contrast * blend
		target.ambient = target.ambient:Lerp(Color3.new(), (1 - BOSS.Ambient) * blend)
		target.outdoor = target.outdoor:Lerp(Color3.new(), (1 - BOSS.Ambient) * blend)
		target.tint = target.tint:Lerp(BOSS.Tint, BOSS.TintBlend * blend)
	end

	--[[ The visibility bias, applied after the mood so a boss still darkens the
	     scene by the same proportion at any setting. Ambient does the heavy
	     lifting: it is the term that decides whether an unlit doorway contains
	     information or a hole. ]]
	if VISIBILITY ~= 1 then
		local light = 1 + (VISIBILITY - 1) * VIS_BRIGHTNESS
		local amb = 1 + (VISIBILITY - 1) * VIS_AMBIENT
		local fog = 1 + (VISIBILITY - 1) * VIS_FOG
		local thin = 1 - (VISIBILITY - 1) * VIS_DENSITY

		target.brightness *= light
		target.ambient = scaleColor(target.ambient, amb)
		target.outdoor = scaleColor(target.outdoor, amb)
		target.fogEnd *= fog
		target.fogStart *= fog
		target.density *= math.max(thin, 0)
		target.haze *= math.max(thin, 0)
	end

	-- Clamps last, so no combination of keyframe and mood can push a property
	-- somewhere the engine or the fight cannot use.
	target.fogEnd = math.max(target.fogEnd, MIN_FOG_END)
	target.fogStart = math.clamp(target.fogStart, 0, target.fogEnd - 1)
	target.density = math.clamp(target.density, 0, 1)
	target.haze = math.clamp(target.haze, 0, 10)
	target.glare = math.clamp(target.glare, 0, 10)
	target.saturation = math.clamp(target.saturation, -1, 1)
	target.contrast = math.clamp(target.contrast, -1, 1)
	resolved = true
end

--[[ Writes the resolved look, plus whatever the current flash is worth. The
     flash is added on top of `target` rather than stored anywhere, which is what
     lets a pulse end by writing the correctly interpolated value back instead of
     a value somebody hardcoded when they wrote the explosion code. ]]
local function commit(flash: number, gutter: number, breath: number)
	if not resolved then
		return
	end

	--[[ The gutter is MULTIPLICATIVE where the flash is additive, and that is not
	     a detail. Adding a negative would push a dark keyframe's brightness
	     through zero and out the other side; taking a fraction of whatever the
	     light happens to be right now means the same event costs the same
	     PROPORTION of the scene at golden hour and at midnight. ]]
	local dim = 1 - gutter * GUTTER_DEPTH

	--[[ The far plane, breathing. Applied here rather than in resolve() so the
	     keyframe interpolation stays a pure function of round progress — this is
	     presentation on top of it, and anything reading `target` still reads the
	     honest value.

	     MIN_FOG_END is re-applied because resolve()'s clamp is upstream of this:
	     without it the breath's downward swing could close the fog inside the
	     band the Director spawns in, and infected would pop into existence in
	     front of the players a few times a minute for no visible reason. ]]
	local fogEnd = target.fogEnd * (1 + breath * BREATH_FOG_AMOUNT)
	fogEnd = math.max(fogEnd, MIN_FOG_END, target.fogStart + 1)

	--[[ Quantised, not epsilon-gated: see CLOCK_QUANTUM. Rounded rather than
	     floored so the ramp cannot drift behind its own schedule. ]]
	local clock = math.floor(target.clock / CLOCK_QUANTUM + 0.5) * CLOCK_QUANTUM
	writeNumber(Lighting, "ClockTime", clock, "clock")
	writeNumber(Lighting, "Brightness", (target.brightness + flash * FLASH_TO_LIGHT) * dim, "brightness")
	writeNumber(Lighting, "ExposureCompensation", target.exposure, "exposure")
	writeNumber(Lighting, "FogStart", target.fogStart, "fogStart")
	writeNumber(Lighting, "FogEnd", fogEnd, "fogEnd")
	writeNumber(Lighting, "EnvironmentDiffuseScale", target.envDiffuse * dim, "envDiffuse")
	writeNumber(Lighting, "EnvironmentSpecularScale", target.envSpecular, "envSpecular")
	writeColor(
		Lighting,
		"Ambient",
		target.ambient:Lerp(Color3.new(0, 0, 0), gutter * GUTTER_DEPTH),
		"ambient"
	)
	writeColor(
		Lighting,
		"OutdoorAmbient",
		target.outdoor:Lerp(Color3.new(0, 0, 0), gutter * GUTTER_DEPTH),
		"outdoor"
	)
	writeColor(Lighting, "FogColor", target.fogColor, "fogColor")

	writeNumber(atmosphere, "Density", target.density + breath * BREATH_DENSITY_AMOUNT, "density")
	writeNumber(atmosphere, "Haze", target.haze, "haze")
	writeNumber(atmosphere, "Glare", target.glare, "glare")
	writeColor(atmosphere, "Color", target.atmColor, "atmColor")

	-- ColorCorrection.Brightness saturates at 1; past that a big flash only costs
	-- replication and buys no extra light.
	writeNumber(grade, "Brightness", math.min(flash * FLASH_TO_GRADE, 1), "gradeBrightness")
	writeNumber(grade, "Contrast", target.contrast, "gradeContrast")
	writeNumber(grade, "Saturation", target.saturation, "gradeSaturation")
	writeColor(grade, "TintColor", target.tint, "gradeTint")

	if bloom then
		-- A bloom the user placed keeps the intensity they chose as its floor; the
		-- flash is only ever added on top of it.
		local captured = baseline.FL_AtmosphereBloom
		local base = (not owned[bloom] and captured and captured.Intensity) or BLOOM_BASE_INTENSITY
		writeNumber(bloom, "Intensity", base + flash * FLASH_TO_BLOOM, "bloomIntensity")
	end
end

--[[ How much flash is live right now, and clears the pulse on the frame it ends
     so that frame's commit puts the interpolated values back. ]]
local function flashAmount(now: number): number
	if not flashActive then
		return 0
	end
	local u = (now - flashStartedAt) / flashDuration
	if u >= 1 then
		flashActive = false
		return 0
	end
	-- Instant attack, quadratic decay: a strike is a hard edge followed by a
	-- fall-off, and a symmetrical fade reads as a fluorescent tube, not lightning.
	local fade = 1 - u
	return flashIntensity * fade * fade
end

local function driving(): boolean
	return mode ~= MODE.Restored
end

-- ════════════════════════════════════════════════════════════════════════════
--  Public API
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Sets how far through the round the light is. RoundService is the source of
	truth and the tick reads it directly, so calling this by hand sets the phase
	only until the next tick asks the round again — which is what you want, and
	the reason a cutscene or a test can drive the sky without fighting anything.

	Applied on the next tick rather than immediately, so a caller in a loop cannot
	turn this into a per-frame property write.
]]
function AtmosphereService:setPhaseFromRound(elapsed: number, total: number)
	if typeof(elapsed) ~= "number" or typeof(total) ~= "number" then
		warnOnce("phaseArgs", "setPhaseFromRound wants two numbers; ignoring the call")
		return
	end
	if total <= 0 or elapsed ~= elapsed or total ~= total then
		return
	end

	--[[
		DARKNESS starts the round further down its own ramp.

		The floor is a REMAP, not a clamp: the round still travels from the floor
		to full night across the same seventeen minutes rather than sitting at one
		look for all of them. That matters more than it sounds — the whole reason
		this file exists is that losing the light gradually is frightening and
		being handed a dark room is merely dark, and a modifier that flattened the
		curve would delete the thing it is named after about four minutes in.

		At 0.66 the round opens at roughly the look wave ten usually has, and the
		finale is darker than any unmodified round ever gets.
	]]
	local raw = math.clamp(elapsed / total, 0, 1)
	local floor = math.clamp(ModifierConfig.atmosphereFloor(Workspace), 0, 0.95)
	progress = floor + raw * (1 - floor)
	mode = MODE.Round
end

--[[
	A brief bright pulse: explosions, lightning, anything that should light the
	street for a moment. Non-blocking, allocates nothing, and never fights the
	round interpolation — see commit().

	A live pulse is only replaced by one that is brighter or that lasts longer.
	Two grenades half a second apart must not leave the second one dimming the
	first.
]]
function AtmosphereService:flash(duration: number, intensity: number)
	if not driving() then
		return
	end
	if typeof(duration) ~= "number" or typeof(intensity) ~= "number" then
		warnOnce("flashArgs", "flash wants (duration, intensity) as numbers; ignoring the call")
		return
	end

	-- NaN survives math.clamp and a NaN on a Lighting property is an engine error,
	-- not a dim flash. Callers compute these from explosion maths; check here.
	if duration ~= duration or intensity ~= intensity then
		return
	end

	duration = math.clamp(duration, FLASH_MIN_DURATION, FLASH_MAX_DURATION)
	intensity = math.clamp(intensity, 0, FLASH_MAX_INTENSITY)
	if intensity <= 0 then
		return
	end

	local now = os.clock()
	if flashActive then
		local endsAt = flashStartedAt + flashDuration
		if intensity <= flashIntensity and now + duration <= endsAt then
			return
		end
	end

	flashActive = true
	flashStartedAt = now
	flashDuration = duration
	flashIntensity = intensity
end

--[[
	Pushes the grade colder and darker and tightens the fog while a Tank or the
	Witch is up. This is an OVERRIDE, not the only input: the tick also watches
	FL_TankActive and the live Witch count, so the mood lands whether or not the
	boss code remembers to call anything. Either source holding it true holds it
	true — a caller that turns it on for a scripted moment is not undone by the
	Director having no boss alive.
]]
function AtmosphereService:setBossMood(active: boolean)
	bossExplicit = active == true
end

-- ════════════════════════════════════════════════════════════════════════════
--  Internals
-- ════════════════════════════════════════════════════════════════════════════

local function scheduleStrike(now: number)
	nextStrikeAt = now + random:NextNumber(STRIKE_MIN_GAP, STRIKE_MAX_GAP)
end

local function scheduleGutter(now: number)
	nextGutterAt = now + random:NextNumber(GUTTER_MIN_GAP, GUTTER_MAX_GAP)
end

--[[ How much light the gutter is currently taking, 0-1. Linear interpolation
     between the envelope's points, and it clears itself on the frame it finishes
     so that frame's commit writes the un-dimmed value back. ]]
local function gutterAmount(now: number): number
	if not gutterActive then
		return 0
	end
	local u = (now - gutterStartedAt) / GUTTER_DURATION
	if u >= 1 or u < 0 then
		gutterActive = false
		return 0
	end

	local last = #GUTTER_ENVELOPE
	local scaled = u * (last - 1) + 1
	local index = math.floor(scaled)
	local nextIndex = math.min(index + 1, last)
	local blend = scaled - index
	return GUTTER_ENVELOPE[index] + (GUTTER_ENVELOPE[nextIndex] - GUTTER_ENVELOPE[index]) * blend
end

--[[ The slow, unnameable movement in the fog. Returns a signed -1..1; both terms
     are sampled from the same clock every client shares, so nobody sees the fog
     breathing out of step with anybody else. ]]
local function breathAmount(now: number): number
	local a = math.sin(now * (math.pi * 2) / BREATH_PERIOD_A)
	local b = math.sin(now * (math.pi * 2) / BREATH_PERIOD_B)
	return (a * 0.6 + b * 0.4)
end

--[[ True while something the players are supposed to be frightened of is alive.
     Read from the attribute InfectedService already maintains rather than from a
     signal, so this service holds no boss state of its own to get stale. ]]
--[[ The addendum's contract only promises RoundService:getState(); the current
     implementation also has isRunning(). Ask for the convenience method and fall
     back to the contracted one, so a rewrite of that service on either side of
     the contract still leaves the sky moving. ]]
local function isRoundRunning(round: any): boolean
	if typeof(round.isRunning) == "function" then
		return round:isRunning() == true
	end
	if typeof(round.getState) == "function" then
		local state = round:getState()
		return state == Enums.RoundState.InProgress or state == Enums.RoundState.Starting
	end
	return false
end

local function detectBoss(): boolean
	if Workspace:GetAttribute(Attributes.Game.TankActive) == true then
		return true
	end
	local infected = Registry.find("InfectedService")
	if infected and typeof(infected.getCount) == "function" then
		return infected:getCount(Enums.Infected.Witch) > 0
	end
	return false
end

function AtmosphereService:_step(now: number)
	local round = Registry.find("RoundService")
	if round then
		if isRoundRunning(round) then
			local elapsed = typeof(round.getElapsed) == "function" and round:getElapsed() or 0
			self:setPhaseFromRound(elapsed, TOTAL_DURATION)
		elseif mode == MODE.Round then
			-- The round is over. Hand the place back exactly as we found it and
			-- stop writing; the next round starts the whole arc again at dusk.
			self:_restore()
			return
		end
	elseif mode == MODE.Idle and now - bootAt >= BOOT_GRACE then
		mode = MODE.Static
		progress = STATIC_PROGRESS
		warnOnce(
			"noRound",
			"no RoundService is registered, so the sky cannot tell the time. "
				.. "Holding the static dark preset."
		)
	end

	if not driving() then
		return
	end

	self:_ensureInstances()

	bossDetected = detectBoss()
	local moodTarget = (bossExplicit or bossDetected) and 1 or 0
	if bossBlend ~= moodTarget then
		local rate = TICK_INTERVAL / (moodTarget > bossBlend and BOSS_EASE_IN or BOSS_EASE_OUT)
		bossBlend = math.clamp(bossBlend + math.clamp(moodTarget - bossBlend, -rate, rate), 0, 1)
	end

	if now >= nextStrikeAt then
		scheduleStrike(now)
		-- Weaker while there is still a sky to compete with; at dusk a full
		-- strike just looks like the sun stuttering.
		local scale = 0.35 + 0.65 * progress
		self:flash(STRIKE_DURATION, STRIKE_INTENSITY * scale)
		if random:NextNumber() < DOUBLE_STRIKE_CHANCE then
			pendingStrikeAt = now + DOUBLE_STRIKE_GAP
			pendingStrikeIntensity = STRIKE_INTENSITY * scale * DOUBLE_STRIKE_SCALE
		end
	end

	--[[ Never while a strike is live. Two events on top of each other read as one
	     confused flicker and each robs the other of the thing that makes it
	     work — a flash needs dark around it and a gutter needs light to take. ]]
	if now >= nextGutterAt then
		scheduleGutter(now)
		if progress >= GUTTER_MIN_PROGRESS and not flashActive and not gutterActive then
			gutterActive = true
			gutterStartedAt = now
		end
	end

	resolve()
	commit(flashAmount(now), gutterAmount(now), breathAmount(now))
end

-- ════════════════════════════════════════════════════════════════════════════
--  Boot
-- ════════════════════════════════════════════════════════════════════════════

function AtmosphereService:init()
	--[[ Captured before anything is written. The project file's Lighting block is
	     the user's authored baseline, and a round end owes it back to them. ]]
	baseline.Lighting = {
		ClockTime = Lighting.ClockTime,
		Brightness = Lighting.Brightness,
		ExposureCompensation = Lighting.ExposureCompensation,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogColor = Lighting.FogColor,
		FogStart = Lighting.FogStart,
		FogEnd = Lighting.FogEnd,
		EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
		EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
	}
end

function AtmosphereService:start()
	bootAt = os.clock()
	scheduleStrike(bootAt)
	--[[ Scheduled at boot, or nextGutterAt sits at zero and the very first tick
	     fires one — a light failing in the lobby before anybody has moved. ]]
	scheduleGutter(bootAt)

	-- The lobby sits at the opening keyframe rather than at the place's own
	-- lighting, so the moment the round starts the sun is already where the first
	-- second of it expects — the light falls, it never cuts.
	self:_ensureInstances()
	resolve()
	commit(0, 0, 0)

	--[[ THE loop. One connection for the whole system. The keyframe pass is
	     throttled to TICK_INTERVAL because nothing in a sky changes usefully
	     inside a tenth of a second; only a flash, which is three number writes and
	     no allocation, is allowed to run at frame rate. ]]
	serviceTrove:connect(RunService.Heartbeat, function(delta)
		local now = os.clock()

		-- The second half of a double strike. Checked here rather than with
		-- task.delay so the storm costs no threads.
		if pendingStrikeAt > 0 and now >= pendingStrikeAt then
			pendingStrikeAt = 0
			self:flash(STRIKE_DURATION * 0.8, pendingStrikeIntensity)
		end

		--[[ Both pulses run at frame rate, not at TICK_INTERVAL. A flash is 160ms
		     and a gutter is under a second; sampled ten times a second, the
		     gutter's stutter would land on nine frames and read as the renderer
		     hitching rather than as a light failing. The cost is a handful of
		     number writes on the frames where something is actually happening,
		     and nothing at all the rest of the time. ]]
		if flashActive or gutterActive then
			local flash = flashAmount(now)
			local gutter = gutterAmount(now)
			if driving() then
				commit(flash, gutter, breathAmount(now))
			end
		end

		accumulator += delta
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		self:_step(now)
	end)
end

function AtmosphereService:destroy()
	serviceTrove:destroy()
	if driving() then
		self:_restore()
	end
end

Registry.register("AtmosphereService", AtmosphereService)

return AtmosphereService
