--!nonstrict
--[[
	WeaponPreview — a weapon, in 3D, turning slowly, inside a rectangle of UI.

	The shop and the loadout screen both need one, and it is fiddly enough that
	two copies would diverge within a week. Everything about making a
	ViewportFrame look like it was meant is in here.

	── HOW A VIEWPORT ACTUALLY WORKS ────────────────────────────────────────────
	A ViewportFrame renders its own little world with its own Camera and no
	connection to Lighting, Workspace, or anything else. That means:

	  * a model inside it is invisible until a Camera is assigned to
	    ViewportFrame.CurrentCamera AND that camera is a CHILD of the frame. Both.
	    Assigning a camera that lives elsewhere renders nothing and reports no
	    error, which is the single most common way this is got wrong;
	  * there is no light in there. `LightColor` and `Ambient` on the frame are
	    the whole lighting model, so a model that looks right in the world reads
	    as a black silhouette until they are set;
	  * a WorldModel child is needed for anything that expects to be in a world.
	    Without one the parts render but nothing is simulated — which is what we
	    want here — but with one, `Model:GetBoundingBox` and pivots behave the way
	    they do everywhere else, which is worth the instance.

	── FRAMING ──────────────────────────────────────────────────────────────────
	The camera distance is DERIVED from the model's bounding box and the camera's
	FOV rather than tuned per weapon. A Machete and an M1A EBR differ by a factor
	of four in length, and any fixed distance is either a machete lost in the
	middle of the frame or a rifle with its barrel out of shot.

	── COST ─────────────────────────────────────────────────────────────────────
	A ViewportFrame is a second render pass, so there is exactly one of these per
	screen and it is emptied the moment the screen closes. The turn runs off the
	frame loop only while something is in it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local COLOR = UITheme.Color

--[[ Where the user's models live, and where PlaceholderFactory publishes a
     prepared one when the user has not supplied a reachable copy. See `park`
     in that file. ]]
local ASSETS_FOLDER = "Assets"
local WEAPONS_FOLDER = "Weapons"

--[[ How long to wait for the assets folder at boot. The server builds it during
     its own start-up, so a client that boots first would otherwise decide there
     are no models a fraction of a second before there are. ]]
local ASSET_WAIT = 10

local FIELD_OF_VIEW = 28

--[[ How much room to leave around the weapon, as a multiple of what would
     exactly fill the frame. Above 1 or the longest weapon touches both edges. ]]
local FRAMING_MARGIN = 1.35

--[[ Looking slightly down and from the front-left. Straight on makes every gun
     a rectangle; this is the three-quarter view a catalogue photograph uses,
     and it is what makes a stock and a magazine readable at a glance. ]]
local PITCH = math.rad(14)
local YAW_START = math.rad(-28)

local TURN_SPEED = math.rad(22) -- degrees a second, and it is slow on purpose

local WeaponPreview = {}
WeaponPreview.__index = WeaponPreview

export type Preview = typeof(setmetatable(
	{} :: {
		frame: ViewportFrame,
		world: WorldModel,
		camera: Camera,
		model: Model?,
		radius: number,
		yaw: number,
		connection: RBXScriptConnection?,
	},
	WeaponPreview
))

-- ── finding a model ─────────────────────────────────────────────────────────

local assetsFolder: Folder? = nil

local function weaponsFolder(): Folder?
	if assetsFolder and assetsFolder.Parent then
		return assetsFolder
	end
	local assets = ReplicatedStorage:FindFirstChild(ASSETS_FOLDER)
	local folder = assets and assets:FindFirstChild(WEAPONS_FOLDER)
	assetsFolder = if folder and folder:IsA("Folder") then folder else nil
	return assetsFolder
end

--[[
	The model for a weapon id, or nil.

	The same name order PlaceholderFactory and ViewmodelController use, and for
	the same reason: the real models are called "(71 Mag) PPSh-41" and "Mk 18
	CQBR", which are neither our enum key nor its display name. `modelName` is
	the artist's own name and the only key guaranteed to match it; the id is what
	a published grey-box is parked under.

	A Folder of variants resolves to its first Model, which is how the infected
	rigs are supplied and costs nothing to support here.
]]
local function findTemplate(weaponId: string): Model?
	local folder = weaponsFolder()
	if not folder then
		return nil
	end
	local definition = WeaponConfig.get(weaponId)

	local names = { weaponId }
	if definition then
		table.insert(names, 1, definition.modelName)
		table.insert(names, definition.displayName)
	end

	for _, name in names do
		local entry = if typeof(name) == "string" then folder:FindFirstChild(name) else nil
		if entry then
			if entry:IsA("Model") then
				return entry
			end
			if entry:IsA("Folder") then
				local first = entry:FindFirstChildWhichIsA("Model")
				if first then
					return first
				end
			end
		end
	end
	return nil
end

--[[ Makes a cloned template safe to sit in a viewport: nothing scripted,
     nothing simulated, nothing that can reach out of the frame. A viewport does
     not run physics, but a supplied model routinely arrives with a Script and a
     ProximityPrompt attached and neither belongs in a shop window. ]]
local STRIPPED =
	{ "LuaSourceContainer", "BodyMover", "ProximityPrompt", "ClickDetector", "Sound", "Fire", "Smoke" }

local function tame(model: Model)
	for _, descendant in model:GetDescendants() do
		for _, className in STRIPPED do
			if descendant:IsA(className) then
				descendant:Destroy()
				break
			end
		end
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
		end
	end
end

-- ── the preview ─────────────────────────────────────────────────────────────

--[[
	Builds an empty preview inside `parent`.

	The frame is returned unsized and unpositioned: where a preview sits is the
	screen's business, and the two screens that use this put it in different
	places.
]]
function WeaponPreview.new(parent: Instance, name: string?): Preview
	local frame = Instance.new("ViewportFrame")
	frame.Name = name or "Preview"
	frame.BackgroundColor3 = COLOR.Background
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	--[[ The whole lighting model. A viewport has no connection to Lighting, so
	     without these a weapon renders as a black silhouette — which reads as a
	     model that failed to load rather than as a lighting mistake. ]]
	frame.LightColor = Color3.fromRGB(255, 246, 232)
	frame.LightDirection = Vector3.new(-0.4, -1, -0.6)
	frame.Ambient = Color3.fromRGB(96, 92, 88)
	frame.Parent = parent

	local world = Instance.new("WorldModel")
	world.Parent = frame

	--[[ A CHILD of the frame, and assigned to CurrentCamera. Both are required
	     and neither errors when it is missing — a viewport with a camera that
	     lives anywhere else renders nothing at all, silently. ]]
	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = frame
	frame.CurrentCamera = camera

	return setmetatable({
		frame = frame,
		world = world,
		camera = camera,
		model = nil,
		radius = 1,
		yaw = YAW_START,
		connection = nil,
	}, WeaponPreview)
end

--[[ Points the camera at the model from `self.yaw`, at a distance that frames
     whatever size it turned out to be. Called every frame while turning. ]]
function WeaponPreview.aim(self: Preview)
	if not self.model then
		return
	end

	--[[ Derived from the box and the FOV rather than tuned: a Machete and an M1A
	     EBR differ by a factor of four in length, and any fixed distance loses
	     one of them. ]]
	local distance = (self.radius * FRAMING_MARGIN) / math.tan(math.rad(FIELD_OF_VIEW) * 0.5)
	--[[ The origin, because setWeapon put the model's bounding box there. Orbiting
	     a fixed point rather than tracking the model means the framing cannot
	     drift as the yaw comes round. ]]
	local direction = CFrame.fromEulerAnglesYXZ(-PITCH, self.yaw, 0).LookVector
	self.camera.CFrame = CFrame.lookAt(-direction * distance, Vector3.zero)
end

--[[
	Puts a weapon in the frame, or empties it.

	Passing nil, or an id with no model anywhere, leaves the viewport empty
	rather than erroring — the shop draws a placeholder line over the top for
	that case, because "no model yet" is a real and expected state for every
	coming-soon entry in the catalogue.

	Returns whether anything is now on show.
]]
function WeaponPreview.setWeapon(self: Preview, weaponId: string?): boolean
	if self.model then
		self.model:Destroy()
		self.model = nil
	end

	local template = if typeof(weaponId) == "string" then findTemplate(weaponId) else nil
	if not template then
		self:setTurning(false)
		return false
	end

	local model = template:Clone()
	tame(model)
	model.Parent = self.world

	--[[
		Centred on the origin, so the camera has something predictable to look at.

		The BOUNDING BOX centre, not the pivot: a template is parked wherever it
		was built, and its pivot is its PrimaryPart — which on a weapon is the
		grip, at one end of it. Pivoting the grip to the origin and then orbiting
		the origin would swing the whole gun around its handle and put the barrel
		out of frame for half of every turn.

		Expressed as the rigid transform that takes the box centre to the origin,
		applied to the pivot — the same shape as holding a weapon by its grip in
		CarryVisualService, for the same reason.
	]]
	local box, size = model:GetBoundingBox()
	model:PivotTo(box:Inverse() * model:GetPivot())

	self.model = model
	self.radius = math.max(size.Magnitude * 0.5, 0.5)
	self.yaw = YAW_START
	self:aim()
	self:setTurning(true)
	return true
end

--[[ Starts or stops the slow turn. Off while the screen is closed: a viewport
     is a second render pass and there is no reason to pay for one nobody is
     looking at. ]]
function WeaponPreview.setTurning(self: Preview, turning: boolean)
	if turning and self.model then
		if not self.connection then
			self.connection = RunService.RenderStepped:Connect(function(dt: number)
				self.yaw += TURN_SPEED * dt
				self:aim()
			end)
		end
	elseif self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
end

--[[ Whether a model exists for this weapon at all, without building one. The
     shop asks before it draws, so a coming-soon entry can say so rather than
     showing an empty box. ]]
function WeaponPreview.hasModel(weaponId: string): boolean
	return typeof(weaponId) == "string" and findTemplate(weaponId) ~= nil
end

function WeaponPreview.destroy(self: Preview)
	self:setTurning(false)
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
	self.frame:Destroy()
end

--[[
	Warms the reference to ReplicatedStorage.Assets.Weapons, in the background.

	The server populates that folder during its own start-up, so the first client
	into a fresh server can easily beat it and would otherwise resolve nothing —
	`weaponsFolder` caches only a folder it actually found, so a later lookup
	still succeeds, but the first shop opened would show empty boxes.

	It MUST NOT yield the caller. The client bootstrap runs every controller's
	start() sequentially in one loop, so a WaitForChild here would hold up every
	controller after it — including MainMenuController, whose start() is what
	puts the menu on screen. Two of these, at ten seconds each, is a twenty-second
	black screen if the folder never appears.
]]
function WeaponPreview.awaitAssets()
	task.spawn(function()
		local assets = ReplicatedStorage:WaitForChild(ASSETS_FOLDER, ASSET_WAIT)
		if assets then
			assets:WaitForChild(WEAPONS_FOLDER, ASSET_WAIT)
		end
		weaponsFolder()
	end)
end

return WeaponPreview
