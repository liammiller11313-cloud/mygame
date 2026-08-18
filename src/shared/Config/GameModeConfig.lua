--!strict
--[[
	GameModeConfig — the round structure.

	Fading Light is not a campaign game. There are no safe rooms and no chapters.
	A round is a fixed 17 minutes of holding out against seven escalating waves,
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
	itemDropChance: number, -- odds the breather after this wave restocks the map
	announcement: string,
}

--[[
	Seven waves totalling exactly 17:00 including the opening prep window.

	  prep 15s + waves 830s + breathers 175s = 1020s

	The shape is deliberate: waves 1-3 teach, wave 4 is the first Tank and the
	first time the team has to move as a unit, wave 5 adds the Witch on top of a
	horde so there is something to be afraid of that is not a bullet sponge, wave
	6 is the longest sustained pressure, and wave 7 is a finale with two Tanks
	where the honest expectation is that most teams die.
]]
GameModeConfig.Waves = {
	{
		index = 1,
		name = "First Contact",
		duration = 85,
		breather = 20,
		populationScale = 0.55,
		spawnRateScale = 0.8,
		maxSpecialsAlive = 0,
		specialInterval = 0,
		bosses = {},
		itemDropChance = 0.35,
		announcement = "THEY'RE COMING",
	},
	{
		index = 2,
		name = "Spreading",
		duration = 95,
		breather = 25,
		populationScale = 0.75,
		spawnRateScale = 0.9,
		maxSpecialsAlive = 1,
		specialInterval = 38,
		bosses = {},
		itemDropChance = 0.45,
		announcement = "MORE OF THEM",
	},
	{
		index = 3,
		name = "Swarm",
		duration = 105,
		breather = 25,
		populationScale = 1.0,
		spawnRateScale = 1.0,
		maxSpecialsAlive = 2,
		specialInterval = 30,
		bosses = {},
		itemDropChance = 0.5,
		announcement = "HOLD THE LINE",
	},
	{
		index = 4,
		name = "Heavy",
		duration = 115,
		breather = 30,
		populationScale = 1.1,
		spawnRateScale = 1.05,
		maxSpecialsAlive = 2,
		specialInterval = 28,
		bosses = { Enums.Infected.Tank },
		itemDropChance = 0.7, -- a Tank wave should always leave something behind
		announcement = "TANK INBOUND",
	},
	{
		index = 5,
		name = "The Crying",
		duration = 125,
		breather = 30,
		populationScale = 1.2,
		spawnRateScale = 1.1,
		maxSpecialsAlive = 3,
		specialInterval = 24,
		bosses = { Enums.Infected.Witch },
		itemDropChance = 0.6,
		announcement = "SOMETHING IS CALLING THEM",
	},
	{
		index = 6,
		name = "Overrun",
		duration = 135,
		breather = 35,
		populationScale = 1.35,
		spawnRateScale = 1.2,
		maxSpecialsAlive = 3,
		specialInterval = 22,
		bosses = {},
		itemDropChance = 0.75, -- the last real chance to restock before the finale
		announcement = "OVERRUN",
	},
	{
		index = 7,
		name = "Last Light",
		duration = 180,
		breather = 0,
		populationScale = 1.6,
		spawnRateScale = 1.35,
		maxSpecialsAlive = 4,
		specialInterval = 18,
		bosses = { Enums.Infected.Tank, Enums.Infected.Tank },
		itemDropChance = 0,
		announcement = "SURVIVE",
	},
} :: { WaveDefinition }

GameModeConfig.Classic = table.freeze({
	PrepDuration = 15, -- the calm before wave 1: pick up a gun, find your team
	TotalDuration = 1020, -- 17:00, the number the round timer counts down from
	MaxPlayers = 8,
	MinPlayersToStart = 1, -- solo is allowed; the Director scales down for it

	-- Reaching the end of wave 7 alive is a win, even at one survivor left.
	VictoryRequiresAllAlive = false,
	-- Every survivor dead ends the round immediately rather than running the clock.
	EndOnTeamWipe = true,

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
	seven waves the other side just faced.
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
		Enums.Infected.Rusher,
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
	PostRoundDuration = 25, -- scoreboard, then back to the lobby

	MemoryStoreMapName = "FL_OpenRounds",
	MemoryStoreTtl = 90, -- seconds; a server must re-advertise inside this window
	AdvertiseInterval = 30,
	TeleportRetries = 3,
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
