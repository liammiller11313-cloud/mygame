--[[
	WalrusLeaderboard
	-----------------
	WHERE THIS GOES:  ServerScriptService
	WHAT KIND:        Script   (NOT a LocalScript)

	Builds the leaderboard every player sees when they press Tab.
	Each value inside the "leaderstats" folder becomes one column.
]]

local Players = game:GetService("Players")

-- What the Equipped column says before anyone clicks anything.
local STARTING_ABILITY = "None"

local function setupPlayer(player)
	-- On a busy server this can be reached twice for the same person: once
	-- from PlayerAdded and once from the catch-up loop at the bottom.
	-- Without this they'd end up with two leaderstats folders.
	if player:FindFirstChild("leaderstats") then
		return
	end

	-- Roblox only builds a leaderboard from a folder named exactly "leaderstats".
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	-- StringValue = a column that holds words. This is your Equipped category.
	local equipped = Instance.new("StringValue")
	equipped.Name = "Equipped"
	equipped.Value = STARTING_ABILITY
	equipped.Parent = leaderstats

	-- IntValue = a column that holds whole numbers. AbilityServer adds to this.
	local kills = Instance.new("IntValue")
	kills.Name = "Kills"
	kills.Value = 0
	kills.Parent = leaderstats

	-- Parent the folder last, so both columns show up together.
	leaderstats.Parent = player
end

Players.PlayerAdded:Connect(setupPlayer)

-- Catches anyone already in the game when this script starts.
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end
