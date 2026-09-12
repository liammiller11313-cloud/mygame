--!strict
--[[
	GameModeConfig — the round structure.

	Fading Light is not a campaign game. There are no safe rooms and no chapters.
	A round is a fixed 17 minutes of holding out against fifteen escalating waves,
	and the only question is whether the team is still standing at the end.

	That changes what the AI Director is for. In Left 4 Dead the Director decides
	WHEN pressure happens; here the wave schedule decides when, and the Director
	decides WHAT and HOW MUCH inside each wave. It still reads team intensity, it
	still refuses to spawn in someone's field of view, it still places items based
	on how badly the team is hurting — but it works inside a wave's budget rather
	than inventing its own pacing from nothing.

	The breather between waves is not dead time. It is the whole reason the next
	wave lands: a team that never gets to heal, reload and regroup stops being
	scared and starts being numb.
]]

local Enums = require(script.Parent.Parent.Enums)

local GameModeConfig = {}

GameModeConfig.Modes = table.freeze({
	Classic = "Classic",
	Versus = "Versus",
})

GameModeConfig.DefaultMode = GameModeConfig.Modes.Classic

export type WaveDefinition = {
	index: number,
	name: string,
	duration: number, -- seconds the wave stays active
	breather: number, -- seconds of calm after it, before the next one
	populationScale: number, -- multiplier on the Director's common-infected target
	spawnRateScale: number, -- multiplier on how fast they arrive
	maxSpecialsAlive: number,
	specialInterval: number, -- seconds between special spawns during this wave
	bosses: { string }, -- boss kinds released when the wave starts
	--[[ An InfectedConfig.EliteTiers id applied to every boss this wave releases,
	     or nil for ordinary ones. The finale's Tank is the only user. ]]
	bossTier: string?,
	--[[ What this wave MAY send instead of what `bosses` names, and how often it
	     does. Empty or nil means the wave always sends exactly what it declares.
	     See GameModeConfig.rollBosses — the roll happens once, at the top of the
	     wave, and the callout is spoken from its result. ]]
	bossPool: { string }?,
	bossPoolChance: number?,
	--[[ Whether a Tank this wave releases may bring company. Off unless a wave
	     says otherwise, because the wave that teaches the Tank must send exactly
	     one — see the pack notes below GameModeConfig.Waves. ]]
	bossPack: boolean?,
	itemDropChance: number, -- odds the breather after this wave restocks the map
	announcement: string,
}

--[[
	Fifteen waves totalling exactly 17:00 including the opening prep window.

	  prep 15s + waves 830s + breathers 175s = 1020s

	── WHY FIFTEEN AND NOT SEVEN ───────────────────────────────────────────────
	The round used to be seven long waves. Same seventeen minutes, same total
	horde, but the shape was wrong for what this game actually is: a wave-defence
	round where the number on the screen IS the score. Seven of anything does not
	feel like an achievement to count through, and a 180-second wave is long
	enough that a team stops experiencing it as a wave at all — it becomes
	weather.

	Fifteen short waves fix both. A wave is now 36 to 62 seconds with a 10-to-15
	second breather behind it, so the cycle of "brace, fight, breathe, brace"
	runs fifteen times instead of seven and the count climbs fast enough to be
	worth watching. Nothing about the total pressure changed: the population
	curve is the same weighted average across the same 830 seconds of fighting,
	so a round still costs the same ammunition and pays the same money. It is the
	same round with more punctuation.

	The breathers are shorter than they were, and that is the one real trade.
	Ten seconds is enough to reload, take pills and pick somebody up; it is not
	enough to walk somewhere else and heal. That is on purpose — the breather
	still exists to make the next wave land, and at fifteen waves it has to do
	that job without adding five minutes to the round.

	── THE SHAPE ───────────────────────────────────────────────────────────────
	  1-4    teach. No specials at all for the first two; one from wave 3.
	  5      the first Tank, and the first time the team has to move as a unit.
	  6-7    the aftermath, and the first waves that do not let up.
	  8      the Witch, on top of a horde: something to fear that is not a
	         bullet sponge.

	Bosses land on 5, 8, 11 and 15 — one every three waves.
	  9-14   the long climb. A second Tank at 11 and, by 14, four specials alive
	         at once. Thirteen is where the light finally goes.
	  15     the finale. One Tank, but not one of THOSE Tanks — see
	         `bossTier` and InfectedConfig.EliteTiers. 144 seconds, the longest
	         wave in the round by a factor of two, and the honest expectation is
	         that most teams die on it.
]]
GameModeConfig.Waves = {
	{
		index = 1,
		name = "First Contact",
		duration = 36,
		breather = 10,
		populationScale = 0.50,
		spawnRateScale = 0.75,
		maxSpecialsAlive = 0,
		specialInterval = 0,
		bosses = {},
		itemDropChance = 0.30,
		announcement = "THEY'RE COMING",
	},
	{
		index = 2,
		name = "Stirring",
		duration = 38,
		breather = 10,
		populationScale = 0.58,
		spawnRateScale = 0.80,
		maxSpecialsAlive = 0,
		specialInterval = 0,
		bosses = {},
		itemDropChance = 0.35,
		announcement = "MORE OF THEM",
	},
	{
		index = 3,
		name = "Spreading",
		duration = 40,
		breather = 12,
		populationScale = 0.66,
		spawnRateScale = 0.85,
		maxSpecialsAlive = 1,
		specialInterval = 40,
		bosses = {},
		itemDropChance = 0.40,
		announcement = "THEY KNOW WHERE YOU ARE",
	},
	{
		index = 4,
		name = "Swarm",
		duration = 42,
		breather = 12,
		populationScale = 0.74,
		spawnRateScale = 0.90,
		maxSpecialsAlive = 1,
		specialInterval = 36,
		bosses = {},
		itemDropChance = 0.45,
		announcement = "HOLD THE LINE",
	},
	{
		index = 5,
		name = "Heavy",
		duration = 44,
		breather = 12,
		populationScale = 0.82,
		spawnRateScale = 0.95,
		maxSpecialsAlive = 2,
		specialInterval = 32,
		bosses = { Enums.Infected.Tank },
		itemDropChance = 0.70,
		announcement = "TANK INBOUND",
	},
	{
		index = 6,
		name = "Aftermath",
		duration = 46,
		breather = 14,
		populationScale = 0.90,
		spawnRateScale = 1.00,
		maxSpecialsAlive = 2,
		specialInterval = 30,
		bosses = {},
		itemDropChance = 0.45,
		announcement = "KEEP MOVING",
	},
	{
		index = 7,
		name = "No Let Up",
		duration = 48,
		breather = 12,
		populationScale = 0.98,
		spawnRateScale = 1.05,
		maxSpecialsAlive = 2,
		specialInterval = 28,
		bosses = {},
		itemDropChance = 0.50,
		announcement = "NO LET UP",
	},
	{
		index = 8,
		name = "The Crying",
		duration = 50,
		breather = 12,
		populationScale = 1.06,
		spawnRateScale = 1.08,
		maxSpecialsAlive = 3,
		specialInterval = 26,
		bosses = { Enums.Infected.Witch },
		--[[ The first wave that lies about itself. Announcing "SOMETHING IS
		     CALLING THEM" and then sending a Tank is the point: this is where a
		     team learns the callout is the truth and the schedule is not. ]]
		bossPool = { Enums.Infected.Tank },
		bossPoolChance = 0.30,
		bossPack = true,
		itemDropChance = 0.60,
		announcement = "SOMETHING IS CALLING THEM",
	},
	{
		index = 9,
		name = "Cornered",
		duration = 52,
		breather = 14,
		populationScale = 1.14,
		spawnRateScale = 1.12,
		maxSpecialsAlive = 3,
		specialInterval = 26,
		bosses = {},
		itemDropChance = 0.50,
		announcement = "THEY HAVE THE STREETS",
	},
	{
		index = 10,
		name = "Overrun",
		duration = 54,
		breather = 14,
		populationScale = 1.22,
		spawnRateScale = 1.16,
		maxSpecialsAlive = 3,
		specialInterval = 24,
		bosses = {},
		itemDropChance = 0.55,
		announcement = "OVERRUN",
	},
	{
		index = 11,
		name = "Iron",
		duration = 56,
		breather = 12,
		populationScale = 1.30,
		spawnRateScale = 1.20,
		maxSpecialsAlive = 3,
		specialInterval = 24,
		bosses = { Enums.Infected.Tank },
		--[[ Three ways this wave can go, which is the most any wave gets. By
		     eleven the team has fought a Tank and a Witch and has a plan for
		     both; this is where the Metallic first turns up to spoil it. ]]
		bossPool = { Enums.Infected.Metallic, Enums.Infected.Witch },
		bossPoolChance = 0.40,
		bossPack = true,
		itemDropChance = 0.70,
		announcement = "ANOTHER ONE",
	},
	{
		index = 12,
		name = "Breaking",
		duration = 58,
		breather = 14,
		populationScale = 1.38,
		spawnRateScale = 1.24,
		maxSpecialsAlive = 4,
		specialInterval = 22,
		bosses = {},
		itemDropChance = 0.55,
		announcement = "IT IS NOT STOPPING",
	},
	{
		index = 13,
		name = "The Dark",
		duration = 60,
		breather = 12,
		populationScale = 1.46,
		spawnRateScale = 1.28,
		maxSpecialsAlive = 4,
		specialInterval = 20,
		--[[ No boss, deliberately. Bosses land on 5, 8, 11 and 15 — one every
		     three waves, which is a rhythm a team can feel coming — and thirteen
		     is where the map goes properly dark instead (see AtmosphereService).
		     The darkness is this wave's event; a Witch on top of it would be the
		     thing the team remembers and the dark would be scenery. ]]
		bosses = {},
		itemDropChance = 0.60,
		announcement = "THE LIGHTS ARE GOING",
	},
	{
		index = 14,
		name = "Everything",
		duration = 62,
		breather = 15,
		populationScale = 1.54,
		spawnRateScale = 1.32,
		maxSpecialsAlive = 4,
		specialInterval = 20,
		bosses = {},
		itemDropChance = 0.75,
		announcement = "EVERYTHING THEY HAVE LEFT",
	},
	{
		index = 15,
		name = "Last Light",
		duration = 144,
		breather = 0,
		populationScale = 1.70,
		spawnRateScale = 1.40,
		maxSpecialsAlive = 5,
		specialInterval = 16,
		bosses = { Enums.Infected.Tank },
		--[[ The wave the whole round is counting up to. Its Tank is spawned
		     through InfectedConfig.EliteTiers rather than as an ordinary one: same
		     creature, same tells, several times the health and the reach. ]]
		bossTier = "Apex",
		--[[ A coin flip for the last fight of the round. The substitute comes in
		     WITHOUT the Apex tier — see BossRelease — so the finale is either an
		     Apex Tank or a plain Metallic, and the two are meant to be about as
		     hard as each other by completely different routes. ]]
		bossPool = { Enums.Infected.Metallic },
		bossPoolChance = 0.50,
		itemDropChance = 0.00,
		announcement = "SURVIVE",
	},
} :: { WaveDefinition }

--[[
	── WHAT ACTUALLY WALKS IN ──────────────────────────────────────────────────

	The table above is the round's SHAPE: a boss lands on 5, 8, 11 and 15, and
	that rhythm is deliberate and fixed. What it does not decide any more is
	WHICH boss, or how many of it.

	Two rolls sit between the schedule and the spawn.

	SUBSTITUTION. From wave 8 on, a wave can send something other than what it
	declares. A team that has played four rounds knows a Tank is coming on 11;
	it should not also know it is a Tank. Wave 5 is exempt on purpose — the
	first boss of a player's first round teaches the Tank, and a fight you have
	to learn cannot be the fight you might not get.

	THE PACK. A Tank can arrive with company, and only a Tank: two Witches is
	two ambushes that do not interact, and two Metallics is two charge lanes
	through the same corridor, which is not a fight so much as a coin flip. Two
	Tanks is the one doubling that stays a fight, because the counter to a Tank
	is the team moving as a unit and a second one is what tests that.

	The pack is scaled by how many people are actually holding guns, not by the
	wave. Below three survivors it never fires at all: a second Tank on a duo is
	not harder, it is over. And it only fires on a wave that opted in with
	`bossPack`, which wave 5 does not: the first Tank of a player's first round
	is the one that teaches the fight, and you cannot learn it from two.
]]

--[[ humans -> { chance of a second Tank, chance of a third GIVEN a second }.
     Indices are clamped into range by rollBosses, so a five-player future or a
     zero-player edge case reads the nearest row rather than nil. ]]
GameModeConfig.TankPack = table.freeze({
	table.freeze({ 0.00, 0.00 }),
	table.freeze({ 0.00, 0.00 }),
	table.freeze({ 0.25, 0.00 }),
	table.freeze({ 0.35, 0.20 }),
})

export type BossRelease = {
	kind: string,
	--[[ An EliteTiers id or nil. Carried per release rather than per wave
	     because a SUBSTITUTE never inherits the wave's tier: the finale's Apex
	     multiplies health by three, which on a Tank is the finale and on a
	     Metallic is eighteen thousand health and a fight nobody finishes. The
	     bigger boss is already the escalation; it does not need the modifier
	     that exists to make the smaller one into one. ]]
	tier: string?,
}

--[[
	Turns a wave definition into the bosses this particular run of it releases.

	`promotion` is an EliteTiers id the caller wants applied to anything the wave
	has not already promoted — the ELITE WAVE modifier, in practice, and nil the
	rest of the time. It is taken as a parameter rather than applied to the result
	afterwards because the ORDER matters: a promoted boss does not get a pack, and
	a caller that promoted the list after this returned would hand a full team
	three Apex Tanks on one wave.

	`finale` is the map's own last-wave boss, or nil on every map but one. See
	inside: it applies to the final wave only, and it takes the pool and the tier
	with it.

	Pure apart from `rng`, which the caller supplies so a test can pin it. Never
	returns nil — a wave with no bosses returns an empty list — and never returns
	a kind the wave did not name, list in its pool, or that the map did not ask
	for by name.
]]
function GameModeConfig.rollBosses(
	wave: WaveDefinition,
	humans: number,
	rng: Random,
	promotion: string?,
	finale: string?
): { BossRelease }
	local releases: { BossRelease } = {}
	if not wave or typeof(wave.bosses) ~= "table" then
		return releases
	end

	local pool = wave.bossPool
	local poolChance = wave.bossPoolChance or 0

	--[[
		A map that ends on something of its own.

		`finale` is MapConfig.finaleBoss, passed down by the caller rather than
		looked up here — this file requires Enums and nothing else on purpose,
		and a config that reaches sideways into another config to answer a
		question about the round's shape is a config that has stopped being the
		round's shape.

		It applies on the LAST wave only, which is what "finale" means. A map's
		exclusive boss showing up on wave 8 would be the same creature three
		times a round and none of them special.

		It also switches OFF the substitution pool for that wave. A boss
		exclusive to a map is not exclusive if a coin flip can replace it with a
		Metallic, and wave 15's pool is a 50/50 by design.
	]]
	local override = if typeof(finale) == "string"
			and finale ~= ""
			and wave.index >= #GameModeConfig.Waves
		then finale
		else nil
	if override then
		pool = nil
		poolChance = 0
	end

	for _, declared in wave.bosses do
		local kind = if override then override else declared
		--[[ And it drops the wave's tier, for exactly the reason a substitute
		     does: Apex triples health because that is what turns a Tank into a
		     finale, and a creature that was authored AS one does not need
		     tripling. See BossRelease. ]]
		local tier = if override then nil else wave.bossTier

		if pool and #pool > 0 and poolChance > 0 and rng:NextNumber() < poolChance then
			kind = pool[rng:NextInteger(1, #pool)]
			if kind ~= declared then
				tier = nil
			end
		end

		--[[ The caller's promotion fills in for a wave that asked for no tier of
		     its own. Never the Metallic: it is already three times a Tank's
		     health before any multiplier, and tripling that again is a fight no
		     team finishes inside a wave. ]]
		if tier == nil and promotion and kind ~= Enums.Infected.Metallic then
			tier = promotion
		end

		table.insert(releases, { kind = kind, tier = tier })

		--[[ The pack, and only for a plain Tank. An Apex is already this wave's
		     escalation and two of them is the same wave twice as long. ]]
		if not override and wave.bossPack and kind == Enums.Infected.Tank and tier == nil then
			local row = GameModeConfig.TankPack[math.clamp(math.floor(humans), 1, #GameModeConfig.TankPack)]
			if row and rng:NextNumber() < row[1] then
				table.insert(releases, { kind = kind, tier = nil })
				if rng:NextNumber() < row[2] then
					table.insert(releases, { kind = kind, tier = nil })
				end
			end
		end
	end

	return releases
end

--[[
	── HOW MANY PEOPLE ARE ACTUALLY PLAYING ────────────────────────────────────
	Every number in the wave table above is tuned against a FULL team. Nothing
	anywhere scaled them by how many people turned up, so a solo player and a
	four-stack were handed the identical horde, the identical spawn rate and the
	identical five specials alive.

	That is not merely harder. It is a different game, and on the specials it is
	an unwinnable one: a Hunter, a Jockey, a Charger and a Tongue all end with a
	survivor pinned and needing a TEAMMATE to break it. Alone, the first pin of
	the round is the end of the round, and no amount of skill changes that —
	there is nobody to shoot it off you.

	── SPECIALS FALL HARDEST, AND THAT IS THE POINT ────────────────────────────
	Population scales sub-linearly: a lone survivor can only fight what fits in
	front of them, so quartering the horde for one player would leave a corridor
	empty rather than a fight winnable. Just under half is enough to be a horde
	and few enough to be a horde one person can hold a door against.

	Specials scale much harder than population, because they are the mechanic
	that requires a second player to exist. At wave 15 a full team faces five
	alive; solo that becomes one, which is a threat rather than a sentence.

	And the interval LENGTHENS rather than shortening — it is seconds between
	specials, so fewer players means dividing it by a number below one, which is
	why it has its own row instead of sharing the population multiplier.

	── ON THE ROSTER, NOT ON WHO IS STILL UP ───────────────────────────────────
	Read from the number of players IN the round rather than the number currently
	alive. Scaling on the living would make the round get easier the moment
	somebody went down, which pays a team for losing people and makes the last
	survivor's fight softer than the fight that killed the other three. The
	difficulty is a property of who showed up.
]]
export type HeadcountRow = {
	population: number,
	spawnRate: number,
	specials: number,
	--[[ Divides specialInterval, so a value under 1 makes specials arrive LESS
	     often. Named for what it does rather than for the field it touches. ]]
	specialPace: number,
	--[[ Multiplier on a BOSS's health at spawn. Applied by InfectedService and
	     nothing else; see the boss note below. ]]
	bossHealth: number,
}

--[[
	── AND THE BOSS BAR, WHICH WAS THE WORST OF IT ─────────────────────────────
	A boss's health was the one number in the game that did not move at all. Wave
	5 hands a solo player the same 4,000-health Tank a full team gets, and wave 15
	hands them the Apex at 12,000.

	Worked through with the actual roster: a median primary does about 150 damage
	a second with perfect uptime and no reloading under fire. Four survivors put
	12,000 down in twenty seconds of that, which is the ninety-second fight the
	Apex was designed to be once the dodging and the reloading are added back. One
	survivor needs eighty seconds of PERFECT uptime — realistically well past two
	minutes — while the thing chases them, and the finale wave is 144 seconds
	long. It was not a hard fight solo. It was an arithmetic impossibility, and no
	amount of skill closes a gap the clock closes first.

	These fall harder than population and not quite as hard as specials. A boss
	fight alone is worse than its health bar suggests for reasons the bar does not
	show: nobody else is drawing its attention, nobody is picking you up, and
	every second of the fight is a second you are the only target in the room. 40%
	of an Apex is 4,800, which is around a minute of real solo shooting inside a
	144-second wave — hard, and finishable.
]]
GameModeConfig.Headcount = table.freeze({
	table.freeze({
		population = 0.46,
		spawnRate = 0.70,
		specials = 0.34,
		specialPace = 0.60,
		bossHealth = 0.40,
	}),
	--[[
		── TWO, WHICH WAS THE HARSHEST ROW IN THE TABLE ────────────────────────
		Reported as "really hard when its just 2 people", and the numbers agree.

		Divide each scale by the share of the firepower that crew has, and you
		get what one player is actually carrying against a full team's 1.00:

		    crew   population   specials   boss
		     1        1.84        1.36      1.60
		     2        1.32        1.10      1.24     <- was
		     3        1.12        1.07      1.09
		     4        1.00        1.00      1.00

		The step from 2 to 3 was bigger than the step from 3 to 4, so a duo sat
		much nearer solo than to the trio it is one player away from. That is the
		shape being felt.

		── AND A DUO IS MORE FRAGILE THAN ITS HEADCOUNT SAYS ───────────────────
		Population is only half of it. A pin is the other half, and a pin does
		not scale linearly at all: a Hunter on one of four survivors costs the
		team a quarter of its guns and somebody walks over. A Hunter on one of
		TWO costs half the guns, and the one player left has to choose between
		breaking the pin and holding the horde — which is the same decision a
		solo player never gets to make, because there is nobody to break it.

		So specials fall furthest, to slightly BELOW parity at 0.96 per player.
		That is deliberate and it is the one row where being under 1.00 is
		correct: the raw count understates what each special costs a duo.

		Population lands at 1.20, between the old 1.32 and the trio's 1.12 rather
		than level with it — two players should still be harder than three, just
		not nearly-solo harder.
	]]
	table.freeze({
		population = 0.60,
		spawnRate = 0.82,
		specials = 0.48,
		specialPace = 0.72,
		bossHealth = 0.56,
	}),
	table.freeze({
		population = 0.84,
		spawnRate = 0.94,
		specials = 0.80,
		specialPace = 0.92,
		bossHealth = 0.82,
	}),
	--[[ Four is 1.0 across the board by definition: it is the team the wave
	     table was written against, and a scale that touched it would be a
	     retune of every wave hiding in a lookup. ]]
	table.freeze({
		population = 1.0,
		spawnRate = 1.0,
		specials = 1.0,
		specialPace = 1.0,
		bossHealth = 1.0,
	}),
}) :: { HeadcountRow }

--[[ The row for a headcount, clamped into the table. An empty server and a
     five-player future both get an answer rather than a nil index. ]]
function GameModeConfig.headcountRow(players: number): HeadcountRow
	local count = math.clamp(math.floor(tonumber(players) or 1), 1, #GameModeConfig.Headcount)
	return GameModeConfig.Headcount[count]
end

GameModeConfig.Classic = table.freeze({
	PrepDuration = 15, -- the calm before wave 1: pick up a gun, find your team

	--[[
		How long wave 1 will wait for the team to ready up, before it stops
		waiting.

		The gate exists so the pre-round REQUISITION window is a decision rather
		than a scramble: five options to read, a shared currency to spend, and
		four people who have to agree who is paying. Fifteen seconds of prep is
		not enough time to have that conversation, and a countdown that runs out
		mid-argument turns a team choice into whoever clicked fastest.

		Capped, and the cap is the whole reason this is safe. One player who
		alt-tabbed cannot hold three others hostage — the round starts without
		them, exactly as it would have before the gate existed. Forty-five
		seconds is long enough to read five cards and argue about two of them,
		and short enough that waiting it out is worse than pressing the button.

		The clock the client counts down during the hold is this, not
		PrepDuration: readying early does not shorten the round, it just gets
		everyone to the same starting line sooner. Prep still runs its own
		fifteen seconds afterwards, so there is always a moment to find a gun
		between agreeing and being shot at.
	]]
	ReadyCap = 45,
	TotalDuration = 1020, -- 17:00, the number the round timer counts down from
	MaxPlayers = 8,
	MinPlayersToStart = 1, -- solo is allowed; the Director scales down for it

	--[[ Reaching the end of wave 15 alive is a win, even at one survivor left.

	     NOT READ BY ANYTHING. RoundService's victory branch is unconditional and
	     matches what this says, so the behaviour is right and the flag is
	     decoration — flipping it to true would not make the game require all
	     four. Left in place rather than deleted because "all must survive" is a
	     real mode someone may want, and the wiring is one condition; but until
	     that exists this line describes an intention, not a switch. ]]
	VictoryRequiresAllAlive = false,
	--[[
		A team that cannot recover ends the round, rather than running the clock.

		"Cannot recover" is not "everybody dead" — see SurvivorService
		.canTeamRecover. A reviving, a pull-up and a defibrillator are all
		interactions that only an UPRIGHT survivor may begin, so the moment the
		last one goes down the outcome is already decided. Waiting for four
		incapacitated survivors to bleed out is a hundred and fifty seconds of a
		result that has happened, spent looking at the floor.
	]]
	EndOnTeamWipe = true,
	--[[ How long the team stays down before it counts. Not a chance to recover —
		 there is none — but the last survivor going down is a moment, and ending
		 the round on the same frame reads as the game cutting away from it. Long
		 enough to see the screen go grey and hear it land. ]]
	TeamWipeGrace = 3.0,

	-- Between waves the map restocks and downed players get a second chance.
	BreatherHealsIncapped = false,
	BreatherRestocksAmmo = true,
	BreatherRespawnsDead = true, -- dead players return during the breather
	RespawnHealth = 50,
})

--[[
	Versus: the server splits as evenly as it can, half survivors and half special
	infected. Infected players respawn on a timer and pick from the specials that
	are not already alive, so the team has to coordinate rather than all pick Tank.

	Scoring is by progress, not kills: how many waves the survivor team cleared and
	how far into the next one they got. Then the teams swap and do it again, which
	is what makes the mode fair — you are always being measured against the same
	fifteen waves the other side just faced. Fifteen also makes the score itself
	more readable: "they got to 11, we got to 13" is a scoreline, where "they got
	to 5, we got to 6" was a coin toss.
]]
GameModeConfig.Versus = table.freeze({
	MaxPlayers = 8,
	MinPlayersToStart = 4,
	Halves = 2, -- each team plays survivor once
	SwapBetweenHalves = true,

	InfectedRespawnTime = 22,
	InfectedRespawnTimeFinale = 14,
	InfectedGhostTime = 4, -- seconds as an invisible ghost to pick a spot
	InfectedMaxSameKindAlive = 1,
	InfectedPlayableKinds = {
		Enums.Infected.Hunter,
		Enums.Infected.Jockey,
		Enums.Infected.Charger,
		Enums.Infected.Tank,
	},
	-- The Witch is a hazard, not a class. Nobody plays her; the Director places her.
	TankIsRotated = true, -- the Tank passes between infected players rather than being picked

	ScorePerWaveCleared = 1000,
	ScorePerSecondSurvived = 4,
	ScorePerSurvivorAlive = 500, -- awarded at the end, so protecting each other pays
})

--[[ Matchmaking. One place, one round per server. See MatchmakingService. ]]
GameModeConfig.Matchmaking = table.freeze({
	-- A round still accepts joiners this far in, L4D style. Past it you wait for
	-- the next one rather than being dropped into a finale you cannot survive.
	JoinInProgressUntilWave = 4,
	LobbyCountdown = 20,
	LobbyCountdownWithFullServer = 8,
	--[[
		The end of a round, in two acts.

		ResultsDuration is the win-or-wipeout screen ALONE. The map vote used to
		open on the same frame the round ended, on the reasoning that running it
		under the scoreboard costs no dead time — and it does not, but it also
		means the moment a team finds out whether they held is the moment a vote
		card lands on top of it. Whatever the round was worth is gone.

		So the result gets the screen to itself first, and the vote follows. Long
		enough to read the outcome and your own line on the scoreboard, short
		enough that nobody is waiting.

		PostRoundDuration covers BOTH plus the vote in between, so a server never
		returns to the lobby with a vote still open. Audited: it has to be at
		least ResultsDuration + MapConfig.Vote.DurationSeconds.
	]]
	ResultsDuration = 8,
	PostRoundDuration = 30, -- results, then the vote, then back to the lobby

	MemoryStoreMapName = "FL_OpenRounds",
	MemoryStoreTtl = 90, -- seconds; a server must re-advertise inside this window
	AdvertiseInterval = 30,
	TeleportRetries = 3,

	--[[
		PRIVATE LOBBIES.

		A different thing from the browser above, and the difference is worth
		naming: the browser is how strangers end up in the same round, and these
		are how people who already know each other do. One is a sort, the other is
		a password.

		The code lives in its own MemoryStore hash map — code -> the reserved
		server's access code — rather than in the sorted map, which is keyed by
		JobId and ordered by player count and is the wrong shape for a lookup by
		a string somebody typed.
	]]
	LobbyMapName = "FL_Lobbies",

	--[[ Two hours. Long enough that a lobby made before dinner still works
	     after it, short enough that codes are recycled rather than accumulating
	     for the life of the game. A code outliving its server is harmless — the
	     join fails and says so — but a code that expires while its lobby is
	     still being played in is a group that cannot be rejoined. ]]
	LobbyTtl = 7200,

	--[[
		Six characters, from an alphabet with no O, 0, I, 1, S or 5.

		A lobby code gets read aloud, typed on a phone, and screenshotted. Every
		pair removed here is a pair somebody would otherwise mistype and blame the
		game for — and the cost is nothing, because 30^6 is 729 million codes
		against a collision check that already exists.
	]]
	LobbyCodeLength = 6,
	LobbyCodeAlphabet = "ABCDEFGHJKLMNPQRTUVWXYZ2346789",

	--[[ How many times a code is re-rolled before giving up. Each attempt is one
	     conditional write; three collisions in a row against 729 million codes
	     means the store is refusing writes, not that we were unlucky. ]]
	LobbyCodeAttempts = 3,

	--[[ How often one client may ask to create a lobby, find servers, or join a
	     code. All three are network calls to a rate-limited backend, and all
	     three are one button press — anything faster is not a person. ]]
	LobbyRequestCooldown = 2.0,
})

--[[ The wave at a given index, clamped so a bad index can never crash a round. ]]
function GameModeConfig.getWave(index: number): WaveDefinition
	local waves = GameModeConfig.Waves
	local clamped = math.clamp(index, 1, #waves)
	return waves[clamped]
end

function GameModeConfig.getWaveCount(): number
	return #GameModeConfig.Waves
end

--[[ Seconds from the start of the round to the start of a given wave. Used by the
     HUD to draw the wave pips and by the Director to schedule boss spawns. ]]
function GameModeConfig.getWaveStartTime(index: number): number
	local elapsed = GameModeConfig.Classic.PrepDuration
	for waveIndex = 1, math.min(index - 1, #GameModeConfig.Waves) do
		local wave = GameModeConfig.Waves[waveIndex]
		elapsed += wave.duration + wave.breather
	end
	return elapsed
end

--[[ Sanity check, run once at boot: the wave schedule must actually add up to the
     advertised round length, or the timer and the waves will drift apart. ]]
function GameModeConfig.validate(): (boolean, string?)
	local total = GameModeConfig.Classic.PrepDuration
	for _, wave in GameModeConfig.Waves do
		total += wave.duration + wave.breather
	end
	if total ~= GameModeConfig.Classic.TotalDuration then
		return false,
			string.format(
				"wave schedule totals %ds but Classic.TotalDuration is %ds — they must match",
				total,
				GameModeConfig.Classic.TotalDuration
			)
	end
	return true, nil
end

return GameModeConfig
