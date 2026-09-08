--!strict
--[[
	PogoServer — Script, inside any pogo tool. Decides whether a launch happened.

	── THE BUG THIS REPLACES ────────────────────────────────────────────────────
	The original never ran at all. Its first line was

	    local re = tool:WaitForChild("PogoRequest")

	and no tool in the pack contained a PogoRequest. WaitForChild with no timeout
	yields forever, so the script stopped on line two and its OnServerEvent was
	never connected. Meanwhile PogoClient did the velocity write itself and never
	fired a request, so BOTH ends of the server path were disconnected and the
	only pogo actually running was an unvalidated LocalScript.

	This creates the remote rather than waiting for one, so the wiring cannot be
	half-missing again.

	── AND THE ONE THAT WOULD HAVE BITTEN ───────────────────────────────────────
	Had it been wired, it took the client's HIT POSITION on trust. canPogo asked
	only whether that point was 2 to 50 studs from the player and whether a
	cooldown had passed. It never asked whether the player fired, whether the
	tool was equipped, or whether there was any geometry there at all — so a
	client sending a point two studs beneath itself every 0.25s flew, with no
	weapon involved.

	The remote now carries a DIRECTION. The server casts it against its own copy
	of the world from the character's own root, and the launch comes from what
	the SERVER hit. There is nothing useful left to lie about.

	── WHAT THIS DOES NOT PRETEND TO DO ─────────────────────────────────────────
	It does not stop a determined exploiter from flying. It cannot: a player owns
	their own HumanoidRootPart, so they can write their own velocity whenever
	they like and no server script can take that away. What it stops is this
	tool being the thing that HANDS OUT the launch — which is the part that is
	actually ours to fix, and the part an ordinary cheat menu looks for first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PogoCore = require(ReplicatedStorage:WaitForChild("PogoCore"))

local tool = script.Parent
local profile = PogoCore.profileFor(tool)

local request = tool:FindFirstChild("PogoRequest")
if not request or not request:IsA("RemoteEvent") then
	request = Instance.new("RemoteEvent")
	request.Name = "PogoRequest"
	request.Parent = tool
end
local remote = request :: RemoteEvent

--[[ The verdict goes back so the client can stop predicting a chain the server
     never granted. Without it the two stack counts drift apart and the player
     watches their boost shrink for no visible reason. ]]
local verdict = tool:FindFirstChild("PogoVerdict")
if not verdict or not verdict:IsA("RemoteEvent") then
	verdict = Instance.new("RemoteEvent")
	verdict.Name = "PogoVerdict"
	verdict.Parent = tool
end
local answer = verdict :: RemoteEvent

--[[ A refused request is a launch the client already predicted, so leaving it
     alone would let anybody keep every boost simply by asking for one that
     could never be granted. Clamping upward velocity to about a jump undoes it
     without needing a history of where they were. It only ever fires on a
     refusal, so ordinary physics — an explosion, a conveyor, a fall — is never
     touched by it. ]]
local REFUSAL_CLAMP = 60

type Entry = { readyAt: number, stacks: number, lastAt: number }
local state: { [Player]: Entry } = {}

local function entryFor(player: Player): Entry
	local e = state[player]
	if not e then
		e = { readyAt = 0, stacks = 0, lastAt = 0 }
		state[player] = e
	end
	return e
end

local function partsOf(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?,
		character:FindFirstChildOfClass("Humanoid")
end

local function refuse(player: Player, root: BasePart?)
	if root then
		local v = root.AssemblyLinearVelocity
		if v.Y > REFUSAL_CLAMP then
			root.AssemblyLinearVelocity = Vector3.new(v.X, REFUSAL_CLAMP, v.Z)
		end
	end
	answer:FireClient(player, false, 0)
end

remote.OnServerEvent:Connect(function(player: Player, direction: any)
	local root, humanoid = partsOf(player)
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end

	--[[ Equipped by THIS player, checked against the character rather than
	     trusting that the sender is the holder. The rocket launcher's own fire
	     path got this wrong in the opposite direction — it read Tool.Parent and
	     never looked at who sent the packet, so anybody could fire anybody's
	     launcher. One check, stated once, at the top. ]]
	if tool.Parent ~= player.Character then
		return
	end

	if not PogoCore.validDirection(direction) then
		return
	end

	local now = os.clock()
	local entry = entryFor(player)
	if now < entry.readyAt then
		return -- silently; a held trigger is not worth answering
	end

	-- The server's own raycast, from the server's own root position.
	local hit = PogoCore.cast(root, direction :: Vector3, profile, PogoCore.ServerSlack)
	if not hit or not PogoCore.hitIsLegal(root, hit, profile, PogoCore.ServerSlack) then
		refuse(player, root)
		return
	end

	-- A chain that went quiet starts again at one.
	if profile.stackTimeout > 0 and now - entry.lastAt > profile.stackTimeout then
		entry.stacks = 0
	end
	entry.stacks = math.clamp(entry.stacks + 1, 1, profile.maxStacks)
	entry.lastAt = now
	entry.readyAt = now + profile.cooldown

	local power = PogoCore.boostFor(entry.stacks, profile)
	local launch = PogoCore.launchDirection(root, hit, profile)
	PogoCore.apply(root, humanoid, launch, power, profile)

	answer:FireClient(player, true, entry.stacks)
end)

Players.PlayerRemoving:Connect(function(player)
	state[player] = nil
end)
