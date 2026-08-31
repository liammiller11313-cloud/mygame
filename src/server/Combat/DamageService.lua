--!strict
--[[
	DamageService — the one place health changes.

	Every bullet, pellet, claw, explosion and fire tick in Fading Light ends up
	here. Nothing else in the codebase may touch Humanoid.Health, and the reason
	is not tidiness: the headshot rule, friendly fire, penetration falloff and the
	gore roll all have to agree on the same arithmetic, and eight subsystems only
	agree on arithmetic when exactly one of them does it.

	The order of operations below is the contract from docs/ARCHITECTURE.md and it
	is load-bearing. Region multiplier BEFORE falloff BEFORE resistance means a
	distant headshot still reads as a headshot; applying resistance first would
	let a boss eat the 4x and make aiming pointless against exactly the enemy you
	most need to aim at.

	── headshotAlwaysKills ─────────────────────────────────────────────────────
	A head hit on an infected whose definition sets the flag is lethal. Not
	"probably lethal", not "lethal above some damage threshold" — lethal. That one
	rule is what turns a 46-strong horde from an HP sponge into a readable crowd.

	It is applied by RAISING the damage to exactly the target's remaining health,
	never to infinity. Overkill drives the gore roll, so a pistol tap that pops a
	head must not produce the same explosion of meat as a point-blank shotgun
	blast. A hit whose honest arithmetic already exceeds the target's health keeps
	its real number and its real overkill.

	── what this service deliberately does NOT do ──────────────────────────────
	It never ragdolls, gibs, incapacitates or despawns anything itself. It decides
	how much damage landed and hands the outcome to the service that owns the
	body: SurvivorService, InfectedService, GoreService. A survivor corpse in
	particular stays SurvivorService's property because it is still a defib
	target — gibbing a downed teammate would delete a revive.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)
local WeaponConfig = require(Shared.Config.WeaponConfig)

type DamageContext = Types.DamageContext
type DamageResult = Types.DamageResult

local DamageService = {}

--[[ Fired after every application that actually moved a health bar.
     (target: Model, result: DamageResult, ctx: DamageContext) ]]
DamageService.damageDealt = Signal.new()

-- Difficulty is a Director-owned string that changes at most once a round.
-- Re-asking for it once per pellet of a ten-pellet blast is pure overhead.
local DIFFICULTY_CACHE_TIME = 2.0

-- Blood scale handed to GoreService for a hit that did NOT kill, normalised
-- against max health so chipping a Tank does not spray like a gibbed Common.
local MIN_BLOOD_SCALE = 0.2

-- An explosion samples two points per target. A survivor crouched behind a low
-- crate is exposed from the head and covered at the root; either sightline
-- counts, because "I was clearly behind the wall and still died" is the worst
-- possible read on a grenade.
local EXPLOSION_HEAD_OFFSET = Vector3.new(0, 2, 0)

local EPSILON = 1e-4

local warned: { [string]: boolean } = {}
local cachedDifficulty: any = nil
local cachedDifficultyAt = 0

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[DamageService] " .. message)
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	The Director owns difficulty; DirectorConfig owns what each difficulty means.
	Read through an optional getter so damage still resolves before the Director
	boots, and so a game with no Director at all plays exactly like Normal (whose
	multipliers are 1.0 and 0.25 — identical to the GameConfig defaults).
]]
local function difficultyProfile(): any
	local now = os.clock()
	if cachedDifficulty and now - cachedDifficultyAt < DIFFICULTY_CACHE_TIME then
		return cachedDifficulty
	end

	local profile = DirectorConfig.Difficulty[DirectorConfig.DefaultDifficulty]
	local director = Registry.find("DirectorService")
	if director and typeof(director.getDifficulty) == "function" then
		local ok, name = pcall(director.getDifficulty, director)
		if ok and typeof(name) == "string" and DirectorConfig.Difficulty[name] then
			profile = DirectorConfig.Difficulty[name]
		end
	end

	cachedDifficulty = profile
	cachedDifficultyAt = now
	return profile
end

--[[ Where the damage came from, for the victim's directional hit indicator.
     Falls back to walking back up the shot line, which is exact for anything
     hitscan and still points at the right half of the room for everything else. ]]
local function sourcePositionFor(ctx: DamageContext): Vector3
	if ctx.attackerModel then
		local root = RigUtil.getRoot(ctx.attackerModel)
		if root then
			return root.Position
		end
	end

	local attacker = ctx.attacker
	local character = attacker and attacker.Character
	if character then
		local root = RigUtil.getRoot(character)
		if root then
			return root.Position
		end
	end

	if ctx.direction.Magnitude > EPSILON and ctx.distance > 0 then
		return ctx.hitPosition - ctx.direction.Unit * ctx.distance
	end
	return ctx.hitPosition
end

--[[
	SurvivorService and InfectedService both return a DamageResult. This makes
	sure that whatever comes back is usable even while those services are still
	being written: a missing or malformed result is rebuilt from the humanoid's
	observed health delta, which is the truth regardless of what was reported.

	`humanoidIsAuthoritative` is true only for infected. A survivor's real health
	lives in SurvivorService's incap model, so their Humanoid is a presentation
	detail and must never be read as a verdict on whether they died.
]]
local function coerceResult(
	raw: any,
	healthBefore: number,
	humanoid: Humanoid,
	requested: number,
	humanoidIsAuthoritative: boolean
): DamageResult
	local health = math.max(humanoid.Health, 0)

	if typeof(raw) == "table" and isFiniteNumber(raw.dealt) then
		raw.blocked = raw.blocked == true
		-- An infected at zero health is dead whatever the caller reported.
		-- Without this, a service that forgets to set `killed` silently costs the
		-- kill its gore, its hitmarker and the Director's relief. Survivors are
		-- exempt: their health lives in SurvivorService's incap model, not in the
		-- Humanoid, so a downed teammate at zero is not a corpse.
		raw.killed = raw.killed == true or (humanoidIsAuthoritative and health <= 0)
		if not isFiniteNumber(raw.overkill) then
			raw.overkill = math.max(requested - healthBefore, 0)
		end
		if typeof(raw.goreLevel) ~= "string" then
			raw.goreLevel = Enums.GoreLevel.None
		end
		if not isFiniteNumber(raw.remainingHealth) then
			raw.remainingHealth = health
		end
		return raw
	end

	local dealt = math.max(healthBefore - health, 0)
	return {
		dealt = dealt,
		blocked = dealt <= 0 and health > 0,
		killed = humanoidIsAuthoritative and health <= 0,
		overkill = math.max(requested - healthBefore, 0),
		goreLevel = Enums.GoreLevel.None,
		severedPart = nil,
		remainingHealth = health,
	}
end

--[[
	The kill feed, for infected kills only — SurvivorService already owns the
	survivor-death line.

	It has to be throttled, and the throttle is categorical rather than a token
	bucket, because during a wave the feed's problem is not volume per second but
	relevance: forty-six commons die in the time it takes to read one line, and a
	feed that scrolls the whole horde is a feed nobody looks at.

	  * a SPECIAL or a BOSS dying is news the whole team wants — broadcast it
	  * a Common dying is not news. It goes back to the player who killed it and
	    to nobody else, only on a headshot, and only every HEADSHOT_STREAK_STEP
	    of them in a row — so the line reads as "you are stringing headshots
	    together", which is the only thing about a common kill worth a row.

	A single miss (any non-headshot kill) resets the count, which is what makes
	the line mean something.
]]
local HEADSHOT_STREAK_STEP = 5

-- Weak keys: a player who leaves is collected with their streak, so this needs
-- no PlayerRemoving connection and this service needs no lifecycle at all.
local headshotStreaks: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

--[[
	Tells a shooter, once, that they are hitting a teammate.

	Throttled per player rather than per shot: an automatic weapon into a
	teammate's back would otherwise be fifteen identical notices a second, which
	is not a warning, it is a fault. One message, then silence for long enough
	that a second incident later still says something.

	The table is weak-keyed so a player who leaves takes their entry with them
	rather than pinning the Player instance for the life of the server.
]]
local lastFriendlyWarnAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

local function warnFriendlyFire(attacker: Player?, damageType: string?)
	if not attacker or not attacker.Parent then
		return
	end
	--[[ Never for a melee swing. Swinging a machete in a doorway full of
	     teammates is the correct panic response and always has been — it is
	     zeroed rather than reduced for exactly that reason — so telling the
	     player off for it would be teaching them the wrong lesson with the wrong
	     words. ]]
	if damageType == Enums.DamageType.Melee then
		return
	end
	local now = os.clock()
	local last = lastFriendlyWarnAt[attacker]
	if last and now - last < GameConfig.Survivor.FriendlyFireWarnCooldown then
		return
	end
	lastFriendlyWarnAt[attacker] = now
	Remotes.Event.Notice:FireClient(attacker, { text = "DON'T SHOOT TEAM MATES", tone = "Warn" })
end

--[[
	How much of the infected's damage one player has asked to receive.

	1.0 for anybody who never touched the setting, which is everybody by default.
	The value is read back through SettingsConfig rather than trusted as written,
	because an attribute is a public surface: a future tool, a plugin or a
	mistake elsewhere could put anything on it, and every path out of that table
	is at most 1.
]]
local function personalDamageScale(player: Player?): number
	if not player then
		return 1
	end
	local choice = player:GetAttribute(Attributes.Player.Difficulty)
	if typeof(choice) ~= "string" then
		return 1
	end
	local profile = SettingsConfig.Difficulty[choice]
	if not profile or not isFiniteNumber(profile.incomingDamage) then
		return 1
	end
	return math.clamp(profile.incomingDamage, 0, 1)
end

local function pushKillFeed(attacker: Player, definition: any, ctx: DamageContext, isHeadshot: boolean)
	local payload = {
		killer = attacker.Name,
		victim = definition.displayName,
		weaponId = ctx.weaponId or "",
		headshot = isHeadshot,
	}

	if definition.isSpecial or definition.isBoss then
		headshotStreaks[attacker] = 0
		Remotes.Event.KillFeed:FireAllClients(payload)
		--[[ A boss going down is the loudest moment a round has, and until now it
		     was one more grey line in the kill feed. The whole team gets told,
		     because the whole team was fighting it — a Tank is the only enemy in
		     this game that four people work on together, and the payoff should be
		     shared the same way. Specials are deliberately NOT announced: three
		     Hunters in a wave would turn the notice line into a second kill
		     feed. ]]
		if definition.isBoss then
			Remotes.Event.Notice:FireAllClients({
				text = string.upper(definition.displayName) .. " DOWN",
				tone = "Good",
				--[[ The client plays a stinger for this one. A flag rather than a
				     sound id, because which sound a notice makes is a client
				     presentation decision and the server has no business holding
				     an asset id. ]]
				sting = true,
			})
		end
		return
	end

	if not isHeadshot then
		headshotStreaks[attacker] = 0
		return
	end

	local streak = (headshotStreaks[attacker] or 0) + 1
	headshotStreaks[attacker] = streak
	if streak % HEADSHOT_STREAK_STEP == 0 then
		Remotes.Event.KillFeed:FireClient(attacker, payload)
	end
end

--[[
	The funnel. Returns a DamageResult for EVERY path, rejected ones included, so
	that no caller anywhere has to branch on nil in the middle of a shotgun blast.

	`baseDamage` is the weapon's or attack's raw number — the caller does not
	pre-multiply anything. Every multiplier in the game is applied here.
]]
function DamageService:applyDamage(target: Model, baseDamage: number, ctx: DamageContext): DamageResult
	-- ── 1. reject a dead target or a nonsense context ────────────────────────
	if typeof(target) ~= "Instance" or not target:IsA("Model") or not target.Parent then
		return Types.blockedResult()
	end
	if not isFiniteNumber(baseDamage) or baseDamage <= 0 then
		return Types.blockedResult()
	end
	if typeof(ctx) ~= "table" then
		return Types.blockedResult()
	end

	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return Types.blockedResult()
	end
	if not RigUtil.isAlive(target) then
		return Types.blockedResult(math.max(humanoid.Health, 0))
	end

	local player = Players:GetPlayerFromCharacter(target)
	local isSurvivor = player ~= nil

	local kind = target:GetAttribute(Attributes.Infected.Kind)
	local infectedDefinition = if typeof(kind) == "string" then InfectedConfig.get(kind) else nil
	if not isSurvivor and not infectedDefinition then
		-- Every infected carries FL_Kind (Attributes.Infected.Kind) from the moment
		-- it spawns. A humanoid model without one is a rig that skipped
		-- InfectedService, and guessing its resistance would hide that bug.
		warnOnce(
			"unknownTarget",
			string.format(
				"%q has a Humanoid but no %s attribute; damage refused",
				target.Name,
				Attributes.Infected.Kind
			)
		)
		return Types.blockedResult(math.max(humanoid.Health, 0))
	end

	-- A region that is not in the table would silently become a zero multiplier.
	local region = ctx.region
	if GameConfig.HitRegionMultipliers[region] == nil then
		region = Enums.HitRegion.Torso
		ctx.region = region
	end

	-- The server decides what friendly fire is. A caller could set this field to
	-- anything, and "was that a teammate" is not a client's call to make.
	local isFriendlyFire = isSurvivor and ctx.attacker ~= nil
	ctx.isFriendlyFire = isFriendlyFire

	local healthBefore = math.max(humanoid.Health, 0)

	-- ── 2. hit region ────────────────────────────────────────────────────────
	local damage = baseDamage * GameConfig.HitRegionMultipliers[region]

	-- ── 3. distance falloff, then penetration falloff ────────────────────────
	local definition = if typeof(ctx.weaponId) == "string" then WeaponConfig.get(ctx.weaponId) else nil
	if definition then
		local distance = if isFiniteNumber(ctx.distance) then math.max(ctx.distance, 0) else 0
		damage *= WeaponConfig.getFalloffMultiplier(definition, distance)

		local pierced = if isFiniteNumber(ctx.piercedCount)
			then math.max(math.floor(ctx.piercedCount), 0)
			else 0
		if pierced > 0 then
			damage *= definition.penetrationFalloff ^ pierced
		end
	end

	-- ── 4. resistance, friendly fire, difficulty ─────────────────────────────
	if isSurvivor then
		local difficulty = difficultyProfile()
		if isFriendlyFire then
			--[[
				Friendly fire, off.

				Blocked outright rather than scaled down. At any non-zero multiplier
				the answer to "can a teammate kill me" is still yes given enough
				bullets, and on a public server that is a griefing tool before it is
				a tension. The arithmetic below is left intact behind the flag
				because L4D's friendly fire IS the thing that makes a doorway
				frightening — this is a deployment decision, not a deletion.

				The shooter is told, because the alternative silence reads as a
				broken gun: no damage, no hitmarker, no gore, no explanation.
			]]
			--[[ Your OWN blast and your own fire still hurt you. `isFriendlyFire`
			     counts self-damage — a molotov's fire names its thrower as the
			     attacker — and blocking that too would make throwables free to
			     stand in, which deletes the one thing that makes throwing one a
			     decision. Teammates are protected from a player; a player is not
			     protected from themselves. ]]
			if not GameConfig.Survivor.FriendlyFireEnabled and ctx.attacker ~= player then
				warnFriendlyFire(ctx.attacker, ctx.damageType)
				return Types.blockedResult(healthBefore)
			end

			-- Melee is 0.0 on purpose: swinging a machete in a doorway full of
			-- teammates has to stay the correct panic response, not a team wipe.
			if ctx.damageType == Enums.DamageType.Melee then
				damage *= GameConfig.Survivor.FriendlyFireMeleeMultiplier
			else
				-- DirectorConfig's per-difficulty friendly fire supersedes the
				-- GameConfig default. Normal's is 0.25 — the same number — so the
				-- default game is unchanged either way.
				local multiplier = difficulty.friendlyFire
				if not isFiniteNumber(multiplier) then
					multiplier = GameConfig.Survivor.FriendlyFireMultiplier
				end
				damage *= multiplier
			end
			-- SurvivorService:damage scales friendly fire too, and skips it when
			-- this flag is set. Nothing was setting it, so every teammate hit was
			-- taking 0.25 twice and landing at 6% — friendly fire was effectively
			-- off, and friendly fire is what makes a doorway frightening. Every
			-- call site builds a fresh DamageContext per hit (one per pellet of a
			-- blast), so this cannot leak onto a later hit.
			(ctx :: any).friendlyFireApplied = true
		else
			-- Infected and the world hit harder on higher difficulties. Normal is
			-- 1.0, so this is a no-op in the default game.
			local multiplier = difficulty.infectedDamage
			if not isFiniteNumber(multiplier) then
				multiplier = 1
			end
			damage *= multiplier

			--[[
				Then the player's OWN difficulty, on top of the Director's.

				Two different questions, which is why they multiply rather than one
				replacing the other: the Director's number is how hard this round
				is for everybody, and this one is how much of that a particular
				player asked to be spared. It reads the attribute rather than a
				table so there is one authority — the server wrote it, from a value
				it coerced itself, and nothing on the client can move it.

				Applied here and nowhere else, so it can only ever touch damage
				coming IN. A survivor's outgoing damage, their teammates' health and
				the Director's pacing are all untouched by it.
			]]
			damage *= personalDamageScale(player)
		end
	else
		damage *= (infectedDefinition :: any).damageResistance
	end

	-- ── 5. headshotAlwaysKills. This rule is the game. ───────────────────────
	if
		infectedDefinition
		and region == Enums.HitRegion.Head
		and (infectedDefinition :: any).headshotAlwaysKills
		and damage < healthBefore
	then
		-- Raised to EXACTLY the remaining health, never higher: lethal without
		-- inventing overkill the shot did not earn, so the gore roll still tells
		-- a pistol tap and a point-blank shotgun blast apart.
		damage = healthBefore
	end

	if damage <= 0 then
		return Types.blockedResult(healthBefore)
	end

	-- ── 6. route to the service that owns the body ───────────────────────────
	local raw: any
	if isSurvivor then
		local survivors = Registry.get("SurvivorService")
		raw = survivors:damage(player, damage, ctx)
	else
		local infected = Registry.get("InfectedService")
		raw = infected:damage(target, damage, ctx)
	end

	local result = coerceResult(raw, healthBefore, humanoid, damage, not isSurvivor)
	if result.blocked then
		return result
	end

	-- ── 7. gore ──────────────────────────────────────────────────────────────
	-- Survivors are excluded on purpose: a dead survivor is still a defib target
	-- and their body belongs to SurvivorService until the round says otherwise.
	if result.killed and not isSurvivor then
		local gore = Registry.get("GoreService")
		local maxHealth = math.max(humanoid.MaxHealth, 1)

		-- Wrapped because a gore failure must not swallow the kill, the
		-- hitmarker, or the nine pellets of the blast that have not resolved yet.
		local ok, level, severed = pcall(gore.evaluate, gore, target, ctx, result.overkill, maxHealth)
		if ok then
			result.goreLevel = if typeof(level) == "string" then level else Enums.GoreLevel.None
			result.severedPart = if typeof(severed) == "string" then severed else nil
		else
			warnOnce("evaluate", "GoreService:evaluate failed: " .. tostring(level))
			result.goreLevel = Enums.GoreLevel.None
		end

		-- GoreService implements this too; enforcing it here as well guarantees
		-- that an explosion is never a tidy ragdoll no matter which side of the
		-- scoring formula moves next.
		if GoreConfig.Scoring.ExplosiveAlwaysGibs and ctx.damageType == Enums.DamageType.Explosive then
			result.goreLevel = Enums.GoreLevel.Gib
			result.severedPart = nil
		end

		local processed, err = pcall(gore.processKill, gore, target, ctx, result)
		if not processed then
			warnOnce("processKill", "GoreService:processKill failed: " .. tostring(err))
		end
	elseif not isSurvivor and result.dealt > 0 then
		-- Blood on a hit that did not kill. GoreService owns the blood on a kill
		-- (processKill sprays its own), so this is the only path that would
		-- otherwise leave a wounded body dry. It is throttled by
		-- GoreConfig.Budget.MaxGoreEventsPerSecond on the far side.
		local gore = Registry.find("GoreService")
		if gore and typeof(gore.spawnBlood) == "function" then
			local scale = math.clamp(result.dealt / math.max(humanoid.MaxHealth, 1), MIN_BLOOD_SCALE, 1)
			gore:spawnBlood(ctx.hitPosition, ctx.hitNormal, ctx.direction, scale)
		end
	end

	-- ── 8. feedback ──────────────────────────────────────────────────────────
	local isHeadshot = region == Enums.HitRegion.Head

	local attacker = ctx.attacker
	if attacker and attacker.Parent then
		-- The hitmarker is the player's only proof the server agreed with them.
		-- It goes out immediately and carries the real, post-multiplier number.
		--[[ `kind` rides along on a KILL only, and is what lets the client weight
		     the feedback to the thing that died. A Common and a Tank produce the
		     same hitmarker today, which is the single flattest thing about
		     killing here: the moment that should land hardest in the whole game
		     is indistinguishable from the three hundred that should not.

		     Sent from the server rather than read off the model client-side
		     because by the time this arrives the body is a corpse the client may
		     already have released. Empty for a survivor and for a hit that did
		     not kill — the client treats absent as Common. ]]
		Remotes.Event.HitConfirmed:FireClient(attacker, {
			region = region,
			damage = result.dealt,
			killed = result.killed,
			isHeadshot = isHeadshot,
			position = ctx.hitPosition,
			--[[ What did it, so the client can give a melee connect its own weight.
			     A bullet's feedback is the recoil and the report; a swing has
			     nothing that distinguishes hitting from missing. ]]
			damageType = ctx.damageType,
			kind = if result.killed and not isSurvivor
				then target:GetAttribute(Attributes.Infected.Kind)
				else nil,
		})
	end

	if isSurvivor and player then
		Remotes.Event.DamageTaken:FireClient(player, {
			amount = result.dealt,
			sourcePosition = sourcePositionFor(ctx),
			damageType = ctx.damageType,
		})
	end

	if result.killed and not isSurvivor and attacker and attacker.Parent then
		pushKillFeed(attacker, infectedDefinition :: any, ctx, isHeadshot)
	end

	-- The bone/flesh split is not decoration: it is the only audible existence
	-- the 4x head multiplier has.
	local audio = Registry.find("AudioService")
	if audio then
		local key = if isHeadshot then "Bone" else "Flesh"
		audio:playAt(AudioConfig.Impact[key], ctx.hitPosition)
	end

	-- ── the Director's read on how the fight is going ────────────────────────
	-- find(), not get(): damage has to keep working before the Director boots.
	local director = Registry.find("DirectorService")
	if director then
		if isSurvivor and player and result.dealt > 0 then
			director:addIntensity(player, result.dealt * DirectorConfig.Intensity.DamageTakenWeight)
		end
		if result.killed and not isSurvivor and attacker then
			-- Negative on purpose. Killing things calms the read slightly, which
			-- is what makes clearing a horde feel like earning the next lull.
			director:addIntensity(attacker, -DirectorConfig.Intensity.KillRelief)
		end
	end

	DamageService.damageDealt:fire(target, result, ctx)
	return result
end

--[[
	Radial damage. Falls off linearly to nothing at the rim and requires a
	sightline, so a wall genuinely protects you — a pipe bomb that kills through
	a floor is the single fastest way to make a level feel arbitrary.

	`ctx` supplies the attacker and weapon; the region, position, direction and
	distance are rewritten per target. Returns how many targets were damaged.
]]
function DamageService:applyExplosion(
	position: Vector3,
	radius: number,
	damage: number,
	ctx: DamageContext
): number
	if typeof(position) ~= "Vector3" or not isFiniteNumber(radius) or radius <= 0 then
		return 0
	end
	if not isFiniteNumber(damage) or damage <= 0 then
		return 0
	end

	local context: DamageContext = if typeof(ctx) == "table" then ctx else Types.newDamageContext()

	-- Fire is routed through here too (a molotov burst), and GoreConfig says a
	-- burned body stays recognisably a body, so its damage type survives intact.
	local damageType = if context.damageType == Enums.DamageType.Fire
		then Enums.DamageType.Fire
		else Enums.DamageType.Explosive

	local candidates: { Model } = {}

	local infected = Registry.find("InfectedService")
	if infected and typeof(infected.getAlive) == "function" then
		for _, model in infected:getAlive() do
			table.insert(candidates, model)
		end
	end

	local survivors = Registry.find("SurvivorService")
	if survivors and typeof(survivors.getSurvivorCharacters) == "function" then
		for _, model in survivors:getSurvivorCharacters() do
			table.insert(candidates, model)
		end
	end

	-- Bodies never shield each other. Standing behind a Common has to be worse
	-- than standing behind a wall, or players learn to use the horde as cover.
	local ignore: { Instance } = table.clone(candidates :: any)

	local damaged = 0
	for _, model in candidates do
		if not RigUtil.isAlive(model) then
			continue
		end
		local root = RigUtil.getRoot(model)
		if not root then
			continue
		end

		local delta = root.Position - position
		local distance = delta.Magnitude
		if distance > radius then
			continue
		end

		local exposed = RaycastUtil.hasLineOfSight(position, root.Position, ignore)
			or RaycastUtil.hasLineOfSight(position, root.Position + EXPLOSION_HEAD_OFFSET, ignore)
		if not exposed then
			continue
		end

		local falloff = math.clamp(1 - distance / radius, 0, 1)
		local amount = damage * falloff
		if amount <= 0 then
			continue
		end

		local direction = if distance > EPSILON then delta.Unit else Vector3.yAxis
		local result = self:applyDamage(
			model,
			amount,
			Types.newDamageContext({
				attacker = context.attacker,
				attackerModel = context.attackerModel,
				weaponId = context.weaponId,
				damageType = damageType,
				-- A blast has no aim. Charging it the 4x head multiplier because
				-- a rig's head happened to be nearest would make grenades random.
				region = Enums.HitRegion.Torso,
				hitPosition = root.Position - direction * math.min(distance, root.Size.Magnitude),
				hitNormal = -direction,
				direction = direction,
				distance = distance,
				piercedCount = 0,
			})
		)

		if not result.blocked then
			damaged += 1
		end
	end

	return damaged
end

Registry.register("DamageService", DamageService)

return DamageService
