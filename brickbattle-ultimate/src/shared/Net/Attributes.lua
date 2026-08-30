--!strict
--[[
	Attributes — the contract for continuously-replicated state.

	Roblox replicates Instance attributes to every client automatically, with
	delta compression and no per-frame remote traffic. That makes them strictly
	better than remotes for values that change often and that everyone can see.

	The rule this codebase follows:
	  * Numbers that CHANGE OFTEN and are PUBLIC -> attribute (declared here)
	  * Things that HAPPEN ONCE                  -> RemoteEvent (Remotes.lua)

	Only the server ever writes these. Clients read them, and may listen with
	:GetAttributeChangedSignal(). A client writing one is a no-op that will be
	overwritten, and should be treated as a bug rather than a trick.

	## On the prefix

	Every name is built from PREFIX below, and that is deliberate. The old place
	this game is being revived from runs HD Admin, a Realism Mod and a Slap
	Battles glove kit, any one of which may already write attributes onto players
	or characters. A collision does not error — it silently corrupts state — and
	it cannot be ruled out until the exported place is grepped for SetAttribute.

	So the prefix stays a single constant until then, and changing it stays a
	one-line edit rather than a rename across every reader. See DECISIONS.md Q1.
]]

local PREFIX = "BBU_"

local function name(suffix: string): string
	return PREFIX .. suffix
end

local Attributes = {}

Attributes.PREFIX = PREFIX

--[[
	Written on the Player instance, so it survives character respawns. That
	matters more here than it looks: a timed respawn means the scoreboard and the
	Tix counter must keep rendering for a player who currently has no character.
]]
Attributes.Player = table.freeze({
	Team = name("Team"), -- string, Enums.Team, or "" in the lobby
	Kills = name("Kills"), -- number, this round
	Deaths = name("Deaths"), -- number, this round
	--[[ Tix. An attribute rather than a remote because it moves on every kill
	     and every click, and because the client can read the earning off the
	     DELTA — a "+5" popup for no network cost at all. Public, like everything
	     on a Player: a teammate seeing your balance costs nothing, and the
	     end-of-round screen wants it anyway. ]]
	Tix = name("Tix"), -- number, server-owned
	Level = name("Level"), -- number
	Experience = name("Experience"), -- number, into the current level
	--[[ An absolute GetServerTimeNow stamp, not a countdown. The client renders
	     a smooth respawn timer from a value that changes once, instead of one
	     ticked over the wire sixty times a second. 0 means alive. ]]
	RespawnsAt = name("RespawnsAt"),
	--[[ Set while the profile has not loaded, or has failed to load. The shop
	     reads it and refuses to sell rather than letting someone spend an
	     evening's Tix into a session that will never save. ]]
	DataReady = name("DataReady"), -- boolean
})

--[[
	Written on the game state holder, read by every HUD element that needs to
	agree with every other one.
]]
Attributes.Game = table.freeze({
	Phase = name("Phase"), -- string, Enums.RoundPhase
	--[[ Absolute server-time stamp the current phase ends at, for the same
	     reason RespawnsAt is absolute. Every clock in the UI derives from this
	     one number, which is what stops the lobby countdown and the round timer
	     from ever disagreeing. ]]
	PhaseEndsAt = name("PhaseEndsAt"),
	RedScore = name("RedScore"), -- number
	BlueScore = name("BlueScore"), -- number
	KillTarget = name("KillTarget"), -- number, 0 when the round is on a clock
	MapName = name("MapName"), -- string, "" in the lobby
	RoundNumber = name("RoundNumber"), -- number, since server start
})

--[[
	Written on a Tool instance by the upgrade system. Lives on the Tool rather
	than the Player because a player can hold two upgraded tools at once, and
	because the tool's own scripts are what need to read it.
]]
Attributes.Tool = table.freeze({
	WeaponId = name("WeaponId"), -- string, Enums.Weapon
	UpgradeLevel = name("UpgradeLevel"), -- number, 0 = stock
	OwnerUserId = name("OwnerUserId"), -- number; a dropped tool still knows whose it was
})

--[[
	Written on a projectile part by the server that spawned it, so a client
	rendering the trail knows what it is looking at without a remote per shot.
]]
Attributes.Projectile = table.freeze({
	WeaponId = name("WeaponId"),
	FiredBy = name("FiredBy"), -- number, UserId
	--[[ Absolute stamp at which the projectile self-destructs. A superball that
	     finds a geometry seam and bounces forever is a real outcome, so every
	     projectile carries its own deadline rather than trusting its collisions. ]]
	ExpiresAt = name("ExpiresAt"),
})

return Attributes
