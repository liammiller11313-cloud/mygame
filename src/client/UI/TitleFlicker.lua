--!nonstrict
--[[
	TitleFlicker — the failing fluorescent tube behind the word LIGHT.

	A failing tube holds, drops for a fraction of a second, and holds again. It
	does not strobe. Long gaps and short dips are the whole trick, and the slow
	breath underneath keeps the word from ever sitting perfectly still.

	This is a pure generator: give it a clock and it hands back a transparency.
	It owns no Instance and touches nothing on screen, so the caller decides what
	the number drives — in the main menu it is the title glyphs and the rule under
	them, which flicker together because they are meant to read as one fixture.

	Lifted out of MainMenuController for the same reason the confetti was: eleven
	tuning constants and a state table sat in the module's top-level scope, and
	Luau allows exactly 200 locals there before the file stops compiling. See
	UI/Confetti for the failure that taught us this.
]]

local BASE = 0.02
local BREATH = 0.06
local BREATH_SPEED = 0.7
local BUZZ_SPEED = 47
local MIN_GAP = 2.6
local GAP_RANGE = 6.0
local MIN_DURATION = 0.05
local DURATION_RANGE = 0.22
local MIN_DEPTH = 0.28
local DEPTH_RANGE = 0.5
local MAX = 0.86

local TitleFlicker = {}
TitleFlicker.__index = TitleFlicker

export type TitleFlicker = {
	endsAt: number,
	nextAt: number,
	depth: number,
	alphaAt: (self: TitleFlicker, now: number) -> number,
}

function TitleFlicker.new(): TitleFlicker
	return setmetatable({ endsAt = 0, nextAt = 0, depth = 0 }, TitleFlicker)
end

--[[ The transparency this fixture should sit at right now. Schedules its own
     next dip as it goes, so a caller only ever has to supply the clock. ]]
function TitleFlicker:alphaAt(now: number): number
	if now >= self.nextAt then
		self.endsAt = now + MIN_DURATION + math.random() * DURATION_RANGE
		self.depth = MIN_DEPTH + math.random() * DEPTH_RANGE
		self.nextAt = self.endsAt + MIN_GAP + math.random() * GAP_RANGE
	end

	local alpha = BASE + BREATH * (0.5 + 0.5 * math.sin(now * BREATH_SPEED))
	if now < self.endsAt then
		alpha += self.depth * (0.5 + 0.5 * math.sin(now * BUZZ_SPEED))
	end
	return math.clamp(alpha, 0, MAX)
end

return TitleFlicker
