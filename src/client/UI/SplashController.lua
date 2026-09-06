--!nonstrict
--[[
	SplashController — black, then the studio, then the game.

	Four beats and nothing else:

	    1  black                      a held breath, so the logo arrives rather
	                                  than being already there when you look
	    2  the mark fades up          slow, from slightly too small
	    3  it BLOOMS on the chime     a fast overshoot and a white flare, on the
	                                  same frame as the sound
	    4  it falls away              and the menu is behind it

	── THE BLOOM IS THE WHOLE THING ────────────────────────────────────────────
	A logo that fades in and fades out is a loading screen. A logo that swells a
	few percent and flares white AT THE INSTANT the chime lands is a title card,
	and the difference is entirely that the eye and the ear get the same event.
	So the audio is preloaded before the sequence starts — see PreloadAsync
	below — because a chime that arrives forty milliseconds late lands on nothing
	and the bloom becomes a thing that merely happened.

	── AND IT IS SKIPPABLE ─────────────────────────────────────────────────────
	Any input, any time, jumps to the end. A splash is charming once and an
	obstacle every time after, and the eleventh launch of a play session is the
	one that decides whether somebody keeps playing. Skipping runs the same
	teardown as finishing, so there is no path that leaves it up.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ImageCheck = require(script.Parent.ImageCheck)

local COLOR = UITheme.Color

local IMAGE = "rbxassetid://120745043873992"
--[[ rbxassetid, not rbxsoundid. Roblox accepts the latter in some places and
     silently fails to load in others; the asset scheme is the one that always
     works. ]]
local CHIME = "rbxassetid://1085317309"

--[[ The four beats, in seconds. HOLD_BLACK is short but not nothing: the eye
     needs a moment of nothing to register the logo as an arrival rather than as
     something that was already there. ]]
local HOLD_BLACK = 0.45
local FADE_IN = 1.25
local HOLD = 0.35
local BLOOM = 0.45
local FADE_OUT = 0.7

--[[ The mark starts a touch small and settles at 1, then overshoots on the
     bloom. Both numbers are small on purpose — a logo that zooms is an
     advertisement, one that breathes is a title. ]]
local START_SCALE = 0.86
local BLOOM_SCALE = 1.06

--[[ How wide the mark is drawn, as a fraction of the SHORTER screen edge, so it
     is the same size on a phone held sideways and on an ultrawide. ]]
local MARK_FRACTION = 0.42

--[[ How long the logo has to have been ON SCREEN before an input may skip it.
     See the InputBegan handler: this is the whole fix for a splash nobody ever
     saw. Short — anybody deliberately skipping is still skipping within a
     second — but past the point where the first click of a session lands. ]]
local SKIP_ARMS_AFTER = 0.6

--[[ The longest the black hold will wait on PreloadAsync. It yields until the
     assets arrive or fail, and an id the client cannot reach can take its time
     about failing — which would be a black screen with no way to know why. The
     chime may then land a frame late on a cold cache; a late chime is a worse
     splash and an unbounded black screen is a broken game. ]]
local PRELOAD_BUDGET = 3.0

local SplashController = {}

local trove = Trove.new()

local gui: ScreenGui
local backdrop: Frame
local mark: ImageLabel
local flare: Frame
local scale: UIScale

local state = {
	running = false,
	finished = false,
	--[[ When a skip starts being allowed. Zero means never — see the note on the
	     InputBegan handler in start(), which is where this bug lived. ]]
	skippableAt = 0,
}

-- ── the sequence ────────────────────────────────────────────────────────────

local function tween(instance: Instance, seconds: number, style: Enum.EasingStyle, goal: { [string]: any })
	local info = TweenInfo.new(seconds, style, Enum.EasingDirection.Out)
	local playing = TweenService:Create(instance, info, goal)
	playing:Play()
	return playing
end

--[[ Takes the splash down and hands the screen over. Idempotent: the skip path
     and the natural end both call it, and they can race. ]]
local function finish()
	if state.finished then
		return
	end
	state.finished = true
	state.running = false

	tween(backdrop, FADE_OUT, Enum.EasingStyle.Quad, { BackgroundTransparency = 1 })
	tween(mark, FADE_OUT * 0.7, Enum.EasingStyle.Quad, { ImageTransparency = 1 })

	task.delay(FADE_OUT, function()
		if gui then
			gui.Enabled = false
		end
	end)
end

local function run()
	if state.running or state.finished then
		return
	end
	state.running = true

	--[[ Both assets fetched before a single frame of the sequence plays. The
	     chime landing on the bloom is the entire point, and an id that is still
	     downloading when the tween reaches its peak lands on nothing. Wrapped
	     because PreloadAsync throws on an id the client cannot see, and a splash
	     that errors is a black screen nobody gets past. ]]
	local chime = Instance.new("Sound")
	chime.Name = "FL_SplashChime"
	chime.SoundId = CHIME
	chime.Volume = 0.62
	chime.Parent = SoundService
	trove:add(chime)

	--[[ Bounded. PreloadAsync yields until every id resolves or fails, and one
	     the client cannot see can take several seconds to give up — all of them
	     spent on a black screen. See PRELOAD_BUDGET. ]]
	local preloaded = false
	task.spawn(function()
		pcall(function()
			--[[ The callback form, so a failure is NAMED. The plain call returns
			     the same way whether an id resolved or gave up, which is fine for
			     the timing this preload exists to fix and useless for anything
			     else — and the mark already gets its own named check through
			     ImageCheck above, so the chime was the one asset in this file
			     that could fail in silence. Losing it costs the sequence its
			     whole point: the eye and the ear are supposed to get the same
			     event, and a bloom with nothing under it just looks slow. ]]
			ContentProvider:PreloadAsync({ mark, chime }, function(content: string, fetchStatus: any)
				if fetchStatus == Enum.AssetFetchStatus.Success or content ~= CHIME then
					return
				end
				warn(
					string.format(
						"[SplashController] the splash chime %s could not be fetched (%s), so the boot "
							.. "sequence will play silent. Audio is licensed per place: an id uploaded "
							.. "under an account that does not own this one fails for every player and "
							.. "still plays in Studio for whoever uploaded it.",
						CHIME,
						tostring(fetchStatus)
					)
				)
			end)
		end)
		preloaded = true
	end)
	local deadline = os.clock() + PRELOAD_BUDGET
	while not preloaded and os.clock() < deadline and not state.finished do
		task.wait()
	end

	if state.finished then
		return -- skipped while the preload was in flight
	end

	task.wait(HOLD_BLACK)
	if state.finished then
		return
	end

	tween(mark, FADE_IN, Enum.EasingStyle.Quad, { ImageTransparency = 0 })
	tween(scale, FADE_IN, Enum.EasingStyle.Quad, { Scale = 1 })
	--[[ Armed only now, when there is finally something on screen to skip. ]]
	state.skippableAt = os.clock() + SKIP_ARMS_AFTER
	task.wait(FADE_IN + HOLD)
	if state.finished then
		return
	end

	--[[ The bloom. Sound first by a frame, because the ear is slower to register
	     than the eye and starting them on the same tick reads as the light
	     arriving early. ]]
	--[[
		Into the mixer, by hand, and it has to be by hand.

		MainMenuController owns the FL_Master SoundGroup and adopts anything that
		appears under SoundService — but it connects DescendantAdded in its own
		start(), and this controller is FIRST in the boot list precisely so it can
		draw before everything else. The chime is therefore parented several
		modules before that listener exists, so it would slip past the adoption
		and ignore the master volume slider: the one sound a player hears before
		they have any way to turn it down.
	]]
	if not chime.SoundGroup then
		local group = SoundService:FindFirstChild("FL_Master")
		if group and group:IsA("SoundGroup") then
			chime.SoundGroup = group
		end
	end

	chime:Play()
	tween(scale, BLOOM, Enum.EasingStyle.Back, { Scale = BLOOM_SCALE })
	--[[ A white sheet punched to full and immediately faded. Cheaper than a glow
	     and it does what a glow is for: for a moment the mark is the brightest
	     thing that has been on this screen, which after a minute of near-black
	     menus is a real event. ]]
	flare.BackgroundTransparency = 0.35
	tween(flare, BLOOM * 1.6, Enum.EasingStyle.Quad, { BackgroundTransparency = 1 })

	task.wait(BLOOM)
	finish()
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function SplashController:init()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Splash"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Splash
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	trove:add(gui)

	backdrop = Instance.new("Frame")
	backdrop.Name = "Black"
	backdrop.BackgroundColor3 = Color3.new()
	backdrop.BackgroundTransparency = 0
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Parent = gui

	mark = Instance.new("ImageLabel")
	mark.Name = "Mark"
	mark.BackgroundTransparency = 1
	mark.BorderSizePixel = 0
	mark.Image = IMAGE
	--[[ The splash's own PreloadAsync below is BOUNDED and deliberately ignores
	     its result — it exists to stop the chime landing on nothing, and it must
	     give up quickly because everything it waits for is spent on a black
	     screen. So it cannot be the thing that reports a bad id: a mark that
	     never loads is a boot sequence that fades a glow up over nothing and
	     then proceeds normally, which nobody would ever file. See ImageCheck. ]]
	ImageCheck.verify(IMAGE, "the splash mark")
	--[[ Invisible until the sequence raises it. Starting at 0 and tweening down
	     would show one frame of a full-brightness logo on a black screen, which
	     is the one frame the whole fade exists to avoid. ]]
	mark.ImageTransparency = 1
	mark.ScaleType = Enum.ScaleType.Fit
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Position = UDim2.fromScale(0.5, 0.5)
	mark.Size = UDim2.fromScale(MARK_FRACTION, MARK_FRACTION)
	mark.Parent = backdrop

	--[[ Square, against the SHORTER edge. Without this the mark is a different
	     size in portrait and landscape, and on a phone that is the difference
	     between filling the screen and being a stamp in the middle of it. ]]
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.DominantAxis = Enum.DominantAxis.Height
	ratio.Parent = mark

	scale = Instance.new("UIScale")
	scale.Scale = START_SCALE
	scale.Parent = mark

	flare = Instance.new("Frame")
	flare.Name = "Flare"
	flare.BackgroundColor3 = COLOR.TextPrimary
	flare.BackgroundTransparency = 1
	flare.BorderSizePixel = 0
	flare.Size = UDim2.fromScale(1, 1)
	flare.Parent = backdrop
end

function SplashController:start()
	--[[ Any input at all, and the mouse and touch cases both matter: a player who
	     has seen this eleven times is reaching for the mouse before it finishes,
	     and a phone player is already tapping where PLAY will be. ]]
	--[[
		Skipping, and it is armed LATE on purpose.

		This listener used to fire from the moment it was connected, which is
		before the logo has faded in and — critically — before the player has
		done the very first thing anybody does: click into the window to focus
		it, or tap the screen on a phone. That click is an InputBegan, so the
		splash skipped itself on frame one and the whole sequence played to
		nobody. It looked exactly like a splash that had never been written.

		So a skip is only accepted once the mark has actually been on screen for
		SKIP_ARMS_AFTER. Anybody deliberately skipping still gets out inside a
		second; the opening click of a session no longer counts as one.
	]]
	trove:connect(UserInputService.InputBegan, function()
		if state.finished or state.skippableAt <= 0 then
			return
		end
		if os.clock() >= state.skippableAt then
			finish()
		end
	end)

	task.spawn(run)
end

--[[ Whether the splash still owns the screen. Nothing reads it yet; it is here
     because the first thing that wants to know — a menu deciding whether to
     play its own opening sting — should ask rather than guess from a timer. ]]
function SplashController:isRunning(): boolean
	return state.running and not state.finished
end

function SplashController:destroy()
	trove:destroy()
end

Registry.register("SplashController", SplashController)

return SplashController
