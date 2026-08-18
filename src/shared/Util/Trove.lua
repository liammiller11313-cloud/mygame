--!strict
--[[
	Trove — a cleanup bag.

	Roblox code leaks in exactly one way: something connects a signal or creates
	an instance and the thing that owns it goes away without disconnecting. Every
	system in this game that has a lifetime owns a Trove, adds everything it
	creates to it, and destroys it in one call.

		local trove = Trove.new()
		trove:add(part)
		trove:connect(humanoid.Died, onDied)
		trove:add(function() print("cleaning up") end)
		trove:destroy()   -- undoes all of the above, newest first
]]

local Trove = {}
Trove.__index = Trove

export type Trove = typeof(setmetatable(
	{} :: {
		_objects: { any },
		_destroyed: boolean,
	},
	Trove
))

function Trove.new(): Trove
	return setmetatable({
		_objects = {},
		_destroyed = false,
	}, Trove) :: any
end

--[[
	Tracks anything cleanable: an Instance, an RBXScriptConnection, a function,
	a thread, or any table with a :Destroy/:destroy/:Disconnect method. Returns
	the object so it can be used inline.
]]
function Trove.add<T>(self: Trove, object: T): T
	if self._destroyed then
		warn("[Trove] added an object to an already-destroyed trove; cleaning it immediately")
		Trove._cleanup(object)
		return object
	end
	table.insert(self._objects, object)
	return object
end

--[[ Connects a signal and tracks the connection in one step. ]]
function Trove.connect(self: Trove, signal: RBXScriptSignal, handler: (...any) -> ()): RBXScriptConnection
	return self:add(signal:Connect(handler))
end

--[[ Stops tracking an object and cleans it up now, leaving the rest alone. ]]
function Trove.remove<T>(self: Trove, object: T): boolean
	local index = table.find(self._objects, object :: any)
	if not index then
		return false
	end
	table.remove(self._objects, index)
	Trove._cleanup(object)
	return true
end

--[[ Cleans everything up but keeps the trove usable. ]]
function Trove.clean(self: Trove)
	-- Newest first: a connection added after an instance usually depends on it.
	for index = #self._objects, 1, -1 do
		Trove._cleanup(self._objects[index])
		self._objects[index] = nil
	end
end

function Trove.destroy(self: Trove)
	if self._destroyed then
		return
	end
	self:clean()
	self._destroyed = true
end

function Trove._cleanup(object: any)
	local kind = typeof(object)
	if kind == "Instance" then
		object:Destroy()
	elseif kind == "RBXScriptConnection" then
		object:Disconnect()
	elseif kind == "function" then
		object()
	elseif kind == "thread" then
		-- Cancelling the running coroutine would kill the caller mid-cleanup.
		if coroutine.running() ~= object then
			pcall(task.cancel, object)
		end
	elseif kind == "table" then
		if typeof(object.Destroy) == "function" then
			object:Destroy()
		elseif typeof(object.destroy) == "function" then
			object:destroy()
		elseif typeof(object.Disconnect) == "function" then
			object:Disconnect()
		end
	end
end

Trove.Add = Trove.add
Trove.Connect = Trove.connect
Trove.Remove = Trove.remove
Trove.Clean = Trove.clean
Trove.Destroy = Trove.destroy

return Trove
