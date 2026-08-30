--!strict
--[[
	Remotes — the single declarative network contract.

	Every RemoteEvent and RemoteFunction in the game is declared in the manifest
	below and nowhere else. The server builds the instances on first require; the
	client waits for them. Nothing anywhere should call Instance.new for a remote
	or WaitForChild a remote path by hand.

		local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
		Remotes.Event.SwingTool:FireServer(payload)
		Remotes.Event.PlayerKilled.OnClientEvent:Connect(fn)

	Naming convention: remotes are named for the FACT they carry, from the point
	of view of the sender. "SwingTool" is a client asking; "ToolSwung" is the
	server telling everyone it happened. Keep that tense discipline — it makes
	direction obvious at every call site.

	Continuously-changing numbers do NOT go through remotes. They are Instance
	attributes, declared in Shared/Net/Attributes.lua, because Roblox replicates
	those automatically and cheaply. Remotes are for discrete events only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "BrickbattleNet"
local IS_SERVER = RunService:IsServer()
local WAIT_TIMEOUT = 20

-- Every RemoteEvent in the game, grouped by direction for human readability.
-- (The grouping is documentation only; they all land in one flat namespace.)
local EVENTS: { string } = {
	-- ── Client → Server: player intent ──────────────────────────────────────
	"SwingTool", -- {origin: Vector3, direction: Vector3, clientTime: number}
	"LungeTool", -- () — the sword's double-click
	"ThrowTool", -- {origin: Vector3, direction: Vector3, charge: number}
	"FireTool", -- {origin: Vector3, direction: Vector3, seed: number, clientTime: number}
	"BuildBlock", -- {origin: Vector3, direction: Vector3} — the trowel
	"CastMapVote", -- (mapName: string)
	"ClickForTix", -- () — rate limited server-side; see DECISIONS.md Q8
	"RequestPurchase", -- (itemId: string)
	"SetSetting", -- (key: string, value: any) — validated on arrival

	-- ── Server → Client: combat feedback ────────────────────────────────────
	"ToolSwung", -- {player, weaponId, origin, direction} — for OTHER players
	"HitConfirmed", -- {damage, killed, position} — hitmarker fuel, sender only
	"DamageTaken", -- {amount, sourcePosition, damageType} — vignette + arrow
	"PlayerKilled", -- {victim, killer?, weaponId, damageType} — feed + popup
	"ExplosionEffect", -- {position, radius, weaponId}
	"ImpactEffect", -- {position, normal, material, damageType}

	-- ── Server → Client: state & presentation ───────────────────────────────
	"PhaseChanged", -- {phase, endsAt, mapName?} — every clock derives from this
	"RoundEnded", -- {winner, reason, scoreboard}
	"MapVoteOpened", -- {options: {string}, endsAt: number}
	"MapVoteTallied", -- {tally: {[string]: number}}
	"TixAwarded", -- {amount, source} — drives the floating +N
	"LevelChanged", -- {level, experience, required}
	"PurchaseResult", -- {itemId, ok, reason?}
	"SystemMessage", -- {text, kind}
	"CameraImpulse", -- {position: Vector3, decay: number}
}

-- RemoteFunctions. Kept deliberately few: every one of these is a client
-- blocking on the server, and a server that yields inside one stalls the caller
-- with no timeout of its own.
local FUNCTIONS: { string } = {
	"GetProfileSnapshot", -- () -> {tix, level, experience, owned, upgrades}
	"GetShopCatalogue", -- () -> {{itemId, price, owned}}
}

local Remotes = {
	Event = {} :: { [string]: RemoteEvent },
	Function = {} :: { [string]: RemoteFunction },
}

local function buildOnServer(): Folder
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		created.Parent = ReplicatedStorage
		folder = created
	end

	for _, remoteName in EVENTS do
		local existing = folder:FindFirstChild(remoteName)
		if not existing then
			local remote = Instance.new("RemoteEvent")
			remote.Name = remoteName
			remote.Parent = folder
			existing = remote
		end
		Remotes.Event[remoteName] = existing :: RemoteEvent
	end

	for _, remoteName in FUNCTIONS do
		local existing = folder:FindFirstChild(remoteName)
		if not existing then
			local remote = Instance.new("RemoteFunction")
			remote.Name = remoteName
			remote.Parent = folder
			existing = remote
		end
		Remotes.Function[remoteName] = existing :: RemoteFunction
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

	for _, remoteName in EVENTS do
		local remote = folder:WaitForChild(remoteName, WAIT_TIMEOUT)
		if not remote then
			error(
				string.format(
					"[Remotes] missing RemoteEvent %q — client/server manifests disagree",
					remoteName
				)
			)
		end
		Remotes.Event[remoteName] = remote :: RemoteEvent
	end

	for _, remoteName in FUNCTIONS do
		local remote = folder:WaitForChild(remoteName, WAIT_TIMEOUT)
		if not remote then
			error(string.format("[Remotes] missing RemoteFunction %q — manifests disagree", remoteName))
		end
		Remotes.Function[remoteName] = remote :: RemoteFunction
	end
end

if IS_SERVER then
	buildOnServer()
else
	buildOnClient()
end

--[[
	Fires an event at every client except one. Used constantly: the actor already
	played their own swing locally, so re-sending it to them doubles the effect
	and feels mushy.
]]
function Remotes.fireAllExcept(eventName: string, exclude: Player, ...: any)
	assert(IS_SERVER, "Remotes.fireAllExcept is server-only")
	local remote = Remotes.Event[eventName]
	assert(remote, string.format("unknown remote event %q", eventName))
	for _, player in Players:GetPlayers() do
		if player ~= exclude then
			remote:FireClient(player, ...)
		end
	end
end

--[[
	Fires an event at every client whose character is within `radius` of a point.
	Impacts and explosions use this so a firefight across the map does not cost
	every client bandwidth and particle budget for effects they cannot see.

	Compares squared distances rather than magnitudes: this runs per explosion
	per player, and a square root per comparison buys nothing.
]]
function Remotes.fireInRange(eventName: string, position: Vector3, radius: number, ...: any)
	assert(IS_SERVER, "Remotes.fireInRange is server-only")
	local remote = Remotes.Event[eventName]
	assert(remote, string.format("unknown remote event %q", eventName))
	local radiusSquared = radius * radius
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local offset = root.Position - position
			-- Vector3:Dot(self) is the squared magnitude with no sqrt.
			if offset:Dot(offset) <= radiusSquared then
				remote:FireClient(player, ...)
			end
		end
	end
end

return Remotes
