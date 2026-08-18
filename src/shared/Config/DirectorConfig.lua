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
	MinFlowAhead = -40, -- may spawn slightly behind the team
	MaxFlowAhead = 240, -- but mostly ahead of them
	RequireOutOfSight = true,
	SightCheckFovDegrees = 100,
	MaxSpawnAttempts = 24,
	SpawnGroundClearance = 3,
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

return table.freeze(DirectorConfig)
