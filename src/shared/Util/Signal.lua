--!strict
--[[
	Signal — an event you can fire between modules on the same machine.

	BindableEvents would do this, but they deep-copy every argument across the
	boundary, which means a table you fire comes out the other side as a
	different table. That breaks identity comparisons and quietly costs real
	performance during a horde. This is a plain Lua implementation with no copy.

		local onDeath = Signal.new()
		local connection = onDeath:connect(function(model) ... end)
		onDeath:fire(model)
		connection:disconnect()
]]

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

export type Connection = typeof(setmetatable(
	{} :: {
		_signal: any,
		_handler: ((...any) -> ())?,
		connected: boolean,
	},
	Connection
))

export type Signal = typeof(setmetatable(
	{} :: {
		_connections: { Connection },
		_firing: boolean,
	},
	Signal
))

function Connection.disconnect(self: Connection)
	if not self.connected then
		return
	end
	self.connected = false
	self._handler = nil
	local connections = self._signal._connections
	local index = table.find(connections, self)
	if index then
		table.remove(connections, index)
	end
end

Connection.Disconnect = Connection.disconnect
Connection.Destroy = Connection.disconnect

function Signal.new(): Signal
	return setmetatable({
		_connections = {},
		_firing = false,
	}, Signal) :: any
end

function Signal.connect(self: Signal, handler: (...any) -> ()): Connection
	assert(typeof(handler) == "function", "Signal:connect expects a function")
	local connection = setmetatable({
		_signal = self,
		_handler = handler,
		connected = true,
	}, Connection) :: any
	table.insert(self._connections, connection)
	return connection
end

--[[ Connects a handler that disconnects itself after the first fire. ]]
function Signal.once(self: Signal, handler: (...any) -> ()): Connection
	local connection: Connection
	connection = self:connect(function(...)
		connection:disconnect()
		handler(...)
	end)
	return connection
end

--[[
	Fires every handler. Each runs in its own thread so that one handler erroring
	or yielding cannot stop the others — during a horde, a single bad listener
	silently swallowing every subsequent death event would be very hard to find.
]]
function Signal.fire(self: Signal, ...: any)
	-- Iterate a snapshot: handlers routinely disconnect themselves mid-fire.
	local snapshot = table.clone(self._connections)
	for _, connection in snapshot do
		if connection.connected and connection._handler then
			task.spawn(connection._handler :: any, ...)
		end
	end
end

--[[ Fires synchronously on the calling thread. Use only where ordering matters
     more than isolation — a handler that errors here WILL propagate. ]]
function Signal.fireSync(self: Signal, ...: any)
	local snapshot = table.clone(self._connections)
	for _, connection in snapshot do
		if connection.connected and connection._handler then
			(connection._handler :: any)(...)
		end
	end
end

function Signal.destroy(self: Signal)
	for index = #self._connections, 1, -1 do
		self._connections[index]:disconnect()
	end
	table.clear(self._connections)
end

Signal.Connect = Signal.connect
Signal.Once = Signal.once
Signal.Fire = Signal.fire
Signal.Destroy = Signal.destroy

return Signal
