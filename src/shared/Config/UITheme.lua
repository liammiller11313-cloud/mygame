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
--[[
	── THE GENRE PASS ──────────────────────────────────────────────────────────

	Everything below exists because the interface was too clean. A near-black
	panel, a one-pixel border and an orange hairline is a good modern layout and
	it is the wrong ONE for this game: nothing about it says the lights are going
	out, and a player reads that before they read a word of it.

	The fix is deliberately structural rather than chromatic. The palette above
	is already warm and already dark, and pushing it browner would only make the
	type harder to read in the dark rooms this game ends in. What was missing is
	the vocabulary an industrial surface has — corners that are braced, and
	surfaces that are not perfectly flat.

	All of it is procedural. This project ships no marketplace image assets, so
	every one of these is frames, strokes and gradients, which also means they
	cost nothing to load and cannot 404 in a live game.

	── WHAT IS NOT HERE, AND WHY ───────────────────────────────────────────────
	There was a third one: diagonal yellow-and-black hazard tape, under the menu
	title, under every panel header, and above and below the downed card. It is
	the right idea and Roblox cannot draw it this way.

	Each stripe was a thin bar rotated 31 degrees inside a seven-pixel strip with
	ClipsDescendants on. Clipping does not apply to a ROTATED descendant, so
	nothing was sliced into a diagonal band — every stripe drew as a whole tilted
	rectangle standing well clear of the strip it was supposed to be inside, and
	the effect on screen was a row of yellow squares floating over the title.

	Doing it properly needs the stripes drawn as an image, and this project has
	no image assets on purpose. If one is ever added, that is the way to do it —
	not another attempt at rotating frames inside a clip.
]]

--[[
	Corner brackets: four Ls at the corners of a panel instead of a closed box.

	A complete one-pixel rectangle is the most neutral shape an interface has. The
	same rectangle with its edges left open and its corners braced is a crate, a
	sight, a stencilled marking on a shipping container — and it costs eight small
	frames.
]]
UITheme.Bracket = table.freeze({
	Length = 16,
	Thickness = 2,
})

--[[
	Grime: a vertical gradient that stops a panel being one flat value.

	Real surfaces are darker where they meet the floor and lighter where the
	light hits them. One gradient per panel is the whole difference between
	"a rectangle of #0D0C0B" and "a surface", and Roblox interpolates it on the
	GPU for nothing.

	Deliberately subtle. The temptation with a texture pass is to make it
	visible; the point of this one is that a player never notices it and would
	notice its absence.
]]
UITheme.Grime = table.freeze({
	TopTransparency = 0.0,
	BottomTransparency = 0.22,
	Rotation = 90,
})

--[[
	── THE MENU BACKDROP ───────────────────────────────────────────────────────
	A bare bulb in the dark, behind the main menu, flickering.

	The game is called Fading Light. The one image the menu can afford to carry
	should be the title as a picture, and a bulb that will not hold steady is
	that — it is the thing the survivors are trying to keep on, it is what the
	round's whole atmosphere ramp is about, and it costs one texture.

	── EVERY NUMBER BELOW IS A TREATMENT, NOT THE IMAGE ────────────────────────
	Nothing here edits the asset. The look comes from what is stacked on top of
	it: a tint that pulls the bulb into the interface's own orange and drops its
	brightness, a scrim heavy enough that white type stays readable over it, a
	four-sided vignette, a drift so it is never a still frame, and a flicker that
	drives all of it. That is deliberate — the source stays a clean photograph
	and the grade lives somewhere a person can change it without re-uploading
	anything.

	── THE SCRIM IS NOT DECORATION ─────────────────────────────────────────────
	`DimBright` is the LIGHTEST the backdrop is ever allowed to be, and it is
	still 60% black. The menu draws white headline type straight over this, and a
	background that looks beautiful in isolation and eats the word PLAY is a
	background that has failed. Raise it and check the title, not the picture.
]]
UITheme.Backdrop = table.freeze({
	--[[
		The photograph behind the main menu.

		THIS IS AN IMAGE ID AND IT HAS TO BE. It was 111807251881801 for a day,
		which is the DECAL — the wrapper object you get when you upload a picture
		and the id every Creator Store page and inventory tile shows you. An
		ImageLabel wants the image inside that wrapper and draws nothing at all
		when handed the wrapper itself. Both ids are real, both are yours, and
		only one of them renders; nothing about the config can tell them apart.
		To find the right one: open the decal in Studio and read the id off its
		Texture property. MenuBackdrop.verifyImage now fetches this at boot and
		warns by name if it ever fails again, because the way this breaks is a
		black menu that looks like a design decision.

		The grade below was authored against an earlier picture and is
		deliberately left alone, because every number in it is a READABILITY
		constraint rather than a flattering one — the scrim exists to keep white
		headline type legible and the vignette is measured against the menu's own
		two columns. Both hold for any picture. If this one wants a warmer or
		cooler cast, Tint is the number to move and it is the only one here that
		is purely taste.
	]]
	Image = "rbxassetid://78563803199573",

	--[[ Multiplied into the image, so it both grades and darkens. Warm, because
	     the bulb is the only warm thing left in this game's palette and the round
	     spends seventeen minutes taking it away. ]]
	Tint = Color3.fromRGB(178, 138, 96),

	--[[
		How black the sheet over the image sits, at the bulb's darkest and its
		brightest. Transparency, so the BIGGER number is the brighter screen.

		0.44 first, on the argument that the vignette is what makes the type
		readable and the sheet could afford to be light. That argument holds at
		the EDGES and does not hold in the middle: 56% darkened is fine behind
		nothing and marginal behind anything the menu ever grows into the centre
		band, and a background that looks good in isolation and costs a word of
		the interface has failed.

		0.32 takes the centre to 68% darkened and the two text columns to 90%.
		The bulb is still clearly the brightest thing on the screen — it is a
		light source against black, so it survives a lot of scrim — and the type
		now has room whatever ends up drawn over it.

		DimDark moves with it. What sells the flicker is the RATIO between these
		two, not the gap: dropping only the bright end would have made every
		stutter shallower as a side effect of a readability fix, which is the
		kind of change nobody connects to the thing that caused it. 0.32/0.13 is
		the 2.4 the first pass had.
	]]
	DimDark = 0.13,
	DimBright = 0.32,

	--[[ How much of the tint the flicker takes away at its lowest. Not all of it:
	     a bulb that goes to pure black reads as the game crashing, and the
	     interesting part of a dying filament is that it never quite lets go. ]]
	FlickerDepth = 0.65,

	--[[
		The vignette: how far in from each edge the darkness reaches, and how
		black it is at the very edge.

		These two are the readability pass, and the extent is chosen against the
		menu's own layout rather than by eye. MainMenuController puts its left
		column at COLUMN_X = 0.09 and its right one at 0.91, so both sit deep
		inside a 0.34 vignette — at 9% across the falloff is still about 70%
		black, which is plenty under white headline type.

		The centre band, where the bulb actually is and where the menu writes
		nothing, gets only the sheet — so the picture is brightest exactly where
		there is nothing to read over it and darkest exactly where there is. With
		the sheet at 0.32 that is 90% darkened under both columns against 68% in
		the middle.

		Anything that moves COLUMN_X has to come back to this number.
	]]
	VignetteExtent = 0.34,
	VignetteStrength = 0.06,

	--[[ The drift. The image is drawn oversized so there is somewhere to move to
	     — without the overscan a pan would show the screen behind it — and moves
	     within a fraction of a screen on two slow, deliberately non-harmonic
	     periods so the loop never lines back up and reads as a loop. ]]
	Overscan = 1.09,
	DriftAmount = 0.018,
	DriftPeriodX = 37.0,
	DriftPeriodY = 53.0,
})

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

	--[[
		What a PANEL is titled in, as distinct from what a chapter card is.

		The interface read as a clean modern app rather than as a game about a
		city that has stopped working, and type was most of the reason: every
		heading in it was the same condensed grotesque, set small, on a hairline.
		That is the house style of a settings screen.

		Stencil is the answer and it cannot be the answer everywhere — a battered
		typewriter face is unreadable at body sizes and exhausting in quantity.
		So it is scoped to the one place per screen that says what the screen IS.
		Everything below the title stays Oswald, which is what keeps the panel
		legible while the header carries the genre.
	]]
	Sign = Enum.Font.SpecialElite,
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

	--[[ How far away, on the flat, a source has to be before it counts as a
	     direction at all. Below this the arrow is suppressed: atan2 of nothing is
	     zero, zero is straight ahead, and an arrow pointing confidently at the
	     horizon because a Spitter's pool is under your feet is worse than no
	     arrow. Two studs is inside a body. ]]
	MinDistance = 2,
})

--[[
	── THE DREAD LAYER ─────────────────────────────────────────────────────────

	Two things, drawn under everything else, on every screen the game has: the
	menu, the round, the results card. They are the difference between a dark
	interface and a frightening one.

	AN EDGE THAT IS ALWAYS THERE. UITheme.Vignette below is a READOUT — it reddens
	as you get hurt and it is honestly blank when you are fine, which is correct
	for a thing whose job is to tell you something. The consequence is that a
	healthy survivor plays inside a perfectly clean rectangle. This is the other
	kind of vignette: black, quiet, permanent, and it never says anything. It is
	there so the screen has edges that close in rather than a border.

	It also BREATHES, on a period slow enough that nobody consciously sees it
	move. That is the whole trick — a still frame reads as a picture and a frame
	that is never quite still reads as a place.

	AND AN IMAGE THAT WILL NOT SIT STILL. Two full-screen gradients at angles that
	do not agree, whose stops are re-randomised several times a second. Where they
	cross they interfere, and the frame develops a slow uneven cast that keeps
	moving — light through dirty glass rather than a clean pane.

	It is NOT film grain and is deliberately not called that. Real grain is
	per-pixel and needs a texture; a UIGradient interpolates smoothly between at
	most twenty stops, so what this can produce is soft banding at a scale of
	tens of pixels, not speckle. Set HazeImage to a seamless noise tile and the
	layer uses that instead — which IS grain — and the gradients are what you get
	for free until somebody uploads one.

	It re-seeds at HazeFps rather than per frame, and that is a look decision
	before it is a cost one: something that changes every frame at 120Hz reads as
	electronic noise, and something that changes fourteen times a second reads as
	a projector.
]]
UITheme.Dread = table.freeze({
	--[[ How far in from each edge the darkness reaches, and how black it is at
	     the very corner. Deliberately shallower and far weaker than the menu
	     backdrop's — that one is protecting headline type over a photograph,
	     this one is under a HUD somebody has to read while being chased. ]]
	EdgeExtent = 0.26,
	EdgeStrength = 0.40,

	--[[ The breath. Eighteen seconds is long enough that it never reads as a
	     pulse; the depth is a fifth of the edge, which is under the threshold
	     where anybody could point at it and say what changed. ]]
	BreathPeriod = 18.0,
	BreathDepth = 0.2,

	--[[ Transparency, so the BIGGER number is the fainter haze — and it wants to
	     be very faint indeed. Two layers at 0.955 each is already at the edge of
	     what anybody notices, which is exactly where it belongs: the moment a
	     player can SEE this it has stopped being atmosphere and started being a
	     filter over their game. ]]
	HazeTransparency = 0.955,
	HazeFps = 14,
	--[[ Angles that share no common factor, so the two layers never line up into
	     one visible band pattern. Parallel or perpendicular is the failure mode. ]]
	HazeAngleA = 73,
	HazeAngleB = 149,
	HazeStops = 18, -- NumberSequence allows 20; the two ends are spent on 0 and 1

	--[[
		A seamless noise tile, if there is one. Empty by default and empty is a
		perfectly good answer — the gradients above are the assetless version.

		Set it and the layers become REAL grain: the tile is repeated at
		HazeTileSize and its offset is jerked to a new random place on the same
		clock, which is per-pixel speckle rather than soft banding. That is the
		better effect and it costs one upload; it is not the default because a
		missing or unloaded image is a broken square over somebody's HUD, and an
		atmosphere layer must never be able to do that.
	]]
	HazeImage = "",
	HazeTileSize = 128,

	--[[ A phone is a smaller screen held closer, and a full-strength vignette on
	     one eats the corners of a HUD that is already tight. It also has the
	     least frame budget to spend on something nobody is looking at. ]]
	MobileScale = 0.55,
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
	--[[ The dread EDGES, under everything including the health vignette. They are
	     the world closing in rather than part of the interface, so they darken the
	     3D view and nothing the player has to read. The main menu does not need
	     them and does not get them — it draws its own, stronger, over its own
	     photograph. See UITheme.Backdrop.VignetteExtent. ]]
	Dread = 4,
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
	--[[ Above everything, including the fade. It is the first thing the game
	     draws and the only thing on screen while it runs: a splash with any layer
	     over it is a splash with somebody's HUD bleeding through the studio
	     logo. ]]
	--[[ The dread HAZE, and it is the one thing in this game that draws over the
	     interface on purpose.

	     It is a LENS rather than a layer of UI: the grime is on the glass the
	     whole game is seen through, so a menu that is exempt from it reads as a
	     different, cleaner screen — which is exactly the seam this was added to
	     close. At 4.5% black it costs nothing legible even over body text.

	     Above Fade so a transition to black keeps its texture instead of becoming
	     a clean rectangle at the one moment there is nothing else to look at, and
	     below Splash so the boot logo is the one image in the game that is not
	     seen through dirt.
	]]
	DreadHaze = 92,
	Splash = 100,
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
