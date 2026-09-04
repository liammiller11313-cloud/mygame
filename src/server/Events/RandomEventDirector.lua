--!nonstrict
--[[
	RandomEventDirector — the game deciding that something should happen.

	── THE GAME IS THE DIRECTOR ────────────────────────────────────────────────
	The map does not decide when a random event happens, or which one. This does.
	A map only provides the OBJECTS an event needs, and an event with nothing to
	work with on the current map is never offered — see each module's `supported`.

	That split is the whole architecture, and it is what makes the system global:
	adding a map costs nothing here, and adding an event costs a row in
	EventConfig plus a module in Events/. This file never changes for either.

	── IT DOES NOT ROLL EVERY FRAME ────────────────────────────────────────────
	It schedules. When a round starts, one random time inside the first-delay
	band is chosen and written down; when that moment arrives the pool is built,
	one event is drawn from it by weight, and a new time is scheduled after it
	ends. The tick is two number comparisons.

	That matters more than it sounds. A per-frame probability produces a
	geometric distribution — events clustering early, occasionally none at all —
	and no amount of tuning the probability fixes the shape. Scheduling gives a
	flat distribution inside a band that the config states plainly, which is both
	cheaper and the thing the design actually asked for.

	── WHAT IT REFUSES ─────────────────────────────────────────────────────────
	Eligibility is checked at the moment of the draw, never cached, because every
	term in it can have changed since the last one:

	  * the round has to be running, with survivors up
	  * the event's time and wave windows have to contain now
	  * its own cooldown has to have expired
	  * a non-repeatable event must not have run this round
	  * nothing conflicting may be active
	  * the module has to say the current map supports it
	  * and it must not be a second heavy event in a row

	If the pool comes back empty the whole draw is skipped and rescheduled. A
	round where nothing qualifies is a round with no events, which is a legitimate
	round.

	── ONE AT A TIME ───────────────────────────────────────────────────────────
	There is deliberately no support for two events running at once, even
	non-conflicting ones. Two simultaneous events is one confused thing rather
	than two legible ones, the banner can only say one name, and the conflict
	table is then doing a job that "one at a time" does for free.

	── FAILURE IS NOT FATAL ────────────────────────────────────────────────────
	Every call into a module is wrapped. An event that throws on start is ended
	immediately and its stop is still called, because a module that failed
	halfway is exactly the one whose cleanup matters — and a random event, which
	nobody asked for, must never be the reason a round stops.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local EventConfig = require(Shared.Config.EventConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game

local RandomEventDirector = {}

local serviceTrove = Trove.new()
local random = Random.new()

--[[ Half a second. This decides when an event starts and when it ends, and
     neither wants frame precision — a banner that lands 400ms late is a banner
     nobody can tell was late. ]]
local TICK_INTERVAL = 0.5
local accumulator = 0

--[[
	Everything the director knows, in one table.

	`active` is the running event or nil; `state` is a scratch table the running
	module owns outright and this file never reads into. `history` is per-round
	and cleared with it — a cooldown is a property of THIS round, the same rule
	the ability cooldowns follow.
]]
local active: any = nil
local nextEventAt = 0
--[[ When the round was paused, or 0. See the tick: the deadlines above are
     absolute, so a pause has to be added back rather than waited out. ]]
local pausedSince = 0
local lastIntensity = 0
local history: { [string]: { lastEndedAt: number, count: number } } = {}

--[[ id -> module. Loaded once at boot from the folder beside this one, so a new
     event is a file rather than an edit here. ]]
local modules: { [string]: any } = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function round(): any
	return Registry.find("RoundService")
end

--[[ Seconds since the round's prep window opened, or 0 outside one. The same
     clock every event window is written against. ]]
local function elapsed(): number
	local service = round()
	if not service or typeof(service.getElapsed) ~= "function" then
		return 0
	end
	return service:getElapsed()
end

local function waveIndex(): number
	local service = round()
	if not service or typeof(service.getWaveIndex) ~= "function" then
		return 0
	end
	return service:getWaveIndex()
end

--[[ Whether the round is in a state that can host an event at all. InProgress
     rather than isRunning: `Starting` is the prep window, and an event landing
     while the team is still reading a loadout screen is one nobody sees. ]]
local function roundIsLive(): boolean
	if Workspace:GetAttribute(GA.RoundState) ~= EventConfig.RunningState then
		return false
	end
	--[[ And somebody has to be up. A surge sent at an empty map, a broadcast
	     read to nobody: every event assumes a team, and the honest place to say
	     so once is here rather than in eight modules. ]]
	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getAliveSurvivors) ~= "function" then
		return false
	end
	return #survivors:getAliveSurvivors() > 0
end

--[[ Published for every client, including one that joins mid-event. See the
     comment on Attributes.Game.EventId for why this is state and the banner is
     a remote. ]]
local function publish(definition: any, endsAt: number)
	Workspace:SetAttribute(GA.EventId, if definition then definition.id else "")
	Workspace:SetAttribute(GA.EventName, if definition then definition.displayName else "")
	Workspace:SetAttribute(GA.EventEndsAt, if definition then endsAt else 0)
end

local function record(id: string)
	local entry = history[id]
	if not entry then
		entry = { lastEndedAt = 0, count = 0 }
		history[id] = entry
	end
	return entry
end

-- ── eligibility ─────────────────────────────────────────────────────────────

--[[
	Whether one event could start right now.

	Every clause is checked at the moment of the draw and none is cached, because
	every one of them can have changed since the last draw — the wave has moved,
	a cooldown has expired, the map has been swapped.
]]
local function eligible(definition: any, now: number, seconds: number, wave: number): boolean
	if active then
		return false
	end

	if seconds < definition.minTime or seconds > definition.maxTime then
		return false
	end
	if seconds > EventConfig.NoStartAfter then
		return false
	end
	if wave < definition.minWave or wave > definition.maxWave then
		return false
	end

	local entry = history[definition.id]
	if entry then
		if not definition.repeatable and entry.count > 0 then
			return false
		end
		--[[ Zero cooldown means "as often as the director's own gap allows",
		     which is what the broadcast wants — it is non-repeatable anyway, and
		     a cooldown on top of that would be a second rule saying the same
		     thing. ]]
		if definition.cooldown > 0 and now - entry.lastEndedAt < definition.cooldown then
			return false
		end
	end

	--[[ Two heavy events in a row is a spike nobody configured. The guard only
	     looks at the LAST one, so it costs a round at most one surge and never
	     blocks the weather. ]]
	if lastIntensity >= EventConfig.HeavyIntensity and definition.intensity >= EventConfig.HeavyIntensity then
		return false
	end

	--[[ Last, because it is the only clause that touches the map. Everything
	     above is arithmetic; this walks a folder tree, and it is worth not doing
	     for an event three cheaper tests have already refused. ]]
	local module = modules[definition.id]
	if not module then
		return false
	end
	local ok, supported = pcall(module.supported)
	return ok and supported == true
end

--[[ Everything that could happen right now, and the total weight of it. Both
     together because the caller needs both and building the list twice is how
     the two disagree. ]]
local function pool(now: number): ({ any }, number)
	local out, total = {}, 0
	local seconds = elapsed()
	local wave = waveIndex()
	for _, definition in EventConfig.Definitions do
		if eligible(definition, now, seconds, wave) then
			table.insert(out, definition)
			total += math.max(definition.weight, 0)
		end
	end
	return out, total
end

--[[ One event, drawn by weight. The standard walk: a point on the total, then
     forward through the list until it is spent. The final return is not a
     fallback for a bug — floating point can leave the accumulator a hair short
     of the roll — and it is the last entry, which is the one the roll was
     inside. ]]
local function draw(candidates: { any }, total: number): any
	if #candidates == 0 or total <= 0 then
		return nil
	end
	local roll = random:NextNumber() * total
	for _, definition in candidates do
		roll -= math.max(definition.weight, 0)
		if roll <= 0 then
			return definition
		end
	end
	return candidates[#candidates]
end

-- ── running one ─────────────────────────────────────────────────────────────

local function schedule(now: number, first: boolean)
	local low = if first then EventConfig.FirstDelayMin else EventConfig.GapMin
	local high = if first then EventConfig.FirstDelayMax else EventConfig.GapMax
	nextEventAt = now + random:NextNumber(low, high)
end

local function finish(now: number)
	local running = active
	if not running then
		return
	end
	active = nil

	--[[ Cleared BEFORE stop is called. A module's stop can throw, and an event
	     that failed to clean up must still stop being the active event — the
	     alternative is a round with a banner it can never take down. ]]
	publish(nil, 0)

	local entry = record(running.definition.id)
	entry.lastEndedAt = now
	lastIntensity = running.definition.intensity

	local module = modules[running.definition.id]
	if module and typeof(module.stop) == "function" then
		local ok, err = pcall(module.stop, running)
		if not ok then
			warn(
				string.format("[RandomEventDirector] %s stop threw: %s", running.definition.id, tostring(err))
			)
		end
	end

	schedule(now, false)
end

local function begin(definition: any, now: number)
	local module = modules[definition.id]
	if not module then
		return
	end

	local context = {
		definition = definition,
		endsAt = now + definition.duration,
		--[[ The module's own scratch space. Nothing in this file reads inside it;
		     it exists so an event can keep whatever it needs between start,
		     update and stop without a global of its own. ]]
		state = {},
	}
	active = context

	local entry = record(definition.id)
	entry.count += 1

	publish(definition, context.endsAt)

	local ok, err = pcall(module.start, context)
	if not ok then
		warn(string.format("[RandomEventDirector] %s start threw: %s", definition.id, tostring(err)))
		--[[ Ended immediately, and stop is still called: a module that failed
		     halfway through starting is exactly the one whose cleanup matters. ]]
		finish(now)
		return
	end

	--[[ The banner and the siren, once, at the start. Announced AFTER start
	     succeeded, so a player is never told about an event that did not
	     happen. ]]
	Remotes.Event.RandomEvent:FireAllClients({
		id = definition.id,
		name = definition.displayName,
		endsAt = context.endsAt,
	})

	local service = round()
	if service and typeof(service.announce) == "function" then
		service:announce("", definition.announcement)
	end

	local audio = Registry.find("AudioService")
	if audio then
		for _, player in Players:GetPlayers() do
			audio:play("Event", "Siren", player)
		end
	end

	print(
		string.format(
			"[RandomEventDirector] %s for %ds at %ds into the round",
			definition.id,
			definition.duration,
			math.floor(elapsed())
		)
	)
end

-- ── the tick ────────────────────────────────────────────────────────────────

local function step(now: number)
	if active then
		local module = modules[active.definition.id]
		if module and typeof(module.update) == "function" then
			local ok, err = pcall(module.update, active, now)
			if not ok then
				warn(
					string.format(
						"[RandomEventDirector] %s update threw: %s",
						active.definition.id,
						tostring(err)
					)
				)
			end
		end
		if now >= active.endsAt then
			finish(now)
		end
		return
	end

	if now < nextEventAt then
		return
	end

	--[[ Rescheduled whatever happens next, including when nothing does. Without
	     this an ineligible moment would leave the deadline in the past and the
	     director would try again every tick until something qualified — which is
	     the per-frame roll this design exists to avoid. ]]
	schedule(now, false)

	if not roundIsLive() then
		return
	end
	local candidates, total = pool(now)
	local chosen = draw(candidates, total)
	if chosen then
		begin(chosen, now)
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--[[ Everything back to nothing, and the running event stopped if there is one.
     Called when a round ends, which is also when a round is abandoned, wiped or
     replaced — all four are the same thing to this file. ]]
function RandomEventDirector:reset()
	if active then
		finish(serverNow())
	end
	table.clear(history)
	lastIntensity = 0
	nextEventAt = 0
	pausedSince = 0
	publish(nil, 0)
end

function RandomEventDirector:getActiveId(): string
	return if active then active.definition.id else ""
end

--[[ Starts an event by name, ignoring the schedule but NOT the module. For a
     developer testing one, and for nothing else — the eligibility rules are
     skipped deliberately so a wave-6 event can be seen without playing to wave
     six. ]]
function RandomEventDirector:forceEvent(id: string): boolean
	local definition = EventConfig.get(id)
	if not definition or active or not modules[id] then
		return false
	end
	begin(definition, serverNow())
	return true
end

function RandomEventDirector:init()
	--[[ Loaded from the folder rather than from a list here, so adding an event
	     is a file. A module that fails to load is reported by name and the event
	     it belongs to is simply never eligible — `eligible` refuses anything with
	     no module. ]]
	local folder = script.Parent:FindFirstChild("Events")
	if not folder then
		warn("[RandomEventDirector] no Events folder beside me; no random events will run")
		return
	end

	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") then
			local ok, module = pcall(require, child)
			if not ok or typeof(module) ~= "table" then
				warn(
					string.format("[RandomEventDirector] %s failed to load: %s", child.Name, tostring(module))
				)
			else
				--[[ One module can serve several ids — the three weather events
				     share one file and so do the two blackouts — so the mapping is
				     from the CONFIG's ids to whatever claims them, not from a file
				     name to an event. `claims` is how a module says which. ]]
				local claims = module.claims
				if typeof(claims) == "table" then
					for _, id in claims do
						modules[id] = module
					end
				elseif typeof(module.id) == "string" then
					modules[module.id] = module
				end
			end
		end
	end

	--[[ An event in the config with nothing to run it is a silent hole: it would
	     be drawn, refused by `eligible`, and never explained. Said once at boot,
	     where somebody can act on it. ]]
	for _, definition in EventConfig.Definitions do
		if not modules[definition.id] then
			warn(
				string.format(
					"[RandomEventDirector] %q is in EventConfig but no module claims it; it will never run",
					definition.id
				)
			)
		end
	end

	publish(nil, 0)
end

function RandomEventDirector:start()
	if not EventConfig.Enabled then
		return
	end

	serviceTrove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		local state = Workspace:GetAttribute(GA.RoundState)
		if state == Enums.RoundState.Starting then
			self:reset()
			--[[ The first window is measured from the round STARTING, not from
			     the first wave. Prep is part of the round the player is in, and
			     starting the clock later would push every event in a short round
			     into its second half. ]]
			schedule(serverNow(), true)
		elseif state ~= EventConfig.RunningState then
			self:reset()
		end
	end)

	serviceTrove:connect(RunService.Heartbeat, function(delta: number)
		accumulator += delta
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0

		local now = serverNow()

		--[[
			A paused round takes this with it, and SHIFTS rather than just skips.

			Every deadline here is an absolute server-time stamp, so returning
			early is not enough on its own: a five-minute pause would come back to
			a scheduled event whose moment had passed, and to a running one that
			had "ended" while nobody was playing. So the paused span is added to
			both. The same rule the round's own schedule follows, for the same
			reason — see RoundService._stepPause.
		]]
		if Workspace:GetAttribute(GA.Paused) == true then
			pausedSince = if pausedSince > 0 then pausedSince else now
			return
		end
		if pausedSince > 0 then
			local shift = math.max(now - pausedSince, 0)
			pausedSince = 0
			nextEventAt += shift
			if active then
				active.endsAt += shift
				--[[ Republished so the client's own countdown moves with it rather
				     than showing an event that ends in the past. ]]
				publish(active.definition, active.endsAt)
			end
		end

		step(now)
	end)
end

function RandomEventDirector:destroy()
	serviceTrove:destroy()
	self:reset()
	table.clear(modules)
end

--[[ Named so the siren row cannot be renamed out from under this file without
     the audit noticing. ]]
assert(AudioConfig.Event.Siren ~= nil, "AudioConfig.Event.Siren is required by the event director")

Registry.register("RandomEventDirector", RandomEventDirector)

return RandomEventDirector
