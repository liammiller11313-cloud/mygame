--!strict
--[[
	Spring — critically-dampable spring integrator.

	Recoil, weapon sway, camera kick and crosshair bloom all want the same thing:
	snap hard to a new value, then settle back naturally. Tweens cannot do this,
	because a new impulse mid-tween has to cancel and restart, and the result
	reads as mechanical. A spring just accumulates, which is why every shooter
	that feels good uses one.

		local recoil = Spring.new(Vector3.zero)
		recoil.speed = 18
		recoil.damping = 0.62
		recoil:impulse(Vector3.new(kickUp, kickSide, 0))
		local offset = recoil:update(deltaTime)
]]

local Spring = {}
Spring.__index = Spring

export type Springable = number | Vector2 | Vector3

export type Spring<T> = typeof(setmetatable(
	{} :: {
		position: any,
		velocity: any,
		target: any,
		speed: number,
		damping: number,
		_zero: any,
	},
	Spring
))

--[[
	`speed` is how hard it pulls toward the target (higher is snappier).
	`damping` below 1 overshoots and bounces; 1 is critically damped; above 1
	crawls in. Weapon recoil wants roughly 0.55-0.75 so it has a little life.
]]
function Spring.new<T>(initial: T, speed: number?, damping: number?): Spring<T>
	local zero: any
	if typeof(initial) == "number" then
		zero = 0
	elseif typeof(initial) == "Vector2" then
		zero = Vector2.zero
	elseif typeof(initial) == "Vector3" then
		zero = Vector3.zero
	else
		error("[Spring] supports number, Vector2 and Vector3 only")
	end

	return setmetatable({
		position = initial,
		velocity = zero,
		target = initial,
		speed = speed or 12,
		damping = damping or 1,
		_zero = zero,
	}, Spring) :: any
end

--[[
	Advances the simulation. Uses a semi-implicit Euler step, which stays stable
	at the frame spikes a rocket volley will absolutely produce; dt is clamped so
	that a single 200ms hitch cannot fling the spring across the screen.
]]
function Spring.update<T>(self: Spring<T>, deltaTime: number): T
	local dt = math.min(deltaTime, 1 / 20)
	local displacement = self.position - self.target
	local springForce = displacement * -(self.speed * self.speed)
	local dampingForce = self.velocity * -(2 * self.damping * self.speed)

	self.velocity = self.velocity + (springForce + dampingForce) * dt
	self.position = self.position + self.velocity * dt
	return self.position
end

--[[ Kicks the spring's velocity without moving it. This is a gunshot. ]]
function Spring.impulse<T>(self: Spring<T>, amount: T)
	self.velocity = self.velocity + amount
end

--[[ Snaps everything to a value with no motion. Use on weapon swap and respawn,
     where carrying the previous weapon's recoil across would look broken. ]]
function Spring.reset<T>(self: Spring<T>, value: T?)
	local resolved = if value ~= nil then value else self._zero
	self.position = resolved
	self.target = resolved
	self.velocity = self._zero
end

--[[ True once the spring has effectively stopped, so callers can skip work. ]]
function Spring.isSettled<T>(self: Spring<T>, epsilon: number?): boolean
	local threshold = epsilon or 0.001
	if typeof(self.position) == "number" then
		return math.abs(self.position - self.target) < threshold and math.abs(self.velocity) < threshold
	end
	return (self.position - self.target).Magnitude < threshold and self.velocity.Magnitude < threshold
end

Spring.Update = Spring.update
Spring.Impulse = Spring.impulse
Spring.Reset = Spring.reset

return Spring
