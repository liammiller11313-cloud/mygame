--!strict
--[[
	Fading Light — the viewport scale layer.

	Every pixel offset in this interface was chosen against a 900px-tall
	viewport, which is a desktop window. On a phone those offsets are a wall of
	type covering the play space; on a 4K display they are a postage stamp in
	the corner. Roblox spans both, so neither is hypothetical.

	The fix is one layer. A full-screen Frame carries a UIScale, and the frame is
	sized to 1/factor so that after the scale multiplies it back up it covers the
	viewport exactly. Inside it:
	  - scale-based positions still resolve against the whole screen, so a panel
	    pinned to the bottom-right corner stays in the corner;
	  - offset-based sizes and paddings scale with the display, so a 54px hotbar
	    slot is 54 reference pixels rather than 54 hardware pixels.

	A controller parents its content into the returned Frame instead of into its
	ScreenGui and is resolution-independent for one line. Because everything
	inside stays in reference space, two layers agree on where things are without
	either knowing the factor — which is what lets WaveController hand
	HudController a pixel inset and have it land in the right place on a phone.

	The camera is replaced on death, on spectate and on rejoin, so the viewport
	connection is re-pointed on every camera change rather than accumulating one
	per camera. There is exactly one connection for the whole client no matter
	how many layers exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = {}

type Entry = { frame: Frame, scale: UIScale }

local layers: { Entry } = {}
local viewportConnection: RBXScriptConnection? = nil
local cameraConnection: RBXScriptConnection? = nil

local function currentHeight(): number
	local camera = Workspace.CurrentCamera
	return if camera then camera.ViewportSize.Y else 0
end

--[[ Walked backwards so a layer whose ScreenGui has been destroyed can be
     dropped in place. Writing to a destroyed instance throws, and a controller
     that rebuilds its interface would otherwise leave a corpse in this list
     that breaks every resize from then on. ]]
local function apply()
	local factor = UITheme.scaleFor(currentHeight())
	local inverse = UDim2.fromScale(1 / factor, 1 / factor)

	for index = #layers, 1, -1 do
		local entry = layers[index]
		if entry.frame.Parent == nil then
			table.remove(layers, index)
		else
			entry.scale.Scale = factor
			entry.frame.Size = inverse
		end
	end
end

local function watchViewport()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
	end
	apply()
end

--[[
	A scaled, full-screen content layer inside `parent` (normally a ScreenGui).

	Parent everything the controller draws into the returned Frame. It is
	transparent and does not clip, so it is invisible to everything except the
	layout.
]]
function ScaleLayer.new(parent: Instance, name: string?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name or "Layer"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = parent

	local scale = Instance.new("UIScale")
	scale.Parent = frame

	table.insert(layers, { frame = frame, scale = scale })

	if not cameraConnection then
		cameraConnection = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)
	end
	watchViewport()

	return frame
end

--[[ The factor layers are being drawn at right now. Anything that measures the
     screen in real pixels and then has to talk in layer coordinates — a hit
     test against a mouse position, a tween expressed in screen distance — has
     to divide by this first. ]]
function ScaleLayer.getFactor(): number
	return UITheme.scaleFor(currentHeight())
end

return ScaleLayer
