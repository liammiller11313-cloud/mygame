--[[
	BonkServer
	----------
	WHERE THIS GOES:  ServerScriptService
	WHAT KIND:        Script   (NOT a LocalScript)

	The bonk: lunge forward, swing, knock whoever you catch off their feet.

	All of it runs here rather than on the client, so every player sees the
	same lunge and the same hitbox. A swing only you can see is a swing
	nobody can dodge.

	Expects, from elsewhere in your game:
	  * ReplicatedStorage.SlapEvent      - a RemoteEvent the client fires
	  * character.Walrus                 - the walrus model
	  * character.Walrus.BonkSound       - optional
	  * leaderstats.Icicles              - optional, the payout
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local bonkEvent = ReplicatedStorage:WaitForChild("SlapEvent")

local COOLDOWN = 1 -- seconds between bonks

-- The lunge. A forward shove on your own character, so the walrus goes
-- with it however it happens to be attached.
local LUNGE_SPEED = 28

-- The bonk volume. It starts at the walrus and reaches forward, so there is
-- no dead patch right in front of your face.
local BONK_WIDTH = 5
local BONK_HEIGHT = 5
local BONK_REACH = 12 -- studs in front of you the bonk reaches

-- Draws the hitbox so you can see exactly what you're swinging. Leave it on
-- while you tune the three numbers above; set it false before you publish.
local SHOW_HITBOX = true
local HITBOX_SHOW_TIME = 0.2

local KNOCKBACK = 70
local UPWARD_FORCE = 25

local RAGDOLL_TIME = 2 -- seconds you're on the floor after being bonked

local ICICLES_PER_BONK = 1
local DUMMY_NAME = "BonkDummy"

-- Prints every bonk to the Output window. Turn off before you publish, or
-- a busy server writes a line per bonk per player.
local DEBUG = true

-- When each player's next bonk is allowed. A timestamp rather than a flag
-- plus a timer, so a bonk doesn't schedule work that has to run later.
local nextBonk = {}

Players.PlayerRemoving:Connect(function(player)
	nextBonk[player] = nil
end)

-- ============================================================
--  RAGDOLL
-- ============================================================

-- Which knockdown is currently in charge of each character. Bonk someone
-- who's already down and the newer one takes over, so the older timer
-- doesn't stand them up early.
--
-- Weak keys: when a character is destroyed on respawn, its entry can be
-- collected instead of sitting here for the rest of the round.
local knockdown = setmetatable({}, { __mode = "k" })

local function knockDown(character, seconds)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local token = (knockdown[character] or 0) + 1
	knockdown[character] = token

	-- PlatformStand goes limp and stays down until we turn it off. It works
	-- on any rig, and unlike swapping the character's joints for physics
	-- constraints it can't shake the walrus model loose.
	humanoid.PlatformStand = true

	task.delay(seconds, function()
		-- A later bonk owns them now; let that one stand them back up.
		if knockdown[character] ~= token then
			return
		end
		knockdown[character] = nil

		-- They may have died or respawned while they were down.
		if humanoid.Parent and humanoid.Health > 0 then
			humanoid.PlatformStand = false
		end
	end)
end

-- ============================================================
--  SEEING THE SWING
-- ============================================================

local function showHitbox(cframe, size)
	local box = Instance.new("Part")
	box.Name = "BonkHitbox"
	box.Size = size
	box.CFrame = cframe
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false -- never blocks the line-of-sight check behind it
	box.CanTouch = false
	box.Material = Enum.Material.Neon
	box.Color = Color3.fromRGB(120, 200, 255)
	box.Transparency = 0.75
	box.Parent = workspace

	Debris:AddItem(box, HITBOX_SHOW_TIME)
end

-- ============================================================
--  FINDING WHO GOT HIT
-- ============================================================

-- Which character a hit part belongs to.
--
-- Climbing matters here: the walrus is a Model INSIDE the character, so the
-- first Model above a walrus part is the walrus, not the player. Stopping
-- there means every hit on the walrus itself - the part you can actually
-- see - quietly counts as nothing.
local function findTarget(part, ownCharacter)
	local model = part:FindFirstAncestorOfClass("Model")

	while model do
		if model ~= ownCharacter then
			local otherPlayer = Players:GetPlayerFromCharacter(model)
			if otherPlayer or model.Name == DUMMY_NAME then
				return model, otherPlayer
			end
		end

		model = model:FindFirstAncestorOfClass("Model")
	end

	return nil, nil
end

-- Is there a clear line between them? Without this you can bonk people
-- through walls, which in a knockback game means through the floor too.
local function canSee(fromRoot, toRoot, ownCharacter, targetCharacter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ownCharacter, targetCharacter }
	params.IgnoreWater = true

	return workspace:Raycast(fromRoot.Position, toRoot.Position - fromRoot.Position, params) == nil
end

local function payIcicle(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local icicles = leaderstats and leaderstats:FindFirstChild("Icicles")

	if icicles then
		icicles.Value += ICICLES_PER_BONK
	end
end

-- ============================================================
--  THE BONK
-- ============================================================

bonkEvent.OnServerEvent:Connect(function(player)
	-- No walrus, no bonk. Players in the lobby don't have one.
	local character = player.Character
	if not character then
		return
	end

	local walrus = character:FindFirstChild("Walrus")
	if not walrus then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	-- Don't let a dead walrus keep swinging - or one that's flat on its back.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and (humanoid.Health <= 0 or humanoid.PlatformStand) then
		return
	end

	-- Stop spam.
	local now = os.clock()
	if now < (nextBonk[player] or 0) then
		return
	end
	nextBonk[player] = now + COOLDOWN

	-- The lunge. Keep whatever vertical speed they already had, so this
	-- shoves them forward without cancelling a jump or a fall.
	local rising = root.AssemblyLinearVelocity.Y
	root.AssemblyLinearVelocity = root.CFrame.LookVector * LUNGE_SPEED + Vector3.new(0, rising, 0)

	local bonkCFrame = root.CFrame * CFrame.new(0, 0, -BONK_REACH / 2)
	local bonkSize = Vector3.new(BONK_WIDTH, BONK_HEIGHT, BONK_REACH)

	if SHOW_HITBOX then
		showHitbox(bonkCFrame, bonkSize)
	end

	-- Ask the engine what's in the box directly, rather than building a real
	-- Part to ask with. The drawn box above is decoration only - it takes no
	-- part in this, which is why it can be switched off without changing
	-- who gets hit.
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local parts = workspace:GetPartBoundsInBox(bonkCFrame, bonkSize, params)

	local alreadyHit = {}
	local hitAnyone = false

	for _, part in ipairs(parts) do
		local targetCharacter, otherPlayer = findTarget(part, character)

		if targetCharacter and not alreadyHit[targetCharacter] then
			alreadyHit[targetCharacter] = true

			local otherRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
			local otherHumanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
			local isAlive = not otherHumanoid or otherHumanoid.Health > 0

			if otherRoot and isAlive and canSee(root, otherRoot, character, targetCharacter) then
				hitAnyone = true

				-- Drop them first. Going limp before the shove lands is what
				-- makes them tumble instead of skating along upright.
				knockDown(targetCharacter, RAGDOLL_TIME)

				-- Away from you. Two characters standing in exactly the same
				-- spot give a zero-length direction, which has no .Unit -
				-- fall back to where you're facing.
				local offset = otherRoot.Position - root.Position
				local direction = (offset.Magnitude > 0) and offset.Unit or root.CFrame.LookVector

				otherRoot.AssemblyLinearVelocity = direction * KNOCKBACK + Vector3.new(0, UPWARD_FORCE, 0)

				if otherPlayer then
					payIcicle(player)

					if DEBUG then
						print(player.Name .. " BONKED " .. otherPlayer.Name)
					end
				elseif DEBUG then
					print(player.Name .. " BONKED THE TEST DUMMY!")
				end
			end
		end
	end

	-- Once per bonk, not once per person caught in it. Restarting the same
	-- Sound three times in one frame only ever plays it once anyway.
	if hitAnyone then
		local bonkSound = walrus:FindFirstChild("BonkSound")
		if bonkSound then
			bonkSound:Play()
		end
	end
end)
