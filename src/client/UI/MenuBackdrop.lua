--!nonstrict
--[[
	MenuBackdrop — a bare bulb behind the main menu, and it will not hold steady.

	The menu used to be black. That is a defensible choice and it is the wrong
	one for a game called Fading Light: the one picture the front of the game can
	afford to carry should BE the title, and a filament that keeps almost going
	out is the whole premise in one image.

	── NOTHING HERE EDITS THE PICTURE ──────────────────────────────────────────
	The asset is a clean photograph and stays one. Everything that makes it look
	like this game is stacked on top — see UITheme.Backdrop:

	    tint      multiplied into the image, pulling it into the interface's
	              orange and taking most of its brightness away
	    dim       a black sheet heavy enough that white headline type stays
	              readable over it, and the thing the flicker actually drives
	    vignette  four edge gradients; the corners double up, which is what a
	              vignette wants anyway
	    drift     the image is oversized and never stops moving

	That split is the point. A grade written into the upload is a grade nobody
	can change without re-exporting; a grade written here is four numbers in a
	config next to every other number about how this game looks.

	── THE FLICKER ─────────────────────────────────────────────────────────────
	One number, `level`, from 0 to 1, built from three things that do not agree
	with each other:

	  * a slow breath — two sines on deliberately non-harmonic periods, so the
	    bulb is never quite still and never repeats
	  * a STUTTER — every few seconds, a fast burst of on-off over a fraction of
	    a second. This is the one that reads as a failing bulb rather than a
	    dimmer, because real filaments do not fade, they interrupt
	  * a BROWN-OUT — rarely, a slow sag most of the way down and a slower
	    recovery, which is what makes the stutters feel like symptoms

	Level drives the tint AND the scrim, and it has to be both. Dimming the image
	alone looks like a picture being faded; darkening the sheet over it as well
	makes the whole room go with the bulb, which is what a room lit by one bulb
	actually does.

	It never reaches zero. A backdrop that goes fully black reads as the game
	having crashed, and the interesting thing about a dying filament is that it
	does not quite let go.

	── AND IT SAYS SO WHEN THE PICTURE DOES NOT ARRIVE ─────────────────────────
	If the asset fails to fetch, this degrades to a black menu that looks
	deliberate, which is the worst possible way for it to fail. The id goes
	through ImageCheck, which fetches it once and warns by name.

	── AND IT ONLY RUNS WHILE IT IS ON SCREEN ──────────────────────────────────
	setActive is driven from the menu's own visibility. A RenderStepped
	connection behind a hidden frame is a frame of work per frame for something
	nobody is looking at, and the menu is hidden for the whole seventeen minutes
	of a round.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ImageCheck = require(script.Parent.ImageCheck)
local Widgets = require(script.Parent.Widgets)

local BACKDROP = UITheme.Backdrop
local COLOR = UITheme.Color

--[[ How long between stutters, and how long one lasts. The gap is wide because
     a bulb that fails on a rhythm is a metronome: the whole effect depends on
     not being able to predict the next one. ]]
local STUTTER_GAP_MIN = 3.5
local STUTTER_GAP_MAX = 12.0
local STUTTER_MIN = 0.10
local STUTTER_MAX = 0.42

--[[ How fast a stutter chops, in on-off decisions a second. Fast enough to read
     as electrical rather than as animation. ]]
local STUTTER_HZ = 22

-- And the rarer, slower sag. See the header.
local BROWNOUT_GAP_MIN = 24.0
local BROWNOUT_GAP_MAX = 62.0
local BROWNOUT_FALL = 0.55
local BROWNOUT_HOLD = 0.45
local BROWNOUT_RISE = 1.6
local BROWNOUT_FLOOR = 0.22

--[[ The breath. Two sines whose periods share no small common multiple, so the
     pair never lines back up inside a session anybody will sit through. ]]
local BREATH_SLOW = 6.7
local BREATH_FAST = 2.3
local BREATH_DEPTH = 0.07

-- A level change smaller than this is not worth a property write.
local EPSILON = 0.004

local MenuBackdrop = {}

local trove = Trove.new()
local runTrove = Trove.new()
local random = Random.new()

local root: Frame
local image: ImageLabel
local dim: Frame

local state = {
	attached = false,
	active = false,
	clock = 0,
	level = 1,
	drawn = -1,

	nextStutterAt = 0,
	stutterUntil = 0,

	nextBrownoutAt = 0,
	brownoutAt = 0,
}

-- ── build ───────────────────────────────────────────────────────────────────

local function newFrame(parent: Instance, name: string, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = parent
	return frame
end

--[[
	One side of the vignette: black at the edge, gone by `extent` inward.

	Four frames rather than one radial texture, because a radial vignette is an
	image and an image is a second asset to upload, keep and get wrong. The
	corners end up darkened twice, which is exactly the falloff a real vignette
	has anyway.
]]
local function vignette(parent: Instance, name: string, rotation: number, size: UDim2, position: UDim2)
	local frame = newFrame(parent, name, Color3.new(), BACKDROP.VignetteStrength)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Size = size
	frame.Position = position

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	--[[ Transparency runs edge-to-inward: fully opaque black where it meets the
	     screen edge, gone at the inner lip. The COLOUR stays black throughout;
	     fading a black gradient by colour would grey it. ]]
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
end

--[[ Builds under `parent`. Called once, from the menu's own build(), BEFORE the
     menu's content layer exists — with ZIndexBehavior.Sibling, equal-ZIndex
     siblings draw in creation order, so being built first is the whole of what
     puts this behind the interface. ]]
function MenuBackdrop:attach(parent: Instance)
	if state.attached or typeof(parent) ~= "Instance" then
		return
	end
	state.attached = true

	root = newFrame(parent, "Backdrop", COLOR.Background, 0)
	root.ClipsDescendants = true
	trove:add(root)

	image = Instance.new("ImageLabel")
	image.Name = "Bulb"
	image.BackgroundTransparency = 1
	image.BorderSizePixel = 0
	image.Image = BACKDROP.Image
	image.ImageColor3 = BACKDROP.Tint
	--[[ Crop, so the photograph fills any shape of screen without being
	     stretched. A stretched bulb is the one thing that would make this look
	     cheap on an ultrawide. ]]
	image.ScaleType = Enum.ScaleType.Crop
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.Size = UDim2.fromScale(BACKDROP.Overscan, BACKDROP.Overscan)
	image.Parent = root

	--[[ The same grime gradient every panel in the game wears, so the backdrop
	     belongs to the interface rather than sitting behind it as a photograph.
	     On an ImageLabel a UIGradient modulates the image's own alpha, so what it
	     actually does here is let the bottom of the frame fall away — the light
	     not reaching the floor, which is the one thing a picture of a bulb should
	     be doing. ]]
	Widgets.grime(image)

	--[[ The sheet the flicker drives, over the image and under everything else.
	     See UITheme.Backdrop.DimBright: even at the bulb's brightest this is
	     most of the way to black, because the menu's headline type is drawn
	     straight over it. ]]
	dim = newFrame(root, "Dim", Color3.new(), BACKDROP.DimBright)

	local extent = BACKDROP.VignetteExtent
	vignette(root, "VigTop", 90, UDim2.fromScale(1, extent), UDim2.fromScale(0.5, extent * 0.5))
	vignette(root, "VigBottom", 270, UDim2.fromScale(1, extent), UDim2.fromScale(0.5, 1 - extent * 0.5))
	vignette(root, "VigLeft", 0, UDim2.fromScale(extent, 1), UDim2.fromScale(extent * 0.5, 0.5))
	vignette(root, "VigRight", 180, UDim2.fromScale(extent, 1), UDim2.fromScale(1 - extent * 0.5, 0.5))

	--[[ Named, so a failure names THIS picture rather than an id. See
	     ImageCheck: the way this breaks is a black menu that looks deliberate,
	     and the id it is fetching was a decal for a day. ]]
	ImageCheck.verify(BACKDROP.Image, "the menu photograph")
end

-- ── the flicker ─────────────────────────────────────────────────────────────

local function scheduleStutter(now: number)
	state.nextStutterAt = now + random:NextNumber(STUTTER_GAP_MIN, STUTTER_GAP_MAX)
end

local function scheduleBrownout(now: number)
	state.nextBrownoutAt = now + random:NextNumber(BROWNOUT_GAP_MIN, BROWNOUT_GAP_MAX)
end

--[[ Where a brown-out is in its own arc: 1 for "not in one", falling to
     BROWNOUT_FLOOR and back. Returned as a MULTIPLIER so it composes with the
     breath and the stutter rather than overriding them — a bulb sagging and
     stuttering at the same time is the best thing this effect does. ]]
local function brownoutLevel(now: number): number
	if state.brownoutAt <= 0 then
		return 1
	end
	local elapsed = now - state.brownoutAt
	if elapsed < BROWNOUT_FALL then
		return 1 - (1 - BROWNOUT_FLOOR) * (elapsed / BROWNOUT_FALL)
	end
	elapsed -= BROWNOUT_FALL
	if elapsed < BROWNOUT_HOLD then
		return BROWNOUT_FLOOR
	end
	elapsed -= BROWNOUT_HOLD
	if elapsed < BROWNOUT_RISE then
		return BROWNOUT_FLOOR + (1 - BROWNOUT_FLOOR) * (elapsed / BROWNOUT_RISE)
	end
	state.brownoutAt = 0
	scheduleBrownout(now)
	return 1
end

--[[ The stutter: a square wave rather than anything smooth. A filament failing
     does not fade, it interrupts, and an eased flicker reads as a dimmer being
     turned by hand. Sampled off the clock so the chop is frame-rate independent
     — on a 144Hz screen an every-frame toggle would be inaudibly fast and on a
     30Hz one it would be a strobe. ]]
local function stutterLevel(now: number): number
	if now >= state.stutterUntil then
		return 1
	end
	local step = math.floor((state.stutterUntil - now) * STUTTER_HZ)
	return if step % 2 == 0 then 1 else 0.14
end

local function step(dt: number)
	state.clock += dt
	local now = state.clock

	if now >= state.nextStutterAt then
		state.stutterUntil = now + random:NextNumber(STUTTER_MIN, STUTTER_MAX)
		scheduleStutter(now)
	end
	if state.brownoutAt <= 0 and now >= state.nextBrownoutAt then
		state.brownoutAt = now
	end

	--[[ Two sines that do not share a period, so the resting bulb never settles
	     into a rhythm a viewer can follow. ]]
	local breath = 1
		- BREATH_DEPTH
			* (0.6 + 0.4 * math.sin(now / BREATH_FAST))
			* (0.5 + 0.5 * math.sin(now / BREATH_SLOW))

	local level = math.clamp(breath * brownoutLevel(now) * stutterLevel(now), 0, 1)
	state.level = level

	--[[ The drift, which is not part of the flicker and deliberately does not
	     react to it: a bulb that lurched every time it stuttered would read as a
	     camera being knocked rather than a light going. ]]
	image.Position = UDim2.fromScale(
		0.5 + math.sin(now / BACKDROP.DriftPeriodX) * BACKDROP.DriftAmount,
		0.5 + math.cos(now / BACKDROP.DriftPeriodY) * BACKDROP.DriftAmount
	)

	if math.abs(level - state.drawn) < EPSILON then
		return
	end
	state.drawn = level

	--[[ Both, and it has to be both. The image dims because the bulb is dimmer;
	     the sheet over it darkens because a room lit by one bulb goes dark with
	     it. Either alone reads as a picture being faded. ]]
	image.ImageColor3 = BACKDROP.Tint:Lerp(Color3.new(), (1 - level) * BACKDROP.FlickerDepth)
	dim.BackgroundTransparency = BACKDROP.DimDark + (BACKDROP.DimBright - BACKDROP.DimDark) * level
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Runs the flicker, or stops it. Driven by the menu's own visibility: the
     menu is hidden for the whole of a round, and a RenderStepped connection
     behind a hidden frame is work per frame for nobody. ]]
function MenuBackdrop:setActive(on: boolean)
	if not state.attached or state.active == (on == true) then
		return
	end
	state.active = on == true

	if not state.active then
		runTrove:clean()
		return
	end

	--[[ Both timers are re-armed on every open rather than left running, so a
	     menu that has been closed for seventeen minutes does not come back
	     mid-brown-out — and so the first thing a player sees on opening it is a
	     steady bulb rather than the tail of an event they did not witness. ]]
	state.brownoutAt = 0
	scheduleStutter(state.clock)
	scheduleBrownout(state.clock)
	runTrove:connect(RunService.RenderStepped, step)
end

--[[ How lit the bulb is this frame, 0 to 1. Nothing reads it yet; it is here
     because anything in the menu that wants to breathe WITH the backdrop — an
     accent rule, the title's glow — should breathe off the same number rather
     than running a second clock that drifts against this one. ]]
function MenuBackdrop:getLevel(): number
	return state.level
end

function MenuBackdrop:destroy()
	runTrove:destroy()
	trove:destroy()
	state.attached = false
	state.active = false
end

Registry.register("MenuBackdrop", MenuBackdrop)

return MenuBackdrop
