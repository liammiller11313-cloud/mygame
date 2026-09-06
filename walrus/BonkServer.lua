--[[
	BonkServer
	----------
	WHERE THIS GOES:  ServerScriptService
	WHAT KIND:        Script   (NOT a LocalScript)

	Knocks people around when they get bonked, and pays the bonker an icicle.

	Expects, from elsewhere in your game:
	  * ReplicatedStorage.SlapEvent      - a RemoteEvent the client fires
	  * character.Walrus                 - the walrus model, so lobby players
										   without one can't bonk
	  * character.Walrus.BonkSound       - optional
	  * leaderstats.Icicles              - optional, the payout
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local bonkEvent = ReplicatedStorage:WaitForChild("SlapEvent")

local COOLDOWN = 1 -- seconds between bonks

-- The bonk volume. It starts at the walrus and reaches forward, so there is
-- no dead patch right in front of your face.
local BONK_WIDTH = 5
local BONK_HEIGHT = 5
local BONK_REACH = 12 -- studs in front of you the bonk reaches

local KNOCKBACK = 70
local UPWARD_FORCE = 25

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

	-- Don't let a dead walrus keep swinging.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return
	end

	-- Stop spam.
	local now = os.clock()
	if now < (nextBonk[player] or 0) then
		return
	end
	nextBonk[player] = now + COOLDOWN

	-- Ask the engine what's in the box directly, rather than building a real
	-- Part to ask with. The old way replicated an invisible part to every
	-- player in the server on every single bonk, and leaked it into the
	-- Workspace forever if anything below it threw an error.
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local bonkCFrame = root.CFrame * CFrame.new(0, 0, -BONK_REACH / 2)
	local bonkSize = Vector3.new(BONK_WIDTH, BONK_HEIGHT, BONK_REACH)
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
