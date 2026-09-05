--[[
	EquipPad
	--------
	WHERE THIS GOES:  inside a Part in the Workspace
	WHAT KIND:        Script   (NOT a LocalScript)

	Makes the Part clickable. Clicking it sets that player's Equipped
	column on the leaderboard to the ability named below.

	To add more abilities later: copy the Part (Ctrl+D) and change the
	one line below to "Tusk Charge", "Blubber Shield", whatever you want.
]]

local part = script.Parent

-- >>> THE ONE LINE YOU CHANGE PER PAD <<<
local ABILITY_NAME = "Basic"

-- Remembered once, so two players clicking at the same time can't
-- leave the pad stuck on its flash colour.
local baseColor = part.Color

-- Adding this in code means you never have to insert a ClickDetector by hand.
local clickDetector = Instance.new("ClickDetector")
clickDetector.MaxActivationDistance = 32 -- how close you must stand, in studs
clickDetector.Parent = part

clickDetector.MouseClick:Connect(function(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end

	local equipped = leaderstats:FindFirstChild("Equipped")
	if not equipped then
		return
	end

	equipped.Value = ABILITY_NAME

	-- A quick green flash, so the click obviously landed.
	part.Color = Color3.fromRGB(120, 220, 120)
	task.wait(0.15)
	part.Color = baseColor
end)
