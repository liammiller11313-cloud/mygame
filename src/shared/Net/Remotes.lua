--!strict
--[[
	Remotes — the single, declarative network contract for Fading Light.

	Every RemoteEvent and RemoteFunction in the game is declared in the MANIFEST
	below and nowhere else. The server builds the instances on first require; the
	client waits for them. Nothing anywhere should ever call Instance.new for a
	remote or WaitForChild a remote path by hand.

		local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
		Remotes.Event.FireWeapon:FireServer(payload)
		Remotes.Event.HitConfirmed.OnClientEvent:Connect(fn)

	Naming convention: remotes are named for the FACT they carry, from the point of
	view of the sender. "FireWeapon" is a client asking; "WeaponFired" is the server
	telling everyone it happened. Keep that tense discipline — it makes direction
	obvious at every call site.

	Continuously-changing numbers (health, ammo, temp health) do NOT go through
	remotes. They are Instance Attributes, declared in Shared/Net/Attributes.lua,
	because Roblox replicates those automatically and cheaply. Remotes are for
	discrete events only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "FadingLightNet"
local IS_SERVER = RunService:IsServer()
local WAIT_TIMEOUT = 20

-- Every RemoteEvent in the game, grouped by direction for human readability.
-- (The grouping is documentation only; all of them land in one flat namespace.)
local EVENTS: { string } = {
	-- ── Client → Server: player intent ──────────────────────────────────────
	"FireWeapon", -- {origin: Vector3, direction: Vector3, seed: number, clientTime: number}
	"ReloadWeapon", -- ()
	"SwitchSlot", -- (slot: string)
	"SwingMelee", -- {origin: Vector3, direction: Vector3, clientTime: number}
	"Shove", -- {origin: Vector3, direction: Vector3}   the L4D panic button
	"ThrowItem", -- {origin: Vector3, direction: Vector3, power: number}
	"UseItem", -- (slot: string)                        medkit / pills / adrenaline
	"BeginInteract", -- (targetRef: Instance)           revive, pickup, door, rescue
	"CancelInteract", -- ()
	"SetAimState", -- (isAiming: boolean)
	"PingLocation", -- {position: Vector3, kind: string}

	-- ── Server → Client: combat feedback ────────────────────────────────────
	"WeaponFired", -- {shooter, weaponId, origin, direction, seed} — for OTHER players
	"HitConfirmed", -- {region, damage, killed, isHeadshot, position} — hitmarker fuel
	"DamageTaken", -- {amount, sourcePosition, damageType} — vignette + direction arrow
	"GoreEvent", -- {model, level, part, direction, force}
	"ImpactEffect", -- {position, normal, material, damageType}
	"TracerEffect", -- {origin, endPosition, weaponId}

	-- ── Server → Client: state & presentation ───────────────────────────────
	"SurvivorStateChanged", -- {player, state, previousState}
	"InventoryChanged", -- {slot, itemId, ammo, reserve}
	"InteractPromptChanged", -- {visible, verb, subject, duration}
	"ScreenEffect", -- {effect: string, duration: number, intensity: number}
	"CameraImpulse", -- {position: Vector3, rotation: Vector3, decay: number}
	"DirectorEvent", -- {kind: string, payload: any} — horde/tank/music cues
	"Subtitle", -- {speaker: string, text: string, duration: number}
	"RoundStateChanged", -- {state, payload}
	"ObjectiveChanged", -- {text: string, progress: number?}
	"KillFeed", -- {killer: string, victim: string, weaponId: string, headshot: boolean}
	"StatsUpdated", -- {player, stats} — end-of-round tally
}

-- Every RemoteFunction. Keep this list SHORT: remote functions block and can be
-- exploited to yield the server. Use them only for initial state handshakes.
local FUNCTIONS: { string } = {
	"RequestInitialState", -- () -> {roundState, survivors, objective, config}
}

local Remotes = {}
Remotes.Event = {} :: { [string]: RemoteEvent }
Remotes.Function = {} :: { [string]: RemoteFunction }

local function buildOnServer(): Folder
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	assert(folder, "unreachable")

	for _, name in EVENTS do
		local existing = folder:FindFirstChild(name)
		if not existing then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
			existing = remote
		end
		Remotes.Event[name] = existing :: RemoteEvent
	end

	for _, name in FUNCTIONS do
		local existing = folder:FindFirstChild(name)
		if not existing then
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
			existing = remote
		end
		Remotes.Function[name] = existing :: RemoteFunction
	end

	return folder :: Folder
end

local function buildOnClient()
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
	if not folder then
		error(
			string.format(
				"[Remotes] ReplicatedStorage.%s never replicated after %ds. "
					.. "The server bootstrap (ServerScriptService.Server) did not run.",
				FOLDER_NAME,
				WAIT_TIMEOUT
			)
		)
	end

	for _, name in EVENTS do
		local remote = folder:WaitForChild(name, WAIT_TIMEOUT)
		if not remote then
			error(
				string.format("[Remotes] missing RemoteEvent %q — client/server manifests disagree", name)
			)
		end
		Remotes.Event[name] = remote :: RemoteEvent
	end

	for _, name in FUNCTIONS do
		local remote = folder:WaitForChild(name, WAIT_TIMEOUT)
		if not remote then
			error(string.format("[Remotes] missing RemoteFunction %q — manifests disagree", name))
		end
		Remotes.Function[name] = remote :: RemoteFunction
	end
end

if IS_SERVER then
	buildOnServer()
else
	buildOnClient()
end

--[[
	Fires an event at every client except one. Used constantly by the combat code:
	the shooter already played their own muzzle flash locally, so re-sending it to
	them would double up the effect and feel mushy.
]]
function Remotes.fireAllExcept(eventName: string, exclude: Player, ...: any)
	assert(IS_SERVER, "Remotes.fireAllExcept is server-only")
	local remote = Remotes.Event[eventName]
	assert(remote, string.format("unknown remote event %q", eventName))
	for _, player in game:GetService("Players"):GetPlayers() do
		if player ~= exclude then
			remote:FireClient(player, ...)
		end
	end
end

--[[
	Fires an event at every client whose character is within `radius` of a point.
	Gore, impacts and tracers use this so a firefight across the map does not cost
	every client bandwidth and particle budget for effects they cannot see.
]]
function Remotes.fireInRange(eventName: string, position: Vector3, radius: number, ...: any)
	assert(IS_SERVER, "Remotes.fireInRange is server-only")
	local remote = Remotes.Event[eventName]
	assert(remote, string.format("unknown remote event %q", eventName))
	local radiusSquared = radius * radius
	for _, player in game:GetService("Players"):GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - position).Magnitude ^ 2 <= radiusSquared then
			remote:FireClient(player, ...)
		end
	end
end

return Remotes
