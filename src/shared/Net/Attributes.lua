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
	--[[ Set on a player who chose to leave the match, and cleared when they pick
	     a mode again. It is what makes RETURN TO MAIN MENU mean it: without it
	     the next round spawns everybody in the server, which pulls somebody who
	     is sitting reading the menu back into a match they walked out of. See
	     RoundService's LeaveMatch handler. ]]
	LeftMatch = "FL_LeftMatch", -- boolean
	Health = "FL_Health", -- number, 0-100 permanent health
	TempHealth = "FL_TempHealth", -- number, decaying pills/adrenaline buffer
	IncapCount = "FL_IncapCount", -- number, incaps this map; drives black & white
	IsBlackAndWhite = "FL_BlackAndWhite", -- boolean, one more down = death
	ReviveProgress = "FL_ReviveProgress", -- number 0-1, drives the teammate ring
	PinnedBy = "FL_PinnedBy", -- string, Enums.Infected or "" when free
	--[[ boolean, whether this survivor has readied up in the pre-round window.
	     On the Player rather than the character because the window opens before
	     anyone has finished spawning, and cleared by RoundService at the start of
	     every prep so last round's answer is never mistaken for this one's. ]]
	Ready = "FL_Ready",
	--[[ number, an absolute GetServerTimeNow stamp the bile clears at, or 0.
	     Absolute rather than a countdown for the same reason the wave clock is:
	     the client renders a smooth fade from a value that only changes when the
	     bile does, instead of one ticked over the wire sixty times a second. ]]
	BiledUntil = "FL_BiledUntil",
	FlowDistance = "FL_Flow", -- number, studs along the level spline
	IsReady = "FL_Ready", -- boolean, lobby readiness
	IsCrouching = "FL_IsCrouching", -- boolean; the server owns it, the client asks
	--[[ boolean, whether this survivor is actually running rather than merely
	     asking to. Published because the FOOTSTEPS need it and the client cannot
	     work it out: WalkSpeed is the sprint speed multiplied by whatever the
	     weapon in hand scales it by, so a heavy rifle at a sprint and a light one
	     at a walk land on the same number. The server already knows the answer —
	     see _computeWalkSpeed — so it says so rather than making four clients
	     guess, and a teammate's gait is audible for the same one write. ]]
	IsSprinting = "FL_IsSprinting", -- boolean
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

	--[[
		Abilities: what is in each slot, and when each slot is next usable.

		One pair per slot, indexed by AbilityConfig.MaxSlots — see
		Shared/Config/AbilityConfig.attributesFor. On the PLAYER rather than in a
		remote for the same reason the loadout is: the HUD reads its own, and a
		teammate's slots are readable by everybody for free, which is what lets a
		future squad panel say who is carrying a medic without a single packet.

		`ReadyAt` is an ABSOLUTE workspace:GetServerTimeNow() stamp, not seconds
		remaining. The client renders a perfectly smooth countdown from a value
		that only changes when the ability is actually used, so a cooldown costs
		one attribute write rather than one a second — and it cannot drift.
	]]
	Ability1Id = "FL_Ability1Id", -- string, an Enums.Ability id or ""
	Ability1ReadyAt = "FL_Ability1ReadyAt", -- number, server time
	Ability2Id = "FL_Ability2Id",
	Ability2ReadyAt = "FL_Ability2ReadyAt",
	Ability3Id = "FL_Ability3Id",
	Ability3ReadyAt = "FL_Ability3ReadyAt",
	Ability4Id = "FL_Ability4Id",
	Ability4ReadyAt = "FL_Ability4ReadyAt",
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
	--[[ string, an InfectedConfig.EliteTiers id, or absent. Same creature with a
	     modifier on it — the finale's Apex Tank is the only one. Read by the
	     client to name the boss bar and to pick its outline. ]]
	Elite = "FL_Elite",
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

--[[
	Written on the puzzle props themselves, by PuzzleService, once a round.

	The clue TEXT rides an attribute as well as the SurfaceGui it is printed on:
	the close-up reader needs the string, and digging a TextLabel out of a
	designer's own instance tree by name is coupling that breaks the first time
	somebody renames a part. One source — the template — and two renderings.
]]
Attributes.Puzzle = table.freeze({
	ClueText = "FL_ClueText", -- string, the document as printed
	CluePrompt = "FL_CluePrompt", -- string, what the interact prompt calls it
	Digits = "FL_PuzzleDigits", -- number, how long the keypad's code is
	ClueOrder = "FL_ClueOrder", -- number, where this prop sits in the chain
})

--[[
	Written on the wood the horde can break, by BarricadeService.

	Both numbers rather than a fraction: the fraction is what a crack overlay
	wants and the raw pair is what anything deciding whether a swing finishes the
	job wants, and deriving the second from the first means every reader carrying
	its own rounding.
]]
Attributes.Barricade = table.freeze({
	Health = "FL_BarricadeHealth", -- number, what is left of it
	MaxHealth = "FL_BarricadeMaxHealth", -- number, what it was armed with
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

	--[[ True while a solo player has the round genuinely stopped. On Workspace
	     rather than on the player, because everything that has to stand still
	     reads it from one place and because the day this game grows a second way
	     to pause, it should set the same flag. ]]
	Paused = "FL_Paused", -- boolean

	--[[ The random event that is running, or "" when none is. Three attributes
	     rather than a remote for the state itself, because a client that joins
	     mid-event has to be able to see it — a remote only ever tells you what
	     happened while you were listening. The BANNER is a remote (see
	     Remotes.RandomEvent), because that is a moment rather than a state. ]]
	EventId = "FL_EventId", -- string, an EventConfig id or ""
	EventName = "FL_EventName", -- string, what to call it on screen
	EventEndsAt = "FL_EventEndsAt", -- number, absolute GetServerTimeNow stamp

	--[[ The pre-round ready gate. `ReadyHold` is true while wave 1 is waiting on
	     the team; the two counts are published rather than left for each client
	     to derive, because "who counts as a survivor right now" is a question
	     SurvivorService already owns and four clients reimplementing it is four
	     chances to disagree with the server about whether the round can start. ]]
	--[[ The optional vault side objective. Present says a puzzle is armed in this
	     map at all — two of the three maps never set it — and Solved is what the
	     keypad UI reads to stop offering a code for a door that is already open. ]]
	VaultPresent = "FL_VaultPresent", -- boolean
	--[[ How many of the vault's clues the TEAM holds, and how many there are.
	     Team-wide on Workspace rather than per player, because four survivors
	     are working one objective — a counter that started again for whoever
	     walked in second would be four separate puzzles in one building. ]]
	CluesFound = "FL_CluesFound", -- number
	CluesTotal = "FL_CluesTotal", -- number, 0 when no puzzle is armed
	VaultSolved = "FL_VaultSolved", -- boolean

	ReadyHold = "FL_ReadyHold", -- boolean
	ReadyCount = "FL_ReadyCount", -- number, survivors who have readied
	ReadyNeeded = "FL_ReadyNeeded", -- number, survivors the gate is waiting on

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

	--[[
		Requisitions: what the team has bought into this round.

		One boolean each rather than a packed list, and on WORKSPACE rather than
		on a Player, because a requisition is bought by ONE person and belongs to
		EVERYBODY — see Round/RequisitionService. Workspace attributes replicate
		to every client for free, which is what lets a client predict a reload at
		the drilled speed and lets the outline system light up specials without
		either of them asking the server anything.

		Boolean-per-id rather than a comma-joined string because the incendiary
		test runs on every bullet that lands. A GetAttribute is a hash lookup; a
		string split is garbage, sixty times a second, during a horde.
	]]
	ReqIncendiary = "FL_ReqIncendiary", -- boolean
	ReqSpotter = "FL_ReqSpotter", -- boolean
	ReqDrill = "FL_ReqDrill", -- boolean
	ReqSurplus = "FL_ReqSurplus", -- boolean
	--[[ AIRDROP fires once and leaves no state behind, so nothing READS this one.
	     It exists so the purchase is visible: without it the panel cannot tell a
	     bought airdrop from an unbought one and offers it forever, and the player
	     finds out by spending a click on a refusal. One switch per requisition,
	     with no exceptions, is also one fewer branch everywhere else. ]]
	ReqAirdrop = "FL_ReqAirdrop", -- boolean

	--[[ The one condition this round is fought under, or "". See
	     Shared/Config/ModifierConfig: it is read by the Director, the atmosphere,
	     the spawner, the crates and the HUD, which is exactly why it lives on
	     Workspace rather than being handed to each of them. ]]
	Modifier = "FL_Modifier", -- string, a ModifierConfig id or ""
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
