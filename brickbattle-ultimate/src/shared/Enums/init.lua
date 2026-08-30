--!strict
--[[
	Enums — every string constant the game compares against, in one place.

	The rule is simple: if two files ever compare the same string literal, that
	string belongs here. A renamed weapon that gets renamed in the config and not
	in the service is the single most common bug in a Roblox codebase of this
	shape, and it fails silently — the comparison just stops matching.

	Every table is frozen, so a typo'd WRITE errors at the assignment rather than
	surfacing later as an unexplained nil.
]]

local Enums = {}

-- The two sides. Classic brickbattle is red against blue and has never been
-- anything else; the values are the BrickColor names so a Team's colour and its
-- identity cannot drift apart.
Enums.Team = table.freeze({
	Red = "Bright red",
	Blue = "Bright blue",
})

-- The classic arsenal. These keys are the identity of a weapon everywhere: the
-- config block, the Tool's name in storage, the upgrade record in a save, and
-- the kill-feed icon all key off the same string.
Enums.Weapon = table.freeze({
	Sword = "Sword", -- the linked sword; lunge on double-click
	Superball = "Superball", -- bounces, kills what it touches
	Slingshot = "Slingshot", -- arcing shot
	PaintballGun = "PaintballGun",
	RocketLauncher = "RocketLauncher", -- radius damage, knockback, rocket jump
	TimeBomb = "TimeBomb", -- thrown, fused, radius
	Trowel = "Trowel", -- builds; not a weapon at all
	SpeedCoil = "SpeedCoil", -- passive movement buff while held
	Knife = "Knife",
})

-- How a player died. Drives the kill-feed verb and the death presentation, and
-- is the branch the friendly-fire and self-damage rules are written against.
Enums.DamageType = table.freeze({
	Melee = "Melee",
	Projectile = "Projectile",
	Explosion = "Explosion",
	Environment = "Environment", -- the void, a crusher, falling out of the map
})

--[[
	The round state machine. The order here IS the loop:

	  Lobby -> Intermission -> Starting -> Live -> Results -> MapVote -> Lobby

	Lobby is the resting state with too few players; Intermission is the
	countdown once there are enough. They are separate because a countdown that
	pauses when someone leaves reads as broken, and one that does not reads as
	unfair — keeping them distinct lets the code do the right thing in each.
]]
Enums.RoundPhase = table.freeze({
	Lobby = "Lobby",
	Intermission = "Intermission",
	Starting = "Starting", -- on the map, forcefielded, 3-2-1
	Live = "Live",
	Results = "Results",
	MapVote = "MapVote",
})

-- Why a round ended. The scoreboard says something different for each, and
-- "everyone left" must not be reported as a win for whoever happened to remain.
Enums.RoundEndReason = table.freeze({
	KillTarget = "KillTarget",
	TimeExpired = "TimeExpired",
	TeamEliminated = "TeamEliminated",
	Abandoned = "Abandoned",
})

--[[
	Where Tix came from. Kept as an enum rather than a bare number because the
	client renders a different popup per source, and because a server-side
	throttle can only be written per-source: clicking needs a rate limit that
	winning a round must not be subject to.
]]
Enums.TixSource = table.freeze({
	Kill = "Kill",
	RoundWin = "RoundWin",
	RoundPlayed = "RoundPlayed",
	Click = "Click",
	Pickup = "Pickup",
	Quest = "Quest",
	Gamepass = "Gamepass",
})

return Enums
