--!strict
--[[
	PressureValve — a needle sweeping a gauge, a green band, and one button.

	The reflex one, and the only one of the five that gets HARDER rather than
	longer: three stages, the band narrowing each time and the needle speeding
	up. That shape matters in a pack of five — four puzzles that are all "read
	this, then press in order" make the generator run feel like paperwork, and
	one that is a held breath in the middle of a horde is what stops it.

	── ONE BUTTON, WHICH IS THE POINT ──────────────────────────────────────────
	Every scheme in the game can press one button quickly. This is the puzzle
	that works identically with a mouse, a thumb and a pad face button, and it
	is here partly because the other four are all about reading a layout — which
	is the thing a phone screen is worst at.

	── THE BANDS ARE PUBLIC ────────────────────────────────────────────────────
	They are drawn on the gauge. There is nothing to hide: the player is aiming
	at a green stripe they can see, and the difficulty is entirely in the timing.
	So `solution` is the same three bands the challenge carries, and the check is
	"was the needle inside it" rather than "did they know where it was".

	The needle itself is animated on the CLIENT and the position it stopped at
	comes back up. A crafted client can therefore always stop it perfectly — and
	that is the correct trade, for the reason GeneratorConfig's header gives:
	what the server refuses to accept from anyone is a generator powered out of
	turn, powered from across the map, or a gate opened without five of them.
	Auto-solving a reflex test in your own team's round costs the other three
	players nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GeneratorConfig = require(Shared.Config.GeneratorConfig)

local PressureValve = {}

PressureValve.Kind = GeneratorConfig.Kind.PressureValve

local SPAN = GeneratorConfig.GaugeSpan

--[[ Three stages, and the numbers that make them a ramp. Widths are out of a
     thousand: 210 is about a fifth of the gauge and generous, 90 is a tenth and
     is the one that costs a player a second attempt.

     Sweeps are in full traversals per second. The last stage is a little over
     twice the speed of the first, which with less than half the band is the
     difference between "press when it is near" and "press when it is there". ]]
local STAGES = table.freeze({
	table.freeze({ width = 210, sweep = 0.62 }),
	table.freeze({ width = 145, sweep = 0.86 }),
	table.freeze({ width = 95, sweep = 1.2 }),
})

--[[ How far from either end a band is allowed to sit. The needle REVERSES at
     the ends, so it spends measurably longer near them than it does in the
     middle — a band jammed against the edge is a free stage, and one just
     inside the turn is a cruel one because the needle crosses it twice in
     quick succession. Keeping every band clear of both ends makes all three
     stages the same test at three difficulties. ]]
local EDGE = 90

export type Deal = { kind: string, challenge: { [string]: any }, solution: { { low: number, high: number } } }

function PressureValve.deal(random: Random): Deal
	local stages = {}
	local bands: { { low: number, high: number } } = {}

	for _, stage in STAGES do
		local half = stage.width // 2
		--[[ The centre, kept a band's-worth clear of both ends. Clamped as well
		     as bounded, so a future stage wide enough to make the range empty
		     lands in the middle of the gauge rather than inverting the roll. ]]
		local lowest = math.min(EDGE + half, SPAN // 2)
		local highest = math.max(SPAN - EDGE - half, SPAN // 2)
		local centre = random:NextInteger(lowest, highest)

		local band = { low = centre - half, high = centre + half }
		table.insert(bands, band)
		table.insert(stages, {
			low = band.low,
			high = band.high,
			sweep = stage.sweep,
		})
	end

	return {
		kind = PressureValve.Kind,
		challenge = { stages = stages, span = SPAN },
		solution = bands,
	}
end

function PressureValve.check(deal: Deal, answer: { number }): boolean
	if #answer ~= #deal.solution then
		return false
	end
	for index, band in deal.solution do
		local at = answer[index]
		if typeof(at) ~= "number" or at ~= at then
			return false
		end
		if at < band.low or at > band.high then
			return false
		end
	end
	return true
end

return PressureValve
