local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared"):WaitForChild("Config"))

local Camera2D = {}
Camera2D.__index = Camera2D
local FAST_OWN_CELL_ROW_BYTES = 20

function Camera2D.new()
	local dynamicScale = math.max(Config.DynamicWorld and Config.DynamicWorld.MaxScale or 1, 1)
	local initialCenter = Config.World.Size * dynamicScale * 0.5
	return setmetatable({
		center = initialCenter,
		targetCenter = initialCenter,
		zoom = 1,
		targetZoom = 1,
		baseTargetZoom = 1,
		manualZoom = 1,
		viewport = Vector2.new(1280, 720),
		localPredictionCenter = nil,
	}, Camera2D)
end

function Camera2D:setViewport(viewport: Vector2)
	self.viewport = Vector2.new(math.max(viewport.X, 1), math.max(viewport.Y, 1))
end

function Camera2D:updateFromSnapshot(snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end

	local center = snapshot.center
	local cells = snapshot.cells
	local you = snapshot.you
	local radiusSum = nil
	local packedFastCells = false
	if snapshot.k == "d" then
		center = snapshot.c
		cells = snapshot.co
		you = snapshot.y
		radiusSum = snapshot.sr
		packedFastCells = true
	end

	if typeof(center) ~= "table" then
		return
	end

	self.targetCenter = Vector2.new(center[1], center[2])

	local ownRadius = 0
	if typeof(radiusSum) == "number" then
		ownRadius = radiusSum
	elseif packedFastCells then
		if typeof(cells) == "buffer" then
			for offset = 0, buffer.len(cells) - FAST_OWN_CELL_ROW_BYTES, FAST_OWN_CELL_ROW_BYTES do
				ownRadius += buffer.readf32(cells, offset + 12)
			end
		else
			for i = 1, #(cells or {}), 5 do
				ownRadius += cells[i + 3] or 0
			end
		end
	else
		for _, packed in cells or {} do
			if packed[2] == you then
				ownRadius += packed[5]
			end
		end
	end

	local referenceSize = Config.Render.AgarZoomReferenceSize or 64
	local exponent = Config.Render.AgarZoomExponent or 0.4
	local referenceWidth = Config.Render.AgarZoomReferenceWidth or 1920
	local referenceHeight = Config.Render.AgarZoomReferenceHeight or 1080
	local viewportScale = math.max(self.viewport.Y / referenceHeight, self.viewport.X / referenceWidth)
	local sizeFactor = math.pow(math.min(referenceSize / math.max(ownRadius, 1), 1), exponent)
	-- Keep more of the arena visible on every device without changing the
	-- world-space blob radius used by authoritative collision checks.
	self.baseTargetZoom = sizeFactor * viewportScale * (Config.Render.AgarZoomOutScale or 1)
	self:_refreshTargetZoom()
end

function Camera2D:_refreshTargetZoom()
	self.manualZoom = math.clamp(self.manualZoom, Config.Render.ManualZoomMin or 0.55, Config.Render.ManualZoomMax or 1.85)
	self.targetZoom = math.clamp(
		self.baseTargetZoom * self.manualZoom,
		Config.Render.MinZoom or 0.22,
		Config.Render.MaxZoom or 1.9
	)
end

function Camera2D:adjustZoom(multiplier: number)
	if typeof(multiplier) ~= "number" or multiplier ~= multiplier or multiplier <= 0 then
		return
	end

	self.manualZoom *= multiplier
	self:_refreshTargetZoom()
end

function Camera2D:zoomIn()
	self:adjustZoom(Config.Render.ZoomButtonStep or 1.18)
end

function Camera2D:zoomOut()
	self:adjustZoom(1 / (Config.Render.ZoomButtonStep or 1.18))
end

function Camera2D:setLocalPredictionCenter(center: Vector2?)
	self.localPredictionCenter = center
end

function Camera2D:step(dt: number)
	local centerAlpha = 1 - math.exp(-dt * Config.Render.CameraSharpness)
	local zoomBlendPerStep = Config.Render.AgarZoomBlendPer60Hz or 0.1
	local zoomAlpha = 1 - math.pow(1 - zoomBlendPerStep, math.max(dt * 60, 0))
	local centerTarget = self.targetCenter
	if Config.Render.OwnCellPredictionEnabled and self.localPredictionCenter then
		local predictionWeight = math.clamp(Config.Render.OwnCellPredictionCameraWeight or 0.85, 0, 1)
		centerTarget = self.targetCenter:Lerp(self.localPredictionCenter, predictionWeight)
	end
	self.center = self.center:Lerp(centerTarget, centerAlpha)
	self.zoom += (self.targetZoom - self.zoom) * zoomAlpha
end

function Camera2D:worldToScreen(pos: Vector2): Vector2
	return (pos - self.center) * self.zoom + self.viewport * 0.5
end

function Camera2D:screenToWorld(pos: Vector2): Vector2
	return (pos - self.viewport * 0.5) / self.zoom + self.center
end

function Camera2D:visible(pos: Vector2, radius: number): boolean
	local screen = self:worldToScreen(pos)
	local sr = radius * self.zoom
	return screen.X + sr >= 0
		and screen.X - sr <= self.viewport.X
		and screen.Y + sr >= 0
		and screen.Y - sr <= self.viewport.Y
end

return Camera2D
