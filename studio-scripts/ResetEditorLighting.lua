--[[
	ResetEditorLighting — paste into the Roblox Studio COMMAND BAR, press Enter.

	Puts Lighting back to the bright, flat, midday setup that the project file
	uses for EDITING.

	You need this because "Run" mode (unlike "Play") leaves whatever the game set
	behind when you stop, so a playtest that ended during wave 7 leaves you trying
	to build a map at midnight in fog. Play mode reverts on its own and does not
	need this.

	It changes nothing about how the game looks when it runs: AtmosphereService
	drives the whole dusk-to-night ramp at runtime and overwrites all of this on
	the first frame of a round.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Lighting = game:GetService("Lighting")

local recording = ChangeHistoryService:TryBeginRecording("ResetEditorLighting")

Lighting.Ambient = Color3.fromRGB(120, 120, 125)
Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 185)
Lighting.Brightness = 3
Lighting.ClockTime = 13.5
Lighting.ExposureCompensation = 0
Lighting.EnvironmentDiffuseScale = 1
Lighting.EnvironmentSpecularScale = 1
Lighting.GlobalShadows = true
Lighting.FogColor = Color3.fromRGB(200, 205, 214)
Lighting.FogStart = 50000
Lighting.FogEnd = 100000

-- The game creates these at runtime and they are what actually darkens the
-- world; neutralising them is most of what makes the editor usable again.
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
if atmosphere then
	atmosphere.Density = 0
	atmosphere.Haze = 0
	atmosphere.Glare = 0
end

local grade = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
if grade then
	grade.Brightness = 0
	grade.Contrast = 0
	grade.Saturation = 0
	grade.TintColor = Color3.new(1, 1, 1)
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

print("[ResetEditorLighting] editor lighting restored — the game still runs dark at runtime.")
