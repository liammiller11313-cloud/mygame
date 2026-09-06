--!strict
--[[
	AudioService — the server's voice mixer.

	Three facts shape everything in this file.

	1. The bank is PARTIALLY filled. Most ids are real now, a few entries are
	   still "". So this service is routinely asked to play a sound that does not
	   exist yet, and that has to be silent, free, and reported exactly ONCE per
	   distinct sound — a warn per gunshot would bury every other message in the
	   output window inside ten seconds, and a playtest with a broken warn stream
	   is a playtest nobody finishes.

	2. A horde death-pile asks for two hundred sounds in a single frame. Roblox
	   will cheerfully start all of them, and the result carries no information:
	   forty identical squelches at slightly different times is noise, not
	   feedback. AudioConfig.Mix is the answer — a hard voice cap, a per-category
	   cap so gunfire cannot starve the special-infected tells that keep players
	   alive, and a retrigger interval so one sound cannot machine-gun itself.

	3. VARIATION IS THE POINT of AudioConfig's `ids` lists, and it only exists if
	   the play path uses it. Every sample is chosen through AudioConfig.pickId,
	   never off `definition.id` — reading the field takes the first entry every
	   time, which turns Impact.Flesh's three samples into one sound that fires
	   on every connecting shot, which is exactly what the feature was added to
	   prevent.

	── LEAVING ONE LISTENER OUT ────────────────────────────────────────────────
	`playAt` and `playOn` take an optional `exclude` player. The shooter's own
	client already played a 2D copy of their gunshot the instant they clicked, so
	a world emitter they can also hear arrives ~100ms later as an echo of their
	own gun. PlayerGui is the only container the server can put an instance into
	and have it replicate to exactly one client, so excluding a listener means
	one emitter per REMAINING listener instead of one in Workspace. That is worth
	doing for the handful of sounds that have an owner and wrong for everything
	else, which is why it is opt-in per call.

	Six call sites pass one, covering the three sounds in this game that a
	player makes and hears themselves: the gunshot (BallisticsService), the
	melee swing (MeleeService), and the four reload cues (InventoryService).
	Everything
	else is deliberately not excluded — an impact, a body falling, a teammate's
	pills — because nobody has already heard those.

	Bullet impacts look like they qualify and do not: the client never plays
	them, on purpose. See the note at the top of ImpactController.

	Positional sounds live on a temporary anchored emitter part. That part is
	CanQuery = false and CanTouch = false, which is not cosmetic: an emitter that
	answers raycasts would stop the next bullet fired through the space where the
	last one landed.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

type SoundDefinition = AudioConfig.SoundDefinition

--[[ One playing sound plus the bookkeeping needed to bill and reclaim it.

     `holders` is a list because an excluded listener forces one emitter per
     remaining player. They are one VOICE regardless: it is one event in the
     world, it costs one slot in the budget, and `sound` is whichever copy the
     sweep reads timing off. ]]
type Voice = {
	sound: Sound,
	holders: { BasePart }?, -- the temporary emitters, when we made any
	category: string,
	priority: number,
	startedAt: number,
	expiresAt: number,
	looped: boolean,
}

local MIX = AudioConfig.Mix

-- The definition banks that share the SoundDefinition shape. Music is
-- deliberately absent: it is a different shape (fade times, no pitch spread)
-- and it is cross-faded on the client by MusicController, not fired as a voice.
local CATEGORIES = { "WeaponFire", "WeaponReload", "Impact", "Gore", "Infected", "Survivor", "UI" }

local UNKNOWN_CATEGORY = "Other"

-- Sound.TimeLength is 0 until the asset streams in, so a fresh voice has no
-- knowable end time. It gets this long to prove it can load; a sound whose id is
-- broken or unreachable must still give its slot back rather than hold it for
-- the rest of the round.
local UNKNOWN_LIFETIME = 12
local TAIL_GRACE = 0.15 -- slack past TimeLength so nothing is clipped by a rounding error

-- Debris is the belt to the sweep's braces: if this service is ever torn down
-- or errors mid-round, no emitter part outlives it.
local DEBRIS_LIFETIME = UNKNOWN_LIFETIME + 4

-- Reclaiming a voice up to this late is inaudible, and sweeping at ~16Hz instead
-- of every frame is a quarter of the work for nothing given up.
local SWEEP_INTERVAL = 0.06

local EMITTER_SIZE = Vector3.new(0.2, 0.2, 0.2)

-- Slack past a definition's own rollOffMax when deciding who gets a per-player
-- emitter. The listener is the camera, not the root part this is measured from,
-- and a survivor who runs toward the sound during its tail should still hear it.
local AUDIBLE_SLACK = 40

-- Retrigger timing is scoped, so a UI sound played for four players in the same
-- frame is four legitimate plays rather than one play and three suppressions.
-- Everything positional shares this one scope.
local WORLD_SCOPE = table.freeze({})

-- A stand-in key for "someone passed nil", which cannot itself be a table key.
local NIL_DEFINITION = table.freeze({})

local random = Random.new()

local AudioService = {}

AudioService._trove = Trove.new()
AudioService._voices = {} :: { Voice }
AudioService._categoryCounts = {} :: { [string]: number }
AudioService._catalog = {} :: { [any]: string } -- definition -> category
AudioService._names = {} :: { [any]: string } -- definition -> "AudioConfig.Gore.Gib"
AudioService._retrigger = {} :: { [any]: { [any]: number } } -- scope -> definition -> os.clock()
AudioService._warned = {} :: { [any]: boolean }
AudioService._sweepAccumulator = 0

function AudioService:init()
	-- Identity-map every definition to its category once, here, so the hot path
	-- can bill a sound without a search or a string build.
	for _, category in CATEGORIES do
		local bank = (AudioConfig :: any)[category]
		if typeof(bank) == "table" then
			for key, definition in bank do
				self._catalog[definition] = category
				self._names[definition] = string.format("AudioConfig.%s.%s", category, key)
			end
		end
	end
end

function AudioService:start()
	-- One connection for every sound in the game. Per-sound Ended handlers would
	-- be dozens of connections during a horde, and they never fire at all for an
	-- id that failed to load — which, right now, is all of them.
	self._trove:add(RunService.Heartbeat:Connect(function(deltaTime: number)
		self._sweepAccumulator += deltaTime
		if self._sweepAccumulator >= SWEEP_INTERVAL then
			self._sweepAccumulator = 0
			self:_sweep()
		end
	end))

	self._trove:add(Players.PlayerRemoving:Connect(function(player: Player)
		self._retrigger[player] = nil
	end))
end

--[[
	Plays a sound at a world position from a temporary emitter.

	`parent` defaults to Workspace. Pass something else only to scope the
	emitter's lifetime to an object that may be destroyed early — a corpse being
	recycled should take its own body-fall sound with it.

	`exclude` leaves one player out of the audience. Pass the shooter for
	anything they already heard locally; see the header. When it is set, `parent`
	is ignored — the emitters have to live in each listener's own PlayerGui or
	they would not be per-player at all.
]]
function AudioService:playAt(
	definition: SoundDefinition,
	position: Vector3,
	parent: Instance?,
	exclude: Player?
): Sound?
	if exclude ~= nil and typeof(exclude) == "Instance" and exclude:IsA("Player") then
		return self:_playExcluding(definition, position, exclude)
	end

	local category = self:_admit(definition, WORLD_SCOPE)
	if not category then
		return nil
	end

	local holder = self:_buildEmitter(position)
	local sound = self:_buildSound(definition)
	sound.Parent = holder
	holder.Parent = parent or Workspace
	sound:Play()

	if not sound.Looped then
		Debris:AddItem(holder, DEBRIS_LIFETIME)
	end

	self:_track(sound, { holder }, category, definition)
	return sound
end

--[[ Plays a sound from an existing part, so it tracks that part as it moves.
     Use this for anything attached to a body: footsteps, vocalisations, a
     Tank's footfalls.

     `exclude` costs the tracking: a per-player emitter cannot be welded to a
     part in Workspace, so an excluded-listener sound is fixed at the part's
     position when it started. Every caller that wants one is a one-shot impact
     of a tenth of a second, which does not move far enough to notice. ]]
function AudioService:playOn(definition: SoundDefinition, part: BasePart, exclude: Player?): Sound?
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		return nil
	end

	if exclude ~= nil and typeof(exclude) == "Instance" and exclude:IsA("Player") then
		return self:_playExcluding(definition, part.Position, exclude)
	end

	local category = self:_admit(definition, WORLD_SCOPE)
	if not category then
		return nil
	end

	local sound = self:_buildSound(definition)
	sound.Parent = part
	sound:Play()

	if not sound.Looped then
		Debris:AddItem(sound, DEBRIS_LIFETIME)
	end

	self:_track(sound, nil, category, definition)
	return sound
end

--[[
	One emitter per listener, in that listener's own PlayerGui, so the excluded
	player never receives the instance at all. That container is the only
	server-side replication filter Roblox offers; there is no way to make a
	single Workspace emitter inaudible to one client.

	The sample and the pitch are chosen ONCE and shared: this is one event in the
	world, and two survivors standing together hearing two different waveforms of
	the same gunshot would read as two guns.

	Returns nil — and costs nothing at all — when nobody is left to hear it,
	which is the whole of solo play. `_admit` is deliberately called after that
	check so an unheard sound never spends a voice. The out-of-earshot skip is
	what keeps this affordable at 22 rounds a second.
]]
function AudioService:_playExcluding(definition: SoundDefinition, position: Vector3, exclude: Player): Sound?
	if definition == nil then
		self:_warnOnce(
			NIL_DEFINITION,
			"[AudioService] asked to play a nil definition — check the AudioConfig key at the call site"
		)
		return nil
	end
	-- Checked here as well as in _admit, because the audience is gathered first
	-- and an unconfigured id must not cost that walk.
	if not AudioConfig.isConfigured(definition) then
		self:_warnOnce(definition, nil)
		return nil
	end

	local reach = (definition.rollOffMax or 200) + AUDIBLE_SLACK
	local reachSquared = reach * reach

	-- The GUIs rather than the players: the second loop would otherwise look each
	-- one up again, and a player who left in between would be a nil parent.
	local guis: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player == exclude then
			continue
		end
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			continue
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude ^ 2 > reachSquared then
			-- Out of the definition's own rolloff. At 22 rounds a second an
			-- emitter for someone who cannot hear it is pure instance churn.
			continue
		end
		table.insert(guis, playerGui)
	end

	if #guis == 0 then
		return nil
	end

	local category = self:_admit(definition, WORLD_SCOPE)
	if not category then
		return nil
	end

	local id = AudioConfig.pickId(definition)
	local pitch = random:NextNumber(definition.pitchMin or 1, definition.pitchMax or 1)

	local holders = table.create(#guis)
	local primary: Sound? = nil

	for _, playerGui in guis do
		local holder = self:_buildEmitter(position)
		local sound = self:_buildSound(definition, id, pitch)
		sound.Parent = holder
		holder.Parent = playerGui
		sound:Play()
		table.insert(holders, holder)
		if not sound.Looped then
			Debris:AddItem(holder, DEBRIS_LIFETIME)
		end
		primary = primary or sound
	end

	self:_track(primary :: Sound, holders, category, definition)
	return primary
end

--[[ The anchored, unqueryable, untouchable part a positional sound rides on. ]]
function AudioService:_buildEmitter(position: Vector3): BasePart
	local holder = Instance.new("Part")
	holder.Name = "FL_SoundEmitter"
	holder.Size = EMITTER_SIZE
	holder.CFrame = CFrame.new(position)
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Locked = true
	return holder
end

--[[
	Plays a non-positional sound for exactly one player.

	A Sound with no BasePart ancestor plays 2D, and PlayerGui replicates to a
	single client — so parenting there is the whole trick. Used for hitmarkers,
	pickups and anything else that is feedback to one player rather than an event
	in the world.
]]
function AudioService:playForPlayer(player: Player, definition: SoundDefinition): Sound?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		-- Joined this instant, or already leaving. Not an error worth reporting.
		return nil
	end

	local category = self:_admit(definition, player)
	if not category then
		return nil
	end

	local sound = self:_buildSound(definition)
	sound.Parent = playerGui
	sound:Play()

	if not sound.Looped then
		Debris:AddItem(sound, DEBRIS_LIFETIME)
	end

	self:_track(sound, nil, category, definition)
	return sound
end

--[[
	Plays a sound by category and key, so callers never touch AudioConfig or the
	voice budget themselves:

		Audio:play("Gore", "Gib", position)
		Audio:play("Infected", "TankRoar", tankRoot)
		Audio:play("UI", "Pickup", player)

	`where` may be a Vector3 (emitter), a BasePart (attached), or a Player (2D,
	that client only). `exclude` is forwarded to the positional paths.
]]
function AudioService:play(
	category: string,
	key: string,
	where: any,
	parent: Instance?,
	exclude: Player?
): Sound?
	local definition = self:getDefinition(category, key)
	if not definition then
		-- Keyed on the joined pair so a mistyped call site reports once, by name.
		local label = tostring(category) .. "." .. tostring(key)
		self:_warnOnce(label, "[AudioService] no sound definition at AudioConfig." .. label)
		return nil
	end

	local kind = typeof(where)
	if kind == "Vector3" then
		return self:playAt(definition, where, parent, exclude)
	elseif kind == "Instance" then
		if where:IsA("BasePart") then
			return self:playOn(definition, where, exclude)
		elseif where:IsA("Player") then
			return self:playForPlayer(where, definition)
		end
	end
	return nil
end

--[[ Looks up a definition without playing it. ]]
function AudioService:getDefinition(category: string, key: string): SoundDefinition?
	local bank = (AudioConfig :: any)[category]
	if typeof(bank) ~= "table" then
		return nil
	end
	return bank[key]
end

--[[ Stops and reclaims every voice. Round reset and teardown only — this is not
     a mixer duck. ]]
function AudioService:stopAll()
	local voices = self._voices
	for index = #voices, 1, -1 do
		local voice = voices[index]
		voices[index] = nil
		-- Stop before destroy: a looped sound can otherwise tick over one more
		-- buffer on its way out.
		voice.sound:Stop()
		self:_destroyVoice(voice)
	end
	table.clear(self._categoryCounts)
end

--[[ Live voice count, for the debug overlay and for tuning the Mix numbers. ]]
function AudioService:getActiveCount(category: string?): number
	if category then
		return self._categoryCounts[category] or 0
	end
	return #self._voices
end

--[[
	The gate every play path passes through: is it configured, is it retriggering
	faster than the mix allows, and is there a voice for it. Returns the category
	to bill it to, or nil when the play should be dropped — silently, because the
	whole point of the budget is that exceeding it is normal and expected.
]]
function AudioService:_admit(definition: any, scope: any): string?
	if definition == nil then
		self:_warnOnce(
			NIL_DEFINITION,
			"[AudioService] asked to play a nil definition — check the AudioConfig key at the call site"
		)
		return nil
	end

	if not AudioConfig.isConfigured(definition) then
		self:_warnOnce(definition, nil)
		return nil
	end

	local now = os.clock()
	local scopeTimes = self._retrigger[scope]
	if not scopeTimes then
		scopeTimes = {}
		self._retrigger[scope] = scopeTimes
	end

	local last = scopeTimes[definition]
	if last and now - last < MIX.MinRetriggerInterval then
		return nil
	end

	local category = self._catalog[definition] or UNKNOWN_CATEGORY
	if not self:_reserveVoice(category, definition.priority or 1) then
		return nil
	end

	scopeTimes[definition] = now
	return category
end

--[[
	Claims a voice slot, evicting a quieter sound if the budget is full.

	Eviction rather than refusal is deliberate: when a Tank roars into a room
	already full of footstep loops, the roar is the sound that matters. Ties go to
	the incumbent — a sound already playing is one the player is already hearing,
	and restarting its twin adds nothing.
]]
function AudioService:_reserveVoice(category: string, priority: number): boolean
	local used = self._categoryCounts[category] or 0
	if used >= MIX.MaxConcurrentPerCategory and not self:_evictWeakest(category, priority) then
		return false
	end

	if #self._voices >= MIX.MaxConcurrent and not self:_evictWeakest(nil, priority) then
		return false
	end

	self._categoryCounts[category] = (self._categoryCounts[category] or 0) + 1
	return true
end

--[[ Drops the lowest-priority voice (oldest breaks the tie) when the newcomer
     outranks it. Returns false when everything playing matters more. ]]
function AudioService:_evictWeakest(category: string?, priority: number): boolean
	local voices = self._voices
	local weakestIndex: number? = nil
	local weakestPriority = math.huge
	local weakestStart = math.huge

	for index, voice in voices do
		local inScope = category == nil or voice.category == category
		if inScope and voice.priority < priority then
			local quieter = voice.priority < weakestPriority
			local sameButOlder = voice.priority == weakestPriority and voice.startedAt < weakestStart
			if weakestIndex == nil or quieter or sameButOlder then
				weakestIndex = index
				weakestPriority = voice.priority
				weakestStart = voice.startedAt
			end
		end
	end

	if not weakestIndex then
		return false
	end

	local voice = table.remove(voices, weakestIndex) :: Voice
	self._categoryCounts[voice.category] = math.max((self._categoryCounts[voice.category] or 1) - 1, 0)
	self:_destroyVoice(voice)
	return true
end

--[[ `id` and `pitch` are passed in only by the per-listener path, which has to
     give every copy of one event the same waveform. Everywhere else they are
     rolled here, per play. ]]
function AudioService:_buildSound(definition: SoundDefinition, id: string?, pitch: number?): Sound
	local sound = Instance.new("Sound")
	-- pickId, never definition.id: reading the field takes the first sample of a
	-- varied entry every single time, and Impact.Flesh fires on every hit.
	sound.SoundId = id or AudioConfig.pickId(definition)
	sound.Volume = (definition.volume or 1) * MIX.MasterVolume
	-- A fixed pitch is what turns a 900rpm SMG into a buzzsaw; the per-shot
	-- spread in the config is the single cheapest thing that stops it.
	sound.PlaybackSpeed = pitch or random:NextNumber(definition.pitchMin or 1, definition.pitchMax or 1)
	sound.Looped = definition.looped == true
	-- InverseTapered holds a sound at full volume close in and then falls off
	-- fast, which is what makes a distant horde audible as a direction without
	-- drowning out the teammate beside you.
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = definition.rollOffMin or 12
	sound.RollOffMaxDistance = definition.rollOffMax or 200
	sound.PlayOnRemove = false
	return sound
end

function AudioService:_track(
	sound: Sound,
	holders: { BasePart }?,
	category: string,
	definition: SoundDefinition
)
	local now = os.clock()
	table.insert(
		self._voices,
		{
			sound = sound,
			holders = holders,
			category = category,
			priority = definition.priority or 1,
			startedAt = now,
			expiresAt = now + UNKNOWN_LIFETIME,
			looped = sound.Looped,
		} :: Voice
	)
end

--[[ Reclaims finished voices. Compacts in place rather than swap-removing so the
     array stays in start order, which is what makes the oldest-first tie-break
     in eviction meaningful. ]]
function AudioService:_sweep()
	local voices = self._voices
	local count = #voices
	if count == 0 then
		return
	end

	local now = os.clock()
	local write = 1

	for read = 1, count do
		local voice = voices[read]
		-- Parented nowhere means something already took it: Debris beat us to
		-- it, or a caller destroyed the Sound it was handed. Either way the slot
		-- is free, and a looped voice has no other way to end.
		local finished = voice.sound.Parent == nil

		if not finished and not voice.looped then
			local length = voice.sound.TimeLength
			if length > 0 then
				-- Only knowable once the asset has streamed in, so it is
				-- recomputed every sweep rather than fixed at play time.
				voice.expiresAt = voice.startedAt
					+ length / math.max(voice.sound.PlaybackSpeed, 0.05)
					+ TAIL_GRACE
			end
			finished = now >= voice.expiresAt
		end

		if finished then
			self._categoryCounts[voice.category] =
				math.max((self._categoryCounts[voice.category] or 1) - 1, 0)
			self:_destroyVoice(voice)
		else
			voices[write] = voice
			write += 1
		end
	end

	for index = count, write, -1 do
		voices[index] = nil
	end
end

function AudioService:_destroyVoice(voice: Voice)
	-- Destroying an emitter takes its Sound with it; one Destroy, not two.
	local holders = voice.holders
	if holders then
		for _, holder in holders do
			holder:Destroy()
		end
	else
		voice.sound:Destroy()
	end
end

--[[ One warn per distinct sound, ever. The empty bank is the expected state of
     this game for a while, and it must stay diagnosable rather than deafening. ]]
function AudioService:_warnOnce(key: any, message: string?)
	if self._warned[key] then
		return
	end
	self._warned[key] = true

	if message then
		warn(message)
		return
	end

	local label = self._names[key] or "<sound definition not listed in AudioConfig>"
	warn(
		string.format(
			"[AudioService] %s has no sound id, so it stays silent. Paste one in from Studio; see AudioConfig's header.",
			label
		)
	)
end

Registry.register("AudioService", AudioService)

return AudioService
