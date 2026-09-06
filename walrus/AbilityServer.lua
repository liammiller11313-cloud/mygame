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

-- Is there a clear line between these two? Without this you can swipe
-- people through walls, which feels broken the first time it happens.
local function canSee(fromRoot, toRoot)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { fromRoot.Parent, toRoot.Parent }
	params.IgnoreWater = true

	local hit = workspace:Raycast(fromRoot.Position, toRoot.Position - fromRoot.Position, params)
	return hit == nil -- nothing in the way
end

-- Finds every living player you can actually reach: close enough, roughly in
-- front of you, and not behind cover.
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
					if canSee(root, otherRoot) then
						table.insert(found, { Player = other, Humanoid = otherHumanoid, Root = otherRoot })
					end
				end
			end
		end
	end

	return found
end

-- Every ability should deal damage through here, so kills always get counted.
local function dealDamage(attacker, target, amount)
	-- TakeDamage respects ForceFields, so it won't hit players still
	-- protected at their spawn.
	target.Humanoid:TakeDamage(amount)

	-- That blow finished them off - put it on the attacker's scoreboard.
	if target.Humanoid.Health <= 0 then
		local leaderstats = attacker:FindFirstChild("leaderstats")
		local kills = leaderstats and leaderstats:FindFirstChild("Kills")
		if kills then
			kills.Value += 1
		end
	end
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
--
--  Return false from Activate to mean "couldn't run" - the player
--  then keeps their cooldown instead of paying for nothing.
-- ============================================================

local ABILITIES = {

	Basic = {
		Cooldown = 1, -- seconds before you can use it again

		Activate = function(player, root, _humanoid)
			local RANGE = 12
			local DAMAGE = 20

			flash(root.CFrame * CFrame.new(0, 0, -RANGE * 0.4), RANGE * 0.8, Color3.fromRGB(235, 245, 255), 0.15)

			for _, target in ipairs(findTargets(player, root, RANGE, 0.4)) do
				dealDamage(player, target, DAMAGE)

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

			-- Refuse rather than kill them, and hand the cooldown back.
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

	-- The Molten Walrus. Breathes a stream of fire for a couple of seconds,
	-- burning in ticks rather than all at once - so stepping out of the
	-- stream, or ducking behind cover, actually saves you.
	Molten = {
		Cooldown = 10,

		Activate = function(player, root, humanoid)
			local DURATION = 2 -- how long the stream lasts
			local TICK = 0.2 -- how often it burns whoever is caught in it
			local DAMAGE = 6 -- per tick, so about 60 over a full stream
			local RANGE = 18 -- studs the flame reaches
			local CONE = 0.75 -- tighter than a swipe: a stream, not a splash
			local OFFSET = 3 -- studs in front of you the flame starts

			-- An invisible part carrying Roblox's built-in Fire effect. Fire
			-- needs no uploaded texture, which is why this works in a blank
			-- place with nothing in it.
			local nozzle = Instance.new("Part")
			nozzle.Size = Vector3.new(1, 1, 1)
			nozzle.Transparency = 1
			nozzle.Anchored = true
			nozzle.CanCollide = false
			nozzle.CanQuery = false -- so it never blocks a line-of-sight check
			nozzle.CanTouch = false
			nozzle.CFrame = root.CFrame * CFrame.new(0, 0, -OFFSET)
			nozzle.Parent = workspace

			local fire = Instance.new("Fire")
			fire.Size = 14
			fire.Heat = 20
			fire.Color = Color3.fromRGB(255, 140, 40)
			fire.SecondaryColor = Color3.fromRGB(255, 60, 0)
			fire.Parent = nozzle

			-- Half a second past the end, so the last flames fade instead of
			-- vanishing mid-flicker.
			Debris:AddItem(nozzle, DURATION + 0.5)

			-- task.spawn so the stream runs on its own and the server gets
			-- straight back to handling everyone else.
			task.spawn(function()
				local elapsed = 0

				while elapsed < DURATION do
					-- Died or left mid-breath? Stop burning.
					if humanoid.Health <= 0 or not root.Parent then
						break
					end

					-- Keep the flame in front of them as they walk and turn.
					nozzle.CFrame = root.CFrame * CFrame.new(0, 0, -OFFSET)

					for _, target in ipairs(findTargets(player, root, RANGE, CONE)) do
						dealDamage(player, target, DAMAGE)
					end

					-- task.wait hands back how long it really waited, which
					-- is never exactly TICK.
					elapsed += task.wait(TICK)
				end

				fire.Enabled = false -- stop making flame; let the rest burn out
			end)
		end,
	},
}

-- ============================================================
--  THE PLUMBING - you shouldn't need to touch below here
-- ============================================================

-- The server time each player's next go becomes available.
local readyAt = {}

-- Ability names we've already complained about, so a typo warns once
-- instead of once per key press.
local warnedNames = {}

Players.PlayerRemoving:Connect(function(player)
	readyAt[player] = nil -- don't hang onto players who left
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
	if not equipped then
		return
	end

	local ability = ABILITIES[equipped.Value]
	if not ability then
		-- "None" is the normal starting state, not a mistake. Any other name
		-- with no ability behind it is almost always a typo on an EquipPad,
		-- so say so in the Output window rather than failing silently.
		if equipped.Value ~= "None" and not warnedNames[equipped.Value] then
			warnedNames[equipped.Value] = true
			warn(
				("Ability %q is equipped but is not in the ABILITIES table - check the spelling on that EquipPad."):format(
					equipped.Value
				)
			)
		end
		return
	end

	-- GetServerTimeNow is the same clock on the server and on every client,
	-- so the HUD can count the same cooldown down without asking us.
	local now = workspace:GetServerTimeNow()
	if now < (readyAt[player] or 0) then
		return -- still cooling down
	end

	-- Start the cooldown first, then hand it back if the ability turns out
	-- not to have run - too little health to go invisible, say.
	local previous = readyAt[player]
	readyAt[player] = now + ability.Cooldown
	player:SetAttribute("AbilityReadyAt", readyAt[player])

	if ability.Activate(player, root, humanoid) == false then
		readyAt[player] = previous
		player:SetAttribute("AbilityReadyAt", previous or 0)
	end
end)
