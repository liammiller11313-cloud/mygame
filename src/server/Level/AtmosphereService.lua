--!nonstrict
--[[
	AtmosphereService — the round clock, written on the sky.

	The game is called Fading Light. This is the file where that stops being a
	title.

	── THE SKY IS THE TIMER ────────────────────────────────────────────────────
	The round opens under a low orange sun and is pitch dark by wave 7, and the
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
local MIN_FOG_END = DirectorConfig.Spawning.MaxDistanceFromSurvivor * 1.35

-- Property writes below this delta are skipped; smaller than any of these
-- properties can express on screen.
local EPSILON = 1e-4

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
-- light left by wave 7, so they are allowed to bleed.
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

-- ── boss mood ───────────────────────────────────────────────────────────────

--[[ Slow in, slower out. The point is that the room is already wrong by the time
     you work out what changed; a snap would just read as a lighting bug. ]]
local BOSS_EASE_IN = 2.6
local BOSS_EASE_OUT = 4.5

--[[ What a Tank or the Witch does to the look, at full blend. Every number here
     is small on purpose — this is unease, not a filter. ]]
local BOSS = table.freeze({
	Brightness = 0.86, -- multiplier
	Ambient = 0.82, -- multiplier on both ambient terms
	Exposure = -0.06,
	FogEnd = 0.78, -- multiplier: the street closes in
	FogStart = 0.80,
	Density = 0.05,
	Haze = 0.55,
	Glare = -0.04,
	Saturation = -0.09,
	Contrast = 0.05,
	Tint = Color3.fromRGB(196, 213, 236), -- cold, slightly cyan
	TintBlend = 0.5,
})

-- ── keyframes ───────────────────────────────────────────────────────────────

--[[
	Five complete looks. `anchor` is the wave whose start the keyframe sits on;
	"start" and "end" are the ends of the round.

	The shape of the round in light: waves 1-2 are a long orange evening where you
	can still see a street. Wave 3 puts the sun on the horizon. Wave 5 — the Witch
	— lands in blue hour, when everything is legible but nothing is coloured. By
	wave 7 the sun is gone, the fog is at its floor, and the only reason you can
	see anything at all is the map's own fixtures.
]]
local KEYFRAMES = {
	{
		anchor = "start",
		-- Low sun, long shadows down the street. The one keyframe that is warm,
		-- so that losing it later actually costs something.
		clock = 17.2,
		brightness = 2.1,
		exposure = 0.12,
		ambient = Color3.fromRGB(30, 27, 26),
		outdoor = Color3.fromRGB(104, 78, 58),
		fogColor = Color3.fromRGB(112, 84, 62),
		fogStart = 95,
		fogEnd = 880,
		density = 0.30,
		haze = 1.5,
		glare = 0.50,
		atmColor = Color3.fromRGB(148, 116, 86),
		tint = Color3.fromRGB(255, 247, 236),
		contrast = 0.05,
		saturation = -0.02,
		envDiffuse = 0.55,
		envSpecular = 0.60,
	},
	{
		anchor = 3,
		-- Sun on the horizon. Colour is draining out of everything but the sky.
		clock = 18.05,
		brightness = 1.65,
		exposure = 0.18,
		ambient = Color3.fromRGB(24, 22, 25),
		outdoor = Color3.fromRGB(74, 58, 54),
		fogColor = Color3.fromRGB(80, 56, 48),
		fogStart = 72,
		fogEnd = 680,
		density = 0.34,
		haze = 1.9,
		glare = 0.32,
		atmColor = Color3.fromRGB(126, 92, 72),
		tint = Color3.fromRGB(252, 242, 236),
		contrast = 0.08,
		saturation = -0.07,
		envDiffuse = 0.50,
		envSpecular = 0.55,
	},
	{
		anchor = 5,
		-- Blue hour. Shapes without colour: the most useful horror light there
		-- is, because a silhouette at 200 studs could be anything.
		clock = 18.9,
		brightness = 1.05,
		exposure = 0.24,
		ambient = Color3.fromRGB(13, 14, 20),
		outdoor = Color3.fromRGB(33, 38, 52),
		fogColor = Color3.fromRGB(26, 30, 41),
		fogStart = 52,
		fogEnd = 470,
		density = 0.39,
		haze = 2.3,
		glare = 0.18,
		atmColor = Color3.fromRGB(46, 56, 74),
		tint = Color3.fromRGB(236, 242, 255),
		contrast = 0.12,
		saturation = -0.13,
		envDiffuse = 0.40,
		envSpecular = 0.45,
	},
	{
		anchor = 7,
		-- Night. The finale opens here, already dark, so wave 7 does not have to
		-- announce itself twice.
		clock = 20.4,
		brightness = 0.62,
		exposure = 0.30,
		ambient = Color3.fromRGB(7, 8, 12),
		outdoor = Color3.fromRGB(18, 21, 30),
		fogColor = Color3.fromRGB(12, 14, 20),
		fogStart = 34,
		fogEnd = 340,
		density = 0.44,
		haze = 2.7,
		glare = 0.08,
		atmColor = Color3.fromRGB(22, 28, 40),
		tint = Color3.fromRGB(224, 234, 255),
		contrast = 0.15,
		saturation = -0.20,
		envDiffuse = 0.30,
		envSpecular = 0.38,
	},
	{
		anchor = "end",
		-- Last Light. Darker and colder than the project file's baseline in every
		-- term, with the fog at its floor. Whatever you can see here, the map's
		-- own lamps are paying for.
		clock = 22.6,
		brightness = 0.45,
		exposure = 0.32,
		ambient = Color3.fromRGB(4, 5, 8),
		outdoor = Color3.fromRGB(12, 14, 21),
		fogColor = Color3.fromRGB(7, 8, 12),
		fogStart = 24,
		fogEnd = 300,
		density = 0.48,
		haze = 3.0,
		glare = 0.04,
		atmColor = Color3.fromRGB(14, 18, 28),
		tint = Color3.fromRGB(214, 228, 255),
		contrast = 0.18,
		saturation = -0.25,
		envDiffuse = 0.24,
		envSpecular = 0.32,
	},
}

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
local function commit(flash: number)
	if not resolved then
		return
	end

	writeNumber(Lighting, "ClockTime", target.clock, "clock")
	writeNumber(Lighting, "Brightness", target.brightness + flash * FLASH_TO_LIGHT, "brightness")
	writeNumber(Lighting, "ExposureCompensation", target.exposure, "exposure")
	writeNumber(Lighting, "FogStart", target.fogStart, "fogStart")
	writeNumber(Lighting, "FogEnd", target.fogEnd, "fogEnd")
	writeNumber(Lighting, "EnvironmentDiffuseScale", target.envDiffuse, "envDiffuse")
	writeNumber(Lighting, "EnvironmentSpecularScale", target.envSpecular, "envSpecular")
	writeColor(Lighting, "Ambient", target.ambient, "ambient")
	writeColor(Lighting, "OutdoorAmbient", target.outdoor, "outdoor")
	writeColor(Lighting, "FogColor", target.fogColor, "fogColor")

	writeNumber(atmosphere, "Density", target.density, "density")
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

	progress = math.clamp(elapsed / total, 0, 1)
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

	resolve()
	commit(flashAmount(now))
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

	-- The lobby sits at the opening keyframe rather than at the place's own
	-- lighting, so the moment the round starts the sun is already where the first
	-- second of it expects — the light falls, it never cuts.
	self:_ensureInstances()
	resolve()
	commit(0)

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

		if flashActive then
			local amount = flashAmount(now)
			if driving() then
				commit(amount)
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
