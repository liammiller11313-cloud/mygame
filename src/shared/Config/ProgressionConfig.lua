--!strict
--[[
	ProgressionConfig — levels, Scrip, and the quests that pay them.

	Dollars are the ROUND economy: they come from what you did in the last
	seventeen minutes and they buy the guns you carry into the next seventeen.
	EconomyConfig owns that and it is a closed loop — a player who has bought the
	roster has finished it.

	This is the other axis. Experience never resets, never gets spent, and cannot
	be bought; it is the record of everything you have ever done here. Levelling
	pays SCRIP, and Scrip is the only thing the battle pass takes.

	Keeping them apart is the whole design. If levelling paid Dollars it would
	just be a slower shop; if the pass took Dollars it would compete with the guns
	and a player would be punished for buying a rifle. Two currencies, two jobs,
	one of them finite and one of them not.

	── WHY SCRIP ───────────────────────────────────────────────────────────────
	Scrip is what a garrison prints when the banks are gone: paper that is only
	worth anything because the people still standing agree it is. It reads as
	something issued rather than found, which is exactly the difference from the
	Dollars you loot off a corpse.

	── THE NUMBERS ARE DERIVED, NOT PICKED ─────────────────────────────────────
	scripts/economy.py already models a round: 412 Commons, 12 specials, 2.8
	bosses, about a quarter of them headshots, fifteen waves. Every figure below was
	chosen against that round so the curve says something true:

	    a won round        3,346 XP
	    levels 1 to 5      0.6 won rounds — inside the first session
	    level 10           2.3 won rounds
	    level 20           9.1 won rounds, and 0.93 of a round for that level alone
	    level 50           56 won rounds, 2.3 a level

	Fast at the start because the first session has to feel like it is going
	somewhere, and slow later because a number that never slows is a number nobody
	believes.

	Those figures are printed by scripts/economy.py, off this file and the same
	round model the Dollars economy is checked against — so a change here that
	quietly makes level 20 a fortnight away shows up in the same run that catches
	a weapon price nobody can afford. They are not a comment somebody has to
	remember to update.

	── AND THE PASS ────────────────────────────────────────────────────────────
	The whole track is 3,080 Scrip. Levelling alone pays that by level 71; three
	dailies a day pay it in 19. Neither route is meant to be the one — somebody who plays a lot gets there on levels, somebody who plays a
	little gets there on dailies, and most people arrive on a mix a good while
	before either number alone would say.
]]

local ProgressionConfig = {}

--[[ What it is called everywhere a player can read it. One place, because a
     currency named in six files gets renamed in five. ]]
ProgressionConfig.CurrencyName = "SCRIP"
ProgressionConfig.CurrencySymbol = "◈"

--[[ A ceiling, for the same reason EconomyConfig has one: DataStore values are
     JSON, and a number that has been corrupted into something enormous should be
     clamped on the way in rather than written back out. Not a balance number. ]]
ProgressionConfig.MaxLevel = 200
ProgressionConfig.MaxScrip = 9_999_999
ProgressionConfig.MaxXp = 999_999_999

-- ── experience ──────────────────────────────────────────────────────────────

--[[
	What each thing you did in a round is worth.

	Read off StatsService's own snapshot at round end rather than counted here —
	those numbers are already computed for the scoreboard, and a second tally
	would be a second thing to get wrong. That also means XP can only ever reward
	something the game already thought was worth counting.

	Deliberately NOT paid per damage dealt. Damage rewards emptying a magazine
	into a Tank somebody else was about to kill; kills, revives and waves reward
	finishing things, which is the same principle EconomyConfig protects when it
	pays more for surviving a round than for shooting during one.
]]
ProgressionConfig.Xp = table.freeze({
	Common = 4,
	Special = 25,
	Boss = 120,
	--[[ On top of the kill, not instead of it. Small on purpose: it should be
	     worth aiming for and it must not turn levelling into a marksmanship
	     score, which is the same rule EconomyConfig.HeadshotBonus follows. ]]
	Headshot = 2,
	--[[ The one number here that is not about killing. Worth ten Commons, because
	     picking a teammate up under pressure is worth more than ten Commons and
	     the progression should say so out loud. ]]
	Revive = 40,
	--[[ 28, down from 60, when the round went from seven waves to fifteen. Paid
	     per wave reached, so the wave count multiplies it directly: 7 x 60 was
	     420 XP a round and 15 x 60 would have been 900, which is a fifth of a
	     won round's XP arriving because the schedule was cut into more pieces.
	     15 x 28 is 420 — the same round, worth the same. The same correction
	     applies to EconomyConfig.WaveBonus for the same reason. ]]
	WaveReached = 28,
	Victory = 400,
})

--[[
	What the NEXT level costs, at the level you are now.

	Linear step, which makes the running total quadratic — the standard shape,
	and the one players read as "steady" rather than as a wall. Base 250 puts the
	first level-up inside the first few minutes of the first round, which is the
	single most important moment this system has: a player who levels before they
	have finished their first match knows the system exists.

	Clamped at MaxLevel, where it returns 0 — a finished curve should report that
	nothing more is owed rather than an ever-growing number nobody can reach.
]]
ProgressionConfig.XpBase = 250
ProgressionConfig.XpStep = 150

function ProgressionConfig.xpForLevel(level: number): number
	local clean = math.max(math.floor(level), 1)
	if clean >= ProgressionConfig.MaxLevel then
		return 0
	end
	return ProgressionConfig.XpBase + ProgressionConfig.XpStep * (clean - 1)
end

--[[
	Total XP, resolved into a level and the progress through it.

	One function, used by the server to award and by the client to draw, so the
	bar on screen and the level in the profile can never disagree about what a
	number means. Returns level, xp into the current level, and what the current
	level costs — the three things a progress bar needs and nothing else.

	Loops rather than solving the quadratic: MaxLevel is 200, this runs at a
	level-up and when a menu opens, and a closed form would be a clever line
	nobody can check against the table above.
]]
function ProgressionConfig.resolve(totalXp: number): (number, number, number)
	local remaining = math.max(math.floor(totalXp), 0)
	local level = 1
	while level < ProgressionConfig.MaxLevel do
		local cost = ProgressionConfig.xpForLevel(level)
		if remaining < cost then
			return level, remaining, cost
		end
		remaining -= cost
		level += 1
	end
	return ProgressionConfig.MaxLevel, 0, 0
end

-- ── Scrip ───────────────────────────────────────────────────────────────────

--[[
	What a level pays.

	Levelling is the ONLY source of Scrip that is not a quest, which is what makes
	the level number worth caring about beyond bragging: it is the rate at which
	the pass unlocks. Every fifth level pays the milestone on top, so the curve
	has a shape a player can feel rather than a flat drip.
]]
ProgressionConfig.ScripPerLevel = 25
ProgressionConfig.ScripMilestone = 100
ProgressionConfig.MilestoneEvery = 5

function ProgressionConfig.scripForLevel(level: number): number
	local clean = math.max(math.floor(level), 1)
	local paid = ProgressionConfig.ScripPerLevel
	if clean % ProgressionConfig.MilestoneEvery == 0 then
		paid += ProgressionConfig.ScripMilestone
	end
	return paid
end

-- ── quests ──────────────────────────────────────────────────────────────────

export type Quest = {
	id: string,
	text: string,
	--[[ Which field of StatsService's snapshot this counts. `wave` and `victory`
	     are the two that do not come from there; see ProgressionService. ]]
	stat: string,
	target: number,
	xp: number,
	scrip: number,
}

--[[
	The pool three daily quests are drawn from.

	Every one of them counts something StatsService already tracks, which is not a
	coincidence — it is the constraint the pool was written against. A quest that
	needs new bookkeeping is a quest that can silently stop counting, and the
	first thing a player does with a progress bar that has stopped is assume the
	whole system is fake.

	Deliberately spread across the verbs. A pool of nothing but kill counts pays
	the player who was already going to do that; "revive four teammates" and
	"survive to wave eleven" are the ones that change how somebody plays a round,
	and they are the reason this is a quest system rather than a second XP table.
]]
local QUEST_POOL: { Quest } = table.freeze({
	table.freeze({
		id = "commons150",
		--[[ Says "Infected", not "Common Infected". StatsService's `kills` is the
		     total — a special dying bumps `kills` AND `specialKills` — so a quest
		     promising commons would tick on a Hunter and read as broken. ]]
		text = "Put down 150 Infected",
		stat = "kills",
		target = 150,
		xp = 300,
		scrip = 40,
	}),
	table.freeze({
		id = "heads60",
		text = "Land 60 headshots",
		stat = "headshots",
		target = 60,
		xp = 300,
		scrip = 40,
	}),
	table.freeze({
		id = "specials8",
		text = "Kill 8 Special Infected",
		stat = "specialKills",
		target = 8,
		xp = 350,
		scrip = 50,
	}),
	table.freeze({
		id = "bosses2",
		text = "Bring down 2 bosses",
		stat = "bossKills",
		target = 2,
		xp = 450,
		scrip = 60,
	}),
	table.freeze({
		id = "revive4",
		text = "Get 4 teammates back on their feet",
		stat = "revives",
		target = 4,
		xp = 300,
		scrip = 50,
	}),
	table.freeze({
		--[[ Eleven of fifteen, which is where "reach wave 5" landed when the
		     round was seven waves long: about seventy per cent of the way, far
		     enough that a team has to actually hold out and not so far that only
		     a win counts. Rescaled with the schedule rather than left at 5,
		     which fifteen waves would have turned into a participation prize. ]]
		id = "wave11",
		text = "Reach wave 11",
		stat = "wave",
		target = 11,
		xp = 400,
		scrip = 60,
	}),
	table.freeze({
		id = "win1",
		text = "Survive a whole round",
		stat = "victory",
		target = 1,
		xp = 500,
		scrip = 75,
	}),
})

ProgressionConfig.QuestPool = QUEST_POOL

ProgressionConfig.DailyQuests = 3

--[[ Seconds in the day a quest set lives for. A real day rather than a session:
     the point of a daily is that it is still there tomorrow and gone the day
     after, which is what makes finishing one feel like catching something. ]]
ProgressionConfig.QuestPeriod = 86_400

--[[
	Which three quests today is, from the day number alone.

	Derived rather than rolled, so every server in the world agrees without any
	coordination, and a player who rejoins gets the same three they left. The day
	number is os.time() // QuestPeriod, which is the same integer everywhere.

	A stride coprime with the pool size walks the whole list before repeating, so
	consecutive days do not hand out overlapping sets — with a plain `day + i` the
	three quests would shift by one each day and two of them would always be
	yesterday's.
]]
--[[ The smallest step above 1 that is coprime with the pool size.

     A stride sharing a factor with the count walks a sub-cycle and never
     reaches the rest of the pool: with 6 quests and a stride of 2 the odd
     indices are unreachable, and three of the six could never be handed out.
     Searched rather than hard-coded because the pool is a list somebody will
     add to, and the day it grows to 6 or 9 entries is not the day to discover
     that a constant chosen against 7 was load-bearing. ]]
local function strideFor(count: number): number
	for candidate = 2, math.max(count - 1, 2) do
		local a, b = candidate, count
		while b ~= 0 do
			a, b = b, a % b
		end
		if a == 1 then
			return candidate
		end
	end
	return 1
end

function ProgressionConfig.questsForDay(day: number): { Quest }
	local pool = ProgressionConfig.QuestPool
	local count = #pool
	local wanted = math.min(ProgressionConfig.DailyQuests, count)
	local picked: { Quest } = {}
	local stride = strideFor(count)

	--[[
		ONE cursor across all days, advancing `stride` per pick.

		The obvious version — base at `day * wanted`, offsets at `i * stride` —
		is the version that was here, and it is wrong in a way that only shows up
		on the second day: the base moves 3 and the picks are 3 apart, so two of
		tomorrow's three are two of today's. Against a 7-entry pool it repeats
		{0,3,6} → {2,3,6} → {2,5,6}, which is a rotation that mostly does not
		rotate.

		Multiplying the whole cursor by the stride is what fixes it. Consecutive
		days then share nothing, because the day advances the cursor by
		`wanted * stride` and no pick offset within a day is congruent to that.
	]]
	for i = 0, wanted - 1 do
		local index = (((math.floor(day) * wanted + i) * stride) % count) + 1
		table.insert(picked, pool[index])
	end
	return picked
end

--[[ One quest by id, or nil. Used when a saved progress table names a quest that
     may no longer be in the pool. ]]
function ProgressionConfig.getQuest(id: string): Quest?
	for _, quest in ProgressionConfig.QuestPool do
		if quest.id == id then
			return quest
		end
	end
	return nil
end

-- ── the pass ────────────────────────────────────────────────────────────────

--[[
	What Scrip is FOR.

	A currency with nothing to buy is a number, and a number is not a reward. The
	pass is the PERMANENT sink — the thing Scrip accumulates toward across
	sessions — and it was the only one when this was written.

	Requisitions are the second, and they are a different shape rather than a
	contradiction: bought mid-round, spent immediately, gone when the round ends.
	Some of them DO change how a gun behaves for that round — the field drill
	reloads everyone a quarter faster, incendiary rounds set the horde alight —
	so the claim below that Scrip never touches combat is true of the pass and
	false of the catalogue. Scrip still cannot become Dollars and still buys
	nothing in the shop.

	── WHY NOTHING HERE AFFECTS COMBAT ─────────────────────────────────────────
	Every reward is a name or a colour. That is not modesty about the art budget;
	it is the one rule that keeps this system from becoming a second balance
	problem. A pass that paid damage would mean the player who has been here
	longest shoots harder, and every number EconomyConfig protects would have to
	be re-derived against "how far into the pass are they". A pass that paid
	Dollars would print money into a loop that scripts/economy.py says has no
	headroom left.

	So it pays identity. Your callsign sits under your name on the menu and beside
	you on the scoreboard; your accent is the colour that name is drawn in. Both
	are things other people see, which is the only kind of cosmetic that is
	actually worth anything.

	── SEQUENTIAL, NOT A SHOP ──────────────────────────────────────────────────
	Tier 7 cannot be bought before tier 6. A track that could be cherry-picked is
	a shop with extra steps, and the cheapest interesting item would be the only
	one anybody bought. Going in order is what makes the number on the track mean
	something when somebody else reads it.
]]

--[[ What a tier costs, at that tier. Linear, so the total to finish the track is
     quadratic and the last few tiers are the ones you have to want. Base 40 is
     under two levels' Scrip, so the first tier lands in the first session. ]]
ProgressionConfig.PassCostBase = 40
ProgressionConfig.PassCostStep = 12

function ProgressionConfig.passCost(tier: number): number
	local clean = math.floor(tier)
	if clean < 1 or clean > #ProgressionConfig.PassTrack then
		return 0
	end
	return ProgressionConfig.PassCostBase + ProgressionConfig.PassCostStep * (clean - 1)
end

export type PassTier = {
	--[[ "Callsign" or "Accent". Two kinds rather than one list of things,
	     because they are worn in different places and a screen drawing the track
	     has to know which preview to show. ]]
	kind: string,
	id: string,
	label: string,
	--[[ Accent tiers only. The colour the player's name is drawn in. ]]
	color: Color3?,
}

--[[
	The track, in order. Index IS the tier.

	Alternating on purpose. Two callsigns in a row means the second one replaces
	the first before it has been worn, and the reward for the second is that
	nothing visible changed.
]]
local PASS_TRACK: { PassTier } = table.freeze({
	table.freeze({ kind = "Callsign", id = "survivor", label = "SURVIVOR" }),
	table.freeze({ kind = "Accent", id = "ash", label = "ASH", color = Color3.fromRGB(196, 196, 188) }),
	table.freeze({ kind = "Callsign", id = "scavenger", label = "SCAVENGER" }),
	table.freeze({ kind = "Accent", id = "rust", label = "RUST", color = Color3.fromRGB(168, 84, 42) }),
	table.freeze({ kind = "Callsign", id = "steady", label = "STEADY HAND" }),
	table.freeze({ kind = "Accent", id = "bile", label = "BILE", color = Color3.fromRGB(124, 168, 54) }),
	table.freeze({ kind = "Callsign", id = "medic", label = "FIELD MEDIC" }),
	table.freeze({ kind = "Accent", id = "ember", label = "EMBER", color = Color3.fromRGB(230, 122, 48) }),
	table.freeze({ kind = "Callsign", id = "headhunter", label = "HEADHUNTER" }),
	table.freeze({ kind = "Accent", id = "iron", label = "COLD IRON", color = Color3.fromRGB(126, 150, 168) }),
	table.freeze({ kind = "Callsign", id = "tankkiller", label = "TANK KILLER" }),
	table.freeze({
		kind = "Accent",
		id = "arterial",
		label = "ARTERIAL",
		color = Color3.fromRGB(186, 44, 44),
	}),
	table.freeze({ kind = "Callsign", id = "holdfast", label = "HOLD FAST" }),
	table.freeze({ kind = "Accent", id = "sodium", label = "SODIUM", color = Color3.fromRGB(240, 186, 92) }),
	table.freeze({ kind = "Callsign", id = "quarantine", label = "QUARANTINE" }),
	table.freeze({
		kind = "Accent",
		id = "blackout",
		label = "BLACKOUT",
		color = Color3.fromRGB(96, 92, 104),
	}),
	table.freeze({ kind = "Callsign", id = "nightshift", label = "NIGHT SHIFT" }),
	table.freeze({ kind = "Accent", id = "hazard", label = "HAZARD", color = Color3.fromRGB(232, 208, 74) }),
	table.freeze({ kind = "Callsign", id = "holdout", label = "THE HOLDOUT" }),
	table.freeze({
		kind = "Accent",
		id = "fading",
		label = "FADING LIGHT",
		color = Color3.fromRGB(246, 238, 214),
	}),
})

ProgressionConfig.PassTrack = PASS_TRACK

--[[ Everything a player who has claimed up to `tier` may wear. Returned as two
     lists rather than one, because the menu offers them as two choices — a
     callsign and an accent are worn at the same time, not instead of each
     other. ]]
function ProgressionConfig.unlockedRewards(tier: number): ({ PassTier }, { PassTier })
	local callsigns: { PassTier } = {}
	local accents: { PassTier } = {}
	local claimed = math.clamp(math.floor(tier), 0, #PASS_TRACK)
	for index = 1, claimed do
		local reward = PASS_TRACK[index]
		if reward.kind == "Accent" then
			table.insert(accents, reward)
		else
			table.insert(callsigns, reward)
		end
	end
	return callsigns, accents
end

--[[ A reward by kind and id, or nil. Used when a saved profile names a callsign
     or accent the track no longer carries — see ProfileService.migrate, which
     drops rather than keeps anything this cannot resolve. ]]
function ProgressionConfig.getReward(kind: string, id: string): PassTier?
	for _, reward in PASS_TRACK do
		if reward.kind == kind and reward.id == id then
			return reward
		end
	end
	return nil
end

--[[ Which tier a reward sits at, so a claim check can ask "is this behind the
     tier they have paid for" without the caller walking the track itself. ]]
function ProgressionConfig.rewardTier(kind: string, id: string): number
	for index, reward in PASS_TRACK do
		if reward.kind == kind and reward.id == id then
			return index
		end
	end
	return 0
end

return table.freeze(ProgressionConfig)
