--!nonstrict
--[[
	WhichClips — what will each infected model actually animate with?

	Paste into the Roblox Studio COMMAND BAR and press Enter. It CHANGES NOTHING.

	── WHAT IT IS FOR ──────────────────────────────────────────────────────────
	Every body resolves each animation role from one of two places, and which one
	is invisible from Studio:

	  1. a clip the MODEL carries — from an Animate script it shipped with, or an
	     FL_Animations folder
	  2. the game's own set in AnimationConfig

	Both are correct. But a folder of thirty-five Commons where some carry clips
	and some do not looks, in play, exactly like the built-in set being applied
	at random — and "some of them animate wrong" is impossible to act on without
	knowing which, and for which role.

	This prints the answer per model and per role, using the SAME name matching
	the game uses. Paste the output back and it says everything needed:
	which models carry clips, which roles they cover, which ones fall through,
	and which clips are named something the game does not recognise.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

--[[ Kept identical to InfectedAnimator.ROLE_FALLBACK. Every name here is an
     ALIAS for that role under a different spelling, never a different role
     borrowed to fill a gap — filling a role stops AnimationConfig filling it,
     so a wrong-role clip locks out the right one. ]]
local ROLE_FALLBACK = {
	idle = { "idle", "stand", "zombieidle", "wait" },
	walk = { "walk", "walkanim", "zombie", "run" },
	run = { "run", "runanim", "sprint", "walk", "zombie" },
	attack = { "attack", "swipe", "slash", "toolslash", "punch" },
	death = { "death", "die", "dead" },
	jump = { "jump", "jumpanim" },
	fall = { "fall", "freefall", "falling" },
	climb = { "climb", "climbanim" },
}

--[[ The roles the game plays, in the order a person thinks about them rather
     than alphabetically: the two you see constantly, then the rest. ]]
local ROLE_ORDER = { "idle", "walk", "run", "jump", "fall", "death", "attack", "climb" }

--[[ Which roles the built-in set covers per rig, so a role that falls through is
     reported as "falls back" rather than as missing. Mirrors
     AnimationConfig.ByRig; a role absent from both is the only real gap, and
     that body goes to the client's procedural poser. ]]
local BUILT_IN = {
	R6 = { idle = true, walk = true, run = true, jump = true, fall = true, climb = true, death = true },
	R15 = {
		idle = true,
		walk = true,
		run = true,
		attack = true,
		jump = true,
		fall = true,
		climb = true,
		death = true,
	},
}

local function rigTypeOf(model)
	--[[ Shallow, like RigUtil.rigTypeOf: a recursive search finds an UpperTorso
	     inside an accessory and calls a hand-built R6 zombie an R15 one. ]]
	return if model:FindFirstChild("UpperTorso") then "R15" else "R6"
end

--[[ Every clip the model carries, as bucket name -> id, by the same rule the
     game's harvester uses: an Animation whose PARENT is named for the role. ]]
local function bucketsOf(model)
	local buckets, count = {}, 0
	for _, d in model:GetDescendants() do
		if not d:IsA("Animation") or d.AnimationId == "" then
			continue
		end
		local parent = d.Parent
		local name = if parent and parent ~= model then string.lower(parent.Name) else "idle"
		if not buckets[name] then
			buckets[name] = d.AnimationId
			count += 1
		end
	end
	return buckets, count
end

local function infectedFolders()
	local found = {}
	for _, root in { ReplicatedStorage, ServerStorage } do
		local assets = root:FindFirstChild("Assets")
		local infected = assets and assets:FindFirstChild("Infected")
		if infected then
			table.insert(found, infected)
		end
	end
	return found
end

print(
	"── WhichClips ────────────────────────────────────────────────────────"
)

local scanned, carrying = 0, 0
local unmatched = {}

for _, infected in infectedFolders() do
	for _, kindFolder in infected:GetChildren() do
		local models = {}
		if kindFolder:IsA("Model") then
			table.insert(models, kindFolder)
		else
			for _, child in kindFolder:GetChildren() do
				if child:IsA("Model") then
					table.insert(models, child)
				end
			end
		end

		for _, model in models do
			scanned += 1
			local rig = rigTypeOf(model)
			local buckets, count = bucketsOf(model)
			local builtIn = BUILT_IN[rig] or {}

			--[[ Resolve every role the way the game will: the rig's own aliases
			     first, then the built-in set for whatever is left. ]]
			local own, fallback, missing = {}, {}, {}
			local usedBuckets = {}
			for _, role in ROLE_ORDER do
				local from = nil
				for _, alias in ROLE_FALLBACK[role] or {} do
					if buckets[alias] then
						from = alias
						usedBuckets[alias] = true
						break
					end
				end
				if from then
					table.insert(own, if from == role then role else string.format("%s(as %s)", role, from))
				elseif builtIn[role] then
					table.insert(fallback, role)
				else
					table.insert(missing, role)
				end
			end

			if count > 0 then
				carrying += 1
			end

			--[[ A clip the model carries that no role wanted. This is where a
			     misnamed bucket shows up — "Walk1" or "ZombieMove" is a clip the
			     author meant to be used and the game will never look at. ]]
			local ignored = {}
			for name in buckets do
				if not usedBuckets[name] then
					table.insert(ignored, name)
					unmatched[name] = (unmatched[name] or 0) + 1
				end
			end
			table.sort(ignored)

			local label = string.format("%s/%s", kindFolder.Name, model.Name)
			print(string.format("  %-26s %-4s %d clip(s)", label, rig, count))
			if #own > 0 then
				print(string.format("      its own : %s", table.concat(own, ", ")))
			end
			if #fallback > 0 then
				print(string.format("      built-in: %s", table.concat(fallback, ", ")))
			end
			if #missing > 0 then
				print(string.format("      NOTHING : %s  (procedural poser)", table.concat(missing, ", ")))
			end
			if #ignored > 0 then
				print(
					string.format("      IGNORED : %s  (no role has this name)", table.concat(ignored, ", "))
				)
			end
		end
	end
end

print(
	"──────────────────────────────────────────────────────────────────────"
)
if scanned == 0 then
	print("Found no models under Assets.Infected.")
else
	print(
		string.format(
			"%d model(s): %d carry clips of their own, %d use the built-in set entirely.",
			scanned,
			carrying,
			scanned - carrying
		)
	)
end

local names = {}
for name, n in unmatched do
	table.insert(names, string.format("%s (x%d)", name, n))
end
if #names > 0 then
	table.sort(names)
	print("")
	print("Clip folders no role matches — rename these and the game will use them:")
	print("  " .. table.concat(names, ", "))
	print("  Roles: " .. table.concat(ROLE_ORDER, ", "))
end
