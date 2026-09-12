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
-- The near edge is the one to watch: everything closer than it is a hole
-- you cannot hit through. Two characters pressed together sit roughly 3 to
-- 4 studs apart root to root, so 4 is about as far out as this can go
-- before someone standing on your nose becomes untouchable. Leave
-- SHOW_HITBOX on and walk into the dummy if you push it further.
local BONK_WIDTH = 5
local BONK_HEIGHT = 5
local BONK_START = 4 -- studs in front of you the box begins
local BONK_REACH = 18 -- studs in front of you the box ends

-- Power is a rating out of 10-to-25, not a speed, so it needs turning into
-- one. Seven studs per point: the starter's 10 becomes the 70 the game was
-- tuned around, and Coinflip's 25 becomes 175.
--
-- This is the one dial that moves the whole roster at once. If the top end
-- starts flinging people off the map, lower this rather than editing four
-- walruses - the spread between them stays exactly as the signs promise.
local KNOCKBACK_PER_POWER = 7

-- How high a bonk throws them. Deliberately NOT scaled by Power: how far
-- you send someone is the walrus's business, how high is the game's. Tie
-- the two together and the strongest walrus turns into a launcher.
local UPWARD_FORCE = 50

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

-- Characters currently ragdolled, and everything needed to put them back:
-- the joints we switched off, and the constraints we made to replace them.
--
-- Weak keys: when a character is destroyed on respawn, its entry can be
-- collected instead of sitting here for the rest of the round.
local ragdolled = setmetatable({}, { __mode = "k" })

-- Take physics off the victim's own machine for as long as they're down.
--
-- Roblox normally hands a player's character to that player's client to
-- simulate. That client is still running its own version of events, and it
-- will happily overwrite a velocity the server just set - which is exactly
-- why a bonk sometimes launched someone and sometimes did nothing. With the
-- server owning the parts, the throw lands every single time.
local function takeOwnership(character)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and not part.Anchored then
			-- Throws for anything not currently simulated. Those don't need it.
			pcall(part.SetNetworkOwner, part, nil)
		end
	end
end

local function returnOwnership(character)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and not part.Anchored then
			pcall(part.SetNetworkOwnershipAuto, part)
		end
	end
end

-- Swap the rig's joints for physics constraints, so the body actually goes
-- limp. PlatformStand on its own only takes away control - the character
-- keeps its shape and tumbles as one rigid lump, which reads as a statue
-- falling over rather than a walrus being launched.
--
-- Anything holding the walrus on is left strictly alone. Your equipper
-- attaches it somehow and this code doesn't know how; turning that joint
-- into a hinge would drop the walrus on the floor the first time its owner
-- got hit.
local function buildRagdoll(character)
	local walrus = character:FindFirstChild("Walrus")
	local motors = {}
	local made = {}

	for _, item in ipairs(character:GetDescendants()) do
		if item:IsA("Motor6D") and item.Part0 and item.Part1 then
			local holdsWalrus = walrus ~= nil
				and (item.Part0:IsDescendantOf(walrus) or item.Part1:IsDescendantOf(walrus))

			if not holdsWalrus then
				-- A BallSocketConstraint joins two Attachments, so the joint's
				-- own C0 and C1 become where those attachments sit. That's what
				-- makes the limb hang from the same point it was welded at.
				local socketEnd = Instance.new("Attachment")
				socketEnd.CFrame = item.C0
				socketEnd.Parent = item.Part0

				local limbEnd = Instance.new("Attachment")
				limbEnd.CFrame = item.C1
				limbEnd.Parent = item.Part1

				local socket = Instance.new("BallSocketConstraint")
				socket.Attachment0 = socketEnd
				socket.Attachment1 = limbEnd

				-- Limits on, or the body reads as a noodle: limbs bend through
				-- themselves and the whole thing looks broken rather than limp.
				socket.LimitsEnabled = true
				socket.UpperAngle = 45
				socket.TwistLimitsEnabled = true
				socket.TwistLowerAngle = -40
				socket.TwistUpperAngle = 40
				socket.Parent = item.Part1

				-- Disabled rather than destroyed, so this is reversible - and so
				-- the running animation has nothing left to drive.
				item.Enabled = false

				table.insert(motors, item)
				table.insert(made, socketEnd)
				table.insert(made, limbEnd)
				table.insert(made, socket)
			end
		end
	end

	return { Motors = motors, Made = made }
end

local function clearRagdoll(state)
	-- Constraints go first. Switching a motor back on while its replacement
	-- is still attached leaves two things fighting over the same joint.
	for _, item in ipairs(state.Made) do
		item:Destroy()
	end

	for _, motor in ipairs(state.Motors) do
		if motor.Parent then
			motor.Enabled = true
		end
	end
end

local function knockDown(character, seconds)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local state = ragdolled[character]

	-- Only come apart once. Hitting someone who's already down must not
	-- build a second set of constraints on joints that are already swapped.
	if not state then
		state = buildRagdoll(character)
		ragdolled[character] = state
		humanoid.PlatformStand = true
		takeOwnership(character)
	end

	-- The newer hit takes over the timer, so the older one can't stand them
	-- up early.
	local token = (state.Token or 0) + 1
	state.Token = token

	task.delay(seconds, function()
		if ragdolled[character] ~= state or state.Token ~= token then
			return -- a later hit owns them now
		end
		ragdolled[character] = nil

		clearRagdoll(state)

		if humanoid.Parent and humanoid.Health > 0 then
			humanoid.PlatformStand = false
		end

		-- Hand the character back to its owner, standing.
		returnOwnership(character)
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

-- Drop them limp, then throw the whole body up and away.
--
-- The order matters: ragdoll first. Flinging a body that hasn't come apart
-- yet just skids it along the floor upright.
--
-- The direction is flattened to the horizontal, and this is the whole
-- reason bonks used to bury people. A target whose root sits even slightly
-- below yours - on a slope, a step down, halfway through a fall, or simply
-- already knocked flat - gives an offset that points downward, and throwing
-- along it drives them into the floor. Height comes from `upward` alone,
-- never from where the two of you happened to be standing.
local function launch(targetCharacter, targetRoot, fromRoot, force, upward, seconds)
	knockDown(targetCharacter, seconds)

	local offset = targetRoot.Position - fromRoot.Position
	local direction = Vector3.new(offset.X, 0, offset.Z)

	if direction.Magnitude < 0.01 then
		-- Standing in exactly the same spot: use where you're facing, flattened
		-- the same way.
		local facing = fromRoot.CFrame.LookVector
		direction = Vector3.new(facing.X, 0, facing.Z)
	end

	if direction.Magnitude < 0.01 then
		-- Looking straight up or down, which a ragdolling root can do. Any
		-- horizontal direction is as good as another here.
		direction = Vector3.xAxis
	end

	local velocity = direction.Unit * force + Vector3.new(0, upward, 0)

	-- Every part, not just the root. Ragdolling broke one assembly into a
	-- dozen loose ones, so setting the root's velocity alone would fling the
	-- root and leave the arms and legs standing where they were.
	for _, part in ipairs(targetCharacter:GetDescendants()) do
		if part:IsA("BasePart") then
			part.AssemblyLinearVelocity = velocity
		end
	end
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
--  HOW HARD EACH WALRUS HITS
--
--  The number on the podium sign. A walrus missing from here falls back
--  to the starter's, so a new walrus is never accidentally weightless.
-- ============================================================

-- Straight off the podium signs. Keep them matching: this table is what
-- the game does, the sign is only what it claims.
local WALRUS_POWER = {
	Basic = 10,
	Flamespitter = 15,
	Buff = 20,
	Coinflip = 25,
}

-- Defined here rather than up with the other helpers because it reads the
-- table above: a function written before that `local` exists would look for
-- a global of the same name, find nothing, and hit for nil every time.
local function powerOf(player, walrus)
	return WALRUS_POWER[walrusNameOf(player, walrus)] or WALRUS_POWER[DEFAULT_WALRUS]
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

		Activate = function(player, character, root, humanoid, knockback)
			local DASH_SPEED = 85 -- studs per second, held for the whole dash
			local DASH_TIME = 0.3 -- so the dash covers about 25 studs

			-- A share of a normal bonk rather than its own number, so tuning
			-- Power moves the jab with it instead of leaving it behind.
			-- Above 1 because closing the distance first should be worth
			-- something; drop it under 1 if the jab should trade reach for force.
			local JAB_SHARE = 1.15
			local JAB_UPWARD = 58 -- higher than a bonk: it's the special
			local JAB_RAGDOLL = 3

			-- Lock the direction now and hold it for the whole dash. A dash that
			-- follows wherever you're looking lets you curve mid-flight, which
			-- makes it unreadable and so undodgeable.
			local facing = root.CFrame.LookVector
			local direction = Vector3.new(facing.X, 0, facing.Z)
			if direction.Magnitude < 0.01 then
				direction = Vector3.xAxis
			end
			direction = direction.Unit

			-- A mover rather than one shove of velocity. A shove is eaten by
			-- friction within a few frames and reads as a stumble; this holds the
			-- speed flat for the whole dash, which is what makes it a dash.
			local anchorPoint = Instance.new("Attachment")
			anchorPoint.Name = "DashAnchor"
			anchorPoint.Parent = root

			local dash = Instance.new("LinearVelocity")
			dash.Attachment0 = anchorPoint
			dash.RelativeTo = Enum.ActuatorRelativeTo.World
			dash.VectorVelocity = direction * DASH_SPEED

			-- Per-axis force with nothing on Y. A mover that also drove the
			-- vertical would hold them at zero fall speed and they'd hover across
			-- the arena; leaving Y alone lets gravity carry on as normal.
			dash.ForceLimitMode = Enum.ForceLimitMode.PerAxis
			dash.MaxAxesForce = Vector3.new(1e6, 0, 1e6)
			dash.Parent = root

			-- Whatever else happens, these do not outlive the dash.
			Debris:AddItem(dash, DASH_TIME + 1)
			Debris:AddItem(anchorPoint, DASH_TIME + 1)

			-- Bonked mid-dash? Cut the motor immediately, or a ragdolling body
			-- keeps being driven forward while it's supposed to be flying away.
			local interrupted
			interrupted = humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(function()
				if humanoid.PlatformStand then
					dash:Destroy()
				end
			end)

			-- The jab fires from the callback that ends the dash, rather than off
			-- a delay of its own. One timer, so the hit always lands exactly where
			-- the dash put you and the two can never drift apart.
			task.delay(DASH_TIME, function()
				interrupted:Disconnect()
				dash:Destroy()
				anchorPoint:Destroy()

				-- Died, left, or got knocked down on the way in.
				if humanoid.Health <= 0 or humanoid.PlatformStand or not root.Parent then
					return
				end

				-- Plant the dash before hitting. Destroying the mover only stops
				-- driving them; twenty five studs a second of momentum carries them
				-- on for several studs more, so the hitbox would otherwise appear
				-- around a walrus still sliding forward. Vertical speed is kept, or
				-- dashing off a ledge would leave you hanging in the air.
				local falling = root.AssemblyLinearVelocity.Y
				root.AssemblyLinearVelocity = Vector3.new(0, falling, 0)

				local targets = hitInFront(character, root, {
					Start = 3,
					Reach = 16,
					Width = 7,
					Height = 7,
					Color = Color3.fromRGB(255, 200, 100),
				})

				for _, target in ipairs(targets) do
					launch(target.Character, target.Root, root, knockback * JAB_SHARE, JAB_UPWARD, JAB_RAGDOLL)

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

	-- Still to write, each the same shape as Basic above:
	--   Flamespitter  "Flamethrower"
	--   Buff          "Seismic Toss"
	--   Coinflip      "Take a Chance"
	--
	-- Until then those three bonk like everyone else, at their own Power,
	-- and the HUD shows them no special row rather than a dead button.
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

	local knockback = powerOf(player, walrus) * KNOCKBACK_PER_POWER

	local targets = hitInFront(character, root, {
		Start = BONK_START,
		Reach = BONK_REACH,
		Width = BONK_WIDTH,
		Height = BONK_HEIGHT,
	})

	for _, target in ipairs(targets) do
		launch(target.Character, target.Root, root, knockback, UPWARD_FORCE, RAGDOLL_TIME)

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

	special.Activate(player, character, root, humanoid, powerOf(player, walrus) * KNOCKBACK_PER_POWER)
end)
