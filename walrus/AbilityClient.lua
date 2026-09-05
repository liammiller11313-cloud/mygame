--[[
	AbilityClient
	-------------
	WHERE THIS GOES:  StarterPlayer > StarterPlayerScripts
	WHAT KIND:        LocalScript   (NOT a Script)

	Watches for the ability key and tells the server about it. That's all
	it does - no damage, no cooldown. Anything a cheater could lie about
	stays on the server.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Waits for AbilityServer to create this when the game starts.
local useAbility = ReplicatedStorage:WaitForChild("UseAbility")

local ACTION_NAME = "UseWalrusAbility"

local function onAction(_actionName, inputState, _inputObject)
	-- Begin = the moment the key goes down. Without this check it would
	-- also fire on the way back up.
	if inputState == Enum.UserInputState.Begin then
		useAbility:FireServer()
	end
end

-- One call covers all three: the E key, the right trigger on a gamepad, and
-- (because of the `true`) an on-screen button on phones and tablets.
ContextActionService:BindAction(ACTION_NAME, onAction, true, Enum.KeyCode.E, Enum.KeyCode.ButtonR2)
ContextActionService:SetTitle(ACTION_NAME, "ABILITY")
