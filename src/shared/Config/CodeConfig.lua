--!strict
--[[
	CodeConfig — redeemable codes, and when they are worth anything.

	── TIME IS UTC, ALWAYS, AND ONLY THE SERVER READS IT ────────────────────────
	Windows are stored as UTC epoch seconds and compared against `os.time()` on
	the server. Not because UTC is tidy, but because every other option is a bug:
	a client's clock is a thing the player can set, and a "local time" window is
	a different window for every player in the server.

	The comment beside each window says what it means in the timezone it was
	written for. That comment is the only place the intent survives — the number
	is unreadable and will be wrong one day, and somebody will need to know what
	it was supposed to say.

	── A CODE IS NOT A SECRET ───────────────────────────────────────────────────
	This file is shared, so a determined player can read the strings out of the
	client. That is fine and is how every game with codes works: the value is in
	the WINDOW and the one-per-account rule, both of which the server owns, not
	in the string being unguessable. What must never live here is anything that
	decides whether a redemption is allowed — see CodeService.
]]

local PassConfig = require(script.Parent.PassConfig)

export type Reward = {
	dollars: number?,
	xp: number?,
	scrip: number?,
	--[[ Pass IDS, not weapon ids. A code that handed over four weapon names
	     would drift the day the pack grows a fifth; handing over the PASS means
	     a redeemer owns whatever the pack contains, the same as somebody who
	     paid for it. See ProfileService.unlockedSet. ]]
	passes: { string }?,
}

export type Code = {
	code: string, -- compared uppercased and trimmed; see CodeConfig.normalise
	displayName: string,
	blurb: string,
	--[[ 0 for either end means "no bound that side". A code with both zero is
	     always live, which is a legitimate thing to want and a dangerous default
	     — so it has to be written rather than fallen into. ]]
	startsAt: number,
	endsAt: number,
	reward: Reward,
}

local CodeConfig = {}

CodeConfig.Codes = table.freeze({
	{
		code = "OG-BRICKBATTLE",
		displayName = "OG BRICKBATTLE",
		blurb = "Brickbattler's Pack, free, for anybody who was there.",
		--[[
			2026-09-10, 17:00–19:00 US Central (CDT, UTC-5).
			Which is 22:00 UTC on the 10th to 00:00 UTC on the 11th — and that
			is the two numbers below.

			── THE WINDOW CROSSES MIDNIGHT UTC, AND THAT IS NOT A TYPO ─────────
			This comment used to say the arithmetic was "(local hour + 5) on the
			same day", which was true of a window that closed at 18:00 local and
			is false of this one: 19:00 + 5 is 24, so the close is 00:00 on the
			ELEVENTH. A future editor following the old rule would write the
			10th, and the code would have expired an hour before anybody could
			type it — on the one night it exists.

			So: convert BOTH ends to UTC independently and let the date fall
			where it falls. Add 5 in September while CDT is in effect, 6 once
			CST returns in November, and never assume the two ends share a day.
		]]
		startsAt = 1789077600,
		endsAt = 1789084800,
		reward = {
			passes = { "BrickbattlersPack" },
			dollars = 250,
		},
	},
} :: { Code })

local byCode: { [string]: Code } = {}

--[[ How a typed string becomes a key. Uppercased and stripped of everything
     that is not a letter, a digit or a dash, so "og brickbattle",
     " OG-Brickbattle " and "ogbrickbattle" all land on the same code.

     Deliberately forgiving. A player who typed the code correctly and got
     REJECTED because of a trailing space learns that codes do not work, and
     tells other people so. ]]
function CodeConfig.normalise(input: any): string
	if typeof(input) ~= "string" then
		return ""
	end
	local upper = string.upper(input)
	local cleaned = string.gsub(upper, "[^%u%d%-]", "")
	return cleaned
end

for _, entry in CodeConfig.Codes do
	byCode[CodeConfig.normalise(entry.code)] = entry
end

function CodeConfig.get(input: any): Code?
	local key = CodeConfig.normalise(input)
	if key == "" then
		return nil
	end
	return byCode[key]
end

--[[ Whether `code` is live at `now`, which is always a SERVER os.time(). Split
     out from the redemption path so the boot report can state the window in
     words without duplicating the comparison. ]]
function CodeConfig.isLive(code: Code, now: number): boolean
	if code.startsAt > 0 and now < code.startsAt then
		return false
	end
	if code.endsAt > 0 and now > code.endsAt then
		return false
	end
	return true
end

--[[ What a reward gives, in the player's words. Built from the same table the
     granting reads, so the confirmation a player sees cannot describe something
     they did not get. ]]
function CodeConfig.describe(reward: Reward): string
	local parts: { string } = {}
	if reward.passes then
		for _, passId in reward.passes do
			local pass = PassConfig.get(passId)
			table.insert(parts, if pass then pass.displayName else string.upper(passId))
		end
	end
	if reward.dollars and reward.dollars > 0 then
		table.insert(parts, string.format("$%d", reward.dollars))
	end
	if reward.scrip and reward.scrip > 0 then
		table.insert(parts, string.format("%d SCRIP", reward.scrip))
	end
	if reward.xp and reward.xp > 0 then
		table.insert(parts, string.format("%d XP", reward.xp))
	end
	if #parts == 0 then
		return "NOTHING"
	end
	return table.concat(parts, "  +  ")
end

return CodeConfig
