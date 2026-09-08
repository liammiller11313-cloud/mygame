--!nonstrict
--[[
	CodeService — redeems codes, and refuses them for a reason.

	── EVERY DECISION IS HERE, NONE OF IT IS IN THE CLIENT ──────────────────────
	CodeConfig is a shared module, so a player can read the code strings straight
	out of the client, and that is fine — it is how every game with codes works.
	The value was never in the string being unguessable. It is in the WINDOW and
	the one-per-account rule, and both of those live on this side of the wire
	where a client cannot reach them.

	So the client sends a string and draws an answer. It never decides whether a
	code is live, never checks whether it was used, and never grants anything.

	── THE CLOCK IS THE SERVER'S ────────────────────────────────────────────────
	`os.time()` here, never a timestamp from the client, and never
	`Workspace:GetServerTimeNow()` — that one counts from when the SERVER started
	and answers a different question entirely. A window is an absolute moment in
	the world; os.time is the only clock that agrees with the one the launch was
	announced in.

	── A CODE BOX IS A BRUTE-FORCE TARGET ───────────────────────────────────────
	Not a serious one here — the codes are readable anyway — but the shape is
	worth getting right, because the next code might be a private one handed to
	a creator. So: a floor between attempts per player, and a short lockout after
	a run of wrong guesses. Both silent. Telling somebody they are being rate
	limited is telling them their guessing is worth continuing more carefully.

	── PAY ONCE, AND MARK BEFORE PAYING ─────────────────────────────────────────
	markRedeemed is what makes a redemption exclusive, so it is called BEFORE any
	reward is handed over and its answer is taken as permission. Two clients
	racing the same code — a double-click, a reconnect mid-redeem — both reach
	the check; only one gets `true` back, and the loser pays nothing. The other
	order pays twice and finds out afterwards.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CodeConfig = require(Shared.Config.CodeConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local CodeService = {}

local ATTEMPT_THROTTLE = 1.0 -- seconds between tries, per player
local WRONG_LIMIT = 6 -- consecutive misses before a cooldown
local WRONG_COOLDOWN = 30

-- The longest code is fourteen characters. See onRedeem.
local MAX_CODE_LENGTH = 64

--[[ Reasons, as the strings the panel prints. Kept here rather than on the
     client because the server is the only thing that knows which one is true,
     and a client inventing its own copy is a client that can drift from it. ]]
local REASON = table.freeze({
	Ok = "REDEEMED",
	Unknown = "THAT CODE DOES NOT EXIST",
	Early = "THAT CODE IS NOT ACTIVE YET",
	Expired = "THAT CODE HAS EXPIRED",
	Used = "YOU HAVE ALREADY USED THAT CODE",
	Empty = "ENTER A CODE",
	Busy = "SLOW DOWN",
	Failed = "COULD NOT REDEEM — TRY AGAIN",
})

type Attempts = { readyAt: number, wrong: number, lockedUntil: number }
local attempts = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: Attempts }

local serviceTrove = Trove.new()

local function attemptsFor(player: Player): Attempts
	local entry = attempts[player]
	if not entry then
		entry = { readyAt = 0, wrong = 0, lockedUntil = 0 }
		attempts[player] = entry
	end
	return entry
end

local function answer(player: Player, ok: boolean, reason: string, granted: string?)
	Remotes.Event.CodeResult:FireClient(player, {
		ok = ok,
		reason = reason,
		granted = granted or "",
	})
end

--[[ Hands over one reward. Returns what was given, in words, for the client to
     print — built by CodeConfig.describe from the same table this reads, so the
     confirmation cannot describe something that was not granted. ]]
local function pay(player: Player, reward: any): string
	local profiles: any = Registry.find("ProfileService")
	if not profiles then
		return ""
	end

	if reward.passes then
		for _, passId in reward.passes do
			profiles:grantPass(player, passId)
		end
	end
	if reward.dollars and reward.dollars > 0 then
		profiles:addDollars(player, reward.dollars)
	end
	if reward.scrip and reward.scrip > 0 and typeof(profiles.addScrip) == "function" then
		profiles:addScrip(player, reward.scrip)
	end
	if reward.xp and reward.xp > 0 and typeof(profiles.addXp) == "function" then
		profiles:addXp(player, reward.xp)
	end

	--[[ One more sync after everything has landed. grantPass and addDollars each
	     publish on their own, but the pass grant changes what LoadoutConfig will
	     accept — so the last word has to be a profile the client can trust,
	     rather than whichever of the two happened to fire last. ]]
	if typeof(profiles.sync) == "function" then
		profiles:sync(player)
	end
	return CodeConfig.describe(reward)
end

local function onRedeem(player: Player, raw: any)
	local entry = attemptsFor(player)
	local now = os.clock()

	if now < entry.lockedUntil or now < entry.readyAt then
		answer(player, false, REASON.Busy)
		return
	end
	entry.readyAt = now + ATTEMPT_THROTTLE

	--[[ Length-checked before normalise rather than after. normalise uppercases
	     and rewrites the whole string, and doing that to a megabyte a client
	     chose to send is work this server agreed to for no reason. The client
	     refuses these too; that refusal is a courtesy, and this one is the
	     rule. ]]
	if typeof(raw) == "string" and #raw > MAX_CODE_LENGTH then
		answer(player, false, REASON.Unknown)
		return
	end

	local key = CodeConfig.normalise(raw)
	if key == "" then
		answer(player, false, REASON.Empty)
		return
	end

	local code = CodeConfig.get(key)
	if not code then
		entry.wrong += 1
		if entry.wrong >= WRONG_LIMIT then
			entry.wrong = 0
			entry.lockedUntil = now + WRONG_COOLDOWN
		end
		answer(player, false, REASON.Unknown)
		return
	end
	entry.wrong = 0

	--[[ os.time, not os.clock. The throttle above measures a duration and clock
	     is right for that; a window is a moment in the world and only os.time
	     knows what moment it is. ]]
	local stamp = os.time()
	if code.startsAt > 0 and stamp < code.startsAt then
		answer(player, false, REASON.Early)
		return
	end
	if code.endsAt > 0 and stamp > code.endsAt then
		answer(player, false, REASON.Expired)
		return
	end

	local profiles: any = Registry.find("ProfileService")
	if not profiles or not profiles:isReady(player) then
		answer(player, false, REASON.Failed)
		return
	end
	if profiles:hasRedeemed(player, key) then
		answer(player, false, REASON.Used)
		return
	end

	--[[ Marked first, and its answer is the permission. A second request racing
	     this one gets false here and pays nothing; paying first and marking
	     after pays twice. ]]
	if not profiles:markRedeemed(player, key) then
		answer(player, false, REASON.Used)
		return
	end

	answer(player, true, REASON.Ok, pay(player, code.reward))
end

function CodeService:init()
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		attempts[player] = nil
	end)
end

function CodeService:start()
	serviceTrove:connect(Remotes.Event.RedeemCode.OnServerEvent, onRedeem)

	--[[ Said once at boot, in words, because the window is two unreadable
	     integers and the failure mode is nobody noticing they are wrong until
	     the event is over. os.date("!*t") formats UTC, which is what they are. ]]
	for _, code in CodeConfig.Codes do
		local window = if code.startsAt > 0 and code.endsAt > 0
			then string.format(
				"%s -> %s UTC",
				os.date("!%Y-%m-%d %H:%M", code.startsAt),
				os.date("!%Y-%m-%d %H:%M", code.endsAt)
			)
			else "always live"
		print(
			string.format(
				"[CodeService] %s  %s  (%s)  reward: %s",
				code.code,
				window,
				if CodeConfig.isLive(code, os.time()) then "LIVE NOW" else "not live",
				CodeConfig.describe(code.reward)
			)
		)
	end
end

function CodeService:destroy()
	serviceTrove:destroy()
end

Registry.register("CodeService", CodeService)

return CodeService
