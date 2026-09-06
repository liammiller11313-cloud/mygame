--[[
	EquipPad
	--------
	WHERE THIS GOES:  inside a Part in the Workspace
	WHAT KIND:        Script   (NOT a LocalScript)

	Makes the Part clickable, labels it, and sets whoever clicks it to the
	ability named below.

	To add more pads: copy the Part (Ctrl+D) and change the one line below.
	The name must match a key in the ABILITIES table in AbilityServer.
]]

local part = script.Parent

-- >>> THE ONE LINE YOU CHANGE PER PAD <<<
local ABILITY_NAME = "Basic"

-- Remembered once, so two players clicking together can't leave the pad
-- stuck on its flash colour.
local baseColor = part.Color

-- ============================================================
--  THE FLOATING LABEL
--  Without this, three identical grey pads are a guessing game.
-- ============================================================

local billboard = Instance.new("BillboardGui")
billboard.Name = "PadLabel"
billboard.Size = UDim2.new(0, 220, 0, 50)
billboard.StudsOffsetWorldSpace = Vector3.new(0, part.Size.Y / 2 + 2, 0)
billboard.AlwaysOnTop = true
billboard.MaxDistance = 80 -- stops distant pads cluttering the screen
billboard.Parent = part

local text = Instance.new("TextLabel")
text.Size = UDim2.fromScale(1, 1)
text.BackgroundTransparency = 1
text.Text = string.upper(ABILITY_NAME)
text.TextColor3 = Color3.fromRGB(255, 255, 255)
text.TextStrokeTransparency = 0 -- a black outline, so it reads over any map
text.TextScaled = true
text.Font = Enum.Font.GothamBold
text.Parent = billboard

-- ============================================================
--  THE CLICK
-- ============================================================

-- Adding this in code means you never insert a ClickDetector by hand.
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
