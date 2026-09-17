local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared"):WaitForChild("Config"))
local SkinData = require(ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared"):WaitForChild("SkinData"))
local CirclePool = require(script.Parent:WaitForChild("CirclePool"))
local Localization = require(script.Parent:WaitForChild("Localization"))
local SkinShop = require(script.Parent:WaitForChild("SkinShop"))

local Renderer = {}
Renderer.__index = Renderer
local FAST_OWN_CELL_ROW_BYTES = 20
local FAST_REMOTE_CELL_ROW_BYTES = 28
local FAST_EJECTED_ROW_BYTES = 21
local DEFAULT_AVATAR_DISPLAY_MODE = "face"
local AVATAR_THUMBNAIL_TYPES = {
	face = Enum.ThumbnailType.HeadShot,
	bust = Enum.ThumbnailType.AvatarBust,
	fullBody = Enum.ThumbnailType.AvatarThumbnail,
}

local function colorFromPayload(payload)
	if typeof(payload) == "table" then
		return Color3.fromRGB(payload[1] or 255, payload[2] or 255, payload[3] or 255)
	end
	return Color3.fromRGB(80, 150, 240)
end

local function colorPayloadFromPacked(value: number)
	value = math.max(0, math.floor(value + 0.5))
	local r = math.floor(value / 65536) % 256
	local g = math.floor(value / 256) % 256
	local b = value % 256
	return { r, g, b }
end

local function displayScore(mass: number): string
	return tostring(math.floor(mass + 0.5))
end

local function normaliseAvatarDisplayMode(value): string
	if value == "face" or value == "bust" or value == "fullBody" or value == "hidden" then
		return value
	end
	return DEFAULT_AVATAR_DISPLAY_MODE
end

local function movementVectorToTarget(target: Vector2?, pos: Vector2, radius: number)
	if not target then
		return Vector2.zero, 0
	end

	local offset = target - pos
	local distance = offset.Magnitude
	local deadZone = math.max(
		Config.Player.MovementDeadZone,
		radius * Config.Player.MovementDeadZoneRadiusScale
	)
	if distance <= deadZone then
		return Vector2.zero, 0
	end

	local slowDistance = math.max(
		Config.Player.MovementSlowDistance,
		radius * Config.Player.MovementSlowRadiusScale
	)
	local speedScale = math.clamp((distance - deadZone) / slowDistance, 0, 1)
	if speedScale < 0.02 then
		return Vector2.zero, 0
	end

	return offset / distance, speedScale
end

local function speedForMass(mass: number?): number
	local speed = Config.Player.BaseSpeed * (Config.Player.InitialMass / math.max(mass or Config.Player.InitialMass, 1)) ^ Config.Player.SpeedExponent
	return math.clamp(speed, Config.Player.MinSpeed, Config.Player.BaseSpeed)
end

local function splitImpulseForMass(mass: number?): number
	local scale = (Config.Player.InitialMass / math.max(mass or Config.Player.InitialMass, 1))
		^ (Config.Cell.SplitImpulseMassExponent or 0.28)
	scale = math.clamp(scale, Config.Cell.MinSplitImpulseScale or 0.34, 1)
	return math.min(Config.Cell.SplitImpulse * scale, Config.Cell.SplitMaxBoost or math.huge)
end

local function canMassFireEjected(mass: number?): boolean
	if not mass then
		return false
	end

	local minFireMass = math.max(Config.Ejected.MinFireMass or 0, 0)
	if mass < minFireMass then
		return false
	end

	local cost = math.max(Config.Ejected.Cost or 0, 0)
	return cost <= 0 or mass > cost
end

local function zIndexForRadius(radius: number): number
	return 3 + math.clamp(math.floor(radius / 24 + 0.5), 0, 14)
end

local function serverTimeNow(): number
	local ok, value = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return os.clock()
end

local function userIdIsAllowed(userId: number, allowedUserIds): boolean
	if typeof(allowedUserIds) ~= "table" then
		return false
	end

	for _, allowedUserId in allowedUserIds do
		if tonumber(allowedUserId) == userId then
			return true
		end
	end
	return false
end

local function foodColorFromIndex(index: number?): Color3
	local colors = Config.Food.Colors
	if typeof(index) == "number" and colors[index] then
		return colors[index]
	end
	return Config.Render.FoodColor
end

local function skinImageFromId(id: string?): string?
	if typeof(id) ~= "string" then
		return nil
	end

	local skin = SkinData.ById[id]
	return skin and skin.image or nil
end

local function isSplitSpawnAnimating(state, now: number?): boolean
	return state.spawnAnimationOrigin ~= nil
end

local function removePackedIds(states, ids, pool, idPrefix: number)
	if typeof(ids) ~= "table" then
		return
	end

	for _, id in ids do
		states[id] = nil
		if pool then
			pool:release(idPrefix + id)
		end
	end
end

local function expandPackedRows(flat, width: number)
	if typeof(flat) ~= "table" then
		return nil
	end

	local rows = {}
	local rowIndex = 1
	for i = 1, #flat, width do
		local row = {}
		for offset = 1, width do
			row[offset] = flat[i + offset - 1]
		end
		rows[rowIndex] = row
		rowIndex += 1
	end
	return rows
end

local function appendRows(target, source)
	if typeof(source) ~= "table" then
		return target
	end
	target = target or {}
	for _, row in source do
		target[#target + 1] = row
	end
	return target
end

local function decodeOwnCellBuffer(payload, ownerUserId: number)
	if typeof(payload) ~= "buffer" then
		local packed = expandPackedRows(payload, 5)
		local rows = nil
		for _, row in packed or {} do
			rows = rows or {}
			rows[#rows + 1] = { row[1], ownerUserId, row[2], row[3], row[4], row[5] }
		end
		return rows
	end

	local rows = {}
	local rowIndex = 1
	for offset = 0, buffer.len(payload) - FAST_OWN_CELL_ROW_BYTES, FAST_OWN_CELL_ROW_BYTES do
		rows[rowIndex] = {
			buffer.readu32(payload, offset),
			ownerUserId,
			buffer.readf32(payload, offset + 4),
			buffer.readf32(payload, offset + 8),
			buffer.readf32(payload, offset + 12),
			buffer.readf32(payload, offset + 16),
		}
		rowIndex += 1
	end
	return rows
end

local function decodeRemoteCellBuffer(payload)
	if typeof(payload) ~= "buffer" then
		return expandPackedRows(payload, 6)
	end

	local rows = {}
	local rowIndex = 1
	for offset = 0, buffer.len(payload) - FAST_REMOTE_CELL_ROW_BYTES, FAST_REMOTE_CELL_ROW_BYTES do
		rows[rowIndex] = {
			buffer.readu32(payload, offset),
			buffer.readf64(payload, offset + 4),
			buffer.readf32(payload, offset + 12),
			buffer.readf32(payload, offset + 16),
			buffer.readf32(payload, offset + 20),
			buffer.readf32(payload, offset + 24),
		}
		rowIndex += 1
	end
	return rows
end

local function decodeEjectedBuffer(payload)
	if typeof(payload) ~= "buffer" then
		return expandPackedRows(payload, 4)
	end

	local rows = {}
	local rowIndex = 1
	for offset = 0, buffer.len(payload) - FAST_EJECTED_ROW_BYTES, FAST_EJECTED_ROW_BYTES do
		local payloadType = buffer.readu8(payload, offset + 12)
		local ownerOrColor = buffer.readf64(payload, offset + 13)
		rows[rowIndex] = {
			buffer.readu32(payload, offset),
			buffer.readf32(payload, offset + 4),
			buffer.readf32(payload, offset + 8),
			if payloadType == 1 then ownerOrColor else colorPayloadFromPacked(ownerOrColor),
		}
		rowIndex += 1
	end
	return rows
end

local function decodeFixedBuffer(payload, width: number)
	if typeof(payload) ~= "buffer" then
		return expandPackedRows(payload, width)
	end

	local rows = {}
	local rowBytes = width * 4
	local rowIndex = 1
	for offset = 0, buffer.len(payload) - rowBytes, rowBytes do
		local row = {}
		for column = 1, width do
			row[column] = buffer.readf32(payload, offset + (column - 1) * 4)
		end
		rows[rowIndex] = row
		rowIndex += 1
	end
	return rows
end

local function configureFullscreenGui(gui: ScreenGui)
	gui.IgnoreGuiInset = true
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.None
	end)
	pcall(function()
		gui.ClipToDeviceSafeArea = false
	end)
end

function Renderer.new(playerGui: PlayerGui, camera, shopRemote: RemoteEvent?, debugRemote: RemoteEvent?)
	local localization = Localization.new(Players.LocalPlayer)

	local gui = Instance.new("ScreenGui")
	gui.Name = "Agar2DScreen"
	configureFullscreenGui(gui)
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundColor3 = Config.Render.BackgroundColor
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui

	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, 1)
	grid.ZIndex = 1
	grid.Parent = root

	local world = Instance.new("Frame")
	world.Name = "World"
	world.BackgroundTransparency = 1
	world.Size = UDim2.fromScale(1, 1)
	world.ZIndex = 2
	world.Parent = root

	local worldBorder = Instance.new("Frame")
	worldBorder.Name = "WorldBorder"
	worldBorder.AnchorPoint = Vector2.zero
	worldBorder.BackgroundTransparency = 1
	worldBorder.BorderSizePixel = 0
	worldBorder.Visible = false
	worldBorder.ZIndex = 2
	worldBorder.Parent = world

	local worldBorderStroke = Instance.new("UIStroke")
	worldBorderStroke.Thickness = 2
	worldBorderStroke.Color = Color3.fromRGB(36, 44, 58)
	worldBorderStroke.Transparency = 0.15
	worldBorderStroke.Parent = worldBorder

	local hud = Instance.new("Frame")
	hud.Name = "Hud"
	hud.BackgroundTransparency = 1
	hud.Size = UDim2.fromScale(1, 1)
	hud.ZIndex = 100
	hud.Parent = root

	local scoreLabel = Instance.new("TextLabel")
	scoreLabel.Name = "Score"
	scoreLabel.BackgroundTransparency = 0.3
	scoreLabel.BackgroundColor3 = Color3.fromRGB(20, 25, 32)
	scoreLabel.BorderSizePixel = 0
	scoreLabel.AnchorPoint = Vector2.new(0, 1)
	scoreLabel.Position = UDim2.new(0, 14, 1, -14)
	scoreLabel.Size = UDim2.fromOffset(160, 34)
	scoreLabel.Font = Enum.Font.GothamMedium
	scoreLabel.TextSize = 16
	scoreLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Left
	scoreLabel.Text = localization:scoreText(0)
	scoreLabel.ZIndex = 101
	scoreLabel.Parent = hud

	local scoreCorner = Instance.new("UICorner")
	scoreCorner.CornerRadius = UDim.new(1, 0)
	scoreCorner.Parent = scoreLabel

	local labelPad = Instance.new("UIPadding")
	labelPad.PaddingLeft = UDim.new(0, 10)
	labelPad.Parent = scoreLabel

	local pingLabel = Instance.new("TextLabel")
	pingLabel.Name = "Ping"
	pingLabel.BackgroundTransparency = 0.3
	pingLabel.BackgroundColor3 = Color3.fromRGB(20, 25, 32)
	pingLabel.BorderSizePixel = 0
	pingLabel.AnchorPoint = Vector2.new(0, 1)
	pingLabel.Position = UDim2.new(0, 14, 1, -54)
	pingLabel.Size = UDim2.fromOffset(160, 34)
	pingLabel.Font = Enum.Font.GothamMedium
	pingLabel.TextSize = 16
	pingLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	pingLabel.TextXAlignment = Enum.TextXAlignment.Left
	pingLabel.Text = localization:pingText(nil)
	pingLabel.ZIndex = 101
	pingLabel.Parent = hud

	local pingCorner = Instance.new("UICorner")
	pingCorner.CornerRadius = UDim.new(1, 0)
	pingCorner.Parent = pingLabel

	local pingPad = Instance.new("UIPadding")
	pingPad.PaddingLeft = UDim.new(0, 10)
	pingPad.Parent = pingLabel

	local coinLabel = Instance.new("TextLabel")
	coinLabel.Name = "Coins"
	coinLabel.BackgroundTransparency = 0.3
	coinLabel.BackgroundColor3 = Color3.fromRGB(20, 25, 32)
	coinLabel.BorderSizePixel = 0
	coinLabel.AnchorPoint = Vector2.new(1, 0)
	coinLabel.Position = UDim2.new(1, -116, 0, 14)
	coinLabel.Size = UDim2.fromOffset(160, 34)
	coinLabel.Font = Enum.Font.GothamMedium
	coinLabel.TextSize = 16
	coinLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	coinLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinLabel.Text = localization:coinsText(0)
	coinLabel.Visible = false
	coinLabel.ZIndex = 101
	coinLabel.Parent = hud

	local coinCorner = Instance.new("UICorner")
	coinCorner.CornerRadius = UDim.new(1, 0)
	coinCorner.Parent = coinLabel

	local coinPad = Instance.new("UIPadding")
	coinPad.PaddingLeft = UDim.new(0, 10)
	coinPad.Parent = coinLabel

	local levelBadge = Instance.new("Frame")
	levelBadge.Name = "LevelBadge"
	levelBadge.BackgroundColor3 = Color3.fromRGB(20, 25, 32)
	levelBadge.BorderSizePixel = 0
	levelBadge.AnchorPoint = Vector2.new(1, 0)
	levelBadge.Position = UDim2.new(1, -464, 0, 14)
	levelBadge.Size = UDim2.fromOffset(58, 34)
	levelBadge.Visible = false
	levelBadge.ZIndex = 101
	levelBadge.Parent = hud

	local levelBadgeCorner = Instance.new("UICorner")
	levelBadgeCorner.CornerRadius = UDim.new(1, 0)
	levelBadgeCorner.Parent = levelBadge

	local levelBadgeText = Instance.new("TextLabel")
	levelBadgeText.Name = "Text"
	levelBadgeText.BackgroundTransparency = 1
	levelBadgeText.Size = UDim2.fromScale(1, 1)
	levelBadgeText.Font = Enum.Font.GothamMedium
	levelBadgeText.TextSize = 16
	levelBadgeText.TextColor3 = Color3.fromRGB(255, 255, 255)
	levelBadgeText.Text = localization:levelText(1)
	levelBadgeText.ZIndex = 102
	levelBadgeText.Parent = levelBadge

	local levelMeter = Instance.new("Frame")
	levelMeter.Name = "LevelMeter"
	levelMeter.BackgroundColor3 = Color3.fromRGB(72, 72, 72)
	levelMeter.BorderSizePixel = 0
	levelMeter.AnchorPoint = Vector2.new(1, 0)
	levelMeter.Position = UDim2.new(1, -284, 0, 14)
	levelMeter.Size = UDim2.fromOffset(180, 34)
	levelMeter.Visible = false
	levelMeter.ZIndex = 101
	levelMeter.Parent = hud

	local levelMeterCorner = Instance.new("UICorner")
	levelMeterCorner.CornerRadius = UDim.new(1, 0)
	levelMeterCorner.Parent = levelMeter

	local levelFill = Instance.new("Frame")
	levelFill.Name = "Fill"
	levelFill.BackgroundColor3 = Color3.fromRGB(64, 156, 232)
	levelFill.BorderSizePixel = 0
	levelFill.Size = UDim2.fromScale(0, 1)
	levelFill.ZIndex = 102
	levelFill.Parent = levelMeter

	local levelFillCorner = Instance.new("UICorner")
	levelFillCorner.CornerRadius = UDim.new(1, 0)
	levelFillCorner.Parent = levelFill

	local levelText = Instance.new("TextLabel")
	levelText.Name = "Text"
	levelText.BackgroundTransparency = 1
	levelText.Size = UDim2.fromScale(1, 1)
	levelText.Font = Enum.Font.GothamMedium
	levelText.TextSize = 16
	levelText.TextColor3 = Color3.fromRGB(255, 255, 255)
	levelText.Text = "0%"
	levelText.ZIndex = 103
	levelText.Parent = levelMeter

	local debugButton = nil
	if debugRemote
		and Config.Debug
		and Config.Debug.WorldResizeEnabled == true
		and userIdIsAllowed(Players.LocalPlayer.UserId, Config.Debug.WorldResizeTesterUserIds)
	then
		debugButton = Instance.new("TextButton")
		debugButton.Name = "ResizeToggle"
		debugButton.BackgroundColor3 = Color3.fromRGB(20, 25, 32)
		debugButton.BackgroundTransparency = 0.3
		debugButton.BorderSizePixel = 0
		debugButton.AnchorPoint = Vector2.new(0.5, 0)
		debugButton.Position = UDim2.new(0.5, 0, 0, 54)
		debugButton.Size = UDim2.fromOffset(220, 34)
		debugButton.Font = Enum.Font.GothamMedium
		debugButton.TextSize = 16
		debugButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		debugButton.Text = localization:mapButtonText(false, 4500)
		debugButton.ZIndex = 101
		debugButton.Parent = hud

		local debugCorner = Instance.new("UICorner")
		debugCorner.CornerRadius = UDim.new(1, 0)
		debugCorner.Parent = debugButton

		local debugPad = Instance.new("UIPadding")
		debugPad.PaddingLeft = UDim.new(0, 10)
		debugPad.PaddingRight = UDim.new(0, 10)
		debugPad.Parent = debugButton

		debugButton.Activated:Connect(function()
			debugRemote:FireServer({ action = "toggle_world_resize" })
		end)
	end

	local skinShop = nil
	if shopRemote then
		skinShop = SkinShop.new(hud, shopRemote, localization)
	end

	local self = setmetatable({
		gui = gui,
		root = root,
		grid = grid,
		world = world,
		worldBorder = worldBorder,
		hud = hud,
		scoreLabel = scoreLabel,
		pingLabel = pingLabel,
		coinLabel = coinLabel,
		levelBadge = levelBadge,
		levelBadgeText = levelBadgeText,
		levelMeter = levelMeter,
		levelFill = levelFill,
		levelText = levelText,
		skinShop = skinShop,
		debugButton = debugButton,
		pingMs = nil,
		displayPingMs = nil,
		lastPingLabelUpdateAt = 0,
		debugWorldResizeEnabled = false,
		localization = localization,
		worldSize = Config.World.Size,
		camera = camera,
		snapshot = nil,
		snapshotSerial = 0,
		score = 0,
		coins = 0,
		level = 1,
		accountXp = 0,
		nextLevelXp = 35,
		menuOpen = false,
		cellStates = {},
		foodStates = {},
		virusStates = {},
		spawnerStates = {},
		ejectedStates = {},
		barrierStates = {},
		nextPredictedEjectedId = -1,
		predictedEjectCycleOffset = 0,
		predictedEjectRng = Random.new(),
		playerMeta = {},
		thumbnailCache = {},
		ownEatCandidatesScratch = {},
		localMoveTarget = nil,
		localMoveAim = Vector2.new(1, 0),
		predictedOwnCenter = nil,
		-- Set by InputController when the player toggles freeze. While
		-- true, own-cell prediction stops advancing displayPos toward the
		-- mouse, matching the server's frozen state. Without this, cells
		-- visibly drift a bit before authoritative snapshots catch up.
		localFrozen = false,
		lastOwnCellCount = 0,
		ownSeparationScratch = {},
		ejectedCollisionScratch = {},
		hudAccumulator = 0,
		lastScoreText = nil,
		lastPingText = nil,
		lastCoinsText = nil,
		lastLevelBadgeText = nil,
		lastLevelText = nil,
		lastLevelFill = nil,
		lastDebugText = nil,
		virusDrawOptions = {
			serrated = true,
			backgroundTransparency = 0,
			strokeEnabled = true,
		},
		spawnerDrawOptions = {
			baseImage = Config.Render.SpawnerImage,
			baseImageColor = Color3.fromRGB(255, 255, 255),
			backgroundTransparency = 1,
			strokeEnabled = false,
		},
		barrierDrawOptions = {
			image = Config.Render.BarrierImage,
			imageColor = Color3.fromRGB(255, 255, 255),
			cornerRadius = UDim.new(0, 0),
			backgroundTransparency = 1,
			strokeEnabled = false,
		},
		foodPool = CirclePool.new(world, 3),
		ejectedPool = CirclePool.new(world, 4),
		virusPool = CirclePool.new(world, 5),
		spawnerPool = CirclePool.new(world, 5),
		barrierPool = CirclePool.new(world, 5),
		cellPool = CirclePool.new(world, 6),
		gridLines = {},
	}, Renderer)

	if skinShop then
		skinShop.visibilityChanged = function(isOpen)
			self:setMenuOpen(isOpen)
		end
	end

	return self
end

function Renderer:setMenuOpen(isOpen: boolean)
	self.menuOpen = isOpen == true
	self.coinLabel.Visible = self.menuOpen
	self.levelBadge.Visible = self.menuOpen
	self.levelMeter.Visible = self.menuOpen
end

function Renderer:_removePredictedEjectedNear(pos: Vector2)
	local bestId = nil
	local bestDistance = math.huge
	local maxDistance = math.max(Config.Ejected.Radius * 6, 54)
	local maxDistanceSquared = maxDistance * maxDistance
	for id, state in self.ejectedStates do
		if state.predicted == true then
			local delta = state.displayPos - pos
			local distanceSquared = delta:Dot(delta)
			if distanceSquared <= maxDistanceSquared and distanceSquared < bestDistance then
				bestId = id
				bestDistance = distanceSquared
			end
		end
	end
	if bestId then
		self.ejectedStates[bestId] = nil
		self.ejectedPool:release(200000000 + bestId)
	end
end

function Renderer:setLocalMoveCommand(target: Vector2?, aim: Vector2?)
	self.localMoveTarget = target
	if typeof(aim) == "Vector2" and aim.Magnitude > 0.001 then
		self.localMoveAim = aim.Unit
	end
end

function Renderer:setLocalFrozen(frozen: boolean)
	local wasFrozen = self.localFrozen == true
	self.localFrozen = frozen == true
	-- Mark the moment we transitioned frozen -> unfrozen so the
	-- visual-separation resolver can ramp its strength/passes up
	-- gradually instead of exploding overlapping cells apart the
	-- instant the freeze releases.
	if wasFrozen and not self.localFrozen then
		self.unfreezeGraceStartedAt = os.clock()
		-- The server clears stored split momentum on release. Mirror that
		-- immediately instead of replaying a stale predicted boost until
		-- the next authoritative snapshot arrives.
		for _, state in self.cellStates do
			if state.isOwn then
				state.splitVisualBoost = nil
				state.velocity = Vector2.zero
			end
		end
	end
end

function Renderer:predictEject(aim: Vector2?, target: Vector2?)
	local fallbackDir = if typeof(aim) == "Vector2" and aim.Magnitude > 0.001 then aim.Unit else Vector2.new(1, 0)
	local eligible = {}
	for id, state in self.cellStates do
		if state.isOwn
			and state.confirmed
			and canMassFireEjected(state.mass)
		then
			eligible[#eligible + 1] = {
				id = id,
				state = state,
			}
		end
	end
	if #eligible <= 0 then
		return
	end
	table.sort(eligible, function(a, b)
		return a.id < b.id
	end)

	local now = os.clock()
	local eligibleCount = #eligible
	local visualLimit = Config.Ejected.LocalVisualMaxCellsPerShotTick or Config.Ejected.MaxCellsPerShotTick or eligibleCount
	local perTickLimit = math.min(eligibleCount, visualLimit)
	local startIndex = (self.predictedEjectCycleOffset % eligibleCount) + 1
	for step = 0, perTickLimit - 1 do
		local entry = eligible[((startIndex - 1 + step) % eligibleCount) + 1]
		local cell = entry.state
		-- Per-cell aim: pellet from THIS cell flies straight at cursor
		-- world position. Falls back to the shared move-aim direction
		-- when the target is missing or degenerate (cursor on cell).
		local dir = fallbackDir
		if typeof(target) == "Vector2" then
			local delta = target - cell.displayPos
			if delta.Magnitude > 0.001 then
				dir = delta.Unit
			end
		end
		local halfCone = math.rad(Config.Ejected.ConeDegrees) * 0.5
		local angle = self.predictedEjectRng:NextNumber(-halfCone, halfCone)
		local cos = math.cos(angle)
		local sin = math.sin(angle)
		local shotDir = Vector2.new(
			dir.X * cos - dir.Y * sin,
			dir.X * sin + dir.Y * cos
		)
		local spawnDistance = cell.radius + Config.Ejected.Radius + (Config.Ejected.NozzleOffset or 0)
		local pos = self:_clampToWorld(cell.displayPos + dir * spawnDistance, Config.Ejected.Radius)
		local id = self.nextPredictedEjectedId
		self.nextPredictedEjectedId -= 1
		if self.nextPredictedEjectedId < -1000000 then
			self.nextPredictedEjectedId = -1
		end

		self.ejectedStates[id] = {
			displayPos = pos,
			targetPos = pos,
			velocity = shotDir * Config.Ejected.Speed,
			radius = Config.Ejected.Radius,
			targetRadius = Config.Ejected.Radius,
			color = cell.color or Config.Render.EjectedColor,
			confirmed = true,
			requireConfirm = false,
			seen = self.snapshotSerial,
			lastSeenSerial = self.snapshotSerial,
			receivedAt = now,
			extrapolate = true,
			predicted = true,
			worldPadding = Config.Ejected.Radius,
			consumeAfter = now + math.max(Config.Ejected.OwnerReeatDelay or 0, Config.Ejected.LocalVisualMinVisibleSeconds or 0),
			expiresAt = now + (Config.Ejected.LocalVisualLifeSeconds or 0.8),
		}
	end
	self.predictedEjectCycleOffset = (startIndex - 1 + perTickLimit) % eligibleCount
end

function Renderer:setSnapshot(snapshot)
	local isFastDynamicPacket = typeof(snapshot) == "table" and snapshot.k == "d"
	local isFastCellSidecar = typeof(snapshot) == "table" and snapshot.k == "c"
	local isFastPacket = typeof(snapshot) == "table" and (snapshot.k == "d" or snapshot.k == "e" or snapshot.k == "c")
	local isFastEjectedSidecar = typeof(snapshot) == "table" and snapshot.k == "e"
	if typeof(snapshot) == "table" and snapshot.k == "d" then
		local cells = appendRows(
			decodeOwnCellBuffer(snapshot.co, snapshot.y),
			decodeRemoteCellBuffer(snapshot.cr)
		)
		snapshot = {
			you = snapshot.y,
			center = snapshot.c,
			cells = cells,
			ejected = decodeEjectedBuffer(snapshot.ej),
			spawners = decodeFixedBuffer(snapshot.sp, 4),
			barriers = decodeFixedBuffer(snapshot.ba, 5),
			score = snapshot.sc,
		}
	elseif typeof(snapshot) == "table" and snapshot.k == "e" then
		snapshot = {
			you = snapshot.y,
			ejected = decodeEjectedBuffer(snapshot.ej),
		}
	elseif typeof(snapshot) == "table" and snapshot.k == "c" then
		snapshot = {
			you = snapshot.y,
			cells = decodeRemoteCellBuffer(snapshot.cr),
		}
	end

	if not snapshot then
		self.snapshot = snapshot
		return
	end

		self.snapshot = snapshot
		if isFastDynamicPacket
			or (not isFastPacket and not snapshot.staticOnly and (
				snapshot.cells ~= nil
				or snapshot.ejected ~= nil
				or snapshot.spawners ~= nil
				or snapshot.barriers ~= nil
				or snapshot.food ~= nil
				or snapshot.viruses ~= nil
			))
		then
			self.snapshotSerial += 1
		end

	local serial = self.snapshotSerial
	local receivedAt = os.clock()
	local nowServer = serverTimeNow()
	local snapshotAgeSeconds = 0
	if typeof(snapshot.serverTime) == "number" then
		snapshotAgeSeconds = math.clamp(
			nowServer - snapshot.serverTime,
			0,
			Config.Render.OwnCellPredictionMaxLeadSeconds or 0.22
		)
	end
	local ownMass = 0
	local ownCellsInSnapshot = 0
	local staticOnly = snapshot.staticOnly == true
	self:_applyRemovedEntities(snapshot.gone)
	self:_applyPlayerMeta(snapshot.players)

	for _, packed in snapshot.food or {} do
		self:_syncEntity(self.foodStates, packed[1], Vector2.new(packed[2], packed[3]), Config.Food.Radius, nil, foodColorFromIndex(packed[4]), nil, serial, receivedAt, true, "food")
	end

	for _, packed in snapshot.viruses or {} do
		self:_syncEntity(self.virusStates, packed[1], Vector2.new(packed[2], packed[3]), packed[4] or Config.Virus.Radius, nil, nil, nil, serial, receivedAt, false, "virus")
	end

	for _, packed in snapshot.spawners or {} do
		self:_syncEntity(self.spawnerStates, packed[1], Vector2.new(packed[2], packed[3]), packed[4], nil, Config.Render.SpawnerColor, nil, serial, receivedAt, false, "spawner")
	end

	for _, packed in snapshot.barriers or {} do
		self:_syncEntity(
			self.barrierStates,
			packed[1],
			Vector2.new(packed[2], packed[3]),
			packed[4] * 0.5,
			nil,
			Config.Render.BarrierColor,
			{ width = packed[4], height = packed[5] },
			serial,
			receivedAt,
			false,
			"barrier"
		)
	end

	if not staticOnly then
		for _, packed in snapshot.ejected or {} do
			if packed[4] == snapshot.you then
				self:_removePredictedEjectedNear(Vector2.new(packed[2], packed[3]))
			end
			self:_syncEntity(self.ejectedStates, packed[1], Vector2.new(packed[2], packed[3]), Config.Ejected.Radius, nil, self:_ejectedColor(packed[4]), nil, serial, receivedAt, false, "ejected")
		end

		for _, packed in snapshot.cells or {} do
			local ownerUserId = packed[2]
			local meta = self.playerMeta[ownerUserId]
			local isOwn = ownerUserId == snapshot.you
			self:_syncEntity(
				self.cellStates,
				packed[1],
				Vector2.new(packed[3], packed[4]),
				packed[5],
				packed[6],
				meta and meta.color or colorFromPayload(packed[7]),
				{
					ownerUserId = ownerUserId,
					name = (meta and meta.name) or packed[8] or "Player",
					skinId = packed[9],
					skinImage = (meta and meta.skinImage) or skinImageFromId(packed[9]),
					isOwn = isOwn,
					snapshotAgeSeconds = if isOwn then snapshotAgeSeconds else nil,
				},
				serial,
				receivedAt,
				false,
				"cell"
			)

			if packed[2] == snapshot.you then
				ownMass += packed[6]
				ownCellsInSnapshot += 1
			end
		end
	end

	if not staticOnly and not isFastEjectedSidecar and not isFastCellSidecar then
		if ownCellsInSnapshot > (self.lastOwnCellCount or 0) then
			local separateUntil = receivedAt + (Config.Render.OwnCellVisualSeparationSeconds or Config.Cell.RecombineSeconds or 12)
			for _, state in self.cellStates do
				if state.isOwn then
					state.visualSeparateUntil = separateUntil
				end
			end
		end
		self.lastOwnCellCount = ownCellsInSnapshot
	end

	if typeof(snapshot.score) == "number" then
		self.score = snapshot.score
	elseif not staticOnly and not isFastEjectedSidecar and not isFastCellSidecar then
		self.score = ownMass
	end
	self.coins = snapshot.coinBalance or self.coins
	self.level = if typeof(snapshot.level) == "number" then snapshot.level else self.level
	self.accountXp = if typeof(snapshot.accountXp) == "number" then snapshot.accountXp else self.accountXp
	self.nextLevelXp = if typeof(snapshot.nextLevelXp) == "number" then snapshot.nextLevelXp else self.nextLevelXp
	if typeof(snapshot.debugWorldResizeEnabled) == "boolean" then
		self.debugWorldResizeEnabled = snapshot.debugWorldResizeEnabled == true
	end
	if typeof(snapshot.world) == "table" and typeof(snapshot.world[1]) == "number" and typeof(snapshot.world[2]) == "number" then
		self.worldSize = Vector2.new(snapshot.world[1], snapshot.world[2])
	end
	if typeof(snapshot.serverTime) == "number" then
		local measured = math.max(0, (nowServer - snapshot.serverTime) * 1000)
		if self.pingMs then
			self.pingMs += (measured - self.pingMs) * 0.2
		else
			self.pingMs = measured
		end
	end
	if self.pingMs and receivedAt - (self.lastPingLabelUpdateAt or 0) >= 0.75 then
		self.displayPingMs = self.pingMs
		self.lastPingLabelUpdateAt = receivedAt
	end
	-- Capped static snapshots are not authoritative absence. Static removals arrive through reliable gone payloads.
	if not staticOnly and not isFastPacket then
		self:_removeStale(self.ejectedStates, serial, Config.Render.EjectedMissingGraceSnapshots or Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots, false, self.ejectedPool, 200000000)
		self:_removeStale(self.spawnerStates, serial, Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots, false, self.spawnerPool, 350000000)
		self:_removeStale(self.barrierStates, serial, Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots, false, self.barrierPool, 450000000)
		self:_removeStale(self.cellStates, serial, Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots, false, self.cellPool, 0)
	end
	if isFastDynamicPacket then
		self:_removeMissingRemoteCells(serial, Config.Render.RemoteCellMissingGraceSnapshots)
		self:_removeStale(
			self.ejectedStates,
			serial,
			Config.Render.EjectedMissingGraceSnapshots or Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots,
			true,
			self.ejectedPool,
			200000000
		)
		self:_removeStale(
			self.spawnerStates,
			serial,
			Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots,
			true,
			self.spawnerPool,
			350000000
		)
		self:_removeStale(
			self.barrierStates,
			serial,
			Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots,
			true,
			self.barrierPool,
			450000000
		)
	end

	if self.skinShop then
		if snapshot.hasShop then
			self.skinShop:update(self.coins, snapshot.ownedSkins, snapshot.equippedSkin, snapshot.avatarDisplayMode, snapshot.nickname)
		else
			self.skinShop:updateCoins(self.coins)
		end
	end
end

function Renderer:_applyPlayerMeta(players)
	if typeof(players) ~= "table" then
		return
	end

	for _, packed in players do
		local userId = packed[1]
		if typeof(userId) == "number" then
			local equippedSkinId = if typeof(packed[4]) == "string" and packed[4] ~= "" then packed[4] else nil
			local locationSkinId = if typeof(packed[5]) == "string" and packed[5] ~= "" then packed[5] else nil
			local skinId = equippedSkinId or locationSkinId
			local avatarDisplayMode = normaliseAvatarDisplayMode(packed[6])
			self.playerMeta[userId] = {
				color = colorFromPayload(packed[2]),
				name = if typeof(packed[3]) == "string" then packed[3] else "Player",
				equippedSkinId = equippedSkinId,
				locationSkinId = locationSkinId,
				skinImage = skinImageFromId(skinId),
				avatarDisplayMode = avatarDisplayMode,
				overlayAvatar = avatarDisplayMode ~= "hidden",
			}
		end
	end
end

function Renderer:_ejectedColor(payload): Color3
	if typeof(payload) == "number" then
		local meta = self.playerMeta[payload]
		if meta then
			return meta.color
		end
	end
	return colorFromPayload(payload)
end

function Renderer:_beginConsumedCellAnimations(ids, consumeRows)
	if typeof(ids) ~= "table" then
		return
	end

	local removed = {}
	for _, id in ids do
		removed[id] = true
	end
	local consumeTargets = {}
	local consumeList = if typeof(consumeRows) == "table" then consumeRows else {}
	for _, row in consumeList do
		if typeof(row) == "table" then
			consumeTargets[row[1]] = row[2]
		end
	end

	local now = os.clock()
	local duration = math.max(Config.Render.ConsumeAnimationSeconds or 0.22, 0.01)
	for _, id in ids do
		local state = self.cellStates[id]
		if not state then
			continue
		end

		local sourcePos = state.targetPos or state.displayPos
		local sourceOwner = state.extra and state.extra.ownerUserId
		local explicitTargetId = consumeTargets[id]
		local bestTarget = explicitTargetId and self.cellStates[explicitTargetId] or nil
		local bestScore = math.huge
		if not bestTarget then
			for otherId, candidate in self.cellStates do
				if otherId ~= id and not removed[otherId] and not candidate.consumeUntil then
					local targetPos = candidate.targetPos or candidate.displayPos
					local delta = targetPos - sourcePos
					local distanceSquared = delta:Dot(delta)
					local reach = (candidate.targetRadius or candidate.radius or 0)
						+ (state.targetRadius or state.radius or 0)
					if distanceSquared <= reach * reach then
						local sameOwner = sourceOwner ~= nil
							and candidate.extra
							and candidate.extra.ownerUserId == sourceOwner
						local score = distanceSquared + (sameOwner and 0 or 100000000)
						if score < bestScore then
							bestScore = score
							bestTarget = candidate
						end
					end
				end
			end
		end

		if bestTarget then
			state.consumeTarget = bestTarget
			state.consumeStartedAt = now
			state.consumeUntil = now + duration
			state.consumeStartRadius = state.radius
			state.extrapolate = false
			state.isOwn = false
		else
			self.cellStates[id] = nil
			self.cellPool:release(id)
		end
	end
end

function Renderer:_applyRemovedEntities(gone)
	if typeof(gone) ~= "table" then
		return
	end

	removePackedIds(self.foodStates, gone.f, self.foodPool, 100000000)
	removePackedIds(self.virusStates, gone.v, self.virusPool, 300000000)
	removePackedIds(self.ejectedStates, gone.e, self.ejectedPool, 200000000)
	removePackedIds(self.spawnerStates, gone.s, self.spawnerPool, 350000000)
	self:_beginConsumedCellAnimations(gone.c, gone.m)
end

function Renderer:handleShopMessage(payload)
	if self.skinShop then
		self.skinShop:handleServerMessage(payload)
	end
end

function Renderer:_cellSpawnVisualOrigin(id: number, pos: Vector2, radius: number, extra)
	local renderConfig = Config.Render
	if renderConfig.SplitSpawnAnimationEnabled == false or typeof(extra) ~= "table" then
		return nil
	end

	local ownerUserId = extra.ownerUserId
	if ownerUserId == nil then
		return nil
	end

	local maxDistance = math.max(
		renderConfig.SplitSpawnAnimationMaxDistance or 900,
		radius * (renderConfig.SplitSpawnAnimationRadiusScale or 4.5)
	)
	local maxDistanceSquared = maxDistance * maxDistance
	local bestOrigin = nil
	local bestSource = nil
	local bestDistanceSquared = math.huge
	for otherId, state in self.cellStates do
		if otherId ~= id
			and state.confirmed == true
			and not isSplitSpawnAnimating(state)
			and state.extra
			and state.extra.ownerUserId == ownerUserId
		then
			local origin = state.displayPos or state.targetPos
			if origin then
				local delta = pos - origin
				local distanceSquared = delta:Dot(delta)
				if distanceSquared <= maxDistanceSquared and distanceSquared < bestDistanceSquared then
					bestDistanceSquared = distanceSquared
					bestOrigin = origin
					bestSource = state
				end
			end
		end
	end

	return bestOrigin, bestSource
end

function Renderer:_syncEntity(states, id: number, pos: Vector2, radius: number, mass: number?, color: Color3?, extra, serial: number, receivedAt: number, requireConfirm: boolean?, kind: string?)
	local state = states[id]
	local isStatic = requireConfirm == true
	if not state then
		local displayPos = pos
		local displayRadius = radius
		local spawnSource = nil
		local splitVisualBoost = nil
		if kind == "cell" then
			local origin
			origin, spawnSource = self:_cellSpawnVisualOrigin(id, pos, radius, extra)
			if origin then
				displayPos = origin
				displayRadius = math.max(radius * (Config.Render.SplitSpawnAnimationStartRadiusScale or 0.82), 1)
				local launchDelta = pos - origin
				local launchDir = if launchDelta.Magnitude > 0.001 then launchDelta.Unit else self.localMoveAim
				if not self.localFrozen then
					splitVisualBoost = launchDir * splitImpulseForMass(mass)
				end
			end
		end
		state = {
			displayPos = displayPos,
			targetPos = pos,
			velocity = Vector2.zero,
			radius = displayRadius,
			targetRadius = radius,
			receivedAt = receivedAt,
			seenCount = 1,
			requireConfirm = isStatic,
			confirmed = true,
			staticPos = if isStatic then pos else nil,
			spawnAnimatingUntil = if displayPos ~= pos then receivedAt + (Config.Render.SplitSpawnAnimationSeconds or 0.28) else nil,
			spawnAnimationStartedAt = if displayPos ~= pos then receivedAt else nil,
			spawnAnimationOrigin = if displayPos ~= pos then displayPos else nil,
			spawnAnimationSource = if displayPos ~= pos then spawnSource else nil,
			spawnAnimationOffset = if displayPos ~= pos then displayPos - pos else nil,
			spawnAnimationTargetPos = if displayPos ~= pos then pos else nil,
			spawnAnimationStartRadius = if displayPos ~= pos then displayRadius else nil,
			splitVisualBoost = splitVisualBoost,
		}
		states[id] = state
	else
		if isStatic then
			local tolerance = Config.Render.StaticPositionTolerance or 2
			local staticPos = state.staticPos or state.targetPos
			local delta = pos - staticPos
			if delta:Dot(delta) > tolerance * tolerance then
				if kind == "virus" then
					state.displayPos = pos
					state.targetPos = pos
					state.staticPos = pos
					state.velocity = Vector2.zero
					state.seenCount = 0
				elseif state.confirmed then
					pos = staticPos
				else
					state.displayPos = pos
					state.targetPos = pos
					state.staticPos = pos
					state.velocity = Vector2.zero
					state.seenCount = 0
				end
			else
				pos = staticPos
				state.staticPos = staticPos
				state.velocity = Vector2.zero
			end
		else
			local elapsed = math.max(receivedAt - (state.receivedAt or receivedAt), 1 / Config.Simulation.NetworkHz)
			state.velocity = (pos - state.targetPos) / elapsed
			if kind == "cell" and extra and extra.isOwn and state.splitVisualBoost then
				local moveDir, moveScale = movementVectorToTarget(self.localMoveTarget, state.targetPos, radius)
				local baseVelocity = moveDir * speedForMass(mass) * moveScale
				local observedBoost = state.velocity - baseVelocity
				local maxBoost = math.max(Config.Cell.SplitMaxBoost or 1650, 1)
				if observedBoost.Magnitude > maxBoost then
					observedBoost = observedBoost.Unit * maxBoost
				end
				state.splitVisualBoost = state.splitVisualBoost:Lerp(observedBoost, 0.55)
			end
		end
	end

	state.targetPos = pos
	state.targetRadius = radius
	state.mass = mass
	state.color = color
	state.extra = extra
	state.isOwn = extra and extra.isOwn == true
	if kind == "cell" and state.isOwn then
		state.snapshotAgeSeconds = (extra and extra.snapshotAgeSeconds) or 0
	elseif kind == "cell" then
		state.snapshotAgeSeconds = nil
	end
	state.extrapolate = not state.requireConfirm and not state.isOwn
	if state.requireConfirm then
		state.seenCount += 1
	elseif state.lastSeenSerial == serial - 1 then
		state.seenCount += 1
	else
		state.seenCount = 1
	end
	if not state.requireConfirm or state.confirmed or state.seenCount >= Config.Render.StaticConfirmSnapshots then
		state.confirmed = true
	end
	state.seen = serial
	state.lastSeenSerial = serial
	state.receivedAt = receivedAt
end

function Renderer:_visibleWithPadding(pos: Vector2, radius: number, paddingPixels: number): boolean
	local screen = self.camera:worldToScreen(pos)
	local screenRadius = radius * self.camera.zoom + paddingPixels
	local viewport = self.camera.viewport
	return screen.X + screenRadius >= 0
		and screen.X - screenRadius <= viewport.X
		and screen.Y + screenRadius >= 0
		and screen.Y - screenRadius <= viewport.Y
end

function Renderer:_removeStale(states, serial: number, missingGraceSnapshots: number?, retainWhileVisible: boolean?, pool, idPrefix: number?)
	local grace = missingGraceSnapshots or Config.Render.StaleGraceSnapshots
	local now = os.clock()
	for id, state in states do
		local missed = serial - (state.seen or 0)
		local stale = missed > grace
		if state.requireConfirm then
			local missedSeconds = now - (state.receivedAt or now)
			stale = missedSeconds > (Config.Render.StaticMissingGraceSeconds or 5)
			if stale and not state.confirmed then
				state.seenCount = 0
			end
		elseif missed > grace then
			stale = true
		end

		if stale and not (state.consumeUntil and state.consumeUntil > now) then
			local keepVisibleStatic = retainWhileVisible
				and state.confirmed
				and self:_visibleWithPadding(state.displayPos, state.radius, Config.Render.StaticCachePaddingPixels)
			if not keepVisibleStatic then
				states[id] = nil
				if pool then
					pool:release((idPrefix or 0) + id)
				end
			end
		end
	end
end

function Renderer:_removeMissingRemoteCells(serial: number, missingGraceSnapshots: number?)
	local grace = missingGraceSnapshots or Config.Render.RemoteCellMissingGraceSnapshots or Config.Render.DynamicMissingGraceSnapshots or Config.Render.StaleGraceSnapshots
	for id, state in self.cellStates do
		if state.confirmed == true and not state.isOwn and serial - (state.seen or 0) > grace then
			local stillVisible = self:_visibleWithPadding(state.displayPos, state.radius, Config.Render.StaticCachePaddingPixels or 0)
			if not stillVisible then
				self.cellStates[id] = nil
				self.cellPool:release(id)
			end
		end
	end
end

function Renderer:_thumbnailForUserId(userId: number, avatarDisplayMode: string?): string?
	local mode = normaliseAvatarDisplayMode(avatarDisplayMode)
	local thumbnailType = AVATAR_THUMBNAIL_TYPES[mode]
	if not thumbnailType then
		return nil
	end

	local cacheKey = tostring(userId) .. ":" .. mode
	local cached = self.thumbnailCache[cacheKey]
	if cached == false then
		return nil
	end
	if cached then
		return cached
	end

	self.thumbnailCache[cacheKey] = false
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, thumbnailType, Enum.ThumbnailSize.Size420x420)
		end)
		if ok then
			self.thumbnailCache[cacheKey] = image
		else
			self.thumbnailCache[cacheKey] = nil
		end
	end)

	return nil
end

function Renderer:setViewport(viewport: Vector2)
	self.root.Size = UDim2.fromScale(1, 1)
	self:_ensureGridLines(self:getViewportSize(viewport))
end

function Renderer:getViewportSize(fallback: Vector2?): Vector2
	local size = self.root.AbsoluteSize
	if size.X > 0 and size.Y > 0 then
		return size
	end
	return fallback or Vector2.new(1280, 720)
end

function Renderer:_ensureGridLines(viewport: Vector2, spacing: number?)
	local effectiveSpacing = math.max(spacing or 100, 1)
	local neededVertical = math.ceil(viewport.X / effectiveSpacing) + 3
	local neededHorizontal = math.ceil(viewport.Y / effectiveSpacing) + 3
	local needed = neededVertical + neededHorizontal

	while #self.gridLines < needed do
		local line = Instance.new("Frame")
		line.BorderSizePixel = 0
		line.BackgroundColor3 = Config.Render.GridColor
		line.BackgroundTransparency = 0.35
		line.ZIndex = 1
		line.Parent = self.grid
		self.gridLines[#self.gridLines + 1] = line
	end
end

function Renderer:_drawGrid()
	local viewport = self.camera.viewport
	local spacing = 100 * self.camera.zoom
	if spacing < 35 then
		spacing = 35
	end
	self:_ensureGridLines(viewport, spacing)

	local origin = self.camera:worldToScreen(Vector2.zero)
	local startX = origin.X % spacing
	local startY = origin.Y % spacing
	local lineIndex = 1

	for x = startX, viewport.X + spacing, spacing do
		local line = self.gridLines[lineIndex]
		if line then
			line.Visible = true
			line.Position = UDim2.fromOffset(x, 0)
			line.Size = UDim2.fromOffset(1, viewport.Y)
		end
		lineIndex += 1
	end

	for y = startY, viewport.Y + spacing, spacing do
		local line = self.gridLines[lineIndex]
		if line then
			line.Visible = true
			line.Position = UDim2.fromOffset(0, y)
			line.Size = UDim2.fromOffset(viewport.X, 1)
		end
		lineIndex += 1
	end

	for i = lineIndex, #self.gridLines do
		self.gridLines[i].Visible = false
	end
end

function Renderer:_drawWorldBorder()
	if not self.debugButton then
		self.worldBorder.Visible = false
		return
	end

	local worldSize = self.worldSize or Config.World.Size
	local maxScale = math.max(Config.DynamicWorld and Config.DynamicWorld.MaxScale or 1, 1)
	local maxWorldSize = Config.World.Size * maxScale
	local worldMin = (maxWorldSize - worldSize) * 0.5
	local worldMax = worldMin + worldSize
	local topLeft = self.camera:worldToScreen(worldMin)
	local bottomRight = self.camera:worldToScreen(worldMax)
	local minX = math.min(topLeft.X, bottomRight.X)
	local minY = math.min(topLeft.Y, bottomRight.Y)
	local width = math.max(math.abs(bottomRight.X - topLeft.X), 1)
	local height = math.max(math.abs(bottomRight.Y - topLeft.Y), 1)

	self.worldBorder.Visible = true
	self.worldBorder.Position = UDim2.fromOffset(math.floor(minX + 0.5), math.floor(minY + 0.5))
	self.worldBorder.Size = UDim2.fromOffset(math.floor(width + 0.5), math.floor(height + 0.5))
end

function Renderer:_clampToWorld(pos: Vector2, padding: number?): Vector2
	local worldSize = self.worldSize or Config.World.Size
	local maxScale = math.max(Config.DynamicWorld and Config.DynamicWorld.MaxScale or 1, 1)
	local maxWorldSize = Config.World.Size * maxScale
	local worldMin = (maxWorldSize - worldSize) * 0.5
	local worldMax = worldMin + worldSize
	local pad = math.max(padding or 0, 0)
	local padX = math.min(pad, worldSize.X * 0.5)
	local padY = math.min(pad, worldSize.Y * 0.5)
	return Vector2.new(
		math.clamp(pos.X, worldMin.X + padX, worldMax.X - padX),
		math.clamp(pos.Y, worldMin.Y + padY, worldMax.Y - padY)
	)
end

function Renderer:_barrierHalfSize(barrierState): Vector2
	local extra = barrierState.extra or {}
	return Vector2.new(
		(extra.width and extra.width * 0.5) or barrierState.radius,
		(extra.height and extra.height * 0.5) or barrierState.radius
	)
end

function Renderer:_circleBarrierOverlap(circlePos: Vector2, radius: number, barrierState)
	local halfSize = self:_barrierHalfSize(barrierState)
	local delta = circlePos - barrierState.displayPos
	local closest = Vector2.new(
		math.clamp(delta.X, -halfSize.X, halfSize.X),
		math.clamp(delta.Y, -halfSize.Y, halfSize.Y)
	)
	local nearest = barrierState.displayPos + closest
	local offset = circlePos - nearest
	local distanceSq = offset:Dot(offset)
	if distanceSq > radius * radius then
		return nil, nil
	end

	local distance = math.sqrt(math.max(distanceSq, 0))
	if distance > 0.001 then
		return offset / distance, radius - distance
	end

	local remainingX = halfSize.X + radius - math.abs(delta.X)
	local remainingY = halfSize.Y + radius - math.abs(delta.Y)
	if remainingX < remainingY then
		return Vector2.new(if delta.X >= 0 then 1 else -1, 0), remainingX
	end
	return Vector2.new(0, if delta.Y >= 0 then 1 else -1), remainingY
end

function Renderer:_resolveCircleAgainstBarriers(pos: Vector2, radius: number): Vector2
	local passes = math.max(Config.Render.OwnBarrierPredictionPasses or 1, 1)
	for _ = 1, passes do
		for _, barrierState in self.barrierStates do
			if barrierState.confirmed then
				local dir, penetration = self:_circleBarrierOverlap(pos, radius, barrierState)
				if dir and penetration and penetration > 0 then
					pos = self:_clampToWorld(pos + dir * penetration, radius)
				end
			end
		end
	end
	return pos
end

function Renderer:_moveAxisAgainstBarriers(pos: Vector2, axisDelta: Vector2, radius: number): Vector2
	if axisDelta.Magnitude <= 0 then
		return pos
	end

	local limit = 1
	local proposed = pos + axisDelta
	for _, barrierState in self.barrierStates do
		if barrierState.confirmed then
			local halfSize = self:_barrierHalfSize(barrierState)
			local expanded = Vector2.new(radius, radius)
			local min = barrierState.displayPos - halfSize - expanded
			local max = barrierState.displayPos + halfSize + expanded
			if axisDelta.X ~= 0 then
				if pos.Y >= min.Y and pos.Y <= max.Y then
					if axisDelta.X > 0 and pos.X <= min.X and proposed.X > min.X then
						limit = math.min(limit, math.max((min.X - pos.X) / axisDelta.X, 0))
					elseif axisDelta.X < 0 and pos.X >= max.X and proposed.X < max.X then
						limit = math.min(limit, math.max((max.X - pos.X) / axisDelta.X, 0))
					end
				end
			elseif axisDelta.Y ~= 0 then
				if pos.X >= min.X and pos.X <= max.X then
					if axisDelta.Y > 0 and pos.Y <= min.Y and proposed.Y > min.Y then
						limit = math.min(limit, math.max((min.Y - pos.Y) / axisDelta.Y, 0))
					elseif axisDelta.Y < 0 and pos.Y >= max.Y and proposed.Y < max.Y then
						limit = math.min(limit, math.max((max.Y - pos.Y) / axisDelta.Y, 0))
					end
				end
			end
		end
	end

	return self:_resolveCircleAgainstBarriers(pos + axisDelta * limit, radius)
end

function Renderer:_moveOwnCellWithBarrierCollision(pos: Vector2, delta: Vector2, radius: number): Vector2
	pos = self:_moveAxisAgainstBarriers(pos, Vector2.new(delta.X, 0), radius)
	pos = self:_moveAxisAgainstBarriers(pos, Vector2.new(0, delta.Y), radius)
	return self:_clampToWorld(pos, radius)
end

function Renderer:_resolveOwnBarrierPrediction()
	for _, cellState in self.cellStates do
		if cellState.isOwn and cellState.confirmed then
			cellState.displayPos = self:_resolveCircleAgainstBarriers(cellState.displayPos, cellState.radius)
		end
	end
end

function Renderer:_resolvePredictedEjectedAgainstBarriers(state)
	local pos = state.displayPos
	local velocity = state.velocity or Vector2.zero
	local radius = state.radius or Config.Ejected.Radius
	local bounceScale = math.max(Config.Ejected.WallBounceScale or 0, 0)
	for _, barrierState in self.barrierStates do
		if barrierState.confirmed then
			local dir, penetration = self:_circleBarrierOverlap(pos, radius, barrierState)
			if dir and penetration and penetration > 0 then
				pos = self:_clampToWorld(pos + dir * penetration, radius)
				local inwardSpeed = velocity:Dot(dir)
				if inwardSpeed < 0 then
					velocity -= dir * inwardSpeed * (1 + bounceScale)
				end
				velocity += (barrierState.velocity or Vector2.zero) * 0.55
			end
		end
	end

	state.displayPos = pos
	state.targetPos = pos
	state.velocity = velocity
end

function Renderer:_predictedEjectedTouchesCircle(state, target, padding: number?): boolean
	if not target.confirmed then
		return false
	end

	local radius = state.radius or Config.Ejected.Radius
	local targetRadius = target.radius or target.targetRadius or 0
	local touchDistance = radius + targetRadius + math.max(padding or 0, 0)
	local delta = state.displayPos - target.displayPos
	return delta:Dot(delta) <= touchDistance * touchDistance
end

function Renderer:_predictedEjectedWasConsumed(state, now: number): boolean
	for _, virusState in self.virusStates do
		if self:_predictedEjectedTouchesCircle(state, virusState, 0) then
			return true
		end
	end

	for _, spawnerState in self.spawnerStates do
		if self:_predictedEjectedTouchesCircle(state, spawnerState, 0) then
			return true
		end
	end

	for _, cellState in self.cellStates do
		if cellState.mass and cellState.mass >= (Config.Ejected.EatMinCellMass or 18) then
			if not cellState.isOwn or now >= (state.consumeAfter or 0) then
				-- Own cells consume pellets by center-in-disc (matches
				-- the server rule in ejectedTouchPickupDistance).
				-- Enemies still use edge-to-edge touch.
				if cellState.isOwn then
					local targetRadius = cellState.radius or cellState.targetRadius or 0
					local padding = Config.Ejected.TouchPickupPadding or 0
					local coverage = math.max(Config.Ejected.PickupCoverage or 1, 0)
					local pelletRadius = state.radius or Config.Ejected.Radius
					local touchDistance = math.max(targetRadius - pelletRadius * coverage + padding, 0)
					local delta = state.displayPos - cellState.displayPos
					if delta:Dot(delta) <= touchDistance * touchDistance then
						return true
					end
				elseif self:_predictedEjectedTouchesCircle(state, cellState, 0) then
					return true
				end
			end
		end
	end

	return false
end

function Renderer:_stepPredictedEjectedState(state, dt: number)
	local velocity = state.velocity or Vector2.zero
	local nextPos = state.displayPos + velocity * dt
	local clamped = self:_clampToWorld(nextPos, state.worldPadding or Config.Ejected.Radius)
	if clamped.X ~= nextPos.X then
		velocity = Vector2.new(-velocity.X * math.max(Config.Ejected.WallBounceScale or 0, 0), velocity.Y)
	end
	if clamped.Y ~= nextPos.Y then
		velocity = Vector2.new(velocity.X, -velocity.Y * math.max(Config.Ejected.WallBounceScale or 0, 0))
	end

	state.displayPos = clamped
	state.targetPos = clamped
	state.velocity = velocity * math.max(0, 1 - (Config.Ejected.DragPerSecond or 0) * dt)
	state.radius += ((state.targetRadius or state.radius) - state.radius) * math.clamp(dt * Config.Render.InterpolationSharpness, 0, 1)
	self:_resolvePredictedEjectedAgainstBarriers(state)
end

function Renderer:_projectOwnAuthoritativeTarget(state)
	local target = state.targetPos
	local maxLead = math.max(Config.Render.OwnCellPredictionMaxLeadSeconds or 0, 0)
	if maxLead > 0 then
		local receivedAge = math.max(os.clock() - (state.receivedAt or os.clock()), 0)
		local leadSeconds = math.clamp(
			(state.snapshotAgeSeconds or 0)
				+ receivedAge
				+ (Config.Render.OwnCellPredictionLeadExtraSeconds or 0),
			0,
			maxLead
		)
		if leadSeconds > 0 then
			local dir, speedScale = movementVectorToTarget(self.localMoveTarget, target, state.targetRadius or state.radius)
			if speedScale > 0 then
				local leadScale = math.max(Config.Render.OwnCellPredictionLeadScale or 1, 0)
				local delta = dir * speedForMass(state.mass) * speedScale * leadSeconds * leadScale
				target = self:_moveOwnCellWithBarrierCollision(target, delta, state.radius)
			end
		end
	end

	return self:_resolveCircleAgainstBarriers(self:_clampToWorld(target, state.radius), state.radius)
end

function Renderer:_stepSplitSpawnAnimation(state, targetPos: Vector2, dt: number): boolean
	local origin = state.spawnAnimationOrigin
	local untilTime = state.spawnAnimatingUntil
	if not origin or not untilTime then
		return false
	end

	local targetRadius = state.targetRadius or state.radius
	local now = os.clock()
	local startedAt = state.spawnAnimationStartedAt or (untilTime - (Config.Render.SplitSpawnAnimationSeconds or 0.52))
	local duration = math.max(Config.Render.SplitSpawnAnimationSeconds or (untilTime - startedAt), 0.001)
	local elapsed = math.max(now - startedAt, 0)
	if state.splitVisualBoost and not self.localFrozen then
		state.splitVisualBoost *= math.max(0, 1 - dt * (Config.Cell.SplitBoostDragPerSecond or 1.9))
	end

	local targetLead = math.clamp(
		now - (state.receivedAt or now),
		0,
		math.max(Config.Render.SplitSpawnAnimationTargetLeadSeconds or 0.12, 0)
	)
	local projectedTarget = targetPos + (state.velocity or Vector2.zero) * targetLead
	local targetAlpha = 1 - math.exp(-dt * (Config.Render.SplitSpawnAnimationTargetSharpness or 30))
	local smoothTarget = (state.spawnAnimationTargetPos or projectedTarget):Lerp(projectedTarget, targetAlpha)
	state.spawnAnimationTargetPos = smoothTarget

	local initialOffset = state.spawnAnimationOffset or (origin - smoothTarget)
	-- Smoothstep gives the launch zero acceleration jumps at both ends.
	-- The previous exponential decay moved most of the distance immediately,
	-- which made split children look like they snapped out of the parent.
	local progress = math.clamp(elapsed / duration, 0, 1)
	local easedProgress = progress * progress * (3 - 2 * progress)
	local visualOffset = initialOffset * (1 - easedProgress)
	local startRadius = state.spawnAnimationStartRadius or targetRadius
	state.radius = startRadius + (targetRadius - startRadius) * easedProgress
	local desiredPos = self:_resolveCircleAgainstBarriers(smoothTarget + visualOffset, state.radius)
	local smoothAlpha = 1 - math.exp(-dt * (Config.Render.SplitSpawnAnimationSharpness or 34))
	state.displayPos = self:_resolveCircleAgainstBarriers(state.displayPos:Lerp(desiredPos, smoothAlpha), state.radius)

	local endDistance = math.max(Config.Render.SplitSpawnAnimationEndDistance or 2, 0)
	local remainingDistance = (state.displayPos - desiredPos).Magnitude
	local maxOverrun = math.max(Config.Render.SplitSpawnAnimationMaxOverrunSeconds or 0.12, 0)
	if (elapsed >= duration and visualOffset.Magnitude <= endDistance and remainingDistance <= math.max(endDistance, 2))
		or elapsed >= duration + maxOverrun
	then
		state.spawnAnimatingUntil = nil
		state.spawnAnimationStartedAt = nil
		state.spawnAnimationOrigin = nil
		state.spawnAnimationSource = nil
		state.spawnAnimationOffset = nil
		state.spawnAnimationTargetPos = nil
		state.spawnAnimationStartRadius = nil
	end
	return true
end

function Renderer:_stepOwnCellPrediction(state, dt: number, interpolationAlpha: number)
	-- Frozen: DO NOT reconcile at all. Any reconciliation while frozen
	-- reads on screen as the cells "pulling in" toward the server
	-- position, which is exactly the jolt we're avoiding. Instead we
	-- freeze the display position where it was, and let unfreeze
	-- resume the normal reconcile so the cells ease back to server
	-- state gradually. The snapDistance guard below still triggers for
	-- huge desyncs (>snap threshold) so we never leave display stuck
	-- far from server if something goes wrong.
	local sharpness = Config.Render.OwnCellPredictionReconcileSharpness
		or Config.Render.InterpolationSharpness
	local reconcileAlpha = 1 - math.exp(-dt * sharpness)
	local authoritativeTarget = self:_projectOwnAuthoritativeTarget(state)
	if self:_stepSplitSpawnAnimation(state, authoritativeTarget, dt) then
		return
	end

	local dir, speedScale = movementVectorToTarget(self.localMoveTarget, state.displayPos, state.radius)
	if self.localFrozen then
		-- Frozen: don't advance predicted position toward the mouse.
		-- We also skip normal reconcile below so displayPos truly holds.
		speedScale = 0
	end
	local predictedVelocity = dir * speedForMass(state.mass) * speedScale
	if state.splitVisualBoost and not self.localFrozen then
		state.splitVisualBoost *= math.max(0, 1 - dt * (Config.Cell.SplitBoostDragPerSecond or 1.9))
		if state.splitVisualBoost.Magnitude < 1 then
			state.splitVisualBoost = nil
		else
			predictedVelocity += state.splitVisualBoost
		end
	end
	if predictedVelocity.Magnitude > 0.001 then
		local delta = predictedVelocity * dt
		state.displayPos = self:_moveOwnCellWithBarrierCollision(state.displayPos, delta, state.radius)
	end

	local error = authoritativeTarget - state.displayPos
	local errorDistance = error.Magnitude
	local reconcileDeadband = math.max(
		Config.Render.OwnCellPredictionReconcileDeadband or 0,
		state.radius * (Config.Render.OwnCellPredictionReconcileDeadbandRadiusScale or 0)
	)
	local snapDistance = math.max(Config.Render.OwnCellPredictionSnapDistance or 320, reconcileDeadband * 2)
	local spawnAnimating = (state.spawnAnimatingUntil or 0) > os.clock()
	if errorDistance > snapDistance and not spawnAnimating then
		local reconciled = state.displayPos:Lerp(authoritativeTarget, math.max(reconcileAlpha, 0.65))
		state.displayPos = self:_resolveCircleAgainstBarriers(reconciled, state.radius)
	elseif not self.localFrozen and errorDistance > reconcileDeadband then
		local correctionTarget = state.displayPos + error.Unit * (errorDistance - reconcileDeadband)
		local reconciled = state.displayPos:Lerp(correctionTarget, reconcileAlpha)
		state.displayPos = self:_resolveCircleAgainstBarriers(reconciled, state.radius)
	end
	state.radius += (state.targetRadius - state.radius) * interpolationAlpha
	state.displayPos = self:_resolveCircleAgainstBarriers(state.displayPos, state.radius)
end

function Renderer:_stepEntityStates(states, dt: number)
	local alpha = 1 - math.exp(-dt * Config.Render.InterpolationSharpness)
	local now = os.clock()
	for id, state in states do
		if state.consumeUntil then
			local duration = math.max(state.consumeUntil - (state.consumeStartedAt or now), 0.01)
			local progress = math.clamp((now - (state.consumeStartedAt or now)) / duration, 0, 1)
			local target = state.consumeTarget
			local targetPos = target and (target.displayPos or target.targetPos) or state.targetPos
			local consumeAlpha = 1 - math.exp(-dt * (Config.Render.ConsumeAnimationSharpness or 18))
			state.displayPos = state.displayPos:Lerp(targetPos, consumeAlpha)
			state.radius = math.max((state.consumeStartRadius or state.radius) * (1 - progress), 0)
			if now >= state.consumeUntil then
				states[id] = nil
				self.cellPool:release(id)
			end
			continue
		end
		if state.predicted == true and state.expiresAt and now >= state.expiresAt then
			states[id] = nil
			self.ejectedPool:release(200000000 + id)
			continue
		end
		if state.predicted == true then
			self:_stepPredictedEjectedState(state, dt)
			if self:_predictedEjectedWasConsumed(state, now) then
				states[id] = nil
				self.ejectedPool:release(200000000 + id)
			end
			continue
		end
		if Config.Render.OwnCellPredictionEnabled and state.isOwn then
			self:_stepOwnCellPrediction(state, dt, alpha)
			continue
		end
		local projectedTime = if state.extrapolate then math.min(now - (state.receivedAt or now), Config.Render.ExtrapolationSeconds) else 0
		local projectedTarget = state.targetPos + (state.velocity or Vector2.zero) * projectedTime
		if state.worldPadding then
			projectedTarget = self:_clampToWorld(projectedTarget, state.worldPadding)
		end
		if self:_stepSplitSpawnAnimation(state, projectedTarget, dt) then
			continue
		end
		state.displayPos = state.displayPos:Lerp(projectedTarget, alpha)
		state.radius += (state.targetRadius - state.radius) * alpha
	end
end

function Renderer:_resolveEjectedVisualCollisions(dt: number)
	if Config.Render.EjectedVisualCollisionEnabled == false then
		for _, state in self.ejectedStates do
			state.renderPos = nil
			state.ejectedVisualOffset = nil
		end
		return
	end

	local entries = self.ejectedCollisionScratch
	local entryCount = 0
	for _, state in self.ejectedStates do
		state.renderPos = nil
	end

	local maxStates = math.max(Config.Render.EjectedVisualCollisionMaxStates or 140, 0)
	if maxStates <= 1 then
		return
	end

	for id, state in self.ejectedStates do
		if state.confirmed == true and state.displayPos and state.radius then
			entryCount += 1
			local entry = entries[entryCount] or {}
			entry.id = id
			entry.state = state
			entry.basePos = state.displayPos
			entry.solvePos = state.displayPos + (state.ejectedVisualOffset or Vector2.zero)
			entries[entryCount] = entry
		end
	end
	for index = entryCount + 1, #entries do
		entries[index] = nil
	end

	if entryCount < 2 then
		for index = 1, entryCount do
			local state = entries[index].state
			local currentOffset = state.ejectedVisualOffset or Vector2.zero
			state.ejectedVisualOffset = currentOffset:Lerp(Vector2.zero, math.clamp(dt * 12, 0, 1))
			state.renderPos = state.displayPos + state.ejectedVisualOffset
		end
		return
	end

	table.sort(entries, function(a, b)
		return a.id < b.id
	end)
	if entryCount > maxStates then
		for index = maxStates + 1, entryCount do
			entries[index].state.ejectedVisualOffset = nil
			entries[index] = nil
		end
		entryCount = maxStates
	end

	local passes = math.max(Config.Render.EjectedVisualCollisionPasses or 2, 1)
	local scale = math.max(Config.Render.EjectedVisualCollisionScale or 1, 1)
	local strength = math.clamp(Config.Render.EjectedVisualCollisionStrength or 1, 0, 1)
	local sharpness = math.max(Config.Render.EjectedVisualCollisionSharpness or 20, 0)
	local alpha = 1 - math.exp(-dt * sharpness)
	local maxPush = math.max(Config.Render.EjectedVisualCollisionMaxPush or Config.Ejected.Radius * 2, 0)
	local maxOffset = math.max(Config.Render.EjectedVisualCollisionMaxOffset or Config.Ejected.Radius * 3, 0)

	for _ = 1, passes do
		for i = 1, entryCount - 1 do
			local aEntry = entries[i]
			local a = aEntry.state
			for j = i + 1, entryCount do
				local bEntry = entries[j]
				local b = bEntry.state
				local minDist = ((a.radius or Config.Ejected.Radius) + (b.radius or Config.Ejected.Radius)) * scale
				local delta = bEntry.solvePos - aEntry.solvePos
				local distanceSquared = delta:Dot(delta)
				if distanceSquared >= minDist * minDist then
					continue
				end

				local distance = math.sqrt(math.max(distanceSquared, 0))
				local fallbackAngle = ((aEntry.id or i) * 47 + (bEntry.id or j) * 83) % 628 / 100
				local dir = if distance > 0.001 then delta / distance else Vector2.new(math.cos(fallbackAngle), math.sin(fallbackAngle))
				local push = math.min((minDist - distance) * strength, maxPush)
				local offset = dir * (push * 0.5)
				aEntry.solvePos = self:_clampToWorld(aEntry.solvePos - offset, a.radius or Config.Ejected.Radius)
				bEntry.solvePos = self:_clampToWorld(bEntry.solvePos + offset, b.radius or Config.Ejected.Radius)
			end
		end
	end

	for index = 1, entryCount do
		local entry = entries[index]
		local state = entry.state
		local desiredOffset = entry.solvePos - entry.basePos
		local offsetMagnitude = desiredOffset.Magnitude
		if maxOffset > 0 and offsetMagnitude > maxOffset then
			desiredOffset = desiredOffset / offsetMagnitude * maxOffset
		end

		local currentOffset = state.ejectedVisualOffset or Vector2.zero
		local visualOffset = currentOffset:Lerp(desiredOffset, alpha)
		if visualOffset:Dot(visualOffset) < 0.01 then
			visualOffset = Vector2.zero
		end
		state.ejectedVisualOffset = visualOffset
		state.renderPos = self:_clampToWorld(state.displayPos + visualOffset, state.radius or Config.Ejected.Radius)
	end
end

function Renderer:_updatePredictedOwnCenter()
	local weighted = Vector2.zero
	local totalMass = 0

	for _, state in self.cellStates do
		if state.isOwn and state.confirmed and state.mass then
			weighted += state.displayPos * state.mass
			totalMass += state.mass
		end
	end

	self.predictedOwnCenter = if totalMass > 0 then weighted / totalMass else nil
	if self.camera and self.camera.setLocalPredictionCenter then
		self.camera:setLocalPredictionCenter(self.predictedOwnCenter)
	end
end

function Renderer:_ownCellsForVisualSeparation(now: number)
	local cells = self.ownSeparationScratch
	for i = 1, #cells do
		cells[i] = nil
	end

	for _, state in self.cellStates do
		if state.isOwn
			and state.confirmed
			and (state.visualSeparateUntil or 0) > now
			and not isSplitSpawnAnimating(state, now)
		then
			cells[#cells + 1] = state
		end
	end
	return cells
end

function Renderer:_resolveOwnCellVisualSeparation()
	-- Frozen: skip visual separation so freeze-split cells stay bunched at
	-- the same spot instead of scattering. Server already skips its own
	-- push resolution while frozen; this mirrors it on the client.
	if self.localFrozen then
		return
	end
	local now = os.clock()
	local cells = self:_ownCellsForVisualSeparation(now)
	if #cells < 2 then
		return
	end

	local passes = math.max(Config.Render.OwnCellVisualSeparationPasses or 1, 1)
	local strength = math.clamp(Config.Render.OwnCellVisualSeparationStrength or 0.85, 0, 1)
	local scale = math.max(Config.Render.OwnCellVisualSeparationScale or 1, 1)

	-- Unfreeze grace: from the instant we unfreeze, ramp strength and
	-- passes up smoothly from ~0 to full over a long window that
	-- matches / exceeds the server-side ramp. Without this, the
	-- resolver runs at full strength on frame 1 after unfreeze and
	-- pops overlapping cells apart even though the server is still
	-- easing them out slowly — the "they explode" jolt.
	local graceStart = self.unfreezeGraceStartedAt
	if graceStart and graceStart > 0 then
		local freezeCfg = Config.Freeze or {}
		local graceSeconds = math.max(freezeCfg.UnfreezeGraceSeconds or 0, 0.0001)
		-- Client window matches server grace 1:1 so residual overlap
		-- is squeezed out at the same rate the server is resolving.
		-- Longer than that just prevents cells from separating.
		local windowSeconds = graceSeconds
		local elapsed = now - graceStart
		if elapsed >= windowSeconds then
			self.unfreezeGraceStartedAt = nil
		else
			local exponent = math.max(freezeCfg.UnfreezeGraceCurveExponent or 2.5, 0.1)
			local progress = math.clamp(elapsed / windowSeconds, 0, 1) ^ exponent
			local baseStrength = math.clamp(freezeCfg.UnfreezeGraceStrength or 0.01, 0, 1)
			strength = strength * (baseStrength + (1 - baseStrength) * progress)
			if progress < 0.35 then
				passes = 1
			end
		end
	end

	-- Additional per-pass push cap: even at full ramp we cap how far a
	-- pair of cells can push apart per frame, so a huge stack doesn't
	-- compound into a snap. Cap widens linearly toward "no cap" as
	-- grace decays; base value is small so early frames barely move.
	local freezeCfg = Config.Freeze or {}
	local maxOverlapPerPass = math.max(freezeCfg.UnfreezeMaxOverlapPerPass or 1.2, 0.05)
	local overlapCap
	if graceStart and graceStart > 0 then
		local graceSeconds = math.max(freezeCfg.UnfreezeGraceSeconds or 0, 0.0001)
		local windowSeconds = graceSeconds
		local progress = math.clamp((now - graceStart) / windowSeconds, 0, 1)
		overlapCap = maxOverlapPerPass * (1 + progress * 8)
	end
	for _ = 1, passes do
		for i = 1, #cells - 1 do
			local a = cells[i]
			for j = i + 1, #cells do
				local b = cells[j]
				local delta = b.displayPos - a.displayPos
				local dist = delta.Magnitude
				local minDist = (a.radius + b.radius) * scale
				if dist < minDist then
					local dir = if dist > 0.001 then delta / dist else Vector2.new(1, 0)
					local overlap = (minDist - dist) * strength
					if overlapCap then
						overlap = math.min(overlap, overlapCap)
					end
					local aMass = math.max(a.mass or a.radius, 1)
					local bMass = math.max(b.mass or b.radius, 1)
					local totalMass = aMass + bMass
					a.displayPos = self:_clampToWorld(a.displayPos - dir * overlap * (bMass / totalMass), a.radius)
					b.displayPos = self:_clampToWorld(b.displayPos + dir * overlap * (aMass / totalMass), b.radius)
				end
			end
		end
	end
end

function Renderer:step(dt: number?)
	dt = dt or 1 / 60
	self:_stepEntityStates(self.foodStates, dt)
	self:_stepEntityStates(self.ejectedStates, dt)
	self:_resolveEjectedVisualCollisions(dt)
	self:_stepEntityStates(self.virusStates, dt)
	self:_stepEntityStates(self.spawnerStates, dt)
	self:_stepEntityStates(self.barrierStates, dt)
	self:_stepEntityStates(self.cellStates, dt)
	self:_resolveOwnBarrierPrediction()
	self:_resolveOwnCellVisualSeparation()
	self:_resolveOwnBarrierPrediction()
	self:_updatePredictedOwnCenter()
end

function Renderer:_stateIsDrawable(state): boolean
	return state.confirmed == true
end

function Renderer:_ownCellEatCandidates()
	local candidates = self.ownEatCandidatesScratch
	for i = 1, #candidates do
		candidates[i] = nil
	end
	for _, cell in self.cellStates do
		if cell.isOwn and cell.confirmed and cell.mass then
			candidates[#candidates + 1] = cell
		end
	end
	return candidates
end

function Renderer:_ownCellCanEatFromList(candidates, state, minMass: number, overlapScale: number?): boolean
	for _, cell in candidates do
		if cell.mass >= minMass then
			local eatDistance = cell.radius - state.radius * (overlapScale or Config.Cell.EatOverlap)
			if eatDistance > 0 then
				local delta = cell.displayPos - state.displayPos
				if delta:Dot(delta) <= eatDistance * eatDistance then
					return true
				end
			end
		end
	end
	return false
end

function Renderer:_ownCellCanTouchPickupFromList(candidates, state, minMass: number, padding: number?): boolean
	local pickupRadius = state.radius or state.targetRadius or 0
	for _, cell in candidates do
		if cell.mass >= minMass then
			local coverage = math.max(Config.Ejected.PickupCoverage or 1, 0)
			local touchDistance = math.max(cell.radius - pickupRadius * coverage + (padding or 0), 0)
			local delta = cell.displayPos - state.displayPos
			if delta:Dot(delta) <= touchDistance * touchDistance then
				return true
			end
		end
	end
	return false
end

function Renderer:_drawSimpleStates(pool, idPrefix: number, states, color: Color3, shouldSuppress, fixedZIndex: number?)
	for id, state in states do
		local drawPos = state.renderPos or state.displayPos
		if self:_stateIsDrawable(state)
			and not (shouldSuppress and shouldSuppress(state))
			and self.camera:visible(drawPos, state.radius)
		then
			local screen = self.camera:worldToScreen(drawPos)
			local screenRadius = math.max(state.radius * self.camera.zoom, Config.Render.MinCirclePixels)
			local drawOptions = state.simpleDrawOptions or {}
			state.simpleDrawOptions = drawOptions
			drawOptions.zIndex = fixedZIndex or zIndexForRadius(state.radius)
			pool:draw(idPrefix + id, screen, screenRadius, state.color or color, drawOptions)
		end
	end
end

function Renderer:_updateLabel(label: TextLabel, cacheKey: string, text: string)
	if self[cacheKey] ~= text then
		self[cacheKey] = text
		label.Text = text
	end
end

function Renderer:_updateHud(dt: number)
	local refreshInterval = 1 / math.max(Config.Render.HudRefreshHz or 8, 1)
	self.hudAccumulator += dt
	if self.hudAccumulator < refreshInterval then
		return
	end
	self.hudAccumulator = 0

	self:_updateLabel(self.scoreLabel, "lastScoreText", self.localization:scoreText(math.floor(self.score + 0.5)))
	local pingValue = nil
	if self.displayPingMs then
		pingValue = math.floor(self.displayPingMs + 0.5)
	end
	self:_updateLabel(self.pingLabel, "lastPingText", self.localization:pingText(pingValue))
	self:_updateLabel(self.coinLabel, "lastCoinsText", self.localization:coinsText(math.floor(self.coins + 0.5)))
	self:_updateLabel(self.levelBadgeText, "lastLevelBadgeText", self.localization:levelText(math.floor(self.level + 0.5)))

	local xpPercent = if self.nextLevelXp > 0 then math.clamp(self.accountXp / self.nextLevelXp, 0, 1) else 1
	local visualXpPercent = xpPercent
	if visualXpPercent > 0 and visualXpPercent < 0.08 then
		visualXpPercent = 0.08
	end
	if self.lastLevelFill ~= visualXpPercent then
		self.lastLevelFill = visualXpPercent
		self.levelFill.Size = UDim2.fromScale(visualXpPercent, 1)
	end
	self:_updateLabel(self.levelText, "lastLevelText", ("%d%%"):format(math.floor(xpPercent * 100 + 0.5)))

	if self.debugButton then
		local side = math.floor((self.worldSize and self.worldSize.X or Config.World.Size.X) + 0.5)
		local text = self.localization:mapButtonText(self.debugWorldResizeEnabled, side)
		if self.lastDebugText ~= text then
			self.lastDebugText = text
			self.debugButton.Text = text
		end
	end
end

function Renderer:render(dt: number?)
	dt = dt or 1 / 60
	self:_drawGrid()
	self:_drawWorldBorder()
	local ownEatCandidates = self:_ownCellEatCandidates()

	self.foodPool:begin()
	self.ejectedPool:begin()
	self.virusPool:begin()
	self.spawnerPool:begin()
	self.barrierPool:begin()
	self.cellPool:begin()

	self:_drawSimpleStates(self.foodPool, 100000000, self.foodStates, Config.Render.FoodColor, nil, Config.Render.FoodZIndex or 3)
	local now = os.clock()
	self:_drawSimpleStates(self.ejectedPool, 200000000, self.ejectedStates, Config.Render.EjectedColor, function(state)
		return state.predicted == true
			and now >= (state.consumeAfter or 0)
			and self:_ownCellCanTouchPickupFromList(
				ownEatCandidates,
				state,
				Config.Ejected.EatMinCellMass or 18,
				Config.Ejected.TouchPickupPadding or 0
			)
	end, Config.Render.EjectedZIndex or 4)
	for id, state in self.virusStates do
		if self:_stateIsDrawable(state)
			and self.camera:visible(state.displayPos, state.radius)
		then
			local screen = self.camera:worldToScreen(state.displayPos)
			local screenRadius = math.max(state.radius * self.camera.zoom, Config.Render.MinCirclePixels)
			self.virusDrawOptions.zIndex = math.max(zIndexForRadius(state.radius), Config.Render.ObjectMinZIndex or 6)
			self.virusPool:draw(300000000 + id, screen, screenRadius, Config.Render.VirusColor, self.virusDrawOptions)
		end
	end
	for id, state in self.spawnerStates do
		if self:_stateIsDrawable(state) and self.camera:visible(state.displayPos, state.radius) then
			local screen = self.camera:worldToScreen(state.displayPos)
			local screenRadius = math.max(state.radius * self.camera.zoom, Config.Render.MinCirclePixels)
			self.spawnerDrawOptions.zIndex = math.max(zIndexForRadius(state.radius), Config.Render.ObjectMinZIndex or 6)
			self.spawnerPool:draw(350000000 + id, screen, screenRadius, Config.Render.SpawnerColor, self.spawnerDrawOptions)
		end
	end
	for id, state in self.barrierStates do
		local extra = state.extra or {}
		local halfWidth = extra.width and extra.width * 0.5 or state.radius
		local halfHeight = extra.height and extra.height * 0.5 or state.radius
		if self:_stateIsDrawable(state) and self.camera:visible(state.displayPos, math.max(halfWidth, halfHeight)) then
			local screen = self.camera:worldToScreen(state.displayPos)
			local drawOptions = self.barrierDrawOptions
			drawOptions.width = halfWidth * 2 * self.camera.zoom
			drawOptions.height = halfHeight * 2 * self.camera.zoom
			drawOptions.zIndex = math.max(zIndexForRadius(math.max(halfWidth, halfHeight)), Config.Render.ObjectMinZIndex or 6)
			self.barrierPool:draw(450000000 + id, screen, 0, Config.Render.BarrierColor, drawOptions)
		end
	end

	for id, state in self.cellStates do
		if self.camera:visible(state.displayPos, state.radius) then
			local screen = self.camera:worldToScreen(state.displayPos)
			local screenRadius = math.max(state.radius * self.camera.zoom, Config.Render.MinCirclePixels)
			local extra = state.extra or {}
			local meta = self.playerMeta[extra.ownerUserId]
			local skinId = (meta and meta.equippedSkinId) or (meta and meta.locationSkinId) or extra.skinId
			local skin = SkinData.ById[skinId]
			local skinImage = skin and skin.image or (meta and meta.skinImage) or extra.skinImage
			local overlayAvatar = meta ~= nil and meta.overlayAvatar == true
			local avatarDisplayMode = normaliseAvatarDisplayMode(meta and meta.avatarDisplayMode)
			local avatarImage = extra.ownerUserId and self:_thumbnailForUserId(extra.ownerUserId, avatarDisplayMode) or nil
			local avatarScaleType = if avatarDisplayMode == "face" then Enum.ScaleType.Crop else Enum.ScaleType.Fit
			local name = (meta and meta.name) or extra.name or "Player"
			local drawOptions = state.drawOptions or {}
			state.drawOptions = drawOptions
			drawOptions.name = name
			drawOptions.score = state.mass and displayScore(state.mass) or ""
			drawOptions.baseImage = nil
			drawOptions.baseImageColor = nil
			drawOptions.baseImageRectOffset = nil
			drawOptions.baseImageRectSize = nil
			drawOptions.image = nil
			drawOptions.imageColor = nil
			drawOptions.imageScaleType = nil
			drawOptions.overlayScale = nil
			-- Cells: z-index scales linearly with radius so a big cell is
			-- ALWAYS painted on top of a small one (both own and enemy).
			-- Cap high enough that other UI stays above (HUD is 100+).
			drawOptions.zIndex = math.max(
				math.floor(state.radius),
				Config.Render.CellMinZIndex or 7
			)
			if skinImage and overlayAvatar then
				drawOptions.baseImage = skinImage
				drawOptions.baseImageRectOffset = skin and skin.imageRectOffset
				drawOptions.baseImageRectSize = skin and skin.imageRectSize
				drawOptions.image = avatarImage
				drawOptions.imageScaleType = avatarScaleType
				drawOptions.overlayScale = 1
			elseif skinImage then
				drawOptions.baseImage = skinImage
				drawOptions.baseImageRectOffset = skin and skin.imageRectOffset
				drawOptions.baseImageRectSize = skin and skin.imageRectSize
			else
				drawOptions.image = avatarImage
				drawOptions.imageScaleType = avatarScaleType
			end
			self.cellPool:draw(id, screen, screenRadius, state.color or Color3.fromRGB(80, 150, 240), drawOptions)
		end
	end

	self:_updateHud(dt)

	self.foodPool:finish()
	self.ejectedPool:finish()
	self.virusPool:finish()
	self.spawnerPool:finish()
	self.barrierPool:finish()
	self.cellPool:finish()
end

return Renderer
