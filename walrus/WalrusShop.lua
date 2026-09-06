--[[
	WalrusShop
	----------
	WHERE THIS GOES:  ServerScriptService
	WHAT KIND:        Script   (NOT a LocalScript)

	Owns the walrus collection: who has which walrus, what they cost, and
	which one is equipped. Clicking a podium buys the walrus if you can
	afford it, or just equips it if you already own it.

	SETTING UP A PODIUM - no script goes in it. Instead:
	  1. Select the podium part you want players to click
	  2. In Properties, scroll to Attributes, click the +
	  3. Name it  WalrusName , type String, value  Basic  (or Flamespitter)
	This script finds every part with that attribute and wires it up.

	SAVING needs the place published AND Game Settings > Security >
	Enable Studio Access to API Services ticked, same as any DataStore.

	It deliberately keeps its own save, separate from your PlayerData
	script, so the two can never overwrite each other. Icicles still come
	from leaderstats, which PlayerData keeps saving as it always did.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local WalrusConfig = require(ReplicatedStorage:WaitForChild("WalrusConfig"))

local store = DataStoreService:GetDataStore("WalrusCollection_v1")
local ATTEMPTS = 3

-- Saves we couldn't read. Never write over these - one outage would
-- otherwise take away walruses people had paid Icicles for.
local loadFailed = {}
local collection = {} -- player -> { Owned = {name = true}, Equipped = name }

-- ============================================================
--  SAVING
-- ============================================================

local function loadCollection(player)
	local key = "player_" .. player.UserId

	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)

		if ok then
			return true, result
		end

		warn("Walrus load attempt " .. attempt .. " failed for " .. player.Name .. ": " .. tostring(result))
		task.wait(attempt * 2)
	end

	return false, nil
end

local function saveCollection(player)
	if loadFailed[player] or not collection[player] then
		return
	end

	local key = "player_" .. player.UserId

	for attempt = 1, ATTEMPTS do
		local ok, err = pcall(function()
			store:SetAsync(key, collection[player])
		end)

		if ok then
			return
		end

		warn("Walrus save attempt " .. attempt .. " failed for " .. player.Name .. ": " .. tostring(err))
		task.wait(attempt * 2)
	end
end

-- ============================================================
--  EQUIPPING
-- ============================================================

local function equip(player, name)
	local data = collection[player]
	if not data or not data.Owned[name] then
		return false
	end

	data.Equipped = name

	-- The attribute is the source of truth other scripts read: BonkServer
	-- takes Power from it, and your WalrusEquipper can watch it to know
	-- which model to put on the character.
	player:SetAttribute("EquippedWalrus", name)

	-- Mirror onto the leaderboard if there's a column for it. Optional -
	-- nothing breaks if that column doesn't exist.
	local leaderstats = player:FindFirstChild("leaderstats")
	local equipped = leaderstats and leaderstats:FindFirstChild("Equipped")
	if equipped then
		equipped.Value = name
	end

	return true
end

-- ============================================================
--  JOINING
-- ============================================================

local function setupPlayer(player)
	local ok, saved = loadCollection(player)
	if not ok then
		loadFailed[player] = true
	end

	if not player.Parent then
		return -- left while loading
	end

	local data = saved or {}
	data.Owned = data.Owned or {}

	-- The starter is a gift on first join, and can never be lost after.
	data.Owned[WalrusConfig.Starter] = true

	collection[player] = data

	-- Equip what they had, or the starter if that walrus no longer exists.
	local wanted = data.Equipped
	if not (wanted and data.Owned[wanted] and WalrusConfig.Walruses[wanted]) then
		wanted = WalrusConfig.Starter
	end

	equip(player, wanted)
end

Players.PlayerAdded:Connect(setupPlayer)

Players.PlayerRemoving:Connect(function(player)
	saveCollection(player)
	collection[player] = nil
	loadFailed[player] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupPlayer, player)
end

game:BindToClose(function()
	local pending = 0

	for _, player in ipairs(Players:GetPlayers()) do
		pending += 1
		task.spawn(function()
			saveCollection(player)
			pending -= 1
		end)
	end

	while pending > 0 do
		task.wait()
	end
end)

-- ============================================================
--  PODIUMS
-- ============================================================

-- A short message floating over the podium. Server-made, so everyone can
-- see it - fine in a small game, and far simpler than a client script.
local function announce(podium, message, color)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 260, 0, 50)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, podium.Size.Y / 2 + 6, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = podium

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = message
	label.TextColor3 = color
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	Debris:AddItem(billboard, 2)
end

local function onPodiumClicked(podium, name, player)
	local stats = WalrusConfig.Walruses[name]
	if not stats then
		warn(("Podium %s wants walrus %q, which isn't in WalrusConfig."):format(podium:GetFullName(), name))
		return
	end

	local data = collection[player]
	if not data then
		return -- still loading their collection
	end

	-- Already theirs: just wear it.
	if data.Owned[name] then
		if data.Equipped == name then
			announce(podium, "Already equipped", Color3.fromRGB(200, 200, 210))
		else
			equip(player, name)
			announce(podium, "Equipped " .. name .. "!", Color3.fromRGB(120, 230, 120))
		end
		return
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	local icicles = leaderstats and leaderstats:FindFirstChild("Icicles")
	if not icicles then
		return
	end

	if icicles.Value < stats.Cost then
		local short = stats.Cost - icicles.Value
		announce(podium, "Need " .. short .. " more Icicles", Color3.fromRGB(255, 110, 110))
		return
	end

	-- Take the money and hand over the walrus. Both happen here, together,
	-- so there's no window where they've paid and don't own it.
	icicles.Value -= stats.Cost
	data.Owned[name] = true
	equip(player, name)

	announce(podium, "Bought " .. name .. "!", Color3.fromRGB(120, 230, 120))

	-- Write it away now rather than waiting for them to leave. A server
	-- crash after a purchase shouldn't cost them the Icicles AND the walrus.
	task.spawn(saveCollection, player)
end

local function wirePodium(podium)
	local name = podium:GetAttribute("WalrusName")
	if not name then
		return
	end

	-- Reuse a ClickDetector you already put there, rather than adding a
	-- second one that fights it.
	local detector = podium:FindFirstChildOfClass("ClickDetector")
	if not detector then
		detector = Instance.new("ClickDetector")
		detector.MaxActivationDistance = 32
		detector.Parent = podium
	end

	detector.MouseClick:Connect(function(player)
		onPodiumClicked(podium, podium:GetAttribute("WalrusName"), player)
	end)
end

for _, item in ipairs(workspace:GetDescendants()) do
	if item:IsA("BasePart") then
		wirePodium(item)
	end
end

-- Podiums you add later, or that stream in, still get wired up.
workspace.DescendantAdded:Connect(function(item)
	if item:IsA("BasePart") then
		task.defer(wirePodium, item) -- let its attributes arrive first
	end
end)
