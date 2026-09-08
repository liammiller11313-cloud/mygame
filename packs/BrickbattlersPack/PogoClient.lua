--!strict
--[[
	PogoClient — LocalScript, inside any pogo tool. Predicts, then asks.

	Replaces SlingshotPogo and the old PogoClient, which were the same eighty
	lines twice with different numbers.

	── WHY IT STILL APPLIES THE BOOST LOCALLY ───────────────────────────────────
	Pogo is a rhythm. Chaining twelve of them at a 0.12s cooldown is the whole
	mechanic, and a launch that waits for a round trip lands 80ms late every
	time, which is the difference between a technique and a nuisance.

	So the client predicts: it casts, decides the shot looks legal, and launches
	immediately. Then it asks the server, which casts the same ray against its
	own copy of the world and either agrees or clamps the player back down. The
	player owns their own root and could write that velocity regardless, so
	predicting costs no authority that was ever ours — the server is not being
	asked to permit the write, it is being asked whether this launch was EARNED,
	and it is the only one keeping the stack count.

	── WHAT WENT ───────────────────────────────────────────────────────────────
	  * The invented ground. `findBelowPoint` ended with a fabricated point ten
	    studs below the player whenever nothing was hit, so a shot at open sky
	    launched exactly as well as a shot at a floor. That, plus stacking, is
	    unbounded flight with no map required. If the cast misses now, nothing
	    happens.
	  * mouse.Hit as a position. It is where the mouse landed, which on a long
	    shot is not on the ray at all. Everything is a direction now.
	  * The debug prints, which fired on every attempt including the failures.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local PogoCore = require(ReplicatedStorage:WaitForChild("PogoCore"))

local player = Players.LocalPlayer
local tool = script.Parent
local profile = PogoCore.profileFor(tool)

local REMOTE_WAIT = 10
local request = tool:WaitForChild("PogoRequest", REMOTE_WAIT) :: RemoteEvent?
local verdict = tool:WaitForChild("PogoVerdict", REMOTE_WAIT) :: RemoteEvent?

local mouse: Mouse? = nil
local readyAt = 0
local stacks = 0
local lastAt = 0

local function partsOf(): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?,
		character:FindFirstChildOfClass("Humanoid")
end

--[[ One sound, reused, parented to the root so it travels with the player and
     obeys distance. Created once and replayed rather than cloned per launch: a
     twelve-stack chain would otherwise leave twelve Sounds behind. ]]
local function playSfx()
	local root = partsOf()
	if not root or profile.sfxId <= 0 then
		return
	end
	local name = "PogoSFX_" .. profile.name
	local sound = root:FindFirstChild(name) :: Sound?
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = "rbxassetid://" .. profile.sfxId
		sound.Volume = 0.8
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMaxDistance = 70
		sound.EmitterSize = 3
		sound.Parent = root
	end
	sound.TimePosition = 0
	sound:Play()
end

--[[ Where the player is pointing, as a direction from their own root.

     The camera ray is the honest source: it is what the crosshair is actually
     on, it is defined when the mouse is over open sky, and it is the same thing
     the server will be handed. mouse.Hit is only a fallback for the touch path,
     where there is no camera ray to take. ]]
local function aimDirection(root: BasePart): Vector3?
	local camera = workspace.CurrentCamera
	if camera and mouse then
		local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
		local aimed = ray.Origin + ray.Direction * profile.maxRange
		local delta = aimed - root.Position
		if delta.Magnitude > 1e-3 then
			return delta.Unit
		end
	end
	if mouse then
		local delta = mouse.Hit.Position - root.Position
		if delta.Magnitude > 1e-3 then
			return delta.Unit
		end
	end
	return nil
end

local function tryPogo()
	if not request then
		return
	end
	local now = os.clock()
	if now < readyAt then
		return
	end

	local root, humanoid = partsOf()
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	if tool.Parent ~= player.Character then
		return
	end

	local direction = aimDirection(root)
	if not direction then
		return
	end

	--[[ The client's own cast, at face value rather than the server's slack: it
	     would rather refuse a marginal launch than predict one the server is
	     about to take back. A miss is simply nothing — there is no invented
	     point below the player any more. ]]
	local hit = PogoCore.cast(root, direction, profile)
	if not hit or not PogoCore.hitIsLegal(root, hit, profile) then
		return
	end

	if profile.stackTimeout > 0 and now - lastAt > profile.stackTimeout then
		stacks = 0
	end
	stacks = math.clamp(stacks + 1, 1, profile.maxStacks)
	lastAt = now
	readyAt = now + profile.cooldown

	PogoCore.apply(
		root,
		humanoid,
		PogoCore.launchDirection(root, hit, profile),
		PogoCore.boostFor(stacks, profile),
		profile
	)
	playSfx()

	request:FireServer(direction)
end

--[[ The server keeps the real chain. Taking its count rather than our own is
     what stops a prediction that was refused from inflating the next launch. ]]
if verdict then
	verdict.OnClientEvent:Connect(function(granted: boolean, serverStacks: number)
		if granted and typeof(serverStacks) == "number" then
			stacks = serverStacks
		else
			stacks = 0
		end
	end)
end

tool.Equipped:Connect(function(equippedMouse)
	mouse = equippedMouse or player:GetMouse()
	if mouse and player.Character then
		mouse.TargetFilter = player.Character
	end
end)

tool.Unequipped:Connect(function()
	stacks = 0
end)

tool.Activated:Connect(tryPogo)

if UserInputService.TouchEnabled then
	UserInputService.TouchTapInWorld:Connect(function(_, processed)
		if not processed and tool.Parent == player.Character then
			tryPogo()
		end
	end)
end
