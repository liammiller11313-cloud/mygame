--!nonstrict
--[[
	SoundCheck — did that cue actually arrive?

	The same job UI/ImageCheck does for pictures, for the largest asset bank in
	the game. Sixty-eight ids in AudioConfig, and until this existed not one of
	them was ever checked against anything: AudioService warns when a row is
	EMPTY, which is a different question entirely — "did somebody paste an id"
	rather than "does the id resolve".

	── WHY AUDIO NEEDS ITS OWN, WHEN THE ENGINE ALREADY COMPLAINS ──────────────
	A Sound whose id cannot be fetched does produce an engine line, which an
	ImageLabel does not. That line is worth exactly nothing to whoever has to fix
	it: it names a bare number rather than the cue, it is not visible to script,
	and it appears only in the console of the player it failed for.

	That last part is the whole reason this file exists. Audio is licensed per
	place, so an id that is moderated, private, or uploaded under an account that
	does not own this experience fails PER CLIENT — it plays perfectly in Studio
	for whoever uploaded it and is silent for everybody else. The developer is
	the one person structurally guaranteed not to see it.

	── AND SILENCE IS A LEGITIMATE ANSWER HERE ─────────────────────────────────
	Which is what makes it worse than the image case. AudioConfig deliberately
	ships rows with empty ids, and EventController guards on one — so a cue that
	goes quiet reads as a row nobody has filled in yet rather than as a failure.
	A missing picture looks broken; a missing sound looks unfinished, and nobody
	files a bug against unfinished.

	── IT ALSO WARMS THE BANK, WHICH IS NOT A SIDE EFFECT ──────────────────────
	PreloadAsync is what ContentProvider is for. Checking every cue at join means
	the first shotgun blast of the round is not the one that streams in late, and
	that is worth the round trip on its own.

	Runs once, on the client, at boot. Nothing here changes what is heard.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)

local SoundCheck = {}

local checked = false

--[[ Every cue that names this id, so a failure can say "the M4 shot" rather
     than a number. One sample is shared by several cues on purpose — the
     reload's three phases all ride GunReload — so this is a list. ]]
local function collect(): ({ [string]: { string } }, number)
	local names: { [string]: { string } } = {}
	local rows = 0

	local function note(id: any, label: string)
		if typeof(id) ~= "string" or id == "" then
			return -- a deliberate blank. See the header.
		end
		local list = names[id]
		if list then
			if not table.find(list, label) then
				table.insert(list, label)
			end
		else
			names[id] = { label }
		end
	end

	--[[ Walked from the CATEGORIES the mixer itself bills against rather than
	     from a list written here, so a bank added to AudioConfig is checked
	     without anybody remembering to add it. ]]
	for _, category in
		{ "WeaponFire", "WeaponReload", "Impact", "Gore", "Infected", "Survivor", "UI", "Event" }
	do
		local bank = (AudioConfig :: any)[category]
		if typeof(bank) == "table" then
			for key, definition in bank do
				if typeof(definition) == "table" then
					rows += 1
					local label = string.format("AudioConfig.%s.%s", category, tostring(key))
					note(definition.id, label)
					if typeof(definition.ids) == "table" then
						for _, id in definition.ids do
							note(id, label)
						end
					end
				end
			end
		end
	end

	return names, rows
end

--[[ Typos, caught without a network. Deliberately the same rules UI/ImageCheck
     applies — they are facts about a content string and not about what it
     points at — and the shape gate has to come first there for the same reason
     it does here: PreloadAsync THROWS on a malformed one. ]]
local function shapeProblem(id: string): string?
	if id ~= (string.gsub(id, "%s", "")) then
		return "it contains whitespace"
	end
	if string.match(id, "^https?://") then
		return "it is a URL. Use rbxassetid:// and the bare number"
	end
	if string.match(id, "^rbxasset://") then
		return "rbxasset:// addresses a file inside Studio, not an upload"
	end
	local digits = string.match(id, "^rbxassetid://(%d+)$")
	if not digits then
		if string.match(id, "^%d+$") then
			return "it is a bare number, with no rbxassetid:// prefix"
		end
		return "it is not an rbxassetid:// content id"
	end
	if tonumber(digits) == 0 then
		return "id 0 is not an asset. Use an empty string for a deliberate silence"
	end
	return nil
end

--[[ Checks the whole bank once. Safe to call again; it does nothing the second
     time, because the answer cannot change for the life of the client. ]]
function SoundCheck.run()
	if checked then
		return
	end
	checked = true

	local names, rows = collect()

	local pending: { string } = {}
	for id, labels in names do
		local problem = shapeProblem(id)
		if problem then
			warn(
				string.format(
					"[SoundCheck] %s will never play: %s (%s)",
					table.concat(labels, ", "),
					problem,
					id
				)
			)
		else
			table.insert(pending, id)
		end
	end

	if #pending == 0 then
		return
	end

	--[[ Spawned, and in ONE call. PreloadAsync yields until every id resolves or
	     gives up, and a bank this size on a cold join is several seconds — all
	     of it before the player would otherwise have heard anything. Handing it
	     the whole list lets Roblox pipeline the fetches instead of paying that
	     round trip sixty-eight times. ]]
	task.spawn(function()
		local failed = 0
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(pending, function(content: string, fetchStatus: any)
				if fetchStatus == Enum.AssetFetchStatus.Success then
					return
				end
				failed += 1
				local labels = names[content]
				warn(
					string.format(
						"[SoundCheck] %s could not be fetched (%s). Audio is licensed per PLACE: an "
							.. "id that is moderated, private, or uploaded under an account that does "
							.. "not own this experience is silent for every player and still plays in "
							.. "Studio for whoever uploaded it. (%s)",
						if labels then table.concat(labels, ", ") else "a cue",
						tostring(fetchStatus),
						content
					)
				)
			end)
		end)
		if not ok then
			warn(string.format("[SoundCheck] could not check the sound bank: %s", tostring(err)))
			return
		end
		if failed > 0 then
			warn(
				string.format(
					"[SoundCheck] %d of %d sound id(s) across %d cue(s) will not play on this client.",
					failed,
					#pending,
					rows
				)
			)
		end
	end)
end

function SoundCheck:init() end

function SoundCheck:start()
	SoundCheck.run()
end

Registry.register("SoundCheck", SoundCheck)

return SoundCheck
