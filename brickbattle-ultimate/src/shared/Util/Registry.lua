--!strict
--[[
	Registry — a tiny service locator, used on both server and client.

	The round systems in this game are genuinely mutually dependent. RoundService
	must tell TeamService to rebalance the sides between rounds; TeamService must
	ask RoundService whether a round is live before it moves anyone. ScoreService
	and RoundService need each other in both directions — one decides when the
	kill target is met, the other decides whether a kill counts. Plain `require`
	cannot express that: Luau module cycles either error or silently hand back a
	half-built table.

	So services never require each other. Each one registers itself at boot, and
	looks the others up by name at CALL time, by which point everything exists:

		-- at the bottom of TeamService.lua
		Registry.register("TeamService", TeamService)

		-- inside a function in RoundService.lua
		Registry.get("TeamService"):assign(player)

	`get` is strict — an unknown name is a typo and should stop the show loudly
	rather than return nil and produce a confusing error three frames later.
]]

local Registry = {}

local services: { [string]: any } = {}
local awaiting: { [string]: { thread } } = {}

--[[ Registers a service under a name. Registering twice is a bug: it means two
     modules claim the same name, and whichever loaded second would silently win. ]]
function Registry.register(name: string, service: any)
	assert(typeof(name) == "string" and name ~= "", "Registry.register needs a non-empty name")
	assert(service ~= nil, string.format("Registry.register(%q) was given nil", name))
	if services[name] ~= nil then
		error(string.format("[Registry] %q is already registered — two modules share a name", name), 2)
	end

	services[name] = service

	-- Wake anything that was blocked in waitFor.
	local waiters = awaiting[name]
	if waiters then
		awaiting[name] = nil
		for _, thread in waiters do
			task.spawn(thread, service)
		end
	end
end

--[[ Fetches a service, erroring if it is not registered. Use this everywhere. ]]
function Registry.get(name: string): any
	local service = services[name]
	if service == nil then
		error(
			string.format(
				"[Registry] %q is not registered. Either the bootstrap did not require it yet, "
					.. "or the name is misspelled. Registered: %s",
				name,
				table.concat(Registry.getRegisteredNames(), ", ")
			),
			2
		)
	end
	return service
end

--[[ Fetches a service, or nil. For genuinely optional systems only. ]]
function Registry.find(name: string): any?
	return services[name]
end

--[[ Yields until a service registers. Only for code running outside the boot
     sequence; anything inside it should just be ordered correctly instead. ]]
function Registry.waitFor(name: string, timeout: number?): any
	local existing = services[name]
	if existing ~= nil then
		return existing
	end

	local waiters = awaiting[name]
	if not waiters then
		waiters = {}
		awaiting[name] = waiters
	end

	local thread = coroutine.running()
	table.insert(waiters, thread)

	if timeout then
		task.delay(timeout, function()
			local list = awaiting[name]
			local index = list and table.find(list, thread)
			if index then
				table.remove(list :: any, index)
				task.spawn(thread, nil)
			end
		end)
	end

	return coroutine.yield()
end

function Registry.isRegistered(name: string): boolean
	return services[name] ~= nil
end

function Registry.getRegisteredNames(): { string }
	local names = {}
	for name in services do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--[[ Test/teardown only. Never call this during a live round. ]]
function Registry.reset()
	table.clear(services)
	table.clear(awaiting)
end

return Registry
