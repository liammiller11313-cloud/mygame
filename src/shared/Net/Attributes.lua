--!strict
--[[
	Attributes — the contract for continuously-replicated state.

	Roblox replicates Instance attributes to every client automatically, with
	delta compression and no per-frame remote traffic. That makes them strictly
	better than remotes for values that change often and that everyone can see:
	health, temp health, ammo counts, the Director's current pacing state.

	The rule this codebase follows:
	  * Numbers that CHANGE OFTEN and are PUBLIC  -> attribute (declared here)
	  * Things that HAPPEN ONCE                   -> RemoteEvent (Remotes.lua)

	Only the server ever writes these. Clients read them and may listen with
	:GetAttributeChangedSignal(). A client writing one of these is a no-op that
	will be overwritten and should be treated as a bug.
]]

local Attributes = {}

-- Written on the Player instance. Survives character respawns, so the HUD can
-- keep rendering a teammate's slot while they are dead and awaiting a defib.
Attributes.Player = table.freeze({
	State = "FL_State", -- string, Enums.SurvivorState
	Health = "FL_Health", -- number, 0-100 permanent health
	TempHealth = "FL_TempHealth", -- number, decaying pills/adrenaline buffer
	IncapCount = "FL_IncapCount", -- number, incaps this map; drives black & white
	IsBlackAndWhite = "FL_BlackAndWhite", -- boolean, one more down = death
	ReviveProgress = "FL_ReviveProgress", -- number 0-1, drives the teammate ring
	PinnedBy = "FL_PinnedBy", -- string, Enums.Infected or "" when free
	FlowDistance = "FL_Flow", -- number, studs along the level spline
	IsReady = "FL_Ready", -- boolean, lobby readiness
	IsCrouching = "FL_IsCrouching", -- boolean; the server owns it, the client asks
	--[[ The player's own comfort setting, as a name from SettingsConfig.Difficulty.
	     Only ever softens what the infected do to THIS player — see the header
	     of SettingsConfig. Public rather than private because the HUD wants to
	     be able to say so, and because a setting the team can see is a setting
	     nobody can quietly abuse. ]]
	Difficulty = "FL_Difficulty", -- string, a key of SettingsConfig.Difficulty
	--[[ Dollars. An attribute rather than a remote because it moves on every
	     kill — three hundred times a round — and because the client can read
	     the earning off the DELTA, which is a "+$4" popup for no network cost
	     at all. Public, like everything on a Player: a teammate seeing your
	     balance costs nothing and the end-of-round screen wants it. ]]
	Dollars = "FL_Dollars", -- number, server-owned, see EconomyService
	--[[ Whether this player's profile has finished loading. Nothing may spend,
	     equip or save until it has: a DataStore read takes a moment and a
	     purchase made against an empty profile would be a purchase made
	     against somebody's real balance a second later. ]]
	ProfileReady = "FL_ProfileReady", -- boolean
})

-- Written on the Player instance, read by the ammo counter.
Attributes.Loadout = table.freeze({
	PrimaryId = "FL_PrimaryId", -- string, Enums.Weapon or ""
	PrimaryAmmo = "FL_PrimaryAmmo", -- number, rounds in the magazine
	PrimaryReserve = "FL_PrimaryReserve", -- number, rounds in reserve
	SecondaryId = "FL_SecondaryId",
	SecondaryAmmo = "FL_SecondaryAmmo",
	ThrowableId = "FL_ThrowableId",
	HealthItemId = "FL_HealthItemId",
	PillItemId = "FL_PillItemId",
	ActiveSlot = "FL_ActiveSlot", -- string, Enums.Slot
	IsReloading = "FL_IsReloading", -- boolean
})

-- Written on an infected Model. The client reads these to colour outlines, pick
-- the right hit sound, and decide whether a body deserves the gore budget.
Attributes.Infected = table.freeze({
	Kind = "FL_Kind", -- string, Enums.Infected
	Health = "FL_Health", -- number
	MaxHealth = "FL_MaxHealth", -- number
	IsBoss = "FL_IsBoss", -- boolean, Tank / Witch
	IsDead = "FL_IsDead", -- boolean, set before the model lingers as a corpse
	Target = "FL_Target", -- string, UserId of the survivor being chased, or ""
	Seed = "FL_Seed", -- number, per-body gait variation; see InfectedPoseController
	SpawnFlow = "FL_SpawnFlow", -- number, flow distance it spawned at
	Burning = "FL_Burning", -- boolean, on fire (molotov / gas can)
})

-- Written on a dropped pickup Model so the interact prompt can label it.
Attributes.Pickup = table.freeze({
	Slot = "FL_Slot", -- string, Enums.Slot
	ItemId = "FL_ItemId", -- string
	Ammo = "FL_Ammo", -- number, magazine contents for a dropped gun
	Reserve = "FL_Reserve", -- number
})

-- Written on Workspace. Global, read by the music system and the debug overlay.
Attributes.Game = table.freeze({
	RoundState = "FL_RoundState", -- string, Enums.RoundState
	PacingState = "FL_PacingState", -- string, Enums.PacingState
	TeamIntensity = "FL_TeamIntensity", -- number 0-1, the Director's stress read
	AliveSurvivors = "FL_AliveSurvivors", -- number
	InfectedAlive = "FL_InfectedAlive", -- number
	TankActive = "FL_TankActive", -- boolean, drives the tank music
	ObjectiveText = "FL_Objective", -- string

	-- Round structure. The two *EndsAt fields are absolute
	-- workspace:GetServerTimeNow() stamps rather than remaining seconds, so the
	-- client renders a perfectly smooth countdown from a value that only changes
	-- when the phase does — no per-frame remote traffic, and no drift.
	Mode = "FL_Mode", -- string, GameModeConfig.Modes
	WaveIndex = "FL_WaveIndex", -- number, 0 during prep
	WavePhase = "FL_WavePhase", -- string, "Prep" | "Active" | "Breather" | "Over"
	WaveEndsAt = "FL_WaveEndsAt", -- number, server time the current phase ends
	RoundEndsAt = "FL_RoundEndsAt", -- number, server time the whole round ends
	Difficulty = "FL_Difficulty", -- string, DirectorConfig.Difficulty key
	CurrentMap = "FL_CurrentMap", -- string, MapConfig map id
	MapPhase = "FL_MapPhase", -- string, "Ready" | "Unload" | "Load"
})

--[[ Written on an ammo crate model. The client reads Spent to grey out a crate
     it cannot use yet, and RespawnAt to show how long until it is back. ]]
Attributes.Crate = table.freeze({
	Spent = "FL_CrateSpent", -- boolean
	RespawnAt = "FL_CrateRespawnAt", -- number, absolute server time
	Index = "FL_CrateIndex", -- number, 1-6 as named in the map
})

--[[
	Reads an attribute with a fallback. Attributes are nil until first written,
	and every consumer wanting `(x or 0)` inline gets noisy fast.
]]
function Attributes.get<T>(instance: Instance, name: string, default: T): T
	local value = instance:GetAttribute(name)
	if value == nil then
		return default
	end
	return value :: any
end

return Attributes
