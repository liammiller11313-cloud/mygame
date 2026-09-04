--!nonstrict
--[[
	PauseService — the one case where pausing a Roblox game is honest.

	── THE ARGUMENT ─────────────────────────────────────────────────────────────
	PauseController has said for a long time that nothing is actually paused, and
	it was right to: "Roblox has no pause in a multiplayer game and pretending
	otherwise would be a lie told to one player while three others fight." That
	is still true and this does not change it.

	What it changes is the case the sentence quietly assumed. Classic allows solo
	— GameModeConfig.MinPlayersToStart is 1, and the Director scales down for it
	— so a player can be the only person in the server, and a pause told to
	nobody is not a lie. So: alone, the game genuinely stops. In company, the
	menu keeps saying the round is still running, because it is.

	The check is on the SERVER and on the player count at the moment of asking,
	not on anything the client believes about itself.

	── WHAT ACTUALLY STOPS ──────────────────────────────────────────────────────
	  * The horde. InfectedService's loop stops, which also stops burning — a
	    player who paused while on fire should not come back to a corpse.
	  * The Director. Its clock freezes, so it resumes into the decision it was
	    about to make rather than into a backlog of them.
	  * The round. RoundService holds the schedule still using the same
	    push-startedAt-forward trick the ready gate has used since before this
	    existed, so no wave boundary, boss release or round end moves closer.

	── WHAT DOES NOT ────────────────────────────────────────────────────────────
	Ability cooldowns and other per-player timers keep running. They are between
	a player and themselves, this is only ever reachable when that player is the
	only one here, and the exploit — pausing to skip a cooldown — is cheating at
	solitaire. Freezing them would mean a second clock in six more services for
	no gain anybody can feel.

	Physics keeps running too. A body mid-fall keeps falling. Anchoring the
	character on a pause and unanchoring it after is a good way to drop somebody
	through the floor, and the horde being frozen is what the pause was for.

	── IT ENDS ITSELF ───────────────────────────────────────────────────────────
	A second player joining lifts the pause immediately, because from that moment
	the honest answer changed. So does the pauser leaving, the round ending, and
	the pauser dying — the last one only matters in Versus, where somebody else
	can still be playing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game

local PauseService = {}

local serviceTrove = Trove.new()

--[[ Who asked for the pause that is currently on, or nil. Held so it can be
     lifted when that specific player leaves or the round ends under them, and
     so a second player's request cannot toggle somebody else's pause. ]]
local owner: Player? = nil

--[[
	The floor between one player's pause requests.

	A pause is three service calls and an attribute write, and a client that
	sends the toggle every frame would have the horde stopping and starting at
	frame rate. Small, because the legitimate use — opening and closing the menu
	to check something — is genuinely fast.
]]
local TOGGLE_INTERVAL = 0.2
local lastToggle: { [Player]: number } = {}

local function isPaused(): boolean
	return Workspace:GetAttribute(GA.Paused) == true
end

--[[ Every service that has to stand still, told in one place. Registry.find
     rather than get: a pause is a convenience, and it must not be able to take
     the server down because a module list changed underneath it. ]]
local function apply(paused: boolean)
	Workspace:SetAttribute(GA.Paused, paused)

	local infected = Registry.find("InfectedService")
	if infected and typeof(infected.setPaused) == "function" then
		infected:setPaused(paused)
	end

	local director = Registry.find("DirectorService")
	if director and typeof(director.setPaused) == "function" then
		director:setPaused(paused)
	end

	local round = Registry.find("RoundService")
	if round and typeof(round.setClockPaused) == "function" then
		round:setClockPaused(paused)
	end
end

--[[ Ends a pause however it ended: released, walked away from, joined into, or
     outlived by its round. Safe to call when nothing is paused. ]]
local function release()
	if not isPaused() and owner == nil then
		return
	end
	owner = nil
	apply(false)
end

--[[
	Whether this player may stop the world right now.

	Alone is the whole rule, and it is counted here rather than trusted from the
	client. The round check is the other half: pausing the lobby would freeze the
	Director for a server nobody is playing in, and the menu is already a pause
	in every sense that matters when no round is running.
]]
local function mayPause(player: Player): boolean
	local here = Players:GetPlayers()
	if #here ~= 1 or here[1] ~= player then
		return false
	end
	local round = Registry.find("RoundService")
	return round ~= nil and round:isRunning()
end

local function onRequest(player: Player, wanted: any)
	if typeof(wanted) ~= "boolean" then
		return
	end

	local now = os.clock()
	if now - (lastToggle[player] or 0) < TOGGLE_INTERVAL then
		return
	end
	lastToggle[player] = now

	if not wanted then
		--[[ Only the player who paused can unpause, and anybody at all can fail
		     to: a release from someone who does not hold the pause is a no-op
		     rather than a refusal, because the honest answer to "unpause" from a
		     player who is not paused is that they are already not paused. ]]
		if owner == player then
			release()
		end
		return
	end

	if isPaused() or not mayPause(player) then
		return
	end

	owner = player
	apply(true)
end

function PauseService:isPaused(): boolean
	return isPaused()
end

--[[ For anything that needs to stop a pause it did not start — a mode change, a
     teleport, a test. ]]
function PauseService:release()
	release()
end

function PauseService:init()
	--[[ Cleared on boot rather than assumed. The attribute lives on Workspace and
	     Workspace survives a script error and a soft restart in Studio, so a
	     server that went down mid-pause would otherwise come back up with a
	     frozen horde and nothing holding the flag. ]]
	Workspace:SetAttribute(GA.Paused, false)
end

function PauseService:start()
	serviceTrove:connect(Remotes.Event.SetPause.OnServerEvent, onRequest)

	--[[ A second player arriving ends it on the spot. This is the whole safety
	     story for the feature: the only condition that makes a pause honest is
	     being alone, and the moment that stops being true the pause has to stop
	     with it — before the joiner has finished loading, let alone noticed. ]]
	serviceTrove:connect(Players.PlayerAdded, function()
		if #Players:GetPlayers() > 1 then
			release()
		end
	end)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		lastToggle[player] = nil
		if owner == player then
			release()
		end
	end)

	--[[ And a round that ends under a pause takes it with it. Nothing else would
	     lift it: the pauser is looking at a menu, and a scoreboard behind a
	     frozen Director is a server that never starts another round. ]]
	serviceTrove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		local round = Workspace:GetAttribute(GA.RoundState)
		if round ~= Enums.RoundState.InProgress and round ~= Enums.RoundState.Starting then
			release()
		end
	end)
end

function PauseService:destroy()
	serviceTrove:destroy()
	release()
	table.clear(lastToggle)
end

Registry.register("PauseService", PauseService)

return PauseService
