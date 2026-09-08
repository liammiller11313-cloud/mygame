--!strict
--[[
	ServerLauncher — Script, inside RocketLauncher. Fires the rocket.

	── THE VULNERABILITY THIS CLOSES ────────────────────────────────────────────
	The original built its RemoteEvent like this:

	    local event = game.ReplicatedStorage:FindFirstChild(eventName)
	    if not event then event = Instance.new("RemoteEvent", ...) end

	FindFirstChild first, so the SECOND rocket launcher to load found the first
	one's event and connected to it. So did the third. One RemoteEvent, named
	ROBLOX_RocketFireEvent, sitting in ReplicatedStorage where any client can
	reach it, with every launcher in the game listening on it.

	Then `fire` opened with

	    local vCharacter = Tool.Parent

	— the tool's parent, not the sender's character. It never asked whether the
	player who sent the packet was holding this tool, or holding anything.

	Put together: one FireServer call fired EVERY rocket launcher on the server,
	at a point the caller chose, from wherever those tools happened to be, tagged
	with somebody else's name as the creator. The three-second cooldown lived in
	LocalLauncher — a LocalScript, which an attacker is simply not running. There
	was no server cooldown at all.

	Three changes close it, and none of them change how the weapon plays:
	  * the remote is a CHILD OF THIS TOOL, so it is one launcher's own wire;
	  * the sender must be holding this tool, checked against their character;
	  * the cooldown is the server's, because a limit only the client enforces
	    is not a limit.

	The target is also validated now. It was taken on trust, so a zero-length or
	NaN vector reached `(vTarget - vHandle.Position).unit` and produced a missile
	at an undefined CFrame.
]]

local tool = script.Parent

local COOLDOWN = 3
local MAX_TARGET_RANGE = 1000 -- a target further than this is not a shot, it is a packet
local SPAWN_AHEAD = 10 -- studs in front of the handle, so it never spawns inside the shooter

local template = Instance.new("Part")
template.Name = "Rocket"
template.Locked = true
template.Size = Vector3.new(1, 1, 4)
template.BrickColor = BrickColor.new(23)
--[[ Studs on every face, which is what the original asked for: it wrote the
     bare number 3, and 3 is Enum.SurfaceType.Studs. Spelled out here rather
     than converted to Smooth, because a surface type is how the rocket LOOKS
     and changing it was not the job. ]]
template.BackSurface = Enum.SurfaceType.Studs
template.BottomSurface = Enum.SurfaceType.Studs
template.FrontSurface = Enum.SurfaceType.Studs
template.LeftSurface = Enum.SurfaceType.Studs
template.RightSurface = Enum.SurfaceType.Studs
template.TopSurface = Enum.SurfaceType.Studs

local rocketScript = tool:FindFirstChild("RocketScript")
local explosion = tool:FindFirstChild("Explosion")
local swoosh = tool:FindFirstChild("Swoosh")
for _, asset in { rocketScript, explosion, swoosh } do
	if asset then
		asset:Clone().Parent = template
	end
end

--[[ This launcher's own wire. Parented to the tool rather than to
     ReplicatedStorage, which is the entire fix for the shared-event problem:
     a remote inside a tool is still reachable by its holder's client and by
     nobody else's launcher. ]]
local fireEvent = tool:FindFirstChild("RocketFire")
if not fireEvent or not fireEvent:IsA("RemoteEvent") then
	fireEvent = Instance.new("RemoteEvent")
	fireEvent.Name = "RocketFire"
	fireEvent.Parent = tool
end
local remote = fireEvent :: RemoteEvent

local readyAt = 0

local function finiteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local v = value :: Vector3
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
end

remote.OnServerEvent:Connect(function(player: Player, target: any)
	-- Holding THIS tool. The check the original never made.
	local character = player.Character
	if not character or tool.Parent ~= character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return
	end

	if not finiteVector(target) then
		return
	end

	-- The server's cooldown, not the client's advertised one.
	local now = os.clock()
	if now < readyAt then
		return
	end

	local delta = (target :: Vector3) - handle.Position
	if delta.Magnitude < 1e-3 or delta.Magnitude > MAX_TARGET_RANGE then
		return
	end
	readyAt = now + COOLDOWN

	local direction = delta.Unit
	local origin = handle.Position + direction * SPAWN_AHEAD

	local missile = template:Clone()
	missile.CFrame = CFrame.new(origin, origin + direction)
	if not player.Neutral then
		missile.BrickColor = player.TeamColor
	end

	local creator = Instance.new("ObjectValue")
	creator.Name = "creator"
	creator.Value = player
	creator.Parent = missile

	local body = missile:FindFirstChild("RocketScript")
	if body and body:IsA("BaseScript") then
		body.Disabled = false
	end

	missile.Parent = workspace
end)
