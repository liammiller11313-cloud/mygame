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
-- Three colours: black, white, orange. Nothing else appears on screen unless it
-- is communicating danger, and that restraint is what makes the danger register.
--
-- The blacks are very slightly warm rather than pure #000. Pure black reads as a
-- hole punched in the screen on an OLED panel, and it makes the orange next to it
-- look radioactive. These are dark enough to read as black and warm enough to sit
-- under the accent without fighting it.
UITheme.Color = table.freeze({
	Background = Color3.fromRGB(7, 6, 6),
	Panel = Color3.fromRGB(13, 12, 11),
	PanelRaised = Color3.fromRGB(22, 20, 18),
	Border = Color3.fromRGB(52, 47, 40),
	BorderBright = Color3.fromRGB(226, 148, 44), -- the accent, used as a rule

	TextPrimary = Color3.fromRGB(240, 236, 228),
	TextSecondary = Color3.fromRGB(154, 147, 136),
	TextDim = Color3.fromRGB(92, 87, 79),

	-- The signature orange. Used for the objective line, interact prompts, wave
	-- announcements, and anything the game wants read before the player thinks.
	Accent = Color3.fromRGB(226, 148, 44),
	AccentBright = Color3.fromRGB(255, 176, 66),
	AccentDim = Color3.fromRGB(132, 84, 24),

	-- Health runs white -> orange -> red. White is "fine", orange is "this is
	-- becoming a problem", and red is the only colour on the whole HUD that means
	-- something is actually wrong — which is exactly why it works.
	HealthGood = Color3.fromRGB(238, 234, 226),
	HealthHurt = Color3.fromRGB(226, 148, 44),
	HealthCritical = Color3.fromRGB(198, 48, 34),
	HealthTemp = Color3.fromRGB(140, 134, 126), -- the pill buffer, dimmed white
	HealthIncap = Color3.fromRGB(158, 34, 28),
	HealthBlackWhite = Color3.fromRGB(118, 118, 118),

	Danger = Color3.fromRGB(206, 46, 32),
	Warning = Color3.fromRGB(226, 148, 44),
	Success = Color3.fromRGB(238, 234, 226),

	Blood = Color3.fromRGB(104, 16, 16),
	Bile = Color3.fromRGB(142, 156, 58),
})

--[[
	Survivor outline colours — the one deliberate exception to the three-colour
	rule. Telling four teammates apart through a wall at a glance is a FUNCTION,
	not decoration, and four shades of orange cannot do it.

	So these stay distinguishable, but they are all pulled warm so the palette
	still reads as one system: orange, white, gold, and a hot vermillion. Assigned
	in join order, stable for the whole round.
]]
UITheme.SurvivorColors = table.freeze({
	Color3.fromRGB(226, 148, 44), -- orange
	Color3.fromRGB(240, 236, 228), -- white
	Color3.fromRGB(232, 194, 74), -- gold
	Color3.fromRGB(226, 92, 48), -- vermillion
})

--[[ Silhouettes seen through geometry. This is the most important single piece
     of the L4D interface and it deserves its own tuning. ]]
UITheme.Outline = table.freeze({
	TeammateTransparency = 0.35,
	TeammateOccludedOnly = true, -- solid only when they are actually hidden
	IncapTransparency = 0.0, -- a downed teammate is always fully visible
	IncapPulseSpeed = 2.4,
	PinnedColor = Color3.fromRGB(206, 46, 32),
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
	KillColor = Color3.fromRGB(206, 46, 32),
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
	HeadshotColor = Color3.fromRGB(255, 176, 66),
	KillColor = Color3.fromRGB(206, 46, 32),
	RotationOnKill = 45, -- the kill mark is an X, not a cross
	ScalePunch = 1.5,
})

-- ── Damage feedback ─────────────────────────────────────────────────────────
UITheme.DamageIndicator = table.freeze({
	Radius = 130,
	Width = 66,
	Height = 12,
	Duration = 1.1,
	Color = Color3.fromRGB(206, 46, 32),
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

--[[ Health colour across the bar's range. Deliberately non-linear: it holds
     white all the way down to 60% so that the first hint of orange genuinely
     means something, then runs orange -> red over the bottom 60%. ]]
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
