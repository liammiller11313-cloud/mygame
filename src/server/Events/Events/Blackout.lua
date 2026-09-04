--!nonstrict
--[[
	Blackout — the lights the map offers, turned off. And POWER FAILURE, which is
	the same thing done slowly.

	Two events, one module, for the same reason the three weather events share
	one: a power failure IS a blackout with a flicker in front of it and a
	staggered recovery behind it. They conflict with each other in EventConfig
	precisely because they are the same idea at two speeds, so a round never sees
	both at once and this file never has to reconcile them.

	── THE MAP OWNS THE LIGHTS ─────────────────────────────────────────────────
	Nothing here knows what a Clinton light is. The map puts fixtures in
	Events/Lights and the few that should come ON in Events/EmergencyLights, and
	a map that has neither never sees this event — see `supported`, which is what
	stops the global system announcing a blackout on a map with nothing to black
	out.

	── ENABLED, NOT DESTROYED ──────────────────────────────────────────────────
	A Light is switched with its Enabled property and the fixture it lives in is
	never touched. Deleting or hiding the parts would take the lamp posts with
	the light, and a round that ends mid-blackout would leave a map missing its
	street furniture. Every light this touches is recorded with what it was, so
	stop() puts back exactly what it found rather than "on" — a fixture the
	designer deliberately left dark stays dark.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventConfig = require(Shared.Config.EventConfig)

local Support = require(script.Parent.Parent.Support)

local FOLDERS = EventConfig.MapFolders
local ID = EventConfig.Id

--[[ The flicker that opens a power failure: how many times the lights stutter
     before they give up, and how long each stutter is. The blackout proper has
     none of this — it just goes dark, which is the difference between the two
     events in one number. ]]
local FLICKER_COUNT = 5
local FLICKER_MIN = 0.06
local FLICKER_MAX = 0.22

--[[ How long the emergency set waits before coming on. A gap is the whole point:
     the moment of complete dark between the mains going and the emergency
     lighting arriving is the only part of this event anybody remembers. ]]
local EMERGENCY_DELAY = 2.2

local random = Random.new()

local Blackout = {}

--[[ Both ids. A power failure is this event with a flicker in front of it; they
     conflict in EventConfig so a round never sees the two at once. ]]
Blackout.claims = { ID.Blackout, ID.PowerFailure }

--[[ Offered only where there is something to turn off. One light is enough —
     a map with a single street lamp gets a smaller blackout, which is honest;
     a map with none gets no blackout at all, which is the alternative to
     announcing an event that does nothing. ]]
function Blackout.supported(): boolean
	return #Support.lights(FOLDERS.Lights) > 0
end

--[[ Records every light with the state it was ALREADY in, then switches it.
     Returning the record rather than storing it here is what lets one module
     serve two events without either one being able to see the other's. ]]
local function capture(kind: string): { { light: Light, was: boolean } }
	local out = {}
	for _, light in Support.lights(kind) do
		table.insert(out, { light = light, was = light.Enabled })
	end
	return out
end

local function switch(record: { any }, on: boolean)
	for _, entry in record do
		--[[ Destroyed lights are skipped rather than written to. The map is
		     rebuilt between rounds and an event that outlives one would otherwise
		     throw on the first fixture that went with it. ]]
		if entry.light.Parent then
			entry.light.Enabled = on
		end
	end
end

function Blackout.start(context: any)
	local state = context.state
	--[[ Set FIRST, before anything schedules itself against it. Every delayed
	     step below checks it, and setting it further down meant the plain
	     blackout — which does not go through the flicker loop that used to set
	     it — scheduled its emergency lights against a false and never turned
	     them on. ]]
	state.running = true
	state.mains = capture(FOLDERS.Lights)
	state.emergency = capture(FOLDERS.EmergencyLights)
	state.generation = (state.generation or 0) + 1
	local mine = state.generation

	--[[ Emergency lighting is forced OFF first, whatever the designer left it
	     at. It is the light that means "the mains have failed", and one that was
	     already on before the failure says nothing. ]]
	switch(state.emergency, false)

	local slow = context.definition.id == ID.PowerFailure

	local function fail()
		--[[ The sky sags at the moment the lights actually go, not when the event
		     starts. For a plain blackout those are the same instant; for a power
		     failure the flicker comes first, and darkening the whole scene before
		     the first stutter gave the ending away — the player saw the world dim
		     and then watched the lights pretend to fight it. ]]
		Support.setWeather("Blackout")
		switch(state.mains, false)
		task.delay(EMERGENCY_DELAY, function()
			--[[ The generation check is the whole safety story for these delayed
			     steps. An event can end — a round wipe, a map swap — between the
			     schedule and the fire, and without this the emergency lights come
			     on two seconds into the NEXT round. ]]
			if state.generation == mine and state.running then
				switch(state.emergency, true)
			end
		end)
	end

	if not slow then
		fail()
		return
	end

	--[[ The flicker, on its own thread because it sleeps. Nothing waits for it:
	     the event is already running, and a stutter that fails to finish leaves
	     the lights wherever it got to until stop() puts them back. ]]
	task.spawn(function()
		for _ = 1, FLICKER_COUNT do
			if state.generation ~= mine or not state.running then
				return
			end
			switch(state.mains, false)
			task.wait(random:NextNumber(FLICKER_MIN, FLICKER_MAX))
			if state.generation ~= mine or not state.running then
				return
			end
			switch(state.mains, true)
			task.wait(random:NextNumber(FLICKER_MIN, FLICKER_MAX))
		end
		if state.generation == mine and state.running then
			fail()
		end
	end)
end

function Blackout.stop(context: any)
	local state = context.state
	state.running = false
	--[[ Bumped so anything still sleeping — a flicker mid-loop, the emergency
	     delay — finds a number that is not its own and returns without writing.
	     Cheaper and more certain than cancelling threads, and it cannot miss
	     one. ]]
	state.generation = (state.generation or 0) + 1

	--[[ Back to what was FOUND, not to on. A fixture the designer left dark is
	     part of how the map looks and this event does not get to relight it. ]]
	for _, entry in state.mains or {} do
		if entry.light.Parent then
			entry.light.Enabled = entry.was
		end
	end
	for _, entry in state.emergency or {} do
		if entry.light.Parent then
			entry.light.Enabled = entry.was
		end
	end

	Support.setWeather(nil)
end

return Blackout
