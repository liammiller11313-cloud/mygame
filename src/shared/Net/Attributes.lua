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

local CollectionService = game:GetService("CollectionService")

local Attributes = {}

-- Written on the Player instance. Survives character respawns, so the HUD can
-- keep rendering a teammate's slot while they are dead and awaiting a defib.
Attributes.Player = table.freeze({
	State = "FL_State", -- string, Enums.SurvivorState
	--[[
		A multiplier on this survivor's walk speed, from something outside
		SurvivorService. Absent or 1 means nothing is dragging on them.

		Written by whatever is doing the slowing — today the Bacteria Monster's
		colonies — and read once, last, inside _computeWalkSpeed. It exists
		because that function runs every frame and writes the result: an outside
		write straight to Humanoid.WalkSpeed survives until the survivor sprints
		or swaps weapon, then vanishes, while whatever applied it is still
		holding a stale "real" speed to put back.

		The consequence of doing it this way is the useful one: a slow cannot
		outlive whatever applied it. Clear the attribute and the next frame is
		full speed, with nothing to remember to restore.
	]]
	SpeedDrag = "FL_SpeedDrag", -- number, < 1 while something is slowing them
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
	--[[
		Lobby readiness, which is NOT the pre-round ready gate above it.

		These two were the same string — both "FL_Ready" — so MatchmakingService
		admitting somebody wrote the gate RoundService counts, and dropping them
		cleared it. Prep clears the gate for everybody at the top of the round, which
		is why it never showed up as an obvious bug: what it actually cost was a
		player admitted DURING prep arriving pre-readied, having pressed nothing.

		Nothing reads this one today. It is kept, with its own name, because a
		write-only attribute is cheap and a collision is not.
	]]
	IsReady = "FL_LobbyReady", -- boolean
	IsCrouching = "FL_IsCrouching", -- boolean; the server owns it, the client asks
	--[[
		The walrus, published so every client can see one rather than only the
		player inside it.

		Three attributes and not one, because three different things read them:
		anybody near the walrus needs to know it IS one (the model is welded on
		by the server, but the nameplate and the footsteps change too), the
		walrus's own client needs the health to draw a bar, and it needs the
		deadline to draw a clock. See BecomeWalrus.
	]]
	IsWalrus = "FL_IsWalrus", -- boolean
	WalrusHealth = "FL_WalrusHealth", -- number, what is left of the pool
	WalrusUntil = "FL_WalrusUntil", -- Workspace:GetServerTimeNow() deadline
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
	--[[ Sitting in a turret and driving it by hand. Server-written, so the gate
	     it feeds is the same fact on every machine: the viewmodel goes away and
	     the trigger stops firing the gun in your hands, because it is firing the
	     one you are sitting behind instead. ]]
	ManningTurret = "FL_ManningTurret", -- boolean
	--[[ How many times this survivor has died THIS ROUND, and whether that has
	     run out. Both published because the HUD wants to warn on the last life
	     and the spectate card wants to say why there is no way back. ]]
	Deaths = "FL_Deaths", -- number, reset at every round start
	Eliminated = "FL_Eliminated", -- boolean, out until the next round
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
	--[[ A damage multiplier on this body, 1 when it is not set. Written by a
	     special that has opened a window on itself — see Specials/Metallic's
	     overheat — and read by InfectedService:damage. Published rather than kept
	     private so the HUD can say the window is open, which is the whole point
	     of having one. ]]
	Vulnerable = "FL_Vulnerable", -- number, 1 = normal
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
	--[[ The Enum.Font name the clue is printed in, or nil for the typewriter.
	     The close-up reader reads it so a wall scrawl opens as a scrawl rather
	     than as somebody's wall retyped in Courier — one setting, in the config,
	     rendered twice. ]]
	ClueFont = "FL_ClueFont", -- string?
	--[[
		Which generator this is, 1 through 5, and whether it is running.

		The ORDER is on the prop rather than held only on the server, because the
		prompt has to say "GENERATOR 3" before the player presses anything —
		asking the server what they are looking at would put a round trip in
		front of a label. It is not a secret: the number is written on the side
		of the machine in the map, and the whole objective is to find them in
		that order.

		`GeneratorLive` is what makes a powered generator stop offering a puzzle
		it has already been given. Server-written, like everything else here; a
		client that set it locally would get a prompt that does nothing and a
		refusal from a server that never saw it.
	]]
	GeneratorOrder = "FL_GeneratorOrder", -- number, 1..5
	GeneratorLive = "FL_GeneratorLive", -- boolean, true once it is powered

	--[[
		Which fuse box this is, and whether it has been thrown.

		The NUMBER is the box's identity and not a secret — it is printed on the
		front of the box by the service, because four unlabelled grey boxes in a
		maze of identical corridors is a puzzle nobody can play. What IS secret
		is the order they want, and that is on the server and appears in no
		attribute and no payload.

		`FuseLive` is what stops a thrown box offering to be thrown again, and it
		is also the hook a designer's own light or animation can bind to.
	]]
	FuseOrder = "FL_FuseOrder", -- number, 1..4
	FuseLive = "FL_FuseLive", -- boolean, true once it is thrown

	--[[
		Which beacon this is, whether it is burning, and when it goes out.

		`BeaconUntil` is a server-time stamp rather than a remaining count, the
		same rule every other deadline in this game follows: the client subtracts
		its own clock, so it cannot drift and cannot arrive stale. It is on the
		PROP rather than in a payload because a beacon's state is a fact about
		the world — somebody who joins mid-round, respawns, or looks across the
		field at a fire two hundred studs away reads it for free.
	]]
	BeaconOrder = "FL_BeaconOrder", -- number, 1..4
	BeaconLit = "FL_BeaconLit", -- boolean, true while it burns
	BeaconUntil = "FL_BeaconUntil", -- number, server time it goes out

	--[[ What a doorway that MOVES the player says on its prompt. Written by the
	     service when the door is armed and cleared when it is not, so a door
	     that is still boarded offers nothing at all rather than offering a trip
	     the server will refuse. ]]
	DoorwayPrompt = "FL_DoorwayPrompt", -- string
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

--[[
	Written on a deployed turret model by the Turret ability.

	The health bar over it is a client's job and the numbers behind it are the
	server's, and attributes are the seam: they replicate on their own, they cost
	nothing per frame, and a player who walks up to a turret that was deployed
	before they spawned reads its state without anybody re-sending anything.

	`Manned` is what makes the bar say AUTO or MANUAL, and it is also what stops
	two players fighting over one gun.
]]
Attributes.Turret = table.freeze({
	Health = "FL_TurretHealth", -- number, what is left of it
	MaxHealth = "FL_TurretMaxHealth", -- number, what it was deployed with
	Manned = "FL_TurretManned", -- boolean, somebody is in the seat
	Owner = "FL_TurretOwner", -- number, the UserId of whoever placed it
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
	     map at all — most maps never set it, and only Clinton has one authored
	     today — and Solved is what the keypad UI reads to stop offering a code
	     for a door that is already open. ]]
	VaultPresent = "FL_VaultPresent", -- boolean
	--[[ How many of the vault's clues the TEAM holds, and how many there are.
	     Team-wide on Workspace rather than per player, because four survivors
	     are working one objective — a counter that started again for whoever
	     walked in second would be four separate puzzles in one building. ]]
	CluesFound = "FL_CluesFound", -- number
	CluesTotal = "FL_CluesTotal", -- number, 0 when no puzzle is armed
	VaultSolved = "FL_VaultSolved", -- boolean
	--[[
		What the counter above is COUNTING, in words.

		The three numbers are generic — a side objective with N steps, M of them
		done — and Zombieville's five generators are exactly that shape. What is
		not generic is the wording: a card reading "CLUES 3/5" on a map with no
		clues in it is a counter that lies about what the player is doing.

		So the numbers stay where they are and the words come down beside them.
		The alternative was a second pair of attributes and a client that has to
		work out which pair is live, which is two ways to say one thing and a new
		way for them to disagree.

		Empty on a map with no side objective, which is most of the roster.
	]]
	TrackerLabel = "FL_TrackerLabel", -- string, e.g. "CLUES" or "GENERATORS"
	TrackerHint = "FL_TrackerHint", -- string, the line under it
	--[[
		Where the game is currently pointing, and what it is pointing at.

		Written when a side objective produces a PLACE rather than a fact — the
		loot room, once every generator is powered. An arrow rather than a line
		of text because "get to the loot room" is only useful to somebody who
		already knows where the loot room is, and on a first round nobody does.

		A Vector3 on Workspace rather than a remote, for the same reason every
		other team-wide fact here is an attribute: a survivor who joins, dies and
		respawns, or alt-tabs back in gets the current answer for free, and a
		remote fired once would have missed all three of them.

		Cleared to nil when there is nothing to point at.
	]]
	WaypointPosition = "FL_WaypointPosition", -- Vector3?, nil when nothing is marked
	WaypointLabel = "FL_WaypointLabel", -- string, what the arrow is pointing at

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
		How many BaseParts the live map has, published so a client can tell
		whether it has actually RECEIVED one.

		The distinction this exists for is the whole reason a joining player used
		to end up under the world. A Model replicates to a client as an instance
		first and fills in afterwards, so `CurrentMap` being set and the model
		being findable are both true long before there is a floor in it — and a
		client that answered "I have the map" on either of those was answering a
		question nobody asked.

		A count is the smallest fact that means the right thing, and it works for
		a mid-round joiner as well as for a round start, which is why it is an
		attribute rather than a field in the load event.
	]]
	MapParts = "FL_MapParts", -- number, BaseParts in the live map, 0 in the lobby

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
--[[
	Every pickup in the world carries this tag as well as its attributes.

	The attributes are the CONTRACT — what slot, which item, how much ammo — and
	the tag is how anything finds them at all. Those are different jobs and it
	took a bug to see it: the client's outline pass looked for the Slot attribute
	across Workspace:GetChildren(), which finds a pickup the Director dropped on
	a pad and does not find one standing in the map, because a map's items are
	three levels down inside the map model. So the items a level designer placed
	by hand were the only ones with no outline on them — and they are the ones
	that most need it, since a pill bottle on a dark floor is four studs of
	geometry with no glow of its own.

	Walking the whole of Workspace on a timer instead would be thousands of
	instances several times a second to find a dozen things. A tag is a lookup,
	and it comes with the two signals that make the periodic scan unnecessary.
]]
Attributes.PickupTag = "FL_Pickup"

--[[
	Stands an instance up as a pickup: the slot, the item, and the tag that lets
	anything find it.

	One function rather than four call sites setting two attributes each, because
	the tag was added after three of those four existed and adding it by hand in
	each place is how the fourth gets forgotten.
]]
function Attributes.markPickup(instance: Instance, slot: string, itemId: string)
	instance:SetAttribute(Attributes.Pickup.Slot, slot)
	instance:SetAttribute(Attributes.Pickup.ItemId, itemId)
	CollectionService:AddTag(instance, Attributes.PickupTag)
end

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
