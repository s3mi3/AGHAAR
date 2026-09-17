local SpatialHash = {}
SpatialHash.__index = SpatialHash

function SpatialHash.new(cellSize: number)
	return setmetatable({
		cellSize = cellSize,
		buckets = {},
	}, SpatialHash)
end

function SpatialHash:clear()
	table.clear(self.buckets)
end

function SpatialHash:_bucket(cx: number, cy: number)
	local column = self.buckets[cx]
	if not column then
		column = {}
		self.buckets[cx] = column
	end

	local bucket = column[cy]
	if not bucket then
		bucket = {}
		column[cy] = bucket
	end
	return bucket
end

function SpatialHash:_range(pos: Vector2, radius: number)
	local size = self.cellSize
	return math.floor((pos.X - radius) / size),
		math.floor((pos.X + radius) / size),
		math.floor((pos.Y - radius) / size),
		math.floor((pos.Y + radius) / size)
end

function SpatialHash:insert(id: number, pos: Vector2, radius: number)
	local minX, maxX, minY, maxY = self:_range(pos, radius)
	for cx = minX, maxX do
		for cy = minY, maxY do
			local bucket = self:_bucket(cx, cy)
			bucket[#bucket + 1] = id
		end
	end
end

function SpatialHash:query(pos: Vector2, radius: number, out: { number }?, seenScratch): { number }
	local result = out or {}
	table.clear(result)

	local seen = seenScratch or {}
	table.clear(seen)
	local minX, maxX, minY, maxY = self:_range(pos, radius)
	for cx = minX, maxX do
		local column = self.buckets[cx]
		for cy = minY, maxY do
			local bucket = column and column[cy]
			if bucket then
				for i = 1, #bucket do
					local id = bucket[i]
					if not seen[id] then
						seen[id] = true
						result[#result + 1] = id
					end
				end
			end
		end
	end

	if not seenScratch then
		table.clear(seen)
	end
	return result
end

return SpatialHash
