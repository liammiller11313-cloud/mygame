--!nonstrict
--[[
	AnimationCache — one Animation instance per asset id, kept alive, preloaded.

	Written because animations were loading intermittently, and the two reasons
	were both in the same four lines everywhere they were loaded:

		local animation = Instance.new("Animation")
		animation.AnimationId = "rbxassetid://" .. id
		local track = animator:LoadAnimation(animation)
		animation:Destroy()          -- <- here

	── WHY DESTROYING IT BREAKS THINGS ──────────────────────────────────────────
	`LoadAnimation` returns a track immediately, but the KeyframeSequence behind
	it is fetched ASYNCHRONOUSLY, and the track resolves that fetch through the
	Animation instance it was given. Destroy the instance and the track is left
	pointing at nothing: if the asset was already in the content cache it works,
	and if it was not it silently never plays. That is precisely the "sometimes"
	in "sometimes my animations do not load" — it depends on whether that id
	happened to have been fetched already, which depends on what spawned first.

	Roblox's own Animate script keeps its Animation objects parented for the
	life of the character for the same reason.

	So: one instance per id, created once, parented into a folder, and never
	destroyed. Sixteen instances for the whole game.

	── WHY PRELOADING MATTERS TOO ───────────────────────────────────────────────
	Even with the instance kept, a track whose asset has not arrived plays
	nothing — it reports IsPlaying, its Length is zero, and the body does not
	move. Forty-six zombies spawning in the first ten seconds of a fresh server
	all hit that. `preload` fetches every declared id once, up front, so the
	first horde animates like the tenth.

	── AND WHY A BAD ID USED TO BE SILENT ───────────────────────────────────────
	`LoadAnimation` does not throw for an id that does not exist, is private, or
	belongs to another account — it returns a perfectly ordinary track that never
	plays. Every caller wrapping it in pcall was therefore always taking the
	success branch. PreloadAsync's callback reports the real status, so a broken
	id is now named in the log with the reason it is broken.

	Roblox will only play an animation owned by the place's creator or by Roblox
	itself. An id uploaded under a personal account, in a game owned by a group,
	fails exactly this way.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local FOLDER_NAME = "FL_AnimationCache"

local AnimationCache = {}

local folder: Folder? = nil
--[[ A strong Lua reference as well as a parent. Both matter: the parent is what
     makes the cache inspectable in Studio, and the table is what guarantees the
     instance outlives any garbage collection pass. ]]
local instances: { [string]: Animation } = {}

--[[ What preloading said about each id. Absent means "not asked yet", which is
     not the same as "failed" — a lazily-loaded id is fine until proven otherwise
     and must not be reported as broken. ]]
local status: { [string]: boolean } = {}
local requested: { [string]: boolean } = {}

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[AnimationCache] " .. message)
end

local function container(): Folder
	if folder and folder.Parent then
		return folder :: Folder
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	--[[ ServerStorage on the server so nothing is replicated for no reader; the
	     client keeps its own copy in ReplicatedStorage, where a local write is
	     legal and stays local. Each side caches independently, which is correct:
	     an Animation instance is a handle, not shared state. ]]
	created.Parent = if RunService:IsServer() then ServerStorage else ReplicatedStorage
	folder = created
	return created
end

--[[ An id in the form Roblox wants, from a number or a string in any of the
     three spellings people write. Accepting all of them is not politeness — a
     config full of bare numbers and a config full of "rbxassetid://" strings
     are both things this codebase has had. ]]
local function contentId(id: number | string): string?
	if typeof(id) == "number" then
		if id ~= id or id <= 0 then
			return nil
		end
		return "rbxassetid://" .. string.format("%d", id)
	end
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	local digits = string.match(id, "(%d+)$")
	return if digits then "rbxassetid://" .. digits else nil
end

--[[
	The one Animation instance for this id.

	Created on first ask and kept forever. Returns nil only for an id that is not
	an id at all — a nil, a zero, a string with no number in it — which is a
	config mistake rather than a load failure and is worth telling apart from
	one.
]]
function AnimationCache.get(id: number | string): Animation?
	local key = contentId(id)
	if not key then
		return nil
	end

	local existing = instances[key]
	if existing then
		return existing
	end

	local animation = Instance.new("Animation")
	animation.Name = string.match(key, "%d+$") or "Animation"
	animation.AnimationId = key
	animation.Parent = container()
	instances[key] = animation

	--[[ Warmed the first time anybody asks, so nothing has to remember to. The
	     explicit `preload` below is still worth calling at start-up — this one
	     only helps the SECOND user of an id — but it means an id added later and
	     forgotten still ends up cached. ]]
	AnimationCache.preload({ id })
	return animation
end

--[[
	Fetches these ids so a track made from them can actually play.

	Runs in the background: PreloadAsync yields, sometimes for seconds on a cold
	server, and nothing that loads an animation should be made to wait for it.
	The track works the moment the asset lands, which is what the whole cache is
	for.

	Idempotent per id, so calling it from every spawn costs one table lookup
	after the first.
]]
function AnimationCache.preload(ids: { number | string })
	local pending: { Animation } = {}
	for _, id in ids do
		local key = contentId(id)
		if key and not requested[key] then
			requested[key] = true
			local animation = AnimationCache.get(id)
			if animation then
				table.insert(pending, animation)
			end
		end
	end
	if #pending == 0 then
		return
	end

	task.spawn(function()
		--[[ The callback form reports per-asset status, which is the only way to
		     tell an id that failed from one that merely has not arrived. Wrapped
		     because PreloadAsync throws on a malformed content string, and a
		     malformed one in a config should not take a spawn path down. ]]
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(pending, function(contentString: string, fetchStatus: any)
				local succeeded = fetchStatus == Enum.AssetFetchStatus.Success
				status[contentString] = succeeded
				if not succeeded then
					warnOnce(
						"failed:" .. contentString,
						string.format(
							"%s could not be fetched (%s). Roblox only plays animations owned by "
								.. "this place's creator or by Roblox itself — an id uploaded under a "
								.. "personal account will fail here in a group-owned game. Nothing "
								.. "using this id will animate.",
							contentString,
							tostring(fetchStatus)
						)
					)
				end
			end)
		end)
		if not ok then
			warnOnce("preload", string.format("PreloadAsync failed: %s", tostring(err)))
		end
	end)
end

--[[ Whether an id is known to be unusable. False for an id that simply has not
     been checked yet, so a caller can report a definite failure without
     inventing one. ]]
function AnimationCache.hasFailed(id: number | string): boolean
	local key = contentId(id)
	return key ~= nil and status[key] == false
end

--[[
	Ids proven to be EMPTY UPLOADS — published before any keyframes were saved.

	This cannot be answered from a fetch status, because such a clip fetches
	perfectly well. It is only visible on a real AnimationTrack, whose Length
	stays zero, so the answer arrives from whoever loaded one and is remembered
	here for every later caller. Server-wide and permanent: an empty asset does
	not fill in later.
]]
local emptyIds: { [string]: boolean } = {}

--[[
	Reports what a real track measured, so the next caller does not have to.

	The zero is only believed once the fetch is known to have SUCCEEDED. Length
	is also zero for a clip whose asset has not landed, and treating those the
	same would condemn healthy clips during exactly the seconds when everything
	is loading at once. A non-zero length always clears the flag — proof beats
	any earlier guess.
]]
function AnimationCache.noteLength(id: number | string, length: number)
	local key = contentId(id)
	if not key then
		return
	end
	if length > 0 then
		emptyIds[key] = nil
	elseif status[key] == true then
		emptyIds[key] = true
	end
end

--[[ Whether an id is known to be an empty upload. False for one nobody has
     measured yet, so a caller can act on a fact rather than on a suspicion. ]]
function AnimationCache.isEmpty(id: number | string): boolean
	local key = contentId(id)
	return key ~= nil and emptyIds[key] == true
end

--[[
	Whether an id is known to have ARRIVED. The positive counterpart to hasFailed,
	and false for an id that has simply not been asked about yet.

	Both are needed because there are three states, not two — succeeded, failed,
	and not yet known — and the third one is the reason a naive length test is
	dangerous. An AnimationTrack's Length is 0 both for an empty upload and for a
	clip whose asset has not landed, and those want opposite treatment: throw the
	first away, wait for the second. Asking "did the fetch succeed AND is the
	length still zero" separates them; asking about length alone destroys healthy
	tracks during the first seconds of a server, which is exactly when a horde is
	arriving.
]]
function AnimationCache.isLoaded(id: number | string): boolean
	local key = contentId(id)
	return key ~= nil and status[key] == true
end

--[[
	Loads a track from an id, keeping the instance alive.

	The whole reason this module exists, as one call: every previous caller wrote
	the create-load-destroy sequence by hand and every one of them had the bug.
	Returns nil when the id is unusable or the Animator refuses it.
]]
function AnimationCache.load(animator: Animator, id: number | string): AnimationTrack?
	local animation = AnimationCache.get(id)
	if not animation or typeof(animator) ~= "Instance" then
		return nil
	end
	local ok, track = pcall(animator.LoadAnimation, animator, animation)
	if not ok or not track then
		return nil
	end
	return track
end

return AnimationCache
