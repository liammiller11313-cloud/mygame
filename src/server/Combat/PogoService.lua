--!nonstrict
--[[
	PogoService — the pack's movement tech, on this game's terms.

	Shooting a surface with a pogo weapon throws you off it. WeaponConfig's
	PogoProfile holds the feel; this holds the rules.

	── NO REMOTE, AND THAT IS THE WHOLE DESIGN ──────────────────────────────────
	The standalone pack needs its own RemoteEvent because a classic Tool has no
	server-side shot to hang off: the client says "I aimed there", and the
	server's only defence is to re-cast the ray itself and hope the two agree.
	Half the work in the pack's own PogoServer was that defence.

	None of it is needed here. BallisticsService has already validated the
	shooter, checked the claimed origin against their actual head, generated the
	cone from a seed both sides share, and cast the pellets itself — so by the
	time this is called the launch point is not a claim, it is where the
	SERVER's own raycast landed. There is nothing left to lie about and nothing
	to re-check. A pogo is a consequence of a shot that already happened.

	That also means an exploiter cannot pogo without firing: no shot, no call.
	The rate limit is the weapon's rate of fire and the ammunition in it, which
	are already the server's.

	── ONCE PER SHOT, NOT ONCE PER PELLET ───────────────────────────────────────
	Called from outside the pellet loop, unlike the blast hook next to it, and
	the difference matters: a shotgun-shaped pogo weapon would otherwise launch
	its user once for every pellet in the volley. Nothing in the roster is one
	today. The alternative reads as though it could not be.

	── THE CAP IS LOAD-BEARING ──────────────────────────────────────────────────
	See PogoProfile's own header. Unbounded flight does not merely let somebody
	leave a level, it makes LevelService:getFlowDistance project them onto a
	meaningless point on the flow polyline, and SpawnPlacement then aims the
	Director's horde window at nothing — which breaks the round for everyone
	else on the server, not just the one who flew.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

local PogoService = {}

--[[ Weak-keyed: a player who leaves mid-chain must not hold their own record
     alive, and a chain is worthless the moment they stop existing. ]]
type Chain = { stacks: number, lastAt: number, profile: any }
local chains = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: Chain }

--[[ How long the server keeps hold of a launched player's physics. See seize. ]]
local OWNERSHIP_HOLD = 0.5

local owning = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: number }

local serviceTrove = Trove.new()

--[[
	Takes the launched player's physics off their own machine, briefly.

	A velocity written by the server to a part the client owns is not reliably
	the velocity that happens: the client keeps simulating from its own state and
	replicates back over the top. That is the bug the Tongue's drag shipped with,
	and the Charger's carry says so in its own words — "Nothing the server does
	to a character's velocity or CFrame survives otherwise."

	An impulse survives that better than the Tongue's per-frame position writes
	did, which is exactly why it is tempting to skip this. It is still a coin
	flip under latency, and a pogo that silently does nothing one time in five is
	worse than one that costs half a second of server simulation every time.

	Half a second rather than the 0.8 the bosses use for a throw: the launch is
	instantaneous and everything after it is ordinary falling, which the client
	should be simulating itself.

	Tokened, because chaining pogos is the point. Without it a second launch
	inside the window would be handed back by the FIRST one's timer, mid-flight.
]]
local function seize(player: Player, root: BasePart)
	owning[player] = (owning[player] or 0) + 1
	local mine = owning[player]

	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	task.delay(OWNERSHIP_HOLD, function()
		if owning[player] ~= mine or not root.Parent then
			return
		end
		--[[ Auto rather than back to the player by name: they may have died,
		     respawned or left in the last half second, and Roblox is better
		     placed to answer that than this module guessing. ]]
		pcall(function()
			root:SetNetworkOwnershipAuto()
		end)
	end)
end

--[[
	Throws `player` off the point their shot landed on.

	Returns false when nothing happened, which the caller ignores — the return
	is for reading in a test, not for branching. Every refusal is silent by
	design: a pogo that did not trigger is a shot that simply did not launch
	you, and telling somebody why would mean drawing UI for a mechanic whose
	whole appeal is that it is felt rather than read.
]]
function PogoService:launch(player: Player, profile: any, landedAt: Vector3, hitSomething: boolean): boolean
	if typeof(profile) ~= "table" or typeof(landedAt) ~= "Vector3" then
		return false
	end

	--[[ Nothing was hit. No fabricated point below the shooter, which is the
	     bug the standalone pack shipped for years — its third fallback invented
	     ground ten studs down whenever the raycast missed, so a shot at open sky
	     launched exactly as well as one at a floor. A miss is a miss. ]]
	if not hitSomething then
		return false
	end

	local character = player.Character
	if not character then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return false
	end

	--[[
		A survivor who is down, pinned or hanging does not get to pogo out of it.
		Being unable to act is the entire threat of a pin, and a weapon that
		answered one would be worth more than a teammate.

		Asked through getState rather than an isUpright helper — there is no such
		method, and the first version of this guard called one anyway. Written as
		`typeof(fn) == "function" and not fn(...)`, a missing method makes the
		whole condition false, so the guard did not merely fail to protect: it
		waved every pinned player straight through, silently, in the one shape
		that looks like it is being careful.
	]]
	local survivors: any = Registry.find("SurvivorService")
	if survivors and typeof(survivors.getState) == "function" then
		local state = survivors:getState(player)
		if state ~= Enums.SurvivorState.Healthy and state ~= Enums.SurvivorState.Hurt then
			return false
		end
	end

	local delta = landedAt - root.Position
	local distance = delta.Magnitude
	if distance < 0.05 or distance > profile.maxRange then
		return false
	end
	--[[ A stomp has to land below you. The rocket sets this to zero and takes
	     any angle, which is what makes shooting the wall behind you a move. ]]
	if profile.minDrop > 0 and delta.Y > -profile.minDrop then
		return false
	end

	-- ── the chain ────────────────────────────────────────────────────────────
	local now = os.clock()
	local chain = chains[player]
	--[[ Reset on a different weapon as well as on a quiet window. The chain is
	     per player rather than per weapon, so without this a rocket jump would
	     hand its stack to the slingshot drawn straight after it — a stack the
	     player did not earn on the weapon that spends it. ]]
	local stale = chain ~= nil
		and (chain.profile ~= profile or (profile.window > 0 and now - chain.lastAt > profile.window))
	if not chain or stale then
		chain = { stacks = 0, lastAt = now, profile = profile }
		chains[player] = chain
	end
	chain.stacks = math.clamp(chain.stacks + 1, 1, math.max(profile.maxStacks, 1))
	chain.lastAt = now

	local power = profile.power + (chain.stacks - 1) * profile.stack

	-- ── which way ────────────────────────────────────────────────────────────
	local direction = Vector3.yAxis
	if profile.directional then
		local away = root.Position - landedAt
		if away.Magnitude > 0.05 then
			local unit = away.Unit
			local flat = Vector3.new(unit.X, 0, unit.Z)
			flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zero
			--[[ The pack's own numbers, and its reasoning with them: horizontal at
			     0.85 so the shove reads without throwing you across the street,
			     vertical clamped at zero so a shot from above never drives you
			     into the floor, and a flat quarter of up on top so every rocket
			     jump gets off the ground. ]]
			local up = math.max(unit.Y, 0) + 0.25
			local built = Vector3.new(flat.X * 0.85, up, flat.Z * 0.85)
			direction = if built.Magnitude > 0.05 then built.Unit else Vector3.yAxis
		end
	end

	--[[ math.max(v.Y, 0) is the line the whole mechanic rests on: it throws away
	     downward velocity before adding the boost, so a pogo caught on the way
	     down launches exactly as hard as one from standing. Without it a chain
	     fights its own fall and dies out.

	     The Jumping state comes first because a grounded Humanoid applies
	     standing friction that eats a velocity write in the same frame. ]]
	seize(player, root)
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	local velocity = root.AssemblyLinearVelocity
	local launch = direction * power
	root.AssemblyLinearVelocity = Vector3.new(
		velocity.X + launch.X,
		math.min(math.max(velocity.Y, 0) + launch.Y, profile.maxUpSpeed),
		velocity.Z + launch.Z
	)
	return true
end

function PogoService:init()
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		chains[player] = nil
		owning[player] = nil
	end)
end

function PogoService:destroy()
	serviceTrove:destroy()
end

Registry.register("PogoService", PogoService)

return PogoService
