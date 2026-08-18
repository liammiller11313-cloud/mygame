--!strict
--[[
	UITheme — the Left 4 Dead visual language, in one place.

	What makes the L4D HUD recognisable is not decoration, it is restraint. The
	screen is almost entirely empty. Four survivor bars sit in the bottom-left,
	an ammo count sits in the bottom-right, and everything else appears only when
	it has something to say. There is no minimap, no XP bar, no border art.

	Two ideas do the heavy lifting and both are copied here deliberately:
	  1. Teammate state is read from the SILHOUETTE, not from a bar. You learn
	     where your team is by their outline through the wall, in their colour.
	  2. Colour is used sparingly enough that when something turns red, you look.

	Every colour, size and duration the interface uses lives in this file.
]]

local UITheme = {}

-- ── Palette ─────────────────────────────────────────────────────────────────
-- Warm near-black rather than pure black; pure black reads as a hole on OLED
-- and makes the amber accents look radioactive next to it.
UITheme.Color = table.freeze({
	Background = Color3.fromRGB(10, 9, 8),
	Panel = Color3.fromRGB(18, 17, 15),
	PanelRaised = Color3.fromRGB(27, 25, 22),
	Border = Color3.fromRGB(58, 53, 45),
	BorderBright = Color3.fromRGB(96, 87, 72),

	TextPrimary = Color3.fromRGB(232, 226, 214),
	TextSecondary = Color3.fromRGB(150, 143, 130),
	TextDim = Color3.fromRGB(94, 89, 80),

	-- The signature amber. Used for the objective line, interact prompts, and
	-- anything the game wants read before the player thinks about it.
	Accent = Color3.fromRGB(226, 148, 44),
	AccentBright = Color3.fromRGB(255, 186, 88),
	AccentDim = Color3.fromRGB(138, 90, 26),

	HealthGood = Color3.fromRGB(122, 176, 74),
	HealthHurt = Color3.fromRGB(214, 172, 46),
	HealthCritical = Color3.fromRGB(196, 58, 42),
	HealthTemp = Color3.fromRGB(226, 222, 210), -- the white pill buffer
	HealthIncap = Color3.fromRGB(148, 36, 32),
	HealthBlackWhite = Color3.fromRGB(128, 128, 128),

	Danger = Color3.fromRGB(206, 52, 40),
	Warning = Color3.fromRGB(226, 160, 46),
	Success = Color3.fromRGB(118, 170, 82),

	Blood = Color3.fromRGB(104, 16, 16),
	Bile = Color3.fromRGB(142, 156, 58),
})

--[[ Survivor outline colours. Four, maximally distinguishable, and assigned in
     join order so a given player keeps their colour for the whole campaign. ]]
UITheme.SurvivorColors = table.freeze({
	Color3.fromRGB(96, 164, 226), -- blue
	Color3.fromRGB(226, 148, 44), -- amber
	Color3.fromRGB(126, 196, 96), -- green
	Color3.fromRGB(214, 108, 176), -- magenta
})

--[[ Silhouettes seen through geometry. This is the most important single piece
     of the L4D interface and it deserves its own tuning. ]]
UITheme.Outline = table.freeze({
	TeammateTransparency = 0.35,
	TeammateOccludedOnly = true, -- solid only when they are actually hidden
	IncapTransparency = 0.0, -- a downed teammate is always fully visible
	IncapPulseSpeed = 2.4,
	PinnedColor = Color3.fromRGB(226, 62, 48),
	ItemColor = Color3.fromRGB(226, 148, 44),
	ItemMaxDistance = 90,
	TeammateMaxDistance = 900,
	OutlineThickness = 0.22,
})

-- ── Type ────────────────────────────────────────────────────────────────────
-- Oswald is a condensed grotesque and is as close to the L4D lockup as the
-- built-in Roblox families get. SpecialElite is a battered typewriter face,
-- used only for chapter cards where the game is pretending to be a poster.
UITheme.Font = table.freeze({
	Display = Enum.Font.Oswald,
	Heading = Enum.Font.Oswald,
	Body = Enum.Font.RobotoCondensed,
	Numeric = Enum.Font.RobotoCondensed,
	Stencil = Enum.Font.SpecialElite,
})

UITheme.TextSize = table.freeze({
	Tiny = 12,
	Small = 14,
	Body = 17,
	Large = 22,
	Heading = 30,
	Display = 54,
	Title = 84,
})

-- ── Layout ──────────────────────────────────────────────────────────────────
UITheme.Layout = table.freeze({
	ScreenMargin = 22,
	PanelPadding = 10,
	ElementGap = 6,
	CornerRadius = 2, -- L4D is squared off; rounding it makes it look mobile
	BorderThickness = 1,

	SurvivorPanelWidth = 214,
	SurvivorPanelHeight = 42,
	SurvivorPanelGap = 4,
	HealthBarHeight = 9,

	AmmoPanelWidth = 190,
	AmmoPanelHeight = 76,

	ItemSlotSize = 46,
	ItemSlotGap = 5,
})

-- ── Crosshair ───────────────────────────────────────────────────────────────
-- Four ticks that open with the weapon's current cone of fire. The crosshair IS
-- the spread readout; a player should never have to be told their accuracy.
UITheme.Crosshair = table.freeze({
	Thickness = 2,
	Length = 7,
	MinGap = 3,
	MaxGap = 46,
	GapPerDegree = 5.2, -- studs of gap per degree of spread
	Color = Color3.fromRGB(238, 234, 226),
	HitColor = Color3.fromRGB(255, 255, 255),
	KillColor = Color3.fromRGB(226, 62, 48),
	Transparency = 0.15,
	DotEnabled = false,
	SmoothSpeed = 18,
})

-- ── Hitmarkers ──────────────────────────────────────────────────────────────
-- Three distinct marks so a player can tell a body hit, a headshot and a kill
-- apart from peripheral vision alone, without reading a number.
UITheme.Hitmarker = table.freeze({
	Size = 15,
	HeadshotSize = 21,
	KillSize = 26,
	Thickness = 2,
	Duration = 0.18,
	KillDuration = 0.3,
	NormalColor = Color3.fromRGB(238, 234, 226),
	HeadshotColor = Color3.fromRGB(255, 206, 96),
	KillColor = Color3.fromRGB(226, 62, 48),
	RotationOnKill = 45, -- the kill mark is an X, not a cross
	ScalePunch = 1.5,
})

-- ── Damage feedback ─────────────────────────────────────────────────────────
UITheme.DamageIndicator = table.freeze({
	Radius = 130,
	Width = 66,
	Height = 12,
	Duration = 1.1,
	Color = Color3.fromRGB(216, 52, 40),
	MaxSimultaneous = 6,
})

UITheme.Vignette = table.freeze({
	HurtStart = 0.45, -- health fraction at which the edges start to redden
	MaxIntensity = 0.62,
	IncapIntensity = 0.8,
	PulseSpeed = 1.6,
	Color = Color3.fromRGB(120, 12, 12),
})

-- ── Motion ──────────────────────────────────────────────────────────────────
-- Everything animates fast. A HUD element that takes 300ms to appear is a HUD
-- element the player has already stopped looking for.
UITheme.Motion = table.freeze({
	FastIn = 0.08,
	FastOut = 0.14,
	Normal = 0.2,
	Slow = 0.35,
	Cinematic = 0.9,
	Easing = Enum.EasingStyle.Quad,
	EasingDirection = Enum.EasingDirection.Out,
})

UITheme.DisplayOrder = table.freeze({
	Vignette = 5,
	Hud = 10,
	Crosshair = 15,
	Prompt = 20,
	Subtitle = 25,
	Overlay = 40, -- incap / death / chapter cards
	Fade = 90,
})

--[[ Health colour, blended across the bar's range. The green -> amber -> red
     ramp is deliberately non-linear: it holds green until 60% so that the first
     hint of amber genuinely means something. ]]
function UITheme.getHealthColor(fraction: number): Color3
	local clamped = math.clamp(fraction, 0, 1)
	if clamped > 0.6 then
		local alpha = (clamped - 0.6) / 0.4
		return UITheme.Color.HealthHurt:Lerp(UITheme.Color.HealthGood, alpha)
	end
	local alpha = clamped / 0.6
	return UITheme.Color.HealthCritical:Lerp(UITheme.Color.HealthHurt, alpha)
end

--[[ The stable per-player outline colour, assigned by join order. ]]
function UITheme.getSurvivorColor(index: number): Color3
	local count = #UITheme.SurvivorColors
	return UITheme.SurvivorColors[((index - 1) % count) + 1]
end

return table.freeze(UITheme)
