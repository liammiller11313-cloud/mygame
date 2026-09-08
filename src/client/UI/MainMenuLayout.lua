--!strict
--[[
	MainMenuLayout — the menu's own geometry, in one frozen table.

	Split out of MainMenuController, which was at 181 top-level locals against
	Luau's hard limit of 200 per scope. Twenty-eight of them were bare numbers:
	how tall a nav button is, how wide an entry bar, how long a message lives.

	They are here rather than in UITheme.Layout because they are not the game's
	visual language, they are one screen's measurements — nothing outside the
	main menu has an opinion about how wide its PLAY button should be, and
	putting them in the shared theme would invite something to grow one.

	Twenty-eight names became one.
]]

local MainMenuLayout = table.freeze({
	--[[ Not fully opaque: the blurred world stays faintly visible behind the black,
	which is the difference between a menu that sits in front of the game and a
	menu that replaced it. ]]
	MENU_SCRIM = 0.04,
	RESULTS_SCRIM = 0.02,
	BLUR_SIZE = 26,
	BLUR_EPSILON = 0.05,
	-- The left margin every headline, rule and mode entry lines up against.
	COLUMN_X = 0.09,
	TITLE_RULE_WIDTH = 300,
	PLAY_HEIGHT = 110,
	PLAY_HEIGHT_COMPACT = 64,
	--[[ Under LAYOUT.ScreenMargin, because that gap is where it lives — see where it
	is positioned. Wide to stay tappable at the height that leaves it. ]]
	BACK_HEIGHT = 18,
	BACK_WIDTH = 0.26,
	ENTRY_HEIGHT = 88,
	ENTRY_GAP = 20,
	ENTRY_WIDTH = 0.44,
	ENTRY_BAR_WIDTH = 3,
	ENTRY_TEXT_INSET = 20,
	HOVER_EPSILON = 0.004,
	--[[ How long the menu waits for the server to answer a mode request before it
	stops saying SEARCHING. The only slow path is a MemoryStore browse plus a
	teleport attempt; past this something went wrong and silence is the worst
	possible answer. ]]
	PENDING_TIMEOUT = 14,
	MESSAGE_LIFETIME = 9,
	-- The countdown turns orange here. The last ten seconds are the only ones
	-- anybody actually counts, and that is when the number should start shouting.
	COUNTDOWN_URGENT = 10,
	RESULT_ROW_HEIGHT = 30,
	NAME_WIDTH = 0.30,
	STATUS_WIDTH = 0.14,
	--[[ 56, up from 46. These are tap targets and a phone draws the whole menu at
	ScaleLayer's 0.75 floor, so 46 reference pixels was 34.5 real ones against
	the project's 42-pixel standard — the five things a player has to press to
	get anywhere were all under it. Unconditional rather than input-dependent:
	ten pixels is invisible on a desktop and the row would otherwise have to be
	re-laid-out every time somebody picked up a controller. ]]
	NAV_HEIGHT = 56,
	NAV_GAP = 0.015,
	COMPACT_HEIGHT = 620,
	--[[ The shortest a mode entry is allowed to get. Its title is TEXT.Heading in
	compact, so this has to clear 30 plus its padding — and a 640x360 phone,
	which is 480 reference pixels, needs every one of the studs between. ]]
	ENTRY_HEIGHT_COMPACT = 48,
})

return MainMenuLayout
