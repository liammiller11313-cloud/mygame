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
	--[[ number, an absolute GetServerTimeNow stamp the bile clears at, or 0.
	     Absolute rather than a countdown for the same reason the wave clock is:
	     the client renders a smooth fade from a value that only changes when the
	     bile does, instead of one ticked over the wire sixty times a second. ]]
	BiledUntil = "FL_BiledUntil",
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
	--[[ The four progression facts, for the same reason Dollars is here: they
	     belong to one player, they are read by every OTHER player's screen, and
	     Roblox replicates a Player attribute to everybody for free. The player
	     list draws Level off this, and the scoreboard draws a name in Accent
	     with Callsign under it without asking the server anything.

	     ProgressionSynced carries the rest — quest progress, the pass track,
	     what is claimed — to the one client it belongs to. Nobody else's screen
	     needs to know how far through today's quests you are. ]]
	Level = "FL_Level", -- number, server-owned, see ProgressionService
	Scrip = "FL_Scrip", -- number, the pass currency
	Callsign = "FL_Callsign", -- string, a ProgressionConfig reward id or ""
	Accent = "FL_Accent", -- string, a ProgressionConfig reward id or ""
})

-- Written on the Player instance, read by the ammo counter.
Attributes.Loadout = table.freeze({
	PrimaryId = "FL_PrimaryId", -- string, Enums.Weapon or ""
	PrimaryAmmo = "FL_PrimaryAmmo", -- number, rounds in the magazine
	PrimaryReserve = "FL_PrimaryReserve", -- number, rounds in reserve
	SecondaryId = "FL_SecondaryId",
	SecondaryAmmo = "FL_SecondaryAmmo",
	--[[ No ammo field, and there will not be one: a melee never runs out, which
	     is the whole reason it is worth carrying alongside two guns. ]]
	MeleeId = "FL_MeleeId",
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
	--[[ string, InfectedConfig.CommonTiers id, or absent for a regular. Written
	     only on Commons whose model name lands in a tier band, so anything that
	     needs to tell a riot body from a shambler — a kill feed, a future
	     outline colour, a Studio inspection wondering why this one took three
	     shots — has one field to read rather than a name to parse. ]]
	Tier = "FL_Tier",
	--[[ number, seconds. Written by InfectedService when a death clip starts,
	     read by GoreService as how long to hold the ragdoll so the collapse is
	     animated rather than replaced. Absent means ragdoll now. ]]
	DeathHold = "FL_DeathHold",
	--[[
		boolean. Whether this body has any animation track that can actually drive
		it — written by InfectedAnimator, read by the client's procedural poser.

		The poser used to decide for itself by asking whether any track was
		PLAYING, which is true of a track that moves absolutely nothing. Every way
		a rig can be broken produces exactly that, so the fallback stood down for
		precisely the bodies that needed it and they slid around the map animated
		by neither. The client cannot tell the difference from where it stands —
		but the server already knows, because it is the thing that loaded the
		tracks and the thing that threw the dead ones away.

		So it says so, and there is one writer and one answer. Absent means "no
		opinion yet", which the poser treats as animated, because seizing a rig on
		no evidence would fight a clip that is perfectly fine.
	]]
	Animated = "FL_Animated",
	--[[
		string. The gait role the SERVER believes is playing on this body right
		now — "walk", "idle", "run", "fall" — or "" when it has started nothing.

		Written only when it changes, which is a handful of times per body per
		second at most, and it exists to settle one question no single machine can
		answer alone: when the client's fallback takes over a body, is that because
		the server never started a clip, or because the server started one and this
		client cannot see it? Those have opposite fixes, and from either end alone
		they look identical.
	]]
	Gait = "FL_Gait",
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

--[[
	Writes an attribute. Server-side only in practice — see the header: a client
	writing one of these is a no-op that will be overwritten.

	The counterpart to `get`, and it existed as a call site before it existed as
	a function: three places wrote `Attributes.set(...)` against a module that
	only had `get`, and every one of them threw the first time it ran. Crouching
	and personal difficulty were both broken by it. `scripts/audit.py` check 9i
	is the thing that now catches that shape.

	It writes unconditionally rather than comparing first. Roblox already skips
	the replication when a value has not changed, and a guard here would only
	move that check somewhere it costs a table lookup.
]]
function Attributes.set(instance: Instance, name: string, value: any)
	instance:SetAttribute(name, value)
end

return Attributes
