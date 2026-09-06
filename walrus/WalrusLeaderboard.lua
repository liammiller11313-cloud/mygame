--[[
	WalrusLeaderboard
	-----------------
	WHERE THIS GOES:  ServerScriptService
	WHAT KIND:        Script   (NOT a LocalScript)

	Builds the leaderboard, and remembers what each player had equipped so
	it's still there when they come back.

	SAVING WILL NOT WORK until you have done BOTH of these:
	  1. Publish the place    (File > Publish to Roblox)
	  2. Tick Game Settings > Security > Enable Studio Access to API Services

	Without them every save throws a 403 in the Output window and nothing
	persists. This trips up everyone the first time.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

-- Bump the name (v1 -> v2) if you ever want to wipe everyone's save and
-- start clean. The old data stays behind untouched, so it's reversible.
local store = DataStoreService:GetDataStore("WalrusSave_v1")

local STARTING_ABILITY = "None"
local ATTEMPTS = 3 -- how many times to retry before giving up

-- Players whose save we couldn't read. We must never write over these:
-- one Roblox outage would otherwise reset everybody who joined during it.
local loadFailed = {}

-- Setting up yields, so this marks who we've already started on. Without
-- it, two folders could be built for the same person.
local setupStarted = {}

local function loadData(player)
	local key = "player_" .. player.UserId

	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)

		if ok then
			return true, result -- result is nil for someone brand new
		end

		warn("Load attempt " .. attempt .. " failed for " .. player.Name .. ": " .. tostring(result))
		task.wait(attempt * 2) -- back off a little before trying again
	end

	return false, nil
end

local function saveData(player)
	-- The whole point of tracking this: don't overwrite data we couldn't read.
	if loadFailed[player] then
		return
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	local equipped = leaderstats and leaderstats:FindFirstChild("Equipped")
	if not equipped then
		return
	end

	-- A table rather than a bare string, so adding a second thing to save
	-- later won't break the saves written today.
	local data = { Equipped = equipped.Value }
	local key = "player_" .. player.UserId

	for attempt = 1, ATTEMPTS do
		local ok, err = pcall(function()
			store:SetAsync(key, data)
		end)

		if ok then
			return
		end

		warn("Save attempt " .. attempt .. " failed for " .. player.Name .. ": " .. tostring(err))
		task.wait(attempt * 2)
	end
end

local function setupPlayer(player)
	if setupStarted[player] then
		return
	end
	setupStarted[player] = true

	-- This yields for as long as the DataStore takes to answer.
	local ok, data = loadData(player)
	if not ok then
		loadFailed[player] = true
	end

	if not player.Parent then
		return -- they left while we were loading
	end

	-- Roblox only builds a leaderboard from a folder named exactly "leaderstats".
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	-- StringValue = a column that holds words. This is your Equipped category.
	local equipped = Instance.new("StringValue")
	equipped.Name = "Equipped"
	equipped.Value = (data and data.Equipped) or STARTING_ABILITY
	equipped.Parent = leaderstats

	-- Kills is this round's score rather than a lifetime total, so it
	-- deliberately isn't saved. Add it to `data` above if you want it to be.
	local kills = Instance.new("IntValue")
	kills.Name = "Kills"
	kills.Value = 0
	kills.Parent = leaderstats

	-- Parent the folder last, so both columns show up together.
	leaderstats.Parent = player
end

Players.PlayerAdded:Connect(setupPlayer)

Players.PlayerRemoving:Connect(function(player)
	saveData(player) -- save first, then forget them
	loadFailed[player] = nil
	setupStarted[player] = nil
end)

-- Catches anyone already in the game when this script starts. Spawned,
-- because setupPlayer now waits on the DataStore.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupPlayer, player)
end

-- PlayerRemoving doesn't reliably fire when the whole server is shutting
-- down, so catch everyone still here on the way out.
game:BindToClose(function()
	local pending = 0

	for _, player in ipairs(Players:GetPlayers()) do
		pending += 1
		task.spawn(function()
			saveData(player)
			pending -= 1
		end)
	end

	-- Hold the server open until the last save comes back.
	while pending > 0 do
		task.wait()
	end
end)
