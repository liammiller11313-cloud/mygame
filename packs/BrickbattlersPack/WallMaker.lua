--!strict
--[[
	WallMaker — Script, inside ClassicTrowel. Builds a wall where you point.

	── THE SERVER HANG THIS REPLACES ────────────────────────────────────────────
	The original asked the client where to build:

	    local targetPos = MouseLoc:InvokeClient(player)

	A RemoteFunction invoked from the server toward a client yields the calling
	thread until that client answers — and a client is under no obligation to.
	One that is mid-disconnect, or simply chooses not to reply, leaves that
	thread parked forever. Roblox's own documentation says not to do this, and
	three tools in this pack do it: the trowel, the slingshot and the superball
	all ship a MouseLoc.

	The direction is now reversed. The CLIENT fires a RemoteEvent carrying where
	it wants the wall, and the server validates that against the character's real
	position. Nothing yields, and a client that says nothing simply gets no wall.

	── AND THE WELD ─────────────────────────────────────────────────────────────
	`brick:MakeJoints()` welds each new brick to whatever it is touching. In a
	brickbattle map that is the floor and the brick below it, which is what makes
	a wall stand up. In a game with characters walking around it is also anything
	standing where the wall goes — a player, or in Fading Light an infected, gets
	welded into the geometry and dragged with it.

	The bricks are anchored instead. A wall that never falls over is what the
	weapon was for; welding was only ever the means.
]]

local tool = script.Parent

-- ── the wall ────────────────────────────────────────────────────────────────
local BRICK_SIZE = Vector3.new(4, 1.2, 2)
local WALL_WIDTH = 12
local WALL_HEIGHT = 4
local BRICK_SPEED = 0.04
local COOLDOWN = 5

--[[ A ceiling on the loop rather than a trust in the arithmetic. The original
     walked `while x < wallWidth/2` using a position returned from the brick it
     had just made, so a zero-sized brick — which a misconfigured template gives
     you — never advanced x and built forever. ]]
local MAX_BRICKS = 64

-- How far from the builder a wall may be placed. The original never asked.
local MAX_PLACE_RANGE = 60

local cleanupTemplate = tool:FindFirstChild("BrickCleanup")

local place = tool:FindFirstChild("PlaceWall")
if not place or not place:IsA("RemoteEvent") then
	place = Instance.new("RemoteEvent")
	place.Name = "PlaceWall"
	place.Parent = tool
end
local remote = place :: RemoteEvent

local readyAt = 0
local building = false

local function finiteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local v = value :: Vector3
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
end

--[[ The wall faces whichever axis the builder is most nearly looking along, so
     it always comes up square to the world rather than at whatever angle the
     mouse happened to be at. Unchanged from the original — it is the reason a
     trowel wall reads as a wall. ]]
local function snap(v: Vector3): Vector3
	if math.abs(v.X) > math.abs(v.Z) then
		return if v.X > 0 then Vector3.xAxis else -Vector3.xAxis
	end
	return if v.Z > 0 then Vector3.zAxis else -Vector3.zAxis
end

local function placeBrick(cf: CFrame, offset: Vector3, color: BrickColor): BasePart
	local brick = Instance.new("Part")
	brick.Size = BRICK_SIZE
	brick.BrickColor = color
	brick.Anchored = true
	brick.CFrame = cf * CFrame.new(offset + BRICK_SIZE / 2)
	if cleanupTemplate then
		local cleanup = cleanupTemplate:Clone()
		cleanup.Parent = brick
		if cleanup:IsA("BaseScript") then
			cleanup.Disabled = false
		end
	end
	brick.Parent = workspace
	return brick
end

local function buildWall(cf: CFrame)
	local color = BrickColor.Random()
	local placed = 0

	local y = 0
	while y < WALL_HEIGHT and placed < MAX_BRICKS do
		local x = -WALL_WIDTH / 2
		while x < WALL_WIDTH / 2 and placed < MAX_BRICKS do
			placeBrick(cf, Vector3.new(x, y, 0), color)
			placed += 1
			x += BRICK_SIZE.X
			task.wait(BRICK_SPEED)
		end
		y += BRICK_SIZE.Y
	end
end

remote.OnServerEvent:Connect(function(player: Player, target: any)
	local character = player.Character
	if not character or tool.Parent ~= character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head") :: BasePart?
	if not humanoid or humanoid.Health <= 0 or not head then
		return
	end

	--[[ `building` as well as the clock, because the build yields for half a
	     second and the cooldown is only set once it finishes. Without it a second
	     request during the build starts a second wall. ]]
	local now = os.clock()
	if building or now < readyAt then
		return
	end

	if not finiteVector(target) then
		return
	end
	local point = target :: Vector3
	local delta = point - head.Position
	if delta.Magnitude < 1e-3 or delta.Magnitude > MAX_PLACE_RANGE then
		return
	end

	building = true
	local facing = snap(delta.Unit)
	local handle = tool:FindFirstChild("Handle")
	local sound = handle and handle:FindFirstChild("BuildSound")
	if sound and sound:IsA("Sound") then
		sound:Play()
	end

	--[[ Wrapped, because the build yields and anything that throws inside it —
	     a character leaving mid-wall — would otherwise leave `building` true and
	     the trowel dead for the rest of the round. ]]
	local ok = pcall(buildWall, CFrame.new(point, point + facing))
	if not ok then
		warn("WallMaker: build failed partway")
	end

	building = false
	readyAt = os.clock() + COOLDOWN
end)
