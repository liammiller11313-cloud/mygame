--!strict
--[[
	DirectorConfig — the pacing brain's tuning.

	The AI Director is what separates this from a wave shooter. It does not spawn
	enemies on a timer; it watches how hard the team is being pressed, and then
	deliberately backs off so that the next horde lands on a team that has had
	just enough time to relax. The rhythm is the product.

	The cycle: Relax -> BuildUp -> SustainPeak -> PeakFade -> Relax
]]

local Enums = require(script.Parent.Parent.Enums)

local DirectorConfig = {}

--[[
	Intensity is a 0-1 per-survivor number tracking how rough the last few seconds
	have been. It rises from damage taken, being pinned, and infected crowding
	you; it falls off on its own. The Director reads the TEAM's peak intensity.
]]
DirectorConfig.Intensity = table.freeze({
	DecayPerSecond = 0.055,

	DamageTakenWeight = 0.011, -- per point of damage
	IncapWeight = 0.45,
	PinnedWeight = 0.30,
	ProximityWeight = 0.020, -- per infected inside ProximityRadius, per second
	ProximityRadius = 30,
	LowHealthWeight = 0.12, -- per second while below the hurt threshold
	KillRelief = 0.004, -- killing things feels good; it calms the read slightly

	PeakThreshold = 0.80, -- crossing this forces SustainPeak
	RelaxThreshold = 0.14, -- falling under this allows Relax to end
})

--[[ How long the Director will hold each pacing state. Minimums exist so a state
     cannot flicker; maximums stop a cautious team from stalling out forever. ]]
DirectorConfig.Pacing = table.freeze({
	[Enums.PacingState.Relax] = { min = 22, max = 45 },
	[Enums.PacingState.BuildUp] = { min = 14, max = 90 },
	[Enums.PacingState.SustainPeak] = { min = 5, max = 18 },
	[Enums.PacingState.PeakFade] = { min = 6, max = 14 },
})

--[[ Common infected population, per pacing state. `target` is how many the
     Director wants alive; it trickles toward that number rather than dumping. ]]
DirectorConfig.Population = table.freeze({
	[Enums.PacingState.Relax] = { target = 4, spawnInterval = 6.0, batchSize = 1 },
	[Enums.PacingState.BuildUp] = { target = 18, spawnInterval = 2.2, batchSize = 3 },
	[Enums.PacingState.SustainPeak] = { target = 46, spawnInterval = 0.55, batchSize = 7 },
	[Enums.PacingState.PeakFade] = { target = 8, spawnInterval = 5.0, batchSize = 1 },
})

--[[ Where a spawn is allowed to appear. Getting this right is most of what makes
     a Director feel fair: enemies must arrive from somewhere plausible, never
     materialise in your field of view. ]]
DirectorConfig.Spawning = table.freeze({
	MinDistanceFromSurvivor = 45,
	MaxDistanceFromSurvivor = 190,
	--[[
		How far ABOVE OR BELOW the nearest survivor a body may be placed.

		The distance band is a sphere, so without this a point ninety studs up and
		a hundred and fifty out is a legal spawn — and on a city map that is a
		roof. Players looked up and saw zombies standing in the air, and those
		bodies then spent the whole maroon window failing to find a way down while
		counting against the population the Director is allowed.

		Relative to the survivor rather than absolute, so it costs nothing on a
		vertical map: a team on a rooftop finale gets rooftop spawns, because the
		rule follows them. Twenty-five studs is somewhere between one and two
		storeys — enough for a zombie to come down the stairs of the building you
		are about to enter, far short of the top of it.

		This is a cheap stand-in for the real question, which is "can a body walk
		from here to the team". A raycast cannot answer that — the roof of a low
		shed reads exactly like a street — and the honest fix for the rest of it is
		FL_SpawnNode parts, which are a person answering it directly.
	]]
	MaxHeightFromSurvivor = 25,
	MinFlowAhead = -40, -- may spawn slightly behind the team
	MaxFlowAhead = 240, -- but mostly ahead of them
	RequireOutOfSight = true,
	SightCheckFovDegrees = 100,
	MaxSpawnAttempts = 24,
	--[[ How far above the ground point the old headroom ray looked. Kept for
	     that check; the real clearance test is now SpawnVolume, which measures
	     the body's whole box rather than a line above its feet. ]]
	SpawnGroundClearance = 3,

	--[[
		The box a standing infected occupies, at scale 1, in studs.

		Width x height x depth, measured from the greybox rig PlaceholderFactory
		builds: an upper torso 1.70 wide over a 1.50 lower torso, plus arms, is
		about 3 across at the shoulders, and a rig stands about 5.2 tall. Depth is
		the shallowest axis and is what decides whether a body fits against a
		wall.

		Narrower than the rig's true arm span on purpose. An arm clipping a
		doorframe for one frame as the body starts walking is nothing; a TORSO
		inside a wall is a zombie that never gets out, and the torso is what this
		is protecting. Testing the full span would reject most doorways.

		Scaled per kind by InfectedConfig's `scale`, which is what makes a Tank
		at 2.35 need a genuinely different opening from a Common — the old single
		3-stud constant said they were the same, and a Tank is over eleven studs
		tall.
	]]
	SpawnBodySize = Vector3.new(3.0, 5.2, 2.4),

	--[[ Shrink applied to that box before testing, as a fraction. Roblox's
	     GetPartBoundsInBox tests axis-aligned BOUNDING boxes, which for a rotated
	     or angled part is larger than the part — so without a little slack the
	     test rejects legal ground next to any wall that is not axis-aligned. ]]
	SpawnBodyTolerance = 0.12,
	VisibilityGracePeriod = 0.4, -- newly spawned infected ignore sight briefly
})

--[[ Specials are gated by a shared timer so you never eat two Chargers at once,
     and by pacing so they arrive during pressure rather than during a lull. ]]
DirectorConfig.Specials = table.freeze({
	BaseInterval = 26,
	IntervalJitter = 10,
	MinIntervalBetweenAny = 12,
	MaxAliveTotal = 3,
	RelaxMultiplier = 2.2, -- specials come far less often while relaxing
	PeakMultiplier = 0.55,
	MinFlowBeforeFirst = 120, -- give the team a moment before the first one
})

--[[ Bosses are placed by flow distance, not by timer, so every playthrough of a
     map has a Tank roughly where the map was designed for one. ]]
DirectorConfig.Bosses = table.freeze({
	TankFlowInterval = 1400, -- studs of progress between Tank opportunities
	TankFlowJitter = 350,
	WitchFlowInterval = 900,
	WitchFlowJitter = 400,
	MinSurvivorsAliveForTank = 2,
	TankHealthPerExtraSurvivor = 0.0, -- kept flat; scaling is done via count
})

--[[ Panic events: an alarmed door, a lift, a car alarm. A scripted, bounded
     horde on top of whatever the Director is already doing. ]]
DirectorConfig.PanicEvent = table.freeze({
	WaveCount = 3,
	WaveSize = 22,
	WaveInterval = 9,
	Duration = 45,
	SpawnRadius = 150,
})

--[[ The Director also decides what you find. A team that is hurting finds pills;
     a team that is fine finds ammo. This is the quietest and most effective
     difficulty adjustment in the whole design. ]]
DirectorConfig.ItemPlacement = table.freeze({
	--[[
		Whether the Director puts WEAPONS on the map's item pads.

		Off. The shop sells guns and melee, and a rifle lying in a doorway
		undercuts the thing the player just spent Dollars on — it makes buying a
		primary a choice about impatience rather than a choice about money, and
		it makes the pad you walk past the reason you never went back to the shop.

		The consumables stay, and they are the reason the pads exist at all.
		Medkits, pills and throwables are the Director's quietest difficulty
		adjustment: a team that is hurting finds pills in the next room. That
		mechanic is about the FIGHT and has nothing to do with the economy, so
		nothing about the shop argues with it.

		Turning this back on restores the original cascade exactly, including
		hand-authored FL_Slot pads that name a weapon slot.
	]]
	PlaceWeapons = false,

	BaseHealthItemChance = 0.30,
	HurtTeamHealthItemBonus = 0.45, -- added when the team average is low
	BaseThrowableChance = 0.35,
	BasePillChance = 0.45,
	MinItemsPerSection = 2,
	MaxItemsPerSection = 5,
})

--[[ Difficulty presets scale damage and population without touching the tuning
     above, so "Advanced" stays recognisably the same game as "Normal". ]]
DirectorConfig.Difficulty = table.freeze({
	Easy = { infectedDamage = 0.5, populationScale = 0.7, friendlyFire = 0.0, specialInterval = 1.4 },
	Normal = { infectedDamage = 1.0, populationScale = 1.0, friendlyFire = 0.25, specialInterval = 1.0 },
	Advanced = { infectedDamage = 2.0, populationScale = 1.3, friendlyFire = 0.6, specialInterval = 0.8 },
	Expert = { infectedDamage = 5.0, populationScale = 1.5, friendlyFire = 1.0, specialInterval = 0.65 },
})

DirectorConfig.DefaultDifficulty = "Normal"

--[[
	TEMPERAMENT — the reason two rounds of the same map never play the same.

	The pacing machine above is deterministic: given the same intensity it makes
	the same decision every time. That is correct for readability and wrong for
	replay value, because a team that plays a map twice learns exactly when the
	pressure comes and stops being afraid of it.

	So the Director rolls a TEMPERAMENT at the start of each round, and a lighter
	MOOD at the start of each wave. Neither changes what the Director is willing
	to do — it still refuses to spawn in your field of view, still backs off when
	the team is hurt, still respects the wave budget — only how it leans inside
	those rules. The result is a Director that is unpredictable without ever
	being unfair, which is the only kind of unpredictability worth having.

	Every field is a MULTIPLIER on something the wave already decided, and the
	bands are deliberately narrow. A temperament that doubled the horde would not
	read as personality, it would read as the difficulty changing at random.
]]
export type Temperament = {
	id: string,
	displayName: string,
	weight: number, -- relative odds of being rolled

	population: number, -- multiplier on the common-infected target
	spawnRate: number, -- multiplier on how fast they arrive
	specialRate: number, -- multiplier on the gap between specials
	burstiness: number, -- 0 steady stream, 1 arrives in clumps

	pairChance: number, -- odds two specials are sent together
	flankChance: number, -- odds a group spawns BEHIND the team instead of ahead
}

DirectorConfig.Temperaments = {
	{
		-- The default read of the pacing machine, with no lean at all. Kept in
		-- the pool so that "normal" is a thing a round can actually roll.
		id = "Measured",
		displayName = "Measured",
		weight = 22,
		population = 1.0,
		spawnRate = 1.0,
		specialRate = 1.0,
		burstiness = 0.35,
		pairChance = 0.10,
		flankChance = 0.20,
	},
	{
		-- Long quiet, then everything at once. The most frightening one to play
		-- against, because the silence stops being reassuring.
		id = "Patient",
		displayName = "Patient",
		weight = 18,
		population = 1.1,
		spawnRate = 0.72,
		specialRate = 1.25,
		burstiness = 0.85,
		pairChance = 0.25,
		flankChance = 0.30,
	},
	{
		-- Never stops. Fewer at a time, but the stream does not end, so nobody
		-- gets the ten seconds they need to heal.
		id = "Relentless",
		displayName = "Relentless",
		weight = 18,
		population = 0.92,
		spawnRate = 1.35,
		specialRate = 0.85,
		burstiness = 0.12,
		pairChance = 0.15,
		flankChance = 0.25,
	},
	{
		-- Specials over commons. Punishes a team that has stopped watching each
		-- other and rewards one that holds a tight formation.
		id = "Stalker",
		displayName = "Stalker",
		weight = 14,
		population = 0.8,
		spawnRate = 0.9,
		specialRate = 0.6,
		burstiness = 0.4,
		pairChance = 0.45,
		flankChance = 0.5,
	},
	{
		-- Bodies. Enormous crowds, almost no specials — the wave that makes a
		-- shotgun feel like the correct answer to everything.
		id = "Swarm",
		displayName = "Swarm",
		weight = 14,
		population = 1.35,
		spawnRate = 1.15,
		specialRate = 1.5,
		burstiness = 0.7,
		pairChance = 0.05,
		flankChance = 0.35,
	},
	{
		-- Changes its mind constantly. Rolls a fresh mood far more often than the
		-- others, so it never settles into a rhythm you can read.
		id = "Erratic",
		displayName = "Erratic",
		weight = 14,
		population = 1.0,
		spawnRate = 1.0,
		specialRate = 0.9,
		burstiness = 0.6,
		pairChance = 0.3,
		flankChance = 0.45,
	},
} :: { Temperament }

--[[ The per-wave mood sits on top of the round's temperament, and is much
     narrower — it is the difference between two waves of the same round, not
     between two rounds. ]]
DirectorConfig.Mood = table.freeze({
	PopulationJitter = 0.18, -- +/- fraction
	SpawnRateJitter = 0.22,
	SpecialRateJitter = 0.25,
	-- Erratic rerolls mid-wave; everything else holds its mood for the wave.
	ErraticRerollSeconds = 22,
})

--[[
	SKILL READ — a slow measure of how well the team is actually handling itself,
	separate from the fast intensity signal.

	Intensity answers "is this moment rough". This answers "are these players
	good", and they are genuinely different questions: a strong team can sit at
	low intensity all round because they are killing things before the pressure
	lands, and the Director should notice that and push rather than concluding
	the wave is going fine.

	Deliberately slow and tightly bounded, because a difficulty that visibly
	chases the player's performance feels like being punished for playing well.
]]
DirectorConfig.Skill = table.freeze({
	Window = 45, -- seconds of history the read is built from
	KillsPerSecondBaseline = 1.6, -- what an average team clears
	DamageTakenBaseline = 12, -- per survivor per minute
	MaxBoost = 0.28, -- most a strong team can add to the population
	MaxRelief = 0.35, -- most a struggling team can have taken off
	Responsiveness = 0.12, -- how fast the read moves toward the truth
})

return table.freeze(DirectorConfig)
