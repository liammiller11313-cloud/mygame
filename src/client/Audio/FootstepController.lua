--!nonstrict
--[[
	FootstepController — what a survivor sounds like moving, replacing Roblox's.

	── WHY THIS EXISTS AT ALL ──────────────────────────────────────────────────
	Roblox ships one running sample per character, played by a LocalScript it
	inserts into PlayerScripts, with its PlaybackSpeed scaled by velocity. That
	is why every Roblox character sounds like it is walking on the same floor at
	the same weight, and it is a poor fit for a game where the difference between
	moving carefully and committing to a run is a control the player is actively
	using.

	So: the default is silenced and two loops take its place, one per gait.

	── ON EVERY SURVIVOR, NOT JUST YOURS ───────────────────────────────────────
	The sound is created on each character's own root, so it is positional and a
	teammate breaking into a run behind you is something you HEAR. That is worth
	more than it costs: one Sound per character, swapped between two ids, playing
	only while that character is actually moving on the ground.

	── THE GAIT COMES FROM THE SERVER ──────────────────────────────────────────
	Not from WalkSpeed, which cannot answer it. Sprint speed is multiplied by
	whatever the weapon in hand scales it by, so a heavy rifle at a sprint and a
	light one at a walk land on the same number — see SurvivorService, which
	knows the real answer and publishes Attributes.Player.IsSprinting.

	Movement itself is read locally, from the humanoid, because "is this body
	moving right now" is a question the client can answer sixty times a second
	for free and the server should not be asked sixty times a second at all.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player

--[[ Below this, the body is drifting rather than walking — a shove, a slide off
     a kerb, the last inch of a MoveTo. Sound on that reads as a character
     stepping in place. ]]
local MOVING_SPEED = 2.5

--[[ Ten times a second. A gait change is a property read and a SoundId swap,
     and nothing about either wants a frame. ]]
local TICK_INTERVAL = 0.1

--[[ Which humanoid states have feet on the ground. Falling, jumping, climbing
     and being ragdolled are all silent — a footstep loop that keeps running
     through a fall is the single most noticeable way to get this wrong. ]]
local GROUNDED = table.freeze({
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Landed] = true,
})

local FootstepController = {}

local trove = Trove.new()
local random = Random.new()
local accumulator = 0

--[[ player -> { sound, root, humanoid, gait }. Rebuilt per character rather than
     kept across one: the character is destroyed on death and every reference
     into it dies with it. ]]
local tracked: { [Player]: any } = {}

--[[
	Silences Roblox's own character sounds, at the source.

	They are Sound instances on each HumanoidRootPart, but they are DRIVEN by
	RbxCharacterSounds — a LocalScript the engine puts in PlayerScripts, which
	runs on this client and handles every character this client can see. It sets
	Volume itself when a state changes, so muting a Sound is a value that gets
	written back over the next time that character starts or stops running. That
	is why this disables the script instead: it is the thing doing the writing.

	Best-effort by design. It is engine-supplied, it has been renamed before, and
	a client where it cannot be found should still get our footsteps — just with
	Roblox's underneath. So the per-Sound muting below stays as the fallback,
	which handles the sounds that already exist even where the script survives.
]]
local function silenceEngineSounds()
	local scripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	local default = scripts and scripts:FindFirstChild("RbxCharacterSounds")
	--[[ Disabled rather than destroyed. Deleting something the engine inserted is
	     a fight with a future engine version; disabling is the supported way to
	     say "not in this place". ]]
	if default and default:IsA("LuaSourceContainer") then
		(default :: any).Disabled = true
	end
end

--[[ The fallback, per character: mute what is already there. Harmless when the
     script above is gone, and the only thing that works when it is not. ]]
local function silenceDefault(root: BasePart)
	for _, name in { "Running", "FreeFalling", "Climbing", "Swimming" } do
		local existing = root:FindFirstChild(name)
		if existing and existing:IsA("Sound") then
			existing.Volume = 0
		end
	end
end

--[[ `pitch` is per CHARACTER and fixed for its life, not per step. Four
     survivors running on one sample at one speed is a metronome; a few percent
     of difference each is four people. Rolling it per step instead would make a
     single player's own footsteps wobble, which is worse than the metronome. ]]
local function applyDefinition(sound: Sound, definition: any, pitch: number)
	sound.SoundId = definition.id
	sound.Volume = definition.volume
	sound.RollOffMinDistance = definition.rollOffMin
	sound.RollOffMaxDistance = definition.rollOffMax
	sound.PlaybackSpeed = definition.pitchMin + (definition.pitchMax - definition.pitchMin) * pitch
end

local function release(player: Player)
	local entry = tracked[player]
	if not entry then
		return
	end
	tracked[player] = nil
	if entry.sound then
		entry.sound:Destroy()
	end
end

local function adopt(player: Player, character: Model)
	release(player)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return
	end

	silenceDefault(root)

	local sound = Instance.new("Sound")
	sound.Name = "FL_Footsteps"
	sound.Looped = true
	--[[ On the ROOT, so it is positional. A footstep played through SoundService
	     would be every survivor's footsteps arriving from nowhere at full
	     volume. ]]
	sound.Parent = root

	tracked[player] = {
		sound = sound,
		root = root,
		humanoid = humanoid,
		--[[ "" rather than a gait, so the first tick always applies one — the
		     same sentinel trick the server's own publish uses. ]]
		gait = "",
		pitch = random:NextNumber(),
	}
end

local function watch(player: Player)
	if player.Character then
		adopt(player, player.Character)
	end
	trove:connect(player.CharacterAdded, function(character: Model)
		--[[ Waited for rather than assumed. CharacterAdded fires before the rig
		     has finished streaming in, and the root is what everything here hangs
		     off. ]]
		task.spawn(function()
			if character:WaitForChild("HumanoidRootPart", 10) then
				adopt(player, character)
			end
		end)
	end)
	trove:connect(player.CharacterRemoving, function()
		release(player)
	end)
end

local function step()
	for player, entry in tracked do
		local humanoid = entry.humanoid
		local root = entry.root
		if not humanoid.Parent or not root.Parent then
			release(player)
			continue
		end

		--[[ Horizontal only. A survivor riding a lift or falling has plenty of
		     velocity and none of it is a step. ]]
		local velocity = root.AssemblyLinearVelocity
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local grounded = GROUNDED[humanoid:GetState()] == true
		local moving = grounded and speed >= MOVING_SPEED and humanoid.Health > 0

		local wanted = ""
		if moving then
			wanted = if player:GetAttribute(PA.IsSprinting) == true then "Sprint" else "Walk"
		end

		if wanted ~= entry.gait then
			entry.gait = wanted
			if wanted == "" then
				entry.sound:Stop()
			else
				applyDefinition(entry.sound, AudioConfig.Footstep[wanted], entry.pitch)
				entry.sound:Play()
			end
		end
	end
end

function FootstepController:init() end

function FootstepController:start()
	silenceEngineSounds()

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	trove:connect(Players.PlayerAdded, watch)
	trove:connect(Players.PlayerRemoving, release)

	trove:connect(RunService.Heartbeat, function(delta: number)
		accumulator += delta
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		step()
	end)
end

function FootstepController:destroy()
	trove:destroy()
	for player in tracked do
		release(player)
	end
end

Registry.register("FootstepController", FootstepController)

return FootstepController
