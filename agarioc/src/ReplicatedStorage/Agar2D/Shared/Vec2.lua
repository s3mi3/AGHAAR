local Vec2 = {}

local function safeAxisPadding(size: number, padding: number): number
	return math.min(math.max(padding, 0), size * 0.5)
end

function Vec2.clampToWorld(pos: Vector2, worldSize: Vector2, padding: number?): Vector2
	local pad = padding or 0
	local padX = safeAxisPadding(worldSize.X, pad)
	local padY = safeAxisPadding(worldSize.Y, pad)
	return Vector2.new(
		math.clamp(pos.X, padX, worldSize.X - padX),
		math.clamp(pos.Y, padY, worldSize.Y - padY)
	)
end

function Vec2.safeUnit(vec: Vector2, fallback: Vector2?): Vector2
	if vec.Magnitude > 0.0001 then
		return vec.Unit
	end
	return fallback or Vector2.new(1, 0)
end

function Vec2.randomInWorld(worldSize: Vector2, padding: number?): Vector2
	local pad = padding or 0
	local padX = safeAxisPadding(worldSize.X, pad)
	local padY = safeAxisPadding(worldSize.Y, pad)
	return Vector2.new(
		math.random() * math.max(worldSize.X - padX * 2, 0) + padX,
		math.random() * math.max(worldSize.Y - padY * 2, 0) + padY
	)
end

function Vec2.distanceSquared(a: Vector2, b: Vector2): number
	local dx = a.X - b.X
	local dy = a.Y - b.Y
	return dx * dx + dy * dy
end

function Vec2.fromAngle(angle: number): Vector2
	return Vector2.new(math.cos(angle), math.sin(angle))
end

return Vec2
