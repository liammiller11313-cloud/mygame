--[[
	AbilityServer
	-------------
	WHERE THIS GOES:  ServerScriptService
	WHAT KIND:        Script   (NOT a LocalScript)

	Runs whatever ability the player has equipped on the leaderboard.

	Everything that matters happens here, on the server. The client only
	ever says "I pressed the button" - it never says who it hit or how
	much damage to deal. That is what stops people cheating.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

-- The client fires this. Made here so you never insert it by hand.
local useAbility = Instance.new("RemoteEvent")
useAbility.Name = "UseAbility"
useAbility.Parent = ReplicatedStorage

-- ============================================================
--  HELPERS - the shared bits the abilities below use
-- ============================================================

-- Finds every living player within `range` studs and roughly in front of you.
-- minDot 0.4 is about a 130-degree cone. Closer to 1 = narrower, 0 = a full
-- half-circle, -1 = all the way around you.
local function findTargets(attacker, root, range, minDot)
	local found = {}
	local origin = root.Position
	local facing = root.CFrame.LookVector

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= attacker then
			local character = other.Character
			local otherRoot = character and character:FindFirstChild("HumanoidRootPart")
			local otherHumanoid = character and character:FindFirstChildOfClass("Humanoid")

			if otherRoot and otherHumanoid and otherHumanoid.Health > 0 then
				local offset = otherRoot.Position - origin
				local distance = offset.Magnitude

				if distance > 0 and distance <= range and facing:Dot(offset.Unit) >= minDot then
					table.insert(found, { Humanoid = otherHumanoid, Root = otherRoot })
				end
			end
		end
	end

	return found
end

-- A quick glowing puff so a swing you can feel is also a swing you can see.
local function flash(cframe, size, color, seconds)
	local puff = Instance.new("Part")
	puff.Shape = Enum.PartType.Ball
	puff.Size = Vector3.new(size, size, size)
	puff.CFrame = cframe
	puff.Color = color
	puff.Material = Enum.Material.Neon
	puff.Transparency = 0.6
	puff.Anchored = true
	puff.CanCollide = false
	puff.CanQuery = false
	puff.CanTouch = false
	puff.Parent = workspace

	Debris:AddItem(puff, seconds)
end

-- ============================================================
--  THE ABILITIES
--
--  The key on the left ("Basic") must match exactly what the
--  leaderboard says. Add a new ability by copying a whole block
--  and making an EquipPad whose ABILITY_NAME is the new key.
-- ============================================================

local ABILITIES = {

	Basic = {
		Cooldown = 1, -- seconds before you can use it again

		Activate = function(player, root, _humanoid)
			local RANGE = 12
			local DAMAGE = 20

			flash(root.CFrame * CFrame.new(0, 0, -RANGE * 0.4), RANGE * 0.8, Color3.fromRGB(235, 245, 255), 0.15)

			for _, target in ipairs(findTargets(player, root, RANGE, 0.4)) do
				-- TakeDamage respects ForceFields, so it won't hit players
				-- still protected at their spawn.
				target.Humanoid:TakeDamage(DAMAGE)

				-- A shove away from you, so a hit reads as a hit.
				local push = (target.Root.Position - root.Position).Unit * 35
				target.Root.AssemblyLinearVelocity = push + Vector3.new(0, 25, 0)
			end
		end,
	},

	-- An example of a second, completely different ability: no damage at
	-- all, just a lunge. Make an EquipPad with ABILITY_NAME = "Charge"
	-- and this one works too.
	Charge = {
		Cooldown = 4,

		Activate = function(_player, root, _humanoid)
			flash(root.CFrame, 6, Color3.fromRGB(120, 200, 255), 0.2)
			root.AssemblyLinearVelocity = root.CFrame.LookVector * 90 + Vector3.new(0, 22, 0)
		end,
	},

	-- Expensive on purpose: four seconds of cover, paid for with a quarter
	-- of your health and most of a minute of waiting.
	Invisible = {
		Cooldown = 45, -- seconds before you can use it again

		Activate = function(_player, root, humanoid)
			local DURATION = 4 -- how long you stay hidden
			local HEALTH_COST = 25 -- paid up front, out of your own health
			local TRANSPARENCY = 1 -- 1 = fully gone. 0.85 leaves a faint shimmer.

			local character = humanoid.Parent

			-- Going invisible twice over would record "already invisible" as
			-- the look to restore, and you'd never come back. Can't happen
			-- while Cooldown is above DURATION, but it's cheap to be sure.
			if character:GetAttribute("Invisible") then
				return false
			end

			-- Refuse rather than kill them. Returning false tells the
			-- plumbing below not to spend the cooldown either.
			if humanoid.Health <= HEALTH_COST then
				return false
			end

			-- Straight subtraction rather than TakeDamage: a price you pay
			-- yourself should still be paid inside a spawn ForceField.
			humanoid.Health = humanoid.Health - HEALTH_COST
			character:SetAttribute("Invisible", true)

			-- Remember how see-through each piece was BEFORE we touch it.
			-- HumanoidRootPart is already invisible, so blindly resetting
			-- everything to 0 later would leave a grey block in your chest.
			local original = {}
			for _, item in ipairs(character:GetDescendants()) do
				if item:IsA("BasePart") or item:IsA("Decal") then
					original[item] = item.Transparency
					item.Transparency = math.max(item.Transparency, TRANSPARENCY)
				end
			end

			-- Or you'd be an invisible walrus under a floating name tag.
			local displayType = humanoid.DisplayDistanceType
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

			-- A puff going in and coming out, so both of you get a tell.
			flash(root.CFrame, 7, Color3.fromRGB(180, 160, 255), 0.25)

			task.delay(DURATION, function()
				-- They may have died, respawned or left while hidden, so put
				-- back only what is still there.
				for item, transparency in pairs(original) do
					if item.Parent then
						item.Transparency = transparency
					end
				end

				if humanoid.Parent then
					humanoid.DisplayDistanceType = displayType
				end

				if character.Parent then
					character:SetAttribute("Invisible", false)
					flash(root.CFrame, 7, Color3.fromRGB(180, 160, 255), 0.25)
				end
			end)
		end,
	},
}

-- ============================================================
--  THE PLUMBING - you shouldn't need to touch below here
-- ============================================================

-- When each player last used an ability, so we can enforce cooldowns.
local lastUsed = {}

Players.PlayerRemoving:Connect(function(player)
	lastUsed[player] = nil -- don't hang onto players who left
end)

useAbility.OnServerEvent:Connect(function(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	-- Dead or still loading? Nothing to do.
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end

	-- Read what they have equipped straight off the leaderboard.
	local leaderstats = player:FindFirstChild("leaderstats")
	local equipped = leaderstats and leaderstats:FindFirstChild("Equipped")
	local ability = equipped and ABILITIES[equipped.Value]

	-- Nothing equipped yet, or a name with no ability behind it.
	if not ability then
		return
	end

	-- Still cooling down? Ignore the press.
	local now = os.clock()
	if now - (lastUsed[player] or 0) < ability.Cooldown then
		return
	end
	-- Charge them the cooldown first, then hand it back if the ability
	-- returns false to say it couldn't run - too little health, say.
	local previous = lastUsed[player]
	lastUsed[player] = now

	if ability.Activate(player, root, humanoid) == false then
		lastUsed[player] = previous
	end
end)
