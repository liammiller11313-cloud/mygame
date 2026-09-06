--!nonstrict
--[[
	ImageCheck — did that picture actually arrive?

	Every image in this game is an id typed into a config, and there is no way
	to be sure an id is right from anywhere but a client that has tried to fetch
	it. When one is wrong the ImageLabel simply draws nothing. Nothing throws,
	nothing logs, and what is left behind is almost always something that looks
	like a design decision: a black menu, a blank map card, a boot screen that
	holds on nothing. That is the worst way for anything to fail, because the
	person who could fix it never learns there is anything to fix.

	So: hand every image id in the game through here once, with a name for it.

	── THE ONE THAT KEEPS HAPPENING ────────────────────────────────────────────
	A DECAL ID WHERE AN IMAGE ID WAS WANTED.

	Uploading a picture to Roblox makes two things: the image, and a Decal that
	wraps it. The id shown on a Creator Store page, on an inventory tile, and in
	the toolbox is the DECAL's. An ImageLabel wants the image INSIDE it and
	draws nothing when handed the wrapper. Both ids are real, both belong to
	you, both are the same length, and no amount of staring at the config tells
	them apart. To get the right one: insert the decal in Studio and read the id
	off its Texture property.

	── AND THE ONE THAT IS WORSE ───────────────────────────────────────────────
	An asset that is private, still in moderation, or owned by an account that
	does not own this place, fails PER CLIENT. It loads perfectly in Studio for
	the person who uploaded it, and fails for everybody who plays the game. A
	check that only ever runs on the author's machine would never see it — this
	one runs for every player, which is the only place the truth is.

	── TWO CHECKS, DELIBERATELY ────────────────────────────────────────────────
	The SHAPE of the id is checked immediately and needs no network: an empty
	string, a bare number, the legacy `http://www.roblox.com/asset/?id=` form,
	stray whitespace, `rbxasset://` instead of `rbxassetid://`. These are typos
	and they are worth catching before a round trip.

	The FETCH is checked in the background. PreloadAsync's callback form is the
	only thing that distinguishes an id that failed from one that has merely not
	arrived yet, and on a cold join everything has merely not arrived yet.

	── IT NEVER CHANGES WHAT IS ON SCREEN ──────────────────────────────────────
	This warns and does nothing else. A caller that wants a fallback should
	build one; substituting a placeholder from in here would replace one silent
	wrong picture with a different silent wrong picture, and the degraded state
	of a missing image is usually already correct — a black menu, an empty card.
	What was missing was never the pixels. It was knowing.
]]

local ContentProvider = game:GetService("ContentProvider")

local ImageCheck = {}

--[[ One fetch per id for the lifetime of the client, however many callers ask.
     The map vote asks for its three cards every time it opens, and a vote that
     re-fetches on every round would be three requests a map for nothing. ]]
local seen: { [string]: boolean } = {}

--[[ Named so the warning can say WHICH picture: an id on its own sends whoever
     reads the log grepping for a number. Several callers can name the same id
     (nothing stops two maps sharing a card), so this is a list. ]]
local names: { [string]: { string } } = {}

local function describe(id: string): string
	local list = names[id]
	if not list or #list == 0 then
		return id
	end
	return string.format("%s (%s)", table.concat(list, ", "), id)
end

--[[ The advice, once, because it is the whole value of the warning and it has
     to be in every one of them — a log line that says "failed" and stops has
     told somebody they have a problem and not how to look at it. ]]
local ADVICE = "The usual cause is a DECAL id: the id shown on a Creator Store page or an inventory "
	.. "tile wraps the image rather than being it. Insert the decal in Studio and read the id off its "
	.. "Texture property. Otherwise the asset is private, in moderation, or owned by an account that "
	.. "does not own this place — which fails per player and still loads in Studio for whoever uploaded it."

--[[
	Typos, caught without a network.

	Returns the reason it is malformed, or nil if the shape is fine. Shape being
	fine says nothing about whether the asset exists; that is the fetch's job.
]]
local function shapeProblem(id: string): string?
	if id ~= (string.gsub(id, "%s", "")) then
		return "it contains whitespace"
	end
	if string.match(id, "^https?://") then
		return "it is a URL. The legacy http://www.roblox.com/asset/?id= form is not a content id; "
			.. "use rbxassetid:// and the bare number"
	end
	if string.match(id, "^rbxasset://") then
		return "rbxasset:// addresses a file shipped inside Roblox Studio, not an upload. An uploaded "
			.. "picture is rbxassetid://"
	end
	local digits = string.match(id, "^rbxassetid://(%d+)$")
	if digits then
		if tonumber(digits) == 0 then
			return "id 0 is not an asset. If the picture is meant to be absent, use an empty string"
		end
		return nil
	end

	--[[ The other two schemes an ImageLabel legitimately takes, passed through
	     without inspection. rbxthumb:// is a live thumbnail — a player headshot,
	     a group emblem — whose tail is a query string and not an id at all;
	     rbxgameasset:// addresses an asset by NAME inside this experience. This
	     game uses neither today. They are here because a shape check that is
	     wrong about a valid scheme is worse than no shape check: it teaches
	     whoever hits it that this warning can be ignored. ]]
	if string.match(id, "^rbxthumb://") or string.match(id, "^rbxgameasset://") then
		return nil
	end

	if string.match(id, "^%d+$") then
		return "it is a bare number. An ImageLabel wants the rbxassetid:// prefix"
	end
	if string.match(id, "^rbxassetid://") then
		return "what follows rbxassetid:// is not a plain number"
	end
	return "it is not a content id"
end

--[[
	Check one image id, and say so by name if it is not going to draw.

	`what` is what a person would call this picture — "the menu photograph",
	"the CLINTON map card". It ends up in the warning and it is the difference
	between a log line somebody acts on and one they scroll past.

	An EMPTY id is silence, not a warning. Several things in this game are meant
	to have no picture, and an atmosphere layer with no texture set is a feature
	(see UITheme.Dread.HazeImage); warning about a blank that was chosen would
	train everyone to ignore the ones that were not.
]]
function ImageCheck.verify(id: unknown, what: string)
	if id == nil or id == "" then
		return
	end
	if typeof(id) ~= "string" then
		warn(string.format("[ImageCheck] %s is a %s, not an image id.", what, typeof(id)))
		return
	end

	local existing = names[id]
	if existing then
		if not table.find(existing, what) then
			table.insert(existing, what)
		end
	else
		names[id] = { what }
	end

	--[[ Shape first, and it stops here if the shape is wrong: PreloadAsync
	     THROWS on a malformed content string rather than reporting it, so a
	     typo sent to the fetch becomes an error in a pcall and a worse
	     message than the one already written above. ]]
	local problem = shapeProblem(id)
	if problem then
		warn(string.format("[ImageCheck] %s will not draw: %s.", describe(id), problem))
		return
	end

	if seen[id] then
		return
	end
	seen[id] = true

	--[[ Spawned. PreloadAsync yields until the id resolves or gives up, and one
	     the client cannot see takes seconds to give up. Nothing that builds a
	     screen should wait on a network round trip to do it. ]]
	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync({ id }, function(_content: string, fetchStatus: any)
				if fetchStatus == Enum.AssetFetchStatus.Success then
					return
				end
				warn(
					string.format(
						"[ImageCheck] %s could not be fetched (%s). %s",
						describe(id),
						tostring(fetchStatus),
						ADVICE
					)
				)
			end)
		end)
		if not ok then
			--[[ Reachable despite the shape check above: PreloadAsync also
			     throws where it cannot run at all. Reported as "could not
			     check" rather than "failed", because those are different facts
			     and only one of them is about the asset. Not retried — an
			     environment that cannot fetch on the first call will not manage
			     it on the fourth, and the map vote rebuilds its cards every
			     round. ]]
			warn(string.format("[ImageCheck] could not check %s: %s", describe(id), tostring(err)))
		end
	end)
end

return ImageCheck
