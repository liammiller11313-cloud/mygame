--!strict
--[[
	Slingshot — Script, inside ClassicSlingshot. Fires the pellet.

	── THE SERVER HANG THIS REPLACES ────────────────────────────────────────────
	    local targetPos = MouseLoc:InvokeClient(player)

	A RemoteFunction invoked from the server toward a client yields the calling
	thread until that client answers, and a client is under no obligation to. One
	mid-disconnect, or one that simply declines, parks that thread forever.
	Roblox's own documentation says not to do this.

	The direction is reversed: the client fires a RemoteEvent carrying where it
	is aiming, and that IS the activation. Nothing yields.

	── THE DOOR THAT OPENS WHEN YOU DO THAT ─────────────────────────────────────
	The original was safe from a different problem by accident. It hung off
	Tool.Activated, which the engine only raises for the character actually
	holding the tool — so there was no packet for anyone else to send. Replacing
	that with a RemoteEvent creates precisely the hole the rocket launcher had,
	where any client could fire any weapon.

	So the same three guards arrive with the same change, and they are not
	optional extras:
	  * the remote is a CHILD OF THIS TOOL, not a shared one in ReplicatedStorage;
	  * the sender must be holding this tool, checked against their character;
	  * the cooldown is the server's. Tool.Enabled is still set, because it greys
	    the tool out and stops the client sending in the first place, but a limit
	    only the client enforces is not a limit.

	── NUMBERS ──────────────────────────────────────────────────────────────────
	These are the classic free-model values. If Brickbattle Ultimate's slingshot
	was retuned, these six are the ones to change — nothing else in the file
	depends on them.
]]

local Players = game:GetService("Players")

local tool = script.Parent

local PELLET_SPEED = 100
local PELLET_SIZE = Vector3.new(1, 1, 1)
local PELLET_COLOR = BrickColor.new(26) -- Black
local SPAWN_AHEAD = 5 -- studs in front of the handle, so it never spawns inside you
local RELOAD = 6
local MAX_TARGET_RANGE = 1000 -- further than this is not a shot, it is a packet

local pelletScript = tool:FindFirstChild("PelletScript")

local shoot = tool:FindFirstChild("Shoot")
if not shoot or not shoot:IsA("RemoteEvent") then
	shoot = Instance.new("RemoteEvent")
	shoot.Name = "Shoot"
	shoot.Parent = tool
end
local remote = shoot :: RemoteEvent

local readyAt = 0

local function finiteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local v = value :: Vector3
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
end

local function fire(player: Player, handle: BasePart, direction: Vector3)
	local pellet = Instance.new("Part")
	pellet.Name = "Pellet"
	pellet.Size = PELLET_SIZE
	pellet.Shape = Enum.PartType.Ball
	pellet.BrickColor = PELLET_COLOR
	pellet.TopSurface = Enum.SurfaceType.Smooth
	pellet.BottomSurface = Enum.SurfaceType.Smooth
	pellet.Elasticity = 0
	pellet.Reflectance = 0
	pellet.Friction = 0.9
	pellet.Locked = true
	pellet.CFrame =
		CFrame.new(handle.Position + direction * SPAWN_AHEAD, handle.Position + direction * (SPAWN_AHEAD + 1))

	--[[ Cancels gravity exactly, so the pellet flies flat instead of arcing.
	     That is the classic slingshot's whole feel and it is why this is a force
	     rather than a velocity: the mass is only known once the part exists. ]]
	local lift = Instance.new("BodyForce")
	lift.Force = Vector3.new(0, pellet:GetMass() * workspace.Gravity, 0)
	lift.Parent = pellet

	local creator = Instance.new("ObjectValue")
	creator.Name = "creator"
	creator.Value = player
	creator.Parent = pellet

	if pelletScript then
		local body = pelletScript:Clone()
		body.Parent = pellet
		if body:IsA("BaseScript") then
			body.Disabled = false
		end
	end

	pellet.AssemblyLinearVelocity = direction * PELLET_SPEED
	pellet.Parent = workspace
end

remote.OnServerEvent:Connect(function(player: Player, target: any)
	-- Holding THIS tool. Without this the remote is an open weapon for anybody.
	local character = player.Character
	if not character or tool.Parent ~= character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if not handle or not finiteVector(target) then
		return
	end

	local now = os.clock()
	if now < readyAt then
		return
	end

	local delta = (target :: Vector3) - handle.Position
	if delta.Magnitude < 1e-3 or delta.Magnitude > MAX_TARGET_RANGE then
		return
	end
	readyAt = now + RELOAD

	local sound = handle:FindFirstChild("Fire")
	if sound and sound:IsA("Sound") then
		sound:Play()
	end

	fire(player, handle, delta.Unit)

	--[[ Greys the tool out for the reload. Cosmetic and useful — it stops the
	     client sending packets it knows will be refused — but readyAt above is
	     what actually decides. ]]
	tool.Enabled = false
	task.delay(RELOAD, function()
		tool.Enabled = true
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	if tool.Parent == player.Character then
		tool.Enabled = true
	end
end)
