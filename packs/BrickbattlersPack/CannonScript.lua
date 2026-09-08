--!strict
--[[
	CannonScript — Script, inside ClassicSuperball. Throws the ball.

	Same two changes as the slingshot, for the same two reasons.

	MouseLoc:InvokeClient parked a server thread until the client answered, and a
	client need not. The client now volunteers its aim through a RemoteEvent and
	that is the activation, so nothing yields.

	And because that swaps Tool.Activated — which only the holder can raise — for
	a remote anybody can send, the holder check and the server cooldown arrive in
	the same change. Skipping them would trade a hang for an open weapon.

	── NUMBERS ──────────────────────────────────────────────────────────────────
	Classic free-model values. If yours were retuned, these are the five to
	change. The superball keeps its gravity, unlike the slingshot pellet — the
	arc and the bounce are the weapon.
]]

local Players = game:GetService("Players")

local tool = script.Parent

local BALL_SPEED = 100
local BALL_SIZE = Vector3.new(2, 2, 2)
local BALL_COLOR = BrickColor.new("Bright yellow")
local SPAWN_AHEAD = 5
local RELOAD = 6
local MAX_TARGET_RANGE = 1000

local ballScript = tool:FindFirstChild("CannonBall")

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

local function throw(player: Player, handle: BasePart, direction: Vector3)
	local ball = Instance.new("Part")
	ball.Name = "CannonBall"
	ball.Size = BALL_SIZE
	ball.Shape = Enum.PartType.Ball
	ball.BrickColor = BALL_COLOR
	ball.TopSurface = Enum.SurfaceType.Smooth
	ball.BottomSurface = Enum.SurfaceType.Smooth
	--[[ The bounce. Elasticity at 1 and friction near zero is the difference
	     between a superball and a rock, and it is the reason this one keeps its
	     gravity where the slingshot pellet cancels its own. ]]
	ball.Elasticity = 1
	ball.Friction = 0.1
	ball.Locked = true
	ball.CFrame = CFrame.new(handle.Position + direction * SPAWN_AHEAD)

	local creator = Instance.new("ObjectValue")
	creator.Name = "creator"
	creator.Value = player
	creator.Parent = ball

	if ballScript then
		local body = ballScript:Clone()
		body.Parent = ball
		if body:IsA("BaseScript") then
			body.Disabled = false
		end
	end

	ball.AssemblyLinearVelocity = direction * BALL_SPEED
	ball.Parent = workspace
end

remote.OnServerEvent:Connect(function(player: Player, target: any)
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

	throw(player, handle, delta.Unit)

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
