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

	--[[ The hotbar's own size lives here rather than privately in HudController
	     because TouchController has to lay the on-screen pad out ABOVE it, and a
	     second copy of the number is how the pad ended up eight pixels on top of
	     the ammo counter. One definition, two readers. ]]
	--[[ Squarer than they were. Left 4 Dead's item slots are close to square
	     tiles, and the wide rectangles this replaced read as list rows — which is
	     also 100 studs of screen width saved on a phone. ]]
	HotbarSlotWidth = 78,
	HotbarSlotHeight = 58,

	ItemSlotSize = 46,
	ItemSlotGap = 5,

	--[[ The pause button in the top-right corner. Here rather than privately in
	     PauseController for the same reason the hotbar's size is: the kill feed
	     occupies that exact corner and has to step aside for it, and a second
	     copy of the number is how the two ended up drawn on top of each other.
	     One definition, two readers. ]]
	PauseButtonSize = 40,

	--[[ The Dollars line above the ammo counter. Here rather than privately in
	     HudController because the round-start loadout picker has to sit ABOVE the
	     whole bottom-right stack — hotbar, ammo panel, wallet — and a second copy
	     of this number is how the picker ended up drawn across the ammo counter
	     on a phone. One definition, two readers. ]]
	WalletHeight = 20,
})

--[[
	Modal panel chrome — the shape every full-screen panel in this game shares.

	Settings, the shop, the loadout screen and the pause menu were each built
	from their own private copy of these numbers, and they drifted: three
	different header heights (38, 44, 44), four different scrim opacities (0.35,
	0.45, 0.45, 0.55), three panel transparencies, two row heights. Nobody
	notices any single one of those. Everybody notices that the screens do not
	feel like they came from the same game.

	One definition, four readers. A screen still owns its own WIDTH and its own
	maximum height — a shop with two columns genuinely needs more room than a
	pause menu with three buttons — but nothing below that line is a per-screen
	decision, and Client/UI/Widgets.panel is what actually builds it.
]]
UITheme.Panel = table.freeze({
	--[[ How much of the world a modal hides. Deep enough that type over it stays
	     readable against a muzzle flash, shallow enough that a player can still
	     see the horde arriving behind it. ]]
	Scrim = 0.45,

	--[[ Not quite opaque. A hair of the world coming through is what keeps a
	     panel reading as something laid OVER the game rather than as a screen the
	     game was replaced by. ]]
	Transparency = 0.04,

	--[[ The title bar: name on the left, CLOSE on the right, an accent rule
	     underneath. 44 is sized by the CLOSE button rather than by the type — it
	     is the panel's way out on a phone, and a thumb needs something to hit. ]]
	HeaderHeight = 44,
	TabHeight = 30,
	FooterHeight = 40,
	CloseWidth = 84,

	--[[ A list row, by input scheme. A finger is not a cursor. On the phone where
	     the touch height matters, the whole panel is being drawn at the 0.75 scale
	     floor — so 56 reference pixels is 42 real ones, not 56. ]]
	RowHeight = 44,
	RowHeightTouch = 56,

	--[[ The two fills anything raised off a panel is allowed to have.

	     `RaisedFill` is a surface you can PICK — a loadout card, a weapon slot, a
	     pause entry. `ActionFill` is the one thing on a panel that COMMITS: BUY,
	     SET ACTIVE. It is denser so that on a screen full of pickable rows the
	     button that spends money is not just another row.

	     These were 0.3, 0.35, 0.35 and 0.15, 0.15, 0 across four files. ]]
	RaisedFill = 0.3,
	ActionFill = 0.15,

	--[[ Hairline. A scrollbar here is a position readout rather than a control:
	     every scrolling surface in this interface is also draggable and
	     wheel-driven, so the bar only has to say where you are. ]]
	ScrollBarWidth = 3,

	--[[ How much of the viewport height a panel may take. The remainder is scrim,
	     and seeing some of it is how a player knows the thing is a panel and that
	     clicking outside will close it. ]]
	HeightScale = 0.86,
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
	--[[
		A headshot that KILLS, which is the one outcome the game had no mark for.

		The kill mark is red and the headshot mark is orange, and until now a
		headshot kill drew the red one — so the single most rewarded act in the
		game, the one the main menu teaches and the one the 4x multiplier exists
		for, produced exactly the same feedback as a body shot that happened to
		finish something off.

		Worse, it was not merely rare: Commons have headshotAlwaysKills, so a head
		hit on the enemy you shoot three hundred times a round is ALWAYS lethal and
		therefore ALWAYS took the kill branch. The orange headshot mark was
		mathematically unreachable on 95% of the things in the level.

		Bright gold rather than a blend of the two: this is the good outcome, and
		it should not read as a shade of either half.
	]]
	HeadshotKillColor = Color3.fromRGB(255, 214, 92),
	RotationOnKill = 45, -- the kill mark is an X, not a cross
	ScalePunch = 1.5,
})

--[[
	How hard a kill lands, by what died.

	Every kill in this game used to feel identical: the same red X, the same
	tick, the same 35ms freeze, whether it was the three-hundredth Common of a
	horde or the Tank the whole team had been fighting for a minute. That is the
	flattest thing about killing here — the one moment that should land hardest
	is indistinguishable from the ones that should not.

	`Weight` is 0-1: how much of the heavy treatment a kill of that class earns.
	A Common is deliberately 0, because it has to be. Commons die three hundred
	times a round and anything that shakes the screen or holds the mark for them
	stops being a reward within ninety seconds and becomes the reason somebody
	quits. The escalation only means something if the floor stays flat.

	Read by HitmarkerController (mark size, duration, which cue plays) and by
	CameraController (how much trauma). One table so a Tank cannot end up
	shaking the screen while its mark stays Common-sized.
]]
UITheme.KillFeedback = table.freeze({
	Weight = table.freeze({
		Common = 0,
		Jockey = 0.4,
		Hunter = 0.45,
		Charger = 0.5,
		--[[ Lighter than the pinning specials, and deliberately so. These three
		     are fragile and are meant to die fast; a full special-weight thump
		     every time somebody clips a Spitter would flatten the difference
		     between "I killed the thing that had my teammate" and "I shot the
		     one that was going to spit at me". ]]
		Tongue = 0.4,
		Spitter = 0.3,
		Boomer = 0.35,
		Witch = 1,
		Tank = 1,
	}),

	--[[ Trauma at weight 1. Shake is trauma SQUARED, so 0.5 here is a quarter of
	     a full-strength shake — a distinct thump on a special, and nowhere near
	     the static that a Tank explosion produces. ]]
	MaxTrauma = 0.5,

	-- Multipliers applied to Hitmarker.KillSize and KillDuration at weight 1.
	SizeGain = 1.55,
	DurationGain = 2.0,

	--[[ Kills closer together than this belong to the same run. 2.5s is long
	     enough to survive a reload and short enough that a streak cannot quietly
	     accumulate across a whole wave. ]]
	StreakWindow = 2.5,
	--[[ Below this the count is not worth saying. Two kills is Tuesday; the
	     number should only appear when something is actually going well. ]]
	StreakMin = 3,
	StreakHold = 1.4, -- how long the count lingers after the run ends
	StreakY = 0.62, -- screen fraction, clear below the "+$" line at HudController.EARN_Y
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
	-- One above the crosshair rather than level with it. Two ScreenGuis on the
	-- same DisplayOrder fall back to sibling order, which is creation order,
	-- which is boot order — and a hit confirmation that sometimes draws under
	-- the reticle is worse than one that never does.
	Hitmarker = 16,
	Prompt = 20,
	Subtitle = 25,
	Overlay = 40, -- incap / death / chapter cards

	--[[ The three layers above the game, in the order they have to cover each
	     other. The menu covers the HUD and the end-of-round card; the map vote
	     covers the menu, because the vote runs UNDERNEATH the scoreboard in time
	     and the scoreboard draws a near-opaque scrim over the whole screen — a
	     vote nobody can see is a vote nobody casts; and the fade covers
	     everything, because a teleport has to end on black. ]]
	Menu = 80,
	Vote = 85,
	--[[ Above both, because these are modals the player opened deliberately and
	     they open from inside either of them. A settings panel with a vote card
	     drawn through it is a settings panel nobody can read. The shop and the
	     loadout screen share this layer: they are the same kind of thing and
	     they are never open at the same time. ]]
	--[[ Between the vote and the panels. Above the end-of-round card and the
	     vote because it is a reward for the round both of those are about, and
	     BELOW the shop and the settings panel because those are things the
	     player opened on purpose and a toast must never land on top of one. ]]
	Award = 86,
	Settings = 88,
	--[[ Above the shop and the loadout screen, because the lobby countdown has to
	     be readable from INSIDE them. The lobby waits for somebody to pick a mode
	     before it starts counting, precisely so a player can go and spend their
	     dollars first — and a clock that the shop hides is how that turns into
	     being yanked into a round mid-purchase. See UI/LobbyClock. ]]
	LobbyClock = 89,
	--[[ Above those, because the pause menu is what a player reaches for to get
	     OUT of one of them. A pause menu that can end up behind the screen it is
	     meant to escape is worse than no pause menu. ]]
	Pause = 90,
	Fade = 91,
})

--[[
	Resolution independence, as one number.

	Every pixel offset in this interface was chosen against a 900px-tall
	viewport. Left alone that is a wall of type on a phone and a postage stamp
	on a 4K display, so anything laying out in offsets carries a UIScale driven
	by this. Clamped at both ends deliberately: below Min the type stops being
	legible at all, and above Max the HUD starts eating the play space, which on
	a big display is the whole reason you bought the display.

	Client/UI/ScaleLayer is the machinery; this is the contract it and the main
	menu share, so two independently built layers land on the same factor.
]]
UITheme.Scale = table.freeze({
	ReferenceHeight = 900,
	--[[ The floor is set by LEGIBILITY, not by how much fits. A phone in
	     landscape is around 390px tall, so every scale below about 0.75 renders
	     TextSize.Tiny under nine real pixels — beneath what anyone can read on a
	     handset at arm's length while being shot at. At 0.75 the smallest type in
	     the interface lands at exactly 9px and TextSize.Small at 10.5px, which is
	     the point of the whole exercise.

	     It cannot go much higher: the main menu's mode entries are fixed-height
	     and stack downward from 52% of the screen, and above roughly 0.8 the
	     second one runs off the bottom of a small phone. (A THIRD mode would
	     overflow at any floor, including the old one — worth knowing before one
	     is added.) ]]
	Min = 0.75,
	Max = 1.35,
})

--[[ The scale factor for a viewport height. A height of zero means the camera
     has not resolved yet, which happens for a frame or two at boot; it returns
     1 rather than dividing into nonsense, and the real value arrives with the
     next ViewportSize change. ]]
function UITheme.scaleFor(viewportHeight: number): number
	if viewportHeight <= 0 then
		return 1
	end
	return math.clamp(viewportHeight / UITheme.Scale.ReferenceHeight, UITheme.Scale.Min, UITheme.Scale.Max)
end

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
