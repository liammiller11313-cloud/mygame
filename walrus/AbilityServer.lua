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
	lastUsed[player] = now

	ability.Activate(player, root, humanoid)
end)
