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

local Enums = require(script.Parent.Parent.Enums)
local PassConfig = require(script.Parent.PassConfig)
local WeaponConfig = require(script.Parent.WeaponConfig)

export type Reward = {
	dollars: number?,
	xp: number?,
	scrip: number?,
	--[[ Pass IDS, not weapon ids. A code that handed over four weapon names
	     would drift the day the pack grows a fifth; handing over the PASS means
	     a redeemer owns whatever the pack contains, the same as somebody who
	     paid for it. See ProfileService.unlockedSet. ]]
	passes: { string }?,
	--[[
		WEAPON ids, and the exception to the rule above.

		A pack is a bundle whose contents may grow, so a code hands over the pass
		and the redeemer gets whatever it later contains. A one-off weapon is not
		a bundle and has nothing to be a member of — inventing a pass for it would
		mean a storefront row for something that is not for sale, and a Robux price
		on a gift.

		Every id here must be a WeaponConfig weapon marked `codeOnly = true`, and
		audit.py check 16 fails the build both ways round: a code granting a weapon
		that is not codeOnly, and a codeOnly weapon no code grants.
	]]
	weapons: { string }?,
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
	--[[
		Who is allowed to type it, by Roblox UserId. Absent means anybody.

		── ABSENT AND EMPTY MEAN OPPOSITE THINGS, ON PURPOSE ───────────────────
		Nil is "this code is not restricted" — the ordinary case, and what every
		public code wants. An empty TABLE is "restricted to nobody", and it
		refuses everyone rather than letting everyone through.

		That asymmetry is the whole safety property. A restricted code is
		restricted because it is a gift or a prize, and the failure that matters
		is not somebody being wrongly refused — they can be told — it is the gift
		quietly becoming public because a list was left half-written. So the
		half-written state is the locked one.

		UserId rather than username, and that is not a preference. A Roblox
		username can be changed, and a name-matched grant would stop recognising
		its own owner the day they changed it — silently, months later, with the
		code long expired and no way to re-issue it. A UserId is permanent.
	]]
	allowedUserIds: { number }?,
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
	{
		--[[
			A birthday present, and the only code in this game addressed to one
			person.

			Everything unusual about it is in service of that. It has no window,
			because a gift that expires is a gift you can lose by being asleep. It
			is restricted by UserId, because it is his. And it grants a WEAPON
			rather than a pass, because there is no bundle for a single gun to be
			a member of and inventing one would have put a Robux price on a
			present.

			More rewards are coming — see the reward table, which is the only part
			that needs editing to add them.
		]]
		code = "DAVIS-13TH",
		displayName = "DAVIS 13TH",
		blurb = "Happy birthday. The walrus is loaded.",
		--[[ No window, both ends. Deliberate rather than forgotten, which is
		     exactly the case this file's own type comment says has to be written
		     down rather than fallen into: a present should still be there
		     whenever he gets round to typing it. ]]
		startsAt = 0,
		endsAt = 0,
		--[[ Hawkhoop3. A UserId rather than the name, so a rename cannot quietly
		     take his own present away from him — see the field. ]]
		allowedUserIds = { 3170573678 },
		reward = {
			weapons = { Enums.Weapon.RPG7WalrusSpec },
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

--[[
	Whether this player is allowed to type this code at all.

	Reads the ID and nothing else. A username would be the obvious thing to
	compare and it is the wrong one twice over: it can be changed, and it arrives
	as a string that has to be matched case-insensitively against something a
	player could be persuaded to imitate. A UserId is a number the client does
	not choose.

	Absent list means an ordinary public code. Present list means the code is
	addressed to somebody, and an EMPTY one refuses everybody — see the field for
	why that direction is the safe one.
]]
function CodeConfig.allows(code: Code, userId: any): boolean
	local allowed = code.allowedUserIds
	if allowed == nil then
		return true
	end
	if typeof(userId) ~= "number" then
		return false
	end
	for _, id in allowed do
		if id == userId then
			return true
		end
	end
	return false
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
	--[[ Before the currencies, because a weapon is the headline of any code that
	     carries one and a dollar figure is not. ]]
	if reward.weapons then
		for _, weaponId in reward.weapons do
			local definition = WeaponConfig.get(weaponId)
			table.insert(
				parts,
				if definition then string.upper(definition.displayName) else string.upper(weaponId)
			)
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
