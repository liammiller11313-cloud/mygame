--[[
	BonkServer
	----------
	WHERE THIS GOES:  ServerScriptService
	WHAT KIND:        Script   (NOT a LocalScript)

	Two attacks, both running here so every player sees the same thing.

	  BONK    - left click. Every walrus has it. A swing in place.
	  SPECIAL - E. Different for each walrus. Basic's is Lunge & Jab.

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

-- The client fires this for the special. Made here so you never insert it
-- by hand.
local specialEvent = Instance.new("RemoteEvent")
specialEvent.Name = "SpecialEvent"
specialEvent.Parent = ReplicatedStorage

-- ============================================================
--  THE BONK - the same for every walrus
-- ============================================================

local COOLDOWN = 1 -- seconds between bonks

-- The bonk volume, measured as the near and far edge of a box in front of
-- you. Say where it starts and where it stops and the depth follows, so
-- the two can't drift apart the way a size and a separate offset can.
--
-- Careful with the near edge: everything closer than that is a hole you
-- cannot hit through. 2 is a nose-length. Push it to 6 and someone stood
-- against your chest is untouchable.
local BONK_WIDTH = 5
local BONK_HEIGHT = 5
local BONK_START = 2 -- studs in front of you the box begins
local BONK_REACH = 14 -- studs in front of you the box ends

local KNOCKBACK = 70
local UPWARD_FORCE = 25
local RAGDOLL_TIME = 2 -- seconds they're on the floor

local ICICLES_PER_BONK = 1

-- Draws every hitbox so you can see exactly what you're swinging. Leave it
-- on while you tune the numbers; set it false before you publish.
local SHOW_HITBOX = true
local HITBOX_SHOW_TIME = 0.2

local DUMMY_NAME = "BonkDummy"
local DEFAULT_WALRUS = "Basic"

-- Prints every bonk to the Output window. Turn off before you publish, or
-- a busy server writes a line per bonk per player.
local DEBUG = true

-- ============================================================
--  HELPERS
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
		-- A later hit owns them now; let that one stand them back up.
		if knockdown[character] ~= token then
			return
		end
		knockdown[character] = nil

		if humanoid.Parent and humanoid.Health > 0 then
			humanoid.PlatformStand = false
		end
	end)
end

local function showHitbox(cframe, size, color)
	local box = Instance.new("Part")
	box.Name = "BonkHitbox"
	box.Size = size
	box.CFrame = cframe
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false -- never blocks the line-of-sight check behind it
	box.CanTouch = false
	box.Material = Enum.Material.Neon
	box.Color = color
	box.Transparency = 0.75
	box.Parent = workspace

	Debris:AddItem(box, HITBOX_SHOW_TIME)
end

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

-- Is there a clear line between them? Without this you can hit people
-- through walls, which in a knockback game means through the floor too.
local function canSee(fromRoot, toRoot, ownCharacter, targetCharacter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ownCharacter, targetCharacter }
	params.IgnoreWater = true

	return workspace:Raycast(fromRoot.Position, toRoot.Position - fromRoot.Position, params) == nil
end

-- Everyone standing in a box in front of you. Both attacks go through this,
-- so a new special can't accidentally hit through walls or catch the same
-- person twice.
local function hitInFront(character, root, box)
	-- Depth and centre are derived from the two edges, so the box always
	-- sits exactly where the near and far edge say it does.
	local depth = math.max(box.Reach - box.Start, 0.1)
	local centre = (box.Start + box.Reach) / 2

	local cframe = root.CFrame * CFrame.new(0, 0, -centre)
	local size = Vector3.new(box.Width, box.Height, depth)

	if SHOW_HITBOX then
		showHitbox(cframe, size, box.Color or Color3.fromRGB(120, 200, 255))
	end

	-- Ask the engine what's in the box directly. The drawn box above is
	-- decoration only - it takes no part in this, which is why it can be
	-- switched off without changing who gets hit.
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local found = {}
	local seen = {}

	for _, part in ipairs(workspace:GetPartBoundsInBox(cframe, size, params)) do
		local targetCharacter, otherPlayer = findTarget(part, character)

		if targetCharacter and not seen[targetCharacter] then
			seen[targetCharacter] = true

			local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
			local targetHumanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
			local alive = not targetHumanoid or targetHumanoid.Health > 0

			if targetRoot and alive and canSee(root, targetRoot, character, targetCharacter) then
				table.insert(found, { Character = targetCharacter, Player = otherPlayer, Root = targetRoot })
			end
		end
	end

	return found
end

-- Send them away from you. Two characters standing in exactly the same spot
-- give a zero-length direction, which has no .Unit - fall back to where
-- you're facing.
local function shove(targetRoot, fromRoot, force, upward)
	local offset = targetRoot.Position - fromRoot.Position
	local direction = (offset.Magnitude > 0) and offset.Unit or fromRoot.CFrame.LookVector

	targetRoot.AssemblyLinearVelocity = direction * force + Vector3.new(0, upward, 0)
end

local function payIcicle(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local icicles = leaderstats and leaderstats:FindFirstChild("Icicles")

	if icicles then
		icicles.Value += ICICLES_PER_BONK
	end
end

local function playBonkSound(walrus)
	local sound = walrus:FindFirstChild("BonkSound")
	if sound then
		sound:Play()
	end
end

-- Everything an attack needs, or nil if this player can't attack right now.
local function readyToSwing(player)
	local character = player.Character
	if not character then
		return nil
	end

	-- No walrus, no attack. Players in the lobby don't have one.
	local walrus = character:FindFirstChild("Walrus")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not walrus or not root then
		return nil
	end

	-- Dead walruses don't swing, and neither do ones flat on their back.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and (humanoid.Health <= 0 or humanoid.PlatformStand) then
		return nil
	end

	return character, walrus, root, humanoid
end

-- Which walrus this player is wearing. The model is always called "Walrus"
-- so the name has to come from somewhere else - whichever of these your
-- game sets. Falls back to the starter, which everybody owns.
local function walrusNameOf(player, walrus)
	return player:GetAttribute("EquippedWalrus") or walrus:GetAttribute("WalrusName") or DEFAULT_WALRUS
end

-- ============================================================
--  THE SPECIALS - one per walrus, keyed by the walrus's name
--
--  Add a walrus by copying a whole block. The key on the left must be the
--  walrus's real name, the same one your equipper uses.
-- ============================================================

local SPECIALS = {

	Basic = {
		Name = "Lunge & Jab", -- what the HUD calls it
		Cooldown = 8,

		Activate = function(player, character, root, humanoid)
			local LUNGE_SPEED = 95 -- much harder than a bonk's little step
			local LUNGE_LIFT = 14 -- a hop, so you clear the ground going in
			local JAB_DELAY = 0.25 -- how long the lunge gets before the jab
			local JAB_KNOCKBACK = 110
			local JAB_UPWARD = 40
			local JAB_RAGDOLL = 3

			-- The lunge. Keep whatever vertical speed they already had, so
			-- this can't cancel a jump or pin them mid-fall.
			local rising = root.AssemblyLinearVelocity.Y
			root.AssemblyLinearVelocity = root.CFrame.LookVector * LUNGE_SPEED
				+ Vector3.new(0, rising + LUNGE_LIFT, 0)

			-- The jab lands where the lunge carried you, not where you
			-- started - that's the whole point of the delay.
			task.delay(JAB_DELAY, function()
				-- They may have been knocked down or killed mid-lunge.
				if humanoid.Health <= 0 or humanoid.PlatformStand or not root.Parent then
					return
				end

				local targets = hitInFront(character, root, {
					Start = 1,
					Reach = 13,
					Width = 7,
					Height = 7,
					Color = Color3.fromRGB(255, 200, 100),
				})

				for _, target in ipairs(targets) do
					knockDown(target.Character, JAB_RAGDOLL)
					shove(target.Root, root, JAB_KNOCKBACK, JAB_UPWARD)

					if target.Player then
						payIcicle(player)

						if DEBUG then
							print(player.Name .. " JABBED " .. target.Player.Name)
						end
					end
				end
			end)
		end,
	},

	-- Flamespitter goes here when you're ready - same shape, different
	-- Activate. Nothing else needs to change.
}

-- ============================================================
--  TELLING THE HUD WHAT'S GOING ON
-- ============================================================

local nextBonk = {} -- player -> server time their next bonk is allowed
local nextSpecial = {}

Players.PlayerRemoving:Connect(function(player)
	nextBonk[player] = nil
	nextSpecial[player] = nil
end)

-- GetServerTimeNow reads the same on the server and on every client, so the
-- HUD can count these down without asking us anything.
local function startCooldown(player, store, attribute, seconds)
	local readyAt = workspace:GetServerTimeNow() + seconds
	store[player] = readyAt
	player:SetAttribute(attribute, readyAt)
end

-- Name the special on the player so the HUD can label the button properly
-- rather than just saying "SPECIAL".
local function publishSpecialName(player)
	task.spawn(function()
		local character = player.Character or player.CharacterAdded:Wait()
		local walrus = character:WaitForChild("Walrus", 30)

		if not walrus then
			player:SetAttribute("SpecialName", nil)
			return
		end

		local special = SPECIALS[walrusNameOf(player, walrus)]
		player:SetAttribute("SpecialName", special and special.Name or nil)
	end)
end

Players.PlayerAdded:Connect(function(player)
	publishSpecialName(player)
	player.CharacterAdded:Connect(function()
		publishSpecialName(player)
	end)
end)

-- ============================================================
--  BONK
-- ============================================================

bonkEvent.OnServerEvent:Connect(function(player)
	local character, walrus, root = readyToSwing(player)
	if not character then
		return
	end

	local now = workspace:GetServerTimeNow()
	if now < (nextBonk[player] or 0) then
		return -- still cooling down
	end
	startCooldown(player, nextBonk, "BonkReadyAt", COOLDOWN)

	local targets = hitInFront(character, root, {
		Start = BONK_START,
		Reach = BONK_REACH,
		Width = BONK_WIDTH,
		Height = BONK_HEIGHT,
	})

	for _, target in ipairs(targets) do
		-- Drop them first. Going limp before the shove lands is what makes
		-- them tumble instead of skating along upright.
		knockDown(target.Character, RAGDOLL_TIME)
		shove(target.Root, root, KNOCKBACK, UPWARD_FORCE)

		if target.Player then
			payIcicle(player)

			if DEBUG then
				print(player.Name .. " BONKED " .. target.Player.Name)
			end
		elseif DEBUG then
			print(player.Name .. " BONKED THE TEST DUMMY!")
		end
	end

	-- Once per bonk, not once per person caught in it. Restarting the same
	-- Sound three times in one frame only ever plays it once anyway.
	if #targets > 0 then
		playBonkSound(walrus)
	end
end)

-- ============================================================
--  SPECIAL
-- ============================================================

specialEvent.OnServerEvent:Connect(function(player)
	local character, walrus, root, humanoid = readyToSwing(player)
	if not character then
		return
	end

	local special = SPECIALS[walrusNameOf(player, walrus)]
	if not special then
		return -- this walrus hasn't been given one yet
	end

	local now = workspace:GetServerTimeNow()
	if now < (nextSpecial[player] or 0) then
		return
	end
	startCooldown(player, nextSpecial, "SpecialReadyAt", special.Cooldown)

	special.Activate(player, character, root, humanoid)
end)
