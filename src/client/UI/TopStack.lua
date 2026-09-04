--!nonstrict
--[[
	TopStack — who gets which strip of screen under the round clock.

	── THE BUG THIS EXISTS FOR ─────────────────────────────────────────────────
	Four separate controllers draw "just under the wave block", and until this
	module they each worked it out for themselves:

	    BossBarController   reservedTop() + ElementGap
	    HudController       state.topInset, pushed in by two different callers
	    EventController     reservedTop() + bossExtra + BANNER_GAP
	    VaultController     96          <- a hardcoded number

	Three of those land on the SAME pixel and the fourth lands in the middle of
	the wave block itself. In a round with a modifier, a vault and a live
	objective that is four cards stacked on one another, and the screenshot of it
	is unreadable — "CLUES 0/4" printed through "REQUISITION AND READY UP" printed
	through "SEARCH THE BUILDING".

	(The clue counter has since moved out of the centre entirely, to the left
	column under the orders card — four cards queuing down the middle of the
	screen was legible and still too much furniture over the part of the view a
	player is shooting into. It is named above because it is the reason this file
	exists, not because it is still here.)

	It could not be fixed locally, either. Each controller knew its own height and
	nobody knew the order, so every fix was one more controller reaching into two
	others through Registry and adding numbers up — which is how the third one
	already worked, and it was still wrong.

	── HOW IT WORKS ────────────────────────────────────────────────────────────
	One ordered list, here. A controller claims its slot with the height it is
	currently drawing (`set`), asks where that slot starts (`top`), and is told
	when anything above it moves (`onChanged`). A slot claiming 0 — no boss up, no
	event running — occupies nothing and costs no gap, so the common case is
	exactly as tight as the hand-tuned version was.

	── WHY THE ORDER IS THIS ORDER ─────────────────────────────────────────────
	Spectate is second because it is the one card that is about the PLAYER rather
	than about the round, and a dead player has nothing else on their screen to
	read; only a boss bar outranks it. Everything else is ordered by how permanent
	it is.

	Transient things go LAST. A boss bar arriving pushes the objective and the
	clue counter down, which is correct — a Tank is the most important thing on
	the screen and it has earned the space nearest the clock. But the random-event
	banner lives for four seconds, and putting it above two persistent cards would
	shove both of them down and back up again every time an event fired. So the
	banner sits at the bottom of the stack, where appearing and vanishing moves
	nothing else.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Config.UITheme)
local Registry = require(Shared.Util.Registry)

local LAYOUT = UITheme.Layout

local TopStack = {}

--[[ Top to bottom. A name not in this list is refused rather than silently
     dropped on the floor at y = base: a typo'd key would otherwise draw its card
     over the clock and look exactly like the bug this file replaced. ]]
local ORDER = table.freeze({ "Boss", "Spectate", "Objective", "Event" })

local ALLOWED: { [string]: boolean } = {}
for _, key in ORDER do
	ALLOWED[key] = true
end

local heights: { [string]: number } = {}
local listeners: { [any]: () -> () } = {}
local nextToken = 0

--[[ The bottom of the wave block, which is where the stack starts.

     Re-read on every query rather than cached at build time: the controllers
     that use this build their GUIs during init, and WaveController may not have
     registered yet when they do. Falling back to the screen margin means a card
     built before the round block exists still lands somewhere sane instead of at
     y = 0 under Roblox's own top bar. ]]
local function base(): number
	local waves = Registry.find("WaveController")
	if waves and typeof(waves.getReservedTopHeight) == "function" then
		local ok, height = pcall(waves.getReservedTopHeight, waves)
		if ok and typeof(height) == "number" then
			return height
		end
	end
	return LAYOUT.ScreenMargin
end

--[[ Where `key`'s card starts, in ScaleLayer pixels. Slots above it that are
     claiming nothing are skipped entirely — they cost neither their height nor
     the gap that would have followed them. ]]
function TopStack.top(key: string): number
	local y = base()
	for _, slot in ORDER do
		if slot == key then
			return y + LAYOUT.ElementGap
		end
		local height = heights[slot]
		if height and height > 0 then
			y += LAYOUT.ElementGap + height
		end
	end
	--[[ An unknown key still gets a real number. `set` is where the typo is
	     reported; returning nil here would only turn a misplaced card into a
	     crash in whichever controller asked. ]]
	return y + LAYOUT.ElementGap
end

--[[ How tall `key` is drawing right now. Pass 0 (or nothing) when the card is
     hidden — that is what frees the space for everything below it. ]]
function TopStack.set(key: string, height: number?)
	if not ALLOWED[key] then
		warn(string.format("[TopStack] no slot named %q — see ORDER", tostring(key)))
		return
	end
	local claimed = if typeof(height) == "number" and height > 0 then height else 0
	if heights[key] == claimed then
		return
	end
	heights[key] = claimed

	--[[ Copied before iterating. A listener is free to claim its own slot in
	     response — a card that resizes as it moves is normal — and mutating the
	     table being walked would be undefined. ]]
	local snapshot = table.clone(listeners)
	for _, fn in snapshot do
		local ok, err = pcall(fn)
		if not ok then
			warn(string.format("[TopStack] a listener errored: %s", tostring(err)))
		end
	end
end

--[[ Called whenever a slot above the caller's changes size. Returns a function
     that unsubscribes, which is what a Trove wants. ]]
function TopStack.onChanged(fn: () -> ()): () -> ()
	nextToken += 1
	local token = nextToken
	listeners[token] = fn
	return function()
		listeners[token] = nil
	end
end

return TopStack
