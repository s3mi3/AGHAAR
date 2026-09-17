local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local LocalizationService = game:GetService("LocalizationService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SkinData = require(Shared:WaitForChild("SkinData"))
local SpatialHash = require(Shared:WaitForChild("SpatialHash"))
local Vec2 = require(Shared:WaitForChild("Vec2"))

local GameService = {}
GameService.__index = GameService

local PLAYER_INFO_STORE = (Config.Persistence and Config.Persistence.PlayerInfoDataStoreName) or "PlayerInfo"
local AUTOSAVE_SECONDS = 30
local LIFE_XP_ATTRIBUTE_HZ = 4
local DEFAULT_AVATAR_DISPLAY_MODE = "face"
local VALID_AVATAR_DISPLAY_MODES = {
	face = true,
	bust = true,
	fullBody = true,
	hidden = true,
}
local XP_REQUIREMENT_ANCHORS = {
	{ level = 1, required = 35 },
	{ level = 5, required = 1000 },
	{ level = 10, required = 5000 },
	{ level = 20, required = 20500 },
	{ level = 50, required = 127000 },
	{ level = 75, required = 284500 },
	{ level = 99, required = 494500 },
}

local function playerInfoKey(userId: number): string
	return tostring(userId)
end

local function countrySkinIdForRegion(regionCode: any): string?
	if typeof(regionCode) ~= "string" or regionCode == "" then
		return nil
	end

	local skinId = SkinData.CountrySkinByRegion[string.upper(regionCode)]
	if skinId and SkinData.ById[skinId] then
		return skinId
	end

	return nil
end

local function fetchCountrySkinIdForPlayer(player: Player): string?
	local ok, regionCode = pcall(function()
		return LocalizationService:GetCountryRegionForPlayerAsync(player)
	end)
	if not ok then
		return nil
	end

	return countrySkinIdForRegion(regionCode)
end

local function massToRadius(mass: number): number
	return math.sqrt(math.max(mass, 1)) * Config.Cell.RadiusScale
end

-- Mass-scaled merge cooldown. Formula per Config.Cell comments:
--   clamp(RecombineMinSeconds + (mass / RecombineScaleMass) * RecombinePerScaleMass,
--         RecombineMinSeconds, RecombineMaxSeconds)
-- Small cells re-merge quickly (~1.5s), the biggest cells wait ~5s.
-- Falls back to legacy Config.Cell.RecombineSeconds if the new keys are
-- missing so old configs still work.
local function recombineDelayForMass(mass: number): number
	local cfg = Config.Cell
	local minSec = cfg.RecombineMinSeconds
	local maxSec = cfg.RecombineMaxSeconds
	local scaleMass = cfg.RecombineScaleMass
	local perScale = cfg.RecombinePerScaleMass
	if not (minSec and maxSec and scaleMass and perScale) then
		return cfg.RecombineSeconds or 12
	end
	local scaled = minSec + (math.max(mass, 0) / math.max(scaleMass, 1)) * perScale
	if scaled < minSec then
		scaled = minSec
	end
	if scaled > maxSec then
		scaled = maxSec
	end
	return scaled
end

local function spawnerRadiusForMass(mass: number): number
	return Config.Spawner.BaseRadius * math.sqrt(math.max(mass, 1) / Config.Spawner.BaseMass)
end

local function spawnerMaxMass(): number
	local maxRadius = math.max(Config.Spawner.MaxRadius or Config.Spawner.BaseRadius, Config.Spawner.BaseRadius)
	return Config.Spawner.BaseMass * (maxRadius / Config.Spawner.BaseRadius) ^ 2
end

local function randomPlayerColor(userId: number): Color3
	local seed = (userId % 1000000) + math.floor(os.clock() * 1000)
	local rng = Random.new(seed)
	return Color3.fromHSV(rng:NextNumber(), rng:NextNumber(0.62, 0.9), rng:NextNumber(0.78, 1))
end

local function round(value: number, precision: number): number
	return math.floor(value / precision + 0.5) * precision
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

local function canUseWorldResizeDebug(player: Player): boolean
	return Config.Debug
		and Config.Debug.WorldResizeEnabled == true
		and userIdIsAllowed(player.UserId, Config.Debug.WorldResizeTesterUserIds)
end

local function safeAxisPadding(size: number, padding: number?): number
	return math.min(math.max(padding or 0, 0), size * 0.5)
end

local function approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

local function colorToPayload(color: Color3)
	return {
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5),
	}
end

local function packedColorValue(payload): number
	if typeof(payload) ~= "table" then
		return 0
	end
	local r = math.clamp(math.floor((payload[1] or 0) + 0.5), 0, 255)
	local g = math.clamp(math.floor((payload[2] or 0) + 0.5), 0, 255)
	local b = math.clamp(math.floor((payload[3] or 0) + 0.5), 0, 255)
	return r * 65536 + g * 256 + b
end

local function insertNearestCandidate(list, id: number, distanceSquared: number, maxCount: number)
	if maxCount <= 0 then
		return
	end

	local index
	local count = #list
	if count < maxCount then
		index = count + 1
		list[index] = {
			id = id,
			distanceSquared = distanceSquared,
		}
	elseif distanceSquared < list[count].distanceSquared then
		index = count
		list[index].id = id
		list[index].distanceSquared = distanceSquared
	else
		return
	end

	while index > 1 and list[index].distanceSquared < list[index - 1].distanceSquared do
		list[index], list[index - 1] = list[index - 1], list[index]
		index -= 1
	end
end

local function randomFoodColorIndex(): number
	return math.random(1, #Config.Food.Colors)
end

local function canEatCircleAt(eater, target, ratio: number, eaterMass: number, eaterRadius: number, overlapScale: number): boolean
	if eaterMass < target.mass * ratio then
		return false
	end

	local eatDistance = eaterRadius - target.radius * overlapScale
	if eatDistance <= 0 then
		return false
	end

	return Vec2.distanceSquared(eater.pos, target.pos) <= eatDistance * eatDistance
end

local function canEatCircle(eater, target, ratio: number): boolean
	return canEatCircleAt(eater, target, ratio, eater.mass, eater.radius, Config.Cell.EatOverlap)
end

local function meetsRadiusRatio(eaterRadius: number, targetRadius: number, ratio: number?): boolean
	return eaterRadius >= targetRadius * math.max(ratio or 1, 1)
end

local function canConsumeByRadiusAt(eaterPos: Vector2, eaterRadius: number, target, ratio: number?, overlapScale: number?): boolean
	if not meetsRadiusRatio(eaterRadius, target.radius, ratio) then
		return false
	end

	local eatDistance = eaterRadius - target.radius * (overlapScale or Config.Cell.EatOverlap)
	if eatDistance <= 0 then
		return false
	end

	return Vec2.distanceSquared(eaterPos, target.pos) <= eatDistance * eatDistance
end

local function canConsumeByRadius(eater, target, ratio: number?, overlapScale: number?): boolean
	return canConsumeByRadiusAt(eater.pos, eater.radius, target, ratio, overlapScale)
end

local function canEatVirusAt(eater, virus, eaterMass: number, eaterRadius: number): boolean
	local ratio = 1
	return canConsumeByRadiusAt(eater.pos, eaterRadius, virus, ratio, Config.Cell.EatOverlap)
end

local function canEatVirus(eater, virus): boolean
	return canEatVirusAt(eater, virus, eater.mass, eater.radius)
end

local function canCollectPickup(collector, pickup, minMass: number?, overlapScale: number?): boolean
	if minMass and collector.mass < minMass then
		return false
	end

	local collectDistance = collector.radius + pickup.radius * (overlapScale or 1)
	return Vec2.distanceSquared(collector.pos, pickup.pos) <= collectDistance * collectDistance
end

local function canCoverPickup(collector, pickup, minMass: number?, coverageScale: number?): boolean
	if minMass and collector.mass < minMass then
		return false
	end

	local collectDistance = collector.radius - pickup.radius * (coverageScale or 1)
	return collectDistance > 0
		and Vec2.distanceSquared(collector.pos, pickup.pos) <= collectDistance * collectDistance
end

local function ejectedTouchPickupDistance(collector, ejected): number
	-- Do not remove a pellet until its full visual circle is covered.
	-- Padding remains available as a small inward/outward tuning offset.
	local coverage = math.max(Config.Ejected.PickupCoverage or 1, 0)
	local padding = Config.Ejected.TouchPickupPadding or 0
	return math.max(collector.radius - ejected.radius * coverage + padding, 0)
end

local function canCollectEjected(collector, ejected): boolean
	local minMass = Config.Ejected.EatMinCellMass or 18
	if minMass and collector.mass < minMass then
		return false
	end

	local collectDistance = ejectedTouchPickupDistance(collector, ejected)
	return Vec2.distanceSquared(collector.pos, ejected.pos) <= collectDistance * collectDistance
end

local function canCellFireEjected(cell): boolean
	local minFireMass = math.max(Config.Ejected.MinFireMass or 0, 0)
	if cell.mass < minFireMass then
		return false
	end

	local cost = math.max(Config.Ejected.Cost or 0, 0)
	return cost <= 0 or cell.mass > cost
end

local function canSpawnerConsumeCell(spawner, cell): boolean
	local ratio = Config.Spawner.EatCellRadiusRatio or Config.Cell.MinEatRatio or 1
	return canConsumeByRadius(spawner, cell, ratio, Config.Cell.EatOverlap)
end

local function biasedWorldPosition(rng: Random, worldSize: Vector2, padding: number): Vector2
	local safePadding = math.max(padding or 0, 0)
	local inner = Vector2.new(
		math.max(worldSize.X * 0.5 - safePadding, 1),
		math.max(worldSize.Y * 0.5 - safePadding, 1)
	)
	local center = worldSize * 0.5
	local bias = 0.35
	local function sampleAxis(axisCenter: number, innerHalf: number): number
		local sign = if rng:NextNumber() < 0.5 then -1 else 1
		local t = rng:NextNumber() ^ (1 + bias)
		return axisCenter + sign * t * innerHalf
	end

	return Vector2.new(
		math.clamp(sampleAxis(center.X, inner.X), safePadding, worldSize.X - safePadding),
		math.clamp(sampleAxis(center.Y, inner.Y), safePadding, worldSize.Y - safePadding)
	)
end

local function circleSeparationDirection(aPos: Vector2, bPos: Vector2, fallbackSeed: number): Vector2
	local delta = bPos - aPos
	if delta.Magnitude > 0.001 then
		return delta.Unit
	end
	return Vec2.fromAngle((fallbackSeed % 628) / 100)
end

local function pointSegmentDistanceSquared(point: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local lengthSquared = ab:Dot(ab)
	if lengthSquared <= 0.000001 then
		return Vec2.distanceSquared(point, a)
	end

	local t = math.clamp((point - a):Dot(ab) / lengthSquared, 0, 1)
	local closest = a + ab * t
	return Vec2.distanceSquared(point, closest)
end

local function segmentTouchesCircle(a: Vector2, b: Vector2, center: Vector2, radius: number): boolean
	return pointSegmentDistanceSquared(center, a, b) <= radius * radius
end

local function sortCellsByMassDesc(a, b)
	return a.mass > b.mass
end

local function normaliseCoins(value): number
	local coins = tonumber(value) or 0
	if coins ~= coins or coins == math.huge or coins == -math.huge then
		return 0
	end
	return math.max(0, math.floor(coins))
end

local function normaliseLevel(value): number
	local maxLevel = Config.Progression.MaxLevel or 100
	local level = tonumber(value) or 1
	if level ~= level or level == math.huge or level == -math.huge then
		return 1
	end
	return math.clamp(math.floor(level), 1, maxLevel)
end

local function normaliseXp(value): number
	local xp = tonumber(value) or 0
	if xp ~= xp or xp == math.huge or xp == -math.huge then
		return 0
	end
	return math.max(0, xp)
end

local function normaliseXpMultiplier(value): number
	local multiplier = tonumber(value) or (Config.Progression.DefaultXpBoostMultiplier or 1)
	if multiplier ~= multiplier or multiplier == math.huge or multiplier == -math.huge then
		return Config.Progression.DefaultXpBoostMultiplier or 1
	end
	return math.max(0, multiplier)
end

local function xpRequiredForNextLevel(level: number): number
	local maxLevel = Config.Progression.MaxLevel or 100
	if level >= maxLevel then
		return 0
	end

	for index = 1, #XP_REQUIREMENT_ANCHORS - 1 do
		local current = XP_REQUIREMENT_ANCHORS[index]
		local nextAnchor = XP_REQUIREMENT_ANCHORS[index + 1]
		if level == current.level then
			return current.required
		end
		if level < nextAnchor.level then
			local alpha = (level - current.level) / (nextAnchor.level - current.level)
			return math.floor(current.required + (nextAnchor.required - current.required) * alpha + 0.5)
		end
	end

	return XP_REQUIREMENT_ANCHORS[#XP_REQUIREMENT_ANCHORS].required
end

local function startMassForLevel(level: number): number
	local progression = Config.Progression
	local baseMass = progression.BaseStartMass or Config.Player.SpawnMass
	local maxMass = progression.MaxStartMass or baseMass
	local maxLevel = progression.MaxLevel or 100
	if maxLevel <= 1 or maxMass <= baseMass then
		return baseMass
	end

	local ratio = (math.clamp(level, 1, maxLevel) - 1) / (maxLevel - 1)
	local curvedRatio = ratio ^ (progression.StartMassCurveExponent or 1)
	return math.floor(baseMass + (maxMass - baseMass) * curvedRatio + 0.5)
end

local function levelRewardCoins(level: number): number
	local reward = 10 + math.floor(level * 1.5)
	if level % 5 == 0 then
		reward += 25
	end
	return reward
end

local function normaliseOwnedSkins(value)
	local owned = {}
	if type(value) ~= "table" then
		return owned
	end

	if #value > 0 then
		for _, id in value do
			if SkinData.ById[tostring(id)] then
				owned[tostring(id)] = true
			end
		end
	else
		for id, count in value do
			local skinId = tostring(id)
			local numericCount = tonumber(count)
			if SkinData.ById[skinId] and ((numericCount and numericCount > 0) or (numericCount == nil and count)) then
				owned[skinId] = true
			end
		end
	end

	return owned
end

local function normaliseWearing(value): string?
	if type(value) == "string" then
		if SkinData.ById[value] then
			return value
		end

		local first = string.sub(value, 1, 1)
		if first == "[" or first == "{" then
			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(value)
			end)
			if ok then
				return normaliseWearing(decoded)
			end
		end
	elseif type(value) == "table" then
		if #value > 0 then
			return normaliseWearing(value[1])
		end

		for id, enabled in value do
			if enabled and SkinData.ById[tostring(id)] then
				return tostring(id)
			end
		end
	end

	return nil
end

local function normaliseAvatarDisplayMode(value): string
	if typeof(value) == "string" and VALID_AVATAR_DISPLAY_MODES[value] then
		return value
	end
	return DEFAULT_AVATAR_DISPLAY_MODE
end

local function trim(value: string): string
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function truncateNickname(value: string): string
	local maxLength = math.max(Config.Shop.NicknameMaxLength or 20, 0)
	if maxLength <= 0 then
		return ""
	end

	local ok, length = pcall(function()
		return utf8.len(value)
	end)
	if ok and typeof(length) == "number" and length > maxLength then
		local offsetOk, nextIndex = pcall(function()
			return utf8.offset(value, maxLength + 1)
		end)
		if offsetOk and typeof(nextIndex) == "number" then
			return string.sub(value, 1, nextIndex - 1)
		end
	end

	if not ok and #value > maxLength then
		return string.sub(value, 1, maxLength)
	end
	return value
end

local function normaliseNickname(value): string
	if typeof(value) ~= "string" then
		return ""
	end

	value = value:gsub("[%c]", " ")
	if value == "" then
		return ""
	end
	if not value:match("%S") then
		return " "
	end
	value = value:gsub("%s+", " ")
	value = trim(value)
	if value == "" then
		return ""
	end
	return truncateNickname(value)
end

function GameService.new()
	local self = setmetatable({}, GameService)
	self.remotes = self:_ensureRemotes()
	self.nextId = 1
	self.baseWorldSize = Config.World.Size
	self.maxWorldScale = math.max(Config.DynamicWorld and Config.DynamicWorld.MaxScale or 2, 1)
	self.maxWorldSize = self.baseWorldSize * self.maxWorldScale
	self.currentWorldSize = self.baseWorldSize
	self.lastWorldSnapshotSize = self.currentWorldSize
	self.targetWorldScale = 1
	self.shrinkScaleCandidate = 1
	self.shrinkCandidateElapsed = 0
	self.barriersInitialized = false
	self.debugForceMaxWorldScale = false
	self.staticRefreshBucket = 1
	self.staticOverlapAccumulator = 0
	self.playersByUserId = {}
	self.playerCount = 0
	self.cells = {}
	self.cellConsumeTargets = {}
	self.food = {}
	self.viruses = {}
	self.spawners = {}
	self.ejected = {}
	self.ejectedByOwner = {}
	self.ejectedCount = 0
	self.barriers = {}
	-- DataStores don't work in unpublished Studio places — GetDataStore
	-- throws "You must publish this place to the web to access DataStore".
	-- Wrap in pcall so Studio's debugger doesn't halt on the exception.
	-- Every downstream GetAsync/SetAsync is already pcall'd, and they
	-- all check `if not self.playerInfoStore then return end`-style, so
	-- a nil store just means no persistence (which is what you want in
	-- Studio anyway — no coin/skin data to corrupt while testing).
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(PLAYER_INFO_STORE)
	end)
	self.playerInfoStore = if ok then store else nil
	self.saveDirty = {}
	self.saveInFlight = {}
	self.cellGrid = SpatialHash.new(Config.Simulation.SpatialCellSize)
	self.foodGrid = SpatialHash.new(Config.Simulation.SpatialCellSize)
	self.virusGrid = SpatialHash.new(Config.Simulation.SpatialCellSize)
	self.spawnerGrid = SpatialHash.new(Config.Simulation.SpatialCellSize)
	self.ejectedGrid = SpatialHash.new(Config.Simulation.SpatialCellSize)
	self.barrierGrid = SpatialHash.new(Config.Simulation.SpatialCellSize)
	self.staticGridsDirty = true
	self.queryScratch = {}
	self.querySeenScratch = {}
	self.cellsScratch = {}
	self.eatEventsScratch = {}
	self.ejectedCollisionPairsScratch = {}
	self.rng = Random.new()
	self.running = false
	return self
end

function GameService:_ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild("Agar2DRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Agar2DRemotes"
		folder.Parent = ReplicatedStorage
	end

	local input = folder:FindFirstChild("Input")
	if not input then
		input = Instance.new("RemoteEvent")
		input.Name = "Input"
		input.Parent = folder
	end

	local inputFast = folder:FindFirstChild("InputFast")
	if not inputFast then
		local ok, remote = pcall(function()
			return Instance.new("UnreliableRemoteEvent")
		end)
		if ok and remote then
			inputFast = remote
			inputFast.Name = "InputFast"
			inputFast.Parent = folder
		end
	end

	local snapshot = folder:FindFirstChild("Snapshot")
	if not snapshot then
		snapshot = Instance.new("RemoteEvent")
		snapshot.Name = "Snapshot"
		snapshot.Parent = folder
	end

	local snapshotFast = folder:FindFirstChild("SnapshotFast")
	if not snapshotFast then
		local ok, remote = pcall(function()
			return Instance.new("UnreliableRemoteEvent")
		end)
		if ok and remote then
			snapshotFast = remote
			snapshotFast.Name = "SnapshotFast"
			snapshotFast.Parent = folder
		end
	end

	local snapshotFastEjected = folder:FindFirstChild("SnapshotFastEjected")
	if not snapshotFastEjected then
		local ok, remote = pcall(function()
			return Instance.new("UnreliableRemoteEvent")
		end)
		if ok and remote then
			snapshotFastEjected = remote
			snapshotFastEjected.Name = "SnapshotFastEjected"
			snapshotFastEjected.Parent = folder
		end
	end

	local clientReady = folder:FindFirstChild("ClientReady")
	if not clientReady then
		clientReady = Instance.new("RemoteEvent")
		clientReady.Name = "ClientReady"
		clientReady.Parent = folder
	end

	local shopAction = folder:FindFirstChild("ShopAction")
	if not shopAction then
		shopAction = Instance.new("RemoteEvent")
		shopAction.Name = "ShopAction"
		shopAction.Parent = folder
	end

	local debugAction = folder:FindFirstChild("DebugAction")
	if not debugAction then
		debugAction = Instance.new("RemoteEvent")
		debugAction.Name = "DebugAction"
		debugAction.Parent = folder
	end

	local respawnRequest = folder:FindFirstChild("RespawnRequest")
	if not respawnRequest then
		respawnRequest = Instance.new("RemoteEvent")
		respawnRequest.Name = "RespawnRequest"
		respawnRequest.Parent = folder
	end

	local configUpdate = folder:FindFirstChild("ConfigUpdate")
	if not configUpdate then
		configUpdate = Instance.new("RemoteEvent")
		configUpdate.Name = "ConfigUpdate"
		configUpdate.Parent = folder
	end

	return {
		Folder = folder,
		Input = input,
		InputFast = inputFast,
		Snapshot = snapshot,
		SnapshotFast = snapshotFast,
		SnapshotFastEjected = snapshotFastEjected,
		ClientReady = clientReady,
		ShopAction = shopAction,
		DebugAction = debugAction,
		RespawnRequest = respawnRequest,
		ConfigUpdate = configUpdate,
	}
end

-- ==================================================================
-- Live-config plumbing (see Config.Tunables schema). Admin-only.
-- ==================================================================
local TUNABLE_INDEX

local function buildTunableIndex()
	if TUNABLE_INDEX then
		return TUNABLE_INDEX
	end
	TUNABLE_INDEX = {}
	for _, entry in ipairs(Config.Tunables or {}) do
		if type(entry) == "table" and type(entry.path) == "string" then
			TUNABLE_INDEX[entry.path] = entry
		end
	end
	return TUNABLE_INDEX
end

local function splitConfigPath(path: string)
	local parts = {}
	for part in string.gmatch(path, "[^.]+") do
		table.insert(parts, part)
	end
	return parts
end

local function getConfigValue(path: string)
	local parts = splitConfigPath(path)
	local node = Config
	for _, part in ipairs(parts) do
		if type(node) ~= "table" then
			return nil
		end
		node = node[part]
	end
	return node
end

local function setConfigValue(path: string, value): boolean
	local parts = splitConfigPath(path)
	if #parts == 0 then
		return false
	end
	local node = Config
	for i = 1, #parts - 1 do
		node = node[parts[i]]
		if type(node) ~= "table" then
			return false
		end
	end
	node[parts[#parts]] = value
	return true
end

function GameService:_isAdminPlayer(player: Player?): boolean
	if not player then
		return false
	end
	local creatorId = game.CreatorId
	if creatorId and creatorId > 0 and player.UserId == creatorId then
		return true
	end
	local list = (Config.Admin and Config.Admin.UserIds) or {}
	for _, uid in ipairs(list) do
		if uid == player.UserId then
			return true
		end
	end
	return false
end

function GameService:_snapshotTunables()
	local snapshot = {}
	for _, entry in ipairs(Config.Tunables or {}) do
		if type(entry) == "table" and type(entry.path) == "string" then
			snapshot[entry.path] = getConfigValue(entry.path)
		end
	end
	return snapshot
end

function GameService:_handleConfigUpdate(player: Player, payload)
	if not self:_isAdminPlayer(player) then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	local index = buildTunableIndex()
	local entries = payload
	if payload.path then
		entries = { payload }
	end
	local applied = {}
	for _, item in ipairs(entries) do
		if type(item) == "table" and type(item.path) == "string" then
			local schema = index[item.path]
			if schema then
				local value = item.value
				if schema.type == "bool" then
					value = value and true or false
				elseif schema.type == "number" then
					if type(value) == "string" then
						value = tonumber(value)
					end
					if type(value) ~= "number" or value ~= value then
						value = nil
					end
					if value then
						if schema.min then
							value = math.max(schema.min, value)
						end
						if schema.max then
							value = math.min(schema.max, value)
						end
						if schema.int then
							value = math.floor(value + 0.5)
						end
					end
				else
					value = nil
				end
				if value ~= nil and setConfigValue(item.path, value) then
					applied[item.path] = value
				end
			end
		end
	end
	if next(applied) ~= nil and self.remotes and self.remotes.ConfigUpdate then
		self.remotes.ConfigUpdate:FireAllClients({ kind = "sync", values = applied })
	end
end

function GameService:_nextId(): number
	local id = self.nextId
	self.nextId += 1
	return id
end

function GameService:_worldSize(): Vector2
	return self.currentWorldSize
end

function GameService:_worldScale(): number
	return self.currentWorldSize.X / math.max(self.baseWorldSize.X, 1)
end

function GameService:_worldAreaScale(): number
	local scale = self:_worldScale()
	return scale * scale
end

function GameService:_scaledWorldSize(scale: number): Vector2
	local clampedScale = math.clamp(scale, 1, self.maxWorldScale)
	return self.baseWorldSize * clampedScale
end

function GameService:_worldBounds(worldSize: Vector2?): (Vector2, Vector2)
	local size = worldSize or self.currentWorldSize
	local min = (self.maxWorldSize - size) * 0.5
	return min, min + size
end

function GameService:_worldCenter(): Vector2
	local min, max = self:_worldBounds()
	return (min + max) * 0.5
end

function GameService:_clampToWorld(pos: Vector2, padding: number?, worldSize: Vector2?): Vector2
	local size = worldSize or self.currentWorldSize
	local min, max = self:_worldBounds(size)
	local padX = safeAxisPadding(size.X, padding)
	local padY = safeAxisPadding(size.Y, padding)
	return Vector2.new(
		math.clamp(pos.X, min.X + padX, max.X - padX),
		math.clamp(pos.Y, min.Y + padY, max.Y - padY)
	)
end

function GameService:_positionWithinWorld(pos: Vector2, padding: number?, worldSize: Vector2?): boolean
	local size = worldSize or self.currentWorldSize
	local min, max = self:_worldBounds(size)
	local padX = safeAxisPadding(size.X, padding)
	local padY = safeAxisPadding(size.Y, padding)
	return pos.X >= min.X + padX
		and pos.X <= max.X - padX
		and pos.Y >= min.Y + padY
		and pos.Y <= max.Y - padY
end

function GameService:_randomInWorld(padding: number?, worldSize: Vector2?): Vector2
	local size = worldSize or self.currentWorldSize
	local min, max = self:_worldBounds(size)
	local padX = safeAxisPadding(size.X, padding)
	local padY = safeAxisPadding(size.Y, padding)
	local minX = min.X + padX
	local maxX = math.max(minX, max.X - padX)
	local minY = min.Y + padY
	local maxY = math.max(minY, max.Y - padY)
	return Vector2.new(
		self.rng:NextNumber(minX, maxX),
		self.rng:NextNumber(minY, maxY)
	)
end

function GameService:_biasedWorldPosition(padding: number?, worldSize: Vector2?): Vector2
	local size = worldSize or self.currentWorldSize
	local min = (self.maxWorldSize - size) * 0.5
	return min + biasedWorldPosition(self.rng, size, padding or 0)
end

function GameService:start()
	if self.running then
		return
	end

	self.running = true

	self.remotes.Input.OnServerEvent:Connect(function(player, payload)
		self:_handleInput(player, payload)
	end)
	if self.remotes.InputFast then
		self.remotes.InputFast.OnServerEvent:Connect(function(player, payload)
			self:_handleInput(player, payload)
		end)
	end

	self.remotes.ShopAction.OnServerEvent:Connect(function(player, payload)
		self:_handleShopAction(player, payload)
	end)

	self.remotes.DebugAction.OnServerEvent:Connect(function(player, payload)
		self:_handleDebugAction(player, payload)
	end)

	self.remotes.RespawnRequest.OnServerEvent:Connect(function(player)
		self:_handleRespawnRequest(player)
	end)

	self.remotes.ClientReady.OnServerEvent:Connect(function(player)
		local state = self.playersByUserId[player.UserId]
		if state then
			state.clientReady = true
			state.needsStaticSnapshot = true
			state.shopDirty = true
		end
		if self:_isAdminPlayer(player) and self.remotes.ConfigUpdate then
			self.remotes.ConfigUpdate:FireClient(player, {
				kind = "sync",
				values = self:_snapshotTunables(),
			})
		end
	end)

	if self.remotes.ConfigUpdate then
		self.remotes.ConfigUpdate.OnServerEvent:Connect(function(player, payload)
			self:_handleConfigUpdate(player, payload)
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		self:_addPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_removePlayer(player)
	end)

	for _, player in Players:GetPlayers() do
		self:_addPlayer(player)
	end

	self:_maintainFood()
	self:_maintainViruses(self:_virusTarget())
	self:_maintainSpawners(self:_spawnerTarget())
	self:_maintainBarriers(self:_barrierTarget())
	self:_rebuildGrids()

	task.spawn(function()
		self:_runLoop()
	end)

	task.spawn(function()
		self:_autosaveLoop()
	end)

	game:BindToClose(function()
		self.running = false
		for _, state in self.playersByUserId do
			self:_finishLife(state)
			self:_savePlayerInfo(state, true)
		end
	end)
end

function GameService:_runLoop()
	local simDt = 1 / Config.Simulation.Hz
	local netDt = 1 / Config.Simulation.NetworkHz
	local accumulator = 0
	local netAccumulator = 0
	local staticAccumulator = 0

	while self.running do
		local dt = RunService.Heartbeat:Wait()
		accumulator += math.min(dt, 0.25)
		netAccumulator += dt
		staticAccumulator += dt

		local steps = 0
		while accumulator >= simDt and steps < Config.Simulation.MaxFrameSteps do
			self:_step(simDt)
			accumulator -= simDt
			steps += 1
		end

		if steps == Config.Simulation.MaxFrameSteps then
			accumulator = 0
		end

		if netAccumulator >= netDt then
			local staticDt = 1 / self:_staticNetworkHz()
			local includeStatics = staticAccumulator >= staticDt
			if includeStatics then
				local buckets = math.max(Config.Network.StaticRefreshBuckets or 1, 1)
				self.staticRefreshBucket = (self.staticRefreshBucket % buckets) + 1
			end
			self:_sendSnapshots(includeStatics)
			netAccumulator = 0
			if includeStatics then
				staticAccumulator = 0
			end
		end
	end
end

function GameService:_addPlayer(player: Player)
	if self.playersByUserId[player.UserId] then
		return
	end

	local color = randomPlayerColor(player.UserId)
	local state = {
		player = player,
		userId = player.UserId,
		name = player.DisplayName,
		nickname = "",
		avatarDisplayMode = DEFAULT_AVATAR_DISPLAY_MODE,
		color = color,
		colorPayload = colorToPayload(color),
		metaVersion = 1,
		cells = {},
		input = {
			aim = Vector2.new(1, 0),
			target = nil,
			view = Vector2.new(1280, 720),
			zoom = 1,
			splitToken = 0,
			ejectToken = 0,
			doubleSplitToken = 0,
			tripleSplitToken = 0,
			freezeToken = 0,
			cannibalHeld = false,
		},
		lastSplitToken = 0,
		lastEjectToken = 0,
		lastDoubleSplitToken = 0,
		lastTripleSplitToken = 0,
		lastFreezeToken = 0,
		lastFreezeAt = 0,
		frozen = false,
		ejectCycleOffset = 0,
		center = self:_randomInWorld(Config.World.SpawnPadding),
		clientReady = false,
		staticRefreshPhase = (self.playerCount % math.max(Config.Network.StaticRefreshBuckets or 1, 1)) + 1,
		characterConnection = nil,
		coins = 0,
		accountLevel = 1,
		accountXp = 0,
		totalXp = 0,
		lifeXp = 0,
		lastLifeXpAttributeValue = nil,
		nextLifeXpAttributeAt = 0,
		xpBoostMultiplier = Config.Progression.DefaultXpBoostMultiplier or 1,
		ownedSkins = {},
		equippedSkin = nil,
		locationSkinId = nil,
		useLocaleSkin = true,
		shopDirty = true,
		needsProgressionSave = false,
		knownStatics = {
			food = {},
			viruses = {},
		},
		knownCells = {},
		knownSpawners = {},
		knownEjected = {},
		knownPlayerMeta = {},
		needsStaticSnapshot = true,
		lastStaticSnapshotCenter = nil,
		lastStaticSnapshotRadius = nil,
		lastStaticSnapshotAt = 0,
	}

	self.playersByUserId[player.UserId] = state
	self.playerCount += 1
	self:_loadPlayerInfo(state)
	self:_publishPlayerInfoAttributes(state)
	self:_respawnPlayer(state)
	task.spawn(function()
		local locationSkinId = fetchCountrySkinIdForPlayer(player)
		if not locationSkinId then
			return
		end

		if self.playersByUserId[player.UserId] ~= state then
			return
		end

		if state.locationSkinId ~= locationSkinId then
			state.locationSkinId = locationSkinId
			state.metaVersion = (state.metaVersion or 1) + 1
			state.shopDirty = true
		end
	end)
	state.characterConnection = player.CharacterAdded:Connect(function(character)
		self:_watchCharacter(state, character)
	end)
	if player.Character then
		self:_watchCharacter(state, player.Character)
	end
end

function GameService:_removePlayer(player: Player)
	local state = self.playersByUserId[player.UserId]
	if not state then
		return
	end

	for i = #state.cells, 1, -1 do
		self.cells[state.cells[i]] = nil
	end
	local ejectedToRemove = self.ejectedByOwner[state.userId]
	if ejectedToRemove then
		for _, id in ejectedToRemove do
			self:_removeEjected(id)
		end
	end
	self.ejectedByOwner[state.userId] = nil
	if state.characterConnection then
		state.characterConnection:Disconnect()
	end
	self:_finishLife(state)
	self:_savePlayerInfo(state, true)

	self.playersByUserId[player.UserId] = nil
	self.playerCount = math.max(0, self.playerCount - 1)
	self.saveDirty[state.userId] = nil
	self.saveInFlight[state.userId] = nil
end

function GameService:_displayNameForState(state): string
	local nickname = normaliseNickname(state and state.nickname)
	if nickname ~= "" then
		return nickname
	end
	if state and state.player then
		return state.player.DisplayName
	end
	return "Player"
end

function GameService:_loadPlayerInfo(state)
	if not self.playerInfoStore then
		return -- Studio without publishing; no persistence available.
	end
	local key = playerInfoKey(state.userId)
	local ok, data = pcall(function()
		return self.playerInfoStore:GetAsync(key)
	end)

	if not ok then
		warn("Failed to load PlayerInfo for", state.userId, data)
		return
	end

	if type(data) ~= "table" then
		return
	end

	state.coins = normaliseCoins(data.coins)
	if (tonumber(data.economyVersion) or 0) < (Config.Progression.EconomyVersion or 1) then
		local divisor = math.max(Config.Progression.LegacyCoinScaleDivisor or 10, 1)
		state.coins = math.floor(state.coins / divisor + 0.5)
		state.needsProgressionSave = true
	end
	state.accountLevel = normaliseLevel(data.accountLevel)
	state.accountXp = normaliseXp(data.accountXp)
	state.totalXp = normaliseXp(data.totalXp)
	state.xpBoostMultiplier = normaliseXpMultiplier(data.xpBoostMultiplier)
	state.ownedSkins = normaliseOwnedSkins(data.sellable)
	state.nickname = normaliseNickname(data.nickname)
	state.name = self:_displayNameForState(state)
	state.avatarDisplayMode = normaliseAvatarDisplayMode(data.avatarDisplayMode)
	state.useLocaleSkin = data.useLocaleSkin ~= false

	local equipped = normaliseWearing(data.wearing)
	if equipped and state.ownedSkins[equipped] then
		state.equippedSkin = equipped
	end
end

function GameService:_sellablePayload(state)
	local sellable = {}
	for id in state.ownedSkins do
		sellable[id] = true
	end
	return sellable
end

function GameService:_publishPlayerInfoAttributes(state)
	if not state or not state.player then
		return
	end

	state.player:SetAttribute("Coins", normaliseCoins(state.coins))
	state.player:SetAttribute("AccountLevel", normaliseLevel(state.accountLevel))
	state.player:SetAttribute("AccountXP", math.floor(normaliseXp(state.accountXp) + 0.5))
	self:_publishLifeXpAttribute(state, true)
	state.player:SetAttribute("StartingMass", startMassForLevel(state.accountLevel))
	state.player:SetAttribute("Sellable", HttpService:JSONEncode(self:_sellablePayload(state)))
	state.player:SetAttribute("Wearing", state.equippedSkin)
	state.player:SetAttribute("Nickname", normaliseNickname(state.nickname))
	state.player:SetAttribute("AvatarDisplayMode", normaliseAvatarDisplayMode(state.avatarDisplayMode))
end

function GameService:_publishLifeXpAttribute(state, force: boolean?)
	if not state or not state.player then
		return
	end

	local value = math.floor(normaliseXp(state.lifeXp) + 0.5)
	local now = os.clock()
	local interval = 1 / math.max(LIFE_XP_ATTRIBUTE_HZ, 1)
	if not force then
		if state.lastLifeXpAttributeValue == value then
			return
		end
		if (state.nextLifeXpAttributeAt or 0) > now then
			return
		end
	end

	state.lastLifeXpAttributeValue = value
	state.nextLifeXpAttributeAt = now + interval
	state.player:SetAttribute("LifeXP", value)
end

function GameService:_markPlayerInfoDirty(state, publishFull: boolean?)
	if state then
		self.saveDirty[state.userId] = true
		if publishFull then
			state.shopDirty = true
			state.metaVersion = (state.metaVersion or 1) + 1
		end
		if publishFull then
			self:_publishPlayerInfoAttributes(state)
		elseif state.player then
			state.player:SetAttribute("Coins", normaliseCoins(state.coins))
			state.player:SetAttribute("AccountLevel", normaliseLevel(state.accountLevel))
			state.player:SetAttribute("AccountXP", math.floor(normaliseXp(state.accountXp) + 0.5))
			self:_publishLifeXpAttribute(state, true)
			state.player:SetAttribute("StartingMass", startMassForLevel(state.accountLevel))
		end
	end
end

function GameService:_savePlayerInfo(state, force: boolean?): boolean
	if not state then
		return false
	end

	if not self.playerInfoStore then
		-- Studio-without-publish: nothing to persist to. Report success
		-- so callers don't retry or complain to the player.
		self.saveDirty[state.userId] = nil
		state.needsProgressionSave = false
		return true
	end

	if self.saveInFlight[state.userId] then
		if not force then
			return false
		end

		local deadline = os.clock() + 5
		while self.saveInFlight[state.userId] and os.clock() < deadline do
			task.wait(0.05)
		end
		if self.saveInFlight[state.userId] then
			return false
		end
	end

	if not force and not self.saveDirty[state.userId] and not state.needsProgressionSave then
		return true
	end

	self.saveInFlight[state.userId] = true
	self.saveDirty[state.userId] = nil
	local key = playerInfoKey(state.userId)
	local coins = normaliseCoins(state.coins)
	local accountLevel = normaliseLevel(state.accountLevel)
	local accountXp = normaliseXp(state.accountXp)
	local totalXp = normaliseXp(state.totalXp)
	local xpBoostMultiplier = normaliseXpMultiplier(state.xpBoostMultiplier)
	local equippedSkin = state.equippedSkin
	local ownedSkins = self:_sellablePayload(state)
	local nickname = normaliseNickname(state.nickname)
	local avatarDisplayMode = normaliseAvatarDisplayMode(state.avatarDisplayMode)
	local useLocaleSkin = state.useLocaleSkin ~= false

	local ok, err = pcall(function()
		self.playerInfoStore:UpdateAsync(key, function(info)
			info = type(info) == "table" and info or {}
			info.coins = coins
			info.accountLevel = accountLevel
			info.accountXp = accountXp
			info.totalXp = totalXp
			info.xpBoostMultiplier = xpBoostMultiplier
			info.economyVersion = Config.Progression.EconomyVersion or 1
			info.sellable = type(info.sellable) == "table" and info.sellable or {}
			for id in ownedSkins do
				info.sellable[id] = true
			end
			info.wearing = equippedSkin and { equippedSkin } or nil
			info.nickname = if nickname ~= "" then nickname else nil
			info.avatarDisplayMode = avatarDisplayMode
			info.useLocaleSkin = useLocaleSkin
			return info
		end)
	end)

	self.saveInFlight[state.userId] = nil
	if ok then
		state.needsProgressionSave = false
		self:_publishPlayerInfoAttributes(state)
	else
		self.saveDirty[state.userId] = true
		warn("Failed to save PlayerInfo for", state.userId, err)
	end
	return ok
end

function GameService:_autosaveLoop()
	while self.running do
		task.wait(AUTOSAVE_SECONDS)
		for _, state in self.playersByUserId do
			self:_savePlayerInfo(state, false)
		end
	end
end

function GameService:_watchCharacter(state, character: Model)
	task.spawn(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
		if not humanoid then
			return
		end

		humanoid.Died:Connect(function()
			if self.playersByUserId[state.userId] == state then
				self:_respawnPlayer(state)
			end
		end)
	end)
end

function GameService:_grantLevelReward(state, level: number)
	state.coins += levelRewardCoins(level)
end

function GameService:_addAccountXp(state, amount: number)
	if amount <= 0 then
		return
	end

	local maxLevel = Config.Progression.MaxLevel or 100
	state.totalXp = normaliseXp(state.totalXp + amount)

	if state.accountLevel >= maxLevel then
		self:_markPlayerInfoDirty(state, false)
		return
	end

	state.accountXp = normaliseXp(state.accountXp + amount)
	while state.accountLevel < maxLevel do
		local required = xpRequiredForNextLevel(state.accountLevel)
		if required <= 0 or state.accountXp < required then
			break
		end

		state.accountXp -= required
		state.accountLevel += 1
		self:_grantLevelReward(state, state.accountLevel)
	end

	if state.accountLevel >= maxLevel then
		state.accountLevel = maxLevel
		state.accountXp = 0
	end

	self:_markPlayerInfoDirty(state, false)
end

function GameService:_finishLife(state)
	local baseXp = math.min(normaliseXp(state.lifeXp), Config.Progression.LifeXpCap or 25000)
	state.lifeXp = 0
	self:_publishLifeXpAttribute(state, true)
	if baseXp <= 0 then
		return
	end

	local finalXp = baseXp * normaliseXpMultiplier(state.xpBoostMultiplier)
	self:_addAccountXp(state, finalXp)
end

function GameService:_positionHitsBarrier(pos: Vector2, radius: number): boolean
	for _, barrier in self.barriers do
		local dir, penetration = self:_circleBarrierOverlap(pos, radius, barrier)
		if dir and penetration and penetration > 0 then
			return true
		end
	end
	return false
end

function GameService:_pickSpawnerBiasedSpawnPosition(radius: number): Vector2?
	local spawnerCount = self:_countMap(self.spawners)
	if spawnerCount <= 0 or self.rng:NextNumber() > (Config.Player.SpawnerBiasChance or 0) then
		return nil
	end

	local spawners = {}
	for _, spawner in self.spawners do
		spawners[#spawners + 1] = spawner
	end
	if #spawners == 0 then
		return nil
	end

	local minDistance = math.max(Config.Player.SpawnerBiasMinDistance or 240, radius + 20)
	local maxDistance = math.max(Config.Player.SpawnerBiasMaxDistance or minDistance, minDistance)
	local attempts = math.max(Config.Player.SpawnerBiasAttempts or 12, 1)
	for _ = 1, attempts do
		local spawner = spawners[self.rng:NextInteger(1, #spawners)]
		local dir = Vec2.fromAngle(self.rng:NextNumber(0, math.pi * 2))
		local distance = self.rng:NextNumber(minDistance, maxDistance)
		local pos = self:_clampToWorld(spawner.pos + dir * distance, radius)
		if not self:_positionHitsBarrier(pos, radius) then
			return pos
		end
	end

	return nil
end

function GameService:_respawnPlayer(state)
	self:_finishLife(state)
	for i = #state.cells, 1, -1 do
		self.cells[state.cells[i]] = nil
		state.cells[i] = nil
	end

	local spawnRadius = massToRadius(startMassForLevel(state.accountLevel))
	state.center = self:_pickSpawnerBiasedSpawnPosition(spawnRadius)
		or self:_randomInWorld(Config.World.SpawnPadding)
	state.lastSplitToken = state.input.splitToken
	state.lastEjectToken = state.input.ejectToken
	state.ejectCycleOffset = 0
	self:_spawnPlayerCell(state, state.center, startMassForLevel(state.accountLevel), Vector2.zero)
end

function GameService:_spawnPlayerCell(state, pos: Vector2, mass: number, boost: Vector2)
	if #state.cells >= Config.Player.MaxCells then
		return nil
	end

	local id = self:_nextId()
	local now = os.clock()
	local radius = massToRadius(mass)
	local cell = {
		id = id,
		kind = "cell",
		ownerUserId = state.userId,
		owner = state,
		pos = self:_clampToWorld(pos, radius),
		mass = mass,
		radius = radius,
		boost = boost,
		spawnedAt = now,
		canRecombineAt = now + recombineDelayForMass(mass),
	}

	self.cells[id] = cell
	state.cells[#state.cells + 1] = id
	return cell
end

function GameService:_removeCell(cell, eaterId: number?)
	local owner = cell.owner
	if eaterId then
		self.cellConsumeTargets[cell.id] = {
			eaterId = eaterId,
			expiresAt = os.clock() + 10,
		}
	end
	self.cells[cell.id] = nil

	if owner then
		for i = #owner.cells, 1, -1 do
			if owner.cells[i] == cell.id then
				table.remove(owner.cells, i)
				break
			end
		end
	end
end

function GameService:_setCellMass(cell, mass: number)
	cell.mass = math.max(mass, 1)
	cell.radius = massToRadius(cell.mass)
end

function GameService:_foodSpawnSections()
	local sectionsX = math.max(Config.Food.SpawnSectionsX or 5, 1)
	local sectionsY = math.max(Config.Food.SpawnSectionsY or 5, 1)
	local worldMin, worldMax = self:_worldBounds()
	local worldSize = worldMax - worldMin
	local sectionWidth = math.max(worldSize.X / sectionsX, 1)
	local sectionHeight = math.max(worldSize.Y / sectionsY, 1)
	local counts = {}

	for _, food in self.food do
		if food.source == nil or food.source == "ambient" then
			local sectionX = math.clamp(math.floor((food.pos.X - worldMin.X) / sectionWidth) + 1, 1, sectionsX)
			local sectionY = math.clamp(math.floor((food.pos.Y - worldMin.Y) / sectionHeight) + 1, 1, sectionsY)
			local index = (sectionY - 1) * sectionsX + sectionX
			counts[index] = (counts[index] or 0) + 1
		end
	end

	return {
		counts = counts,
		sectionsX = sectionsX,
		sectionsY = sectionsY,
		worldMin = worldMin,
		sectionWidth = sectionWidth,
		sectionHeight = sectionHeight,
		bestIndices = {},
	}
end

function GameService:_pickBalancedFoodPosition(sections, radius: number): Vector2
	local counts = sections.counts
	local bestIndices = sections.bestIndices
	table.clear(bestIndices)

	local bestCount = math.huge
	local sectionCount = sections.sectionsX * sections.sectionsY
	for index = 1, sectionCount do
		local count = counts[index] or 0
		if count < bestCount then
			bestCount = count
			table.clear(bestIndices)
			bestIndices[#bestIndices + 1] = index
		elseif count == bestCount then
			bestIndices[#bestIndices + 1] = index
		end
	end

	local chosenIndex = bestIndices[self.rng:NextInteger(1, #bestIndices)]
	counts[chosenIndex] = (counts[chosenIndex] or 0) + 1
	local sectionX = ((chosenIndex - 1) % sections.sectionsX) + 1
	local sectionY = math.floor((chosenIndex - 1) / sections.sectionsX) + 1
	local minX = sections.worldMin.X + (sectionX - 1) * sections.sectionWidth + radius
	local maxX = sections.worldMin.X + sectionX * sections.sectionWidth - radius
	local minY = sections.worldMin.Y + (sectionY - 1) * sections.sectionHeight + radius
	local maxY = sections.worldMin.Y + sectionY * sections.sectionHeight - radius
	return self:_clampToWorld(Vector2.new(
		self.rng:NextNumber(minX, math.max(minX, maxX)),
		self.rng:NextNumber(minY, math.max(minY, maxY))
	), radius)
end

function GameService:_spawnFood(count: number)
	if count <= 0 then
		return
	end

	local mass = self:_foodMass()
	local radius = Config.Food.Radius
	local sections = self:_foodSpawnSections()
	for _ = 1, count do
		local id = self:_nextId()
		self.food[id] = {
			id = id,
			kind = "food",
			source = "ambient",
			pos = self:_pickBalancedFoodPosition(sections, radius),
			mass = mass,
			radius = radius,
			colorIndex = randomFoodColorIndex(),
			spawnedAt = os.clock(),
		}
	end
	self:_markStaticGridsDirty()
end

function GameService:_pickVirusSpawnPosition(): Vector2
	local sectionsX = math.max(Config.Virus.SpawnSectionsX or 4, 1)
	local sectionsY = math.max(Config.Virus.SpawnSectionsY or 3, 1)
	local worldSize = self:_worldSize()
	local worldMin = select(1, self:_worldBounds(worldSize))
	local sectionWidth = worldSize.X / sectionsX
	local sectionHeight = worldSize.Y / sectionsY
	local counts = table.create(sectionsX * sectionsY, 0)

	for _, virus in self.viruses do
		local sectionX = math.clamp(math.floor((virus.pos.X - worldMin.X) / sectionWidth) + 1, 1, sectionsX)
		local sectionY = math.clamp(math.floor((virus.pos.Y - worldMin.Y) / sectionHeight) + 1, 1, sectionsY)
		local index = (sectionY - 1) * sectionsX + sectionX
		counts[index] = (counts[index] or 0) + 1
	end

	local bestIndices = {}
	local bestCount = math.huge
	for sectionY = 1, sectionsY do
		for sectionX = 1, sectionsX do
			local index = (sectionY - 1) * sectionsX + sectionX
			local count = counts[index] or 0
			if count < bestCount then
				bestCount = count
				table.clear(bestIndices)
				bestIndices[#bestIndices + 1] = index
			elseif count == bestCount then
				bestIndices[#bestIndices + 1] = index
			end
		end
	end

	local chosenIndex = bestIndices[self.rng:NextInteger(1, #bestIndices)]
	local chosenX = ((chosenIndex - 1) % sectionsX) + 1
	local chosenY = math.floor((chosenIndex - 1) / sectionsX) + 1
	local radius = Config.Virus.Radius
	local minX = worldMin.X + (chosenX - 1) * sectionWidth + radius
	local maxX = worldMin.X + chosenX * sectionWidth - radius
	local minY = worldMin.Y + (chosenY - 1) * sectionHeight + radius
	local maxY = worldMin.Y + chosenY * sectionHeight - radius
	local pos = Vector2.new(
		self.rng:NextNumber(minX, math.max(minX, maxX)),
		self.rng:NextNumber(minY, math.max(minY, maxY))
	)
	return self:_clampToWorld(pos, radius)
end

function GameService:_spawnVirus(pos: Vector2?)
	local spawnPos = pos or self:_pickVirusSpawnPosition()
	local id = self:_nextId()
	self.viruses[id] = {
		id = id,
		kind = "virus",
		pos = self:_clampToWorld(spawnPos, Config.Virus.Radius),
		mass = Config.Virus.Mass,
		radius = Config.Virus.Radius,
		vel = Vector2.zero,
		lastBumpDir = Vector2.new(1, 0),
	}
	self:_markStaticGridsDirty()
end

function GameService:_spawnSpawner(pos: Vector2?)
	local id = self:_nextId()
	local mass = Config.Spawner.BaseMass
	self.spawners[id] = {
		id = id,
		kind = "spawner",
		pos = pos or self:_biasedWorldPosition(Config.World.SpawnPadding),
		mass = mass,
		radius = spawnerRadiusForMass(mass),
		decayPelletBuffer = 0,
		pendingGrowth = 0,
	}
end

function GameService:_spawnBarrier(pos: Vector2?)
	local id = self:_nextId()
	local size = Config.Barrier.Size
	self.barriers[id] = {
		id = id,
		kind = "barrier",
		pos = pos or self:_randomInWorld(Config.World.SpawnPadding),
		halfSize = size * 0.5,
		vel = Vector2.zero,
	}
end

function GameService:_spawnEjected(pos: Vector2, dir: Vector2, ownerUserId: number, sourceCellId: number?, targetCellId: number?)
	self:_trimOwnerEjected(ownerUserId)
	if self.ejectedCount >= Config.Ejected.MaxCount then
		return
	end

	local id = self:_nextId()
	local owner = self.playersByUserId[ownerUserId]
	local ejected = {
		id = id,
		kind = "ejected",
		ownerUserId = ownerUserId,
		-- Cell that fired this pellet. Only THIS cell has to wait
		-- OwnerReeatDelay before eating it back; sibling own-cells can
		-- eat it immediately, which is what makes feeding work.
		sourceCellId = sourceCellId,
		-- Intended receiver. If Config.Ejected.LockPelletsToTarget is
		-- true, sibling own-cells CANNOT pick this pellet up — only
		-- the target cell or an enemy can. Prevents big siblings from
		-- eating pellets aimed at a small cell in the middle.
		targetCellId = targetCellId,
		colorPayload = owner and owner.colorPayload or colorToPayload(Config.Render.EjectedColor),
		pos = self:_clampToWorld(pos, Config.Ejected.Radius),
		vel = dir * Config.Ejected.Speed,
		mass = Config.Ejected.Mass,
		radius = Config.Ejected.Radius,
		spawnedAt = os.clock(),
	}
	self.ejected[id] = ejected
	self.ejectedCount += 1
	self:_trackOwnerEjected(ejected)
end

function GameService:_ownerEjectedLimit(): number
	local playerCount = self:_playerCount()
	if playerCount >= Config.Network.HeavyLoadPlayers then
		return Config.Ejected.HeavyLoadPerPlayerMaxCount or Config.Ejected.PerPlayerMaxCount
	end
	if playerCount >= Config.Network.AdaptiveStartPlayers then
		return Config.Ejected.LoadPerPlayerMaxCount or Config.Ejected.PerPlayerMaxCount
	end
	return Config.Ejected.PerPlayerMaxCount
end

function GameService:_ejectCellsPerTickLimit(): number
	local playerCount = self:_playerCount()
	if playerCount >= Config.Network.HeavyLoadPlayers then
		return Config.Ejected.HeavyLoadMaxCellsPerShotTick or Config.Ejected.MaxCellsPerShotTick
	end
	if playerCount >= Config.Network.AdaptiveStartPlayers then
		return Config.Ejected.LoadMaxCellsPerShotTick or Config.Ejected.MaxCellsPerShotTick
	end
	return Config.Ejected.MaxCellsPerShotTick
end

function GameService:_trackOwnerEjected(ejected)
	local list = self.ejectedByOwner[ejected.ownerUserId]
	if not list then
		list = {}
		self.ejectedByOwner[ejected.ownerUserId] = list
	end
	list[#list + 1] = ejected.id
end

function GameService:_trimOwnerEjected(ownerUserId: number)
	local limit = self:_ownerEjectedLimit()
	if limit <= 0 then
		return
	end

	local list = self.ejectedByOwner[ownerUserId]
	if not list then
		return
	end

	local write = 1
	for read = 1, #list do
		local id = list[read]
		if self.ejected[id] then
			list[write] = id
			write += 1
		end
	end
	for index = write, #list do
		list[index] = nil
	end

	local overflow = #list - limit + 1
	if overflow <= 0 then
		return
	end

	local ownerState = self.playersByUserId[ownerUserId]
	local ownerCenter = ownerState and ownerState.center
	local retainRadius = math.max(Config.Ejected.OwnerTrimRetainRadius or 1800, 0)
	local retainRadiusSquared = retainRadius * retainRadius
	local candidates = {}
	for index, id in list do
		local ejected = self.ejected[id]
		if ejected then
			local distanceSquared = if ownerCenter then Vec2.distanceSquared(ownerCenter, ejected.pos) else math.huge
			candidates[#candidates + 1] = {
				id = id,
				index = index,
				outsideRetainRadius = distanceSquared > retainRadiusSquared,
				distanceSquared = distanceSquared,
				spawnedAt = ejected.spawnedAt or 0,
			}
		end
	end

	table.sort(candidates, function(a, b)
		if a.outsideRetainRadius ~= b.outsideRetainRadius then
			return a.outsideRetainRadius
		end
		if a.distanceSquared ~= b.distanceSquared then
			return a.distanceSquared > b.distanceSquared
		end
		return a.spawnedAt < b.spawnedAt
	end)

	local removeIds = {}
	for index = 1, math.min(overflow, #candidates) do
		removeIds[candidates[index].id] = true
	end
	if next(removeIds) == nil then
		return
	end

	write = 1
	for read = 1, #list do
		local id = list[read]
		if not removeIds[id] then
			list[write] = id
			write += 1
		end
	end
	for index = write, #list do
		list[index] = nil
	end

	for id in removeIds do
		if self.ejected[id] then
			self:_removeEjected(id)
		end
	end
end

function GameService:_removeEjected(id: number)
	if self.ejected[id] then
		self.ejected[id] = nil
		self.ejectedCount = math.max(0, self.ejectedCount - 1)
	end
end

function GameService:_countMap(map): number
	local count = 0
	for _ in map do
		count += 1
	end
	return count
end

function GameService:_countFoodBySource(source: string): number
	local count = 0
	for _, food in self.food do
		if food.source == source or (source == "ambient" and food.source == nil) then
			count += 1
		end
	end
	return count
end

function GameService:_maxEntityRadius(source, fallback: number?): number
	local maxRadius = fallback or 0
	for _, entity in source do
		if entity.radius then
			maxRadius = math.max(maxRadius, entity.radius)
		elseif entity.halfSize then
			maxRadius = math.max(maxRadius, entity.halfSize.X, entity.halfSize.Y)
		end
	end
	return maxRadius
end

function GameService:_activePlayerCount(): number
	local count = 0
	for _, state in self.playersByUserId do
		for _, id in state.cells do
			if self.cells[id] then
				count += 1
				break
			end
		end
	end
	return count
end

-- Returns true if this own-cell is allowed to pick up this own pellet.
-- If LockPelletsToTarget is enabled and the pellet has a targetCellId,
-- only the target cell may collect it (until LockedTargetTimeout elapses),
-- which prevents big sibling cells from stealing pellets aimed at a small
-- receiver in the middle of a cluster.
local function ownCellMayCollectOwnEjected(cell, ejected, now: number): boolean
	if not ejected or ejected.ownerUserId ~= cell.ownerUserId then
		return true
	end
	local cfg = Config.Ejected or {}
	if cfg.LockPelletsToTarget ~= true then
		return true
	end
	local targetId = ejected.targetCellId
	if not targetId then
		return true
	end
	if cell.id == targetId then
		return true
	end
	local timeout = math.max(cfg.LockedTargetTimeout or 0, 0)
	if timeout > 0 and (now - (ejected.spawnedAt or now)) > timeout then
		return true
	end
	return false
end

function GameService:_ejectedMassGain(cell, ejected, gainContext: string?): number
	local baseGain = ejected.mass * math.max(Config.Ejected.PickupMassMultiplier or 1, 0)
	if gainContext ~= "selfFeed" or ejected.ownerUserId ~= cell.ownerUserId then
		return baseGain
	end

	-- Score-scaled recovery is only for direct self-feeding, not spawner or virus rewards.
	local ejectedConfig = Config.Ejected or {}
	local playerScore = self:_playerMass(cell.owner)
	local startScore = math.max(ejectedConfig.SelfRecoveryStartScore or 400000, 0)
	local endScore = math.max(ejectedConfig.SelfRecoveryEndScore or 2400000, startScore + 1)
	local minScale = math.clamp(ejectedConfig.SelfRecoveryMinScale or 0.05, 0, 1)
	local alpha = math.clamp((playerScore - startScore) / (endScore - startScore), 0, 1)
	local exponent = ejectedConfig.SelfRecoveryCurveExponent or 1
	if exponent ~= 1 then
		alpha = alpha ^ exponent
	end

	local recoveryScale = 1 + (minScale - 1) * alpha
	return baseGain * recoveryScale
end

function GameService:_requestedWorldScale(): number
	if self.debugForceMaxWorldScale == true then
		return self.maxWorldScale
	end

	local dynamicConfig = Config.DynamicWorld or {}
	local maxScale = self.maxWorldScale
	local activePlayers = self:_activePlayerCount()
	local basePlayers = math.max(dynamicConfig.BasePlayers or 10, 1)
	local countScale = math.sqrt(math.clamp(activePlayers / basePlayers, 1, maxScale * maxScale))
	if activePlayers <= basePlayers then
		return math.clamp(math.max(1, countScale), 1, maxScale)
	end

	local minX = nil
	local maxX = nil
	local minY = nil
	local maxY = nil
	for _, cell in self.cells do
		local left = cell.pos.X - cell.radius
		local right = cell.pos.X + cell.radius
		local top = cell.pos.Y - cell.radius
		local bottom = cell.pos.Y + cell.radius
		minX = minX and math.min(minX, left) or left
		maxX = maxX and math.max(maxX, right) or right
		minY = minY and math.min(minY, top) or top
		maxY = maxY and math.max(maxY, bottom) or bottom
	end

	local spreadScale = 1
	if activePlayers > 1 and minX and maxX and minY and maxY then
		local padding = math.max(dynamicConfig.ClusterPadding or 900, Config.World.SpawnPadding * 2)
		local requiredWidth = (maxX - minX) + padding * 2
		local requiredHeight = (maxY - minY) + padding * 2
		spreadScale = math.max(requiredWidth / self.baseWorldSize.X, requiredHeight / self.baseWorldSize.Y)
	end

	return math.clamp(math.max(1, countScale, spreadScale), 1, maxScale)
end

function GameService:_occupiedWorldScaleFloor(): number
	local dynamicConfig = Config.DynamicWorld or {}
	local center = self.maxWorldSize * 0.5
	local requiredHalfWidth = self.baseWorldSize.X * 0.5
	local requiredHalfHeight = self.baseWorldSize.Y * 0.5
	local margin = dynamicConfig.ActiveCellMargin or 420
	local activePlayers = self:_activePlayerCount()
	local basePlayers = math.max(dynamicConfig.BasePlayers or 10, 1)

	if activePlayers <= basePlayers then
		return 1
	end

	for _, cell in self.cells do
		requiredHalfWidth = math.max(requiredHalfWidth, math.abs(cell.pos.X - center.X) + cell.radius + margin)
		requiredHalfHeight = math.max(requiredHalfHeight, math.abs(cell.pos.Y - center.Y) + cell.radius + margin)
	end

	local requiredScale = math.max(
		requiredHalfWidth / math.max(self.baseWorldSize.X * 0.5, 1),
		requiredHalfHeight / math.max(self.baseWorldSize.Y * 0.5, 1)
	)
	return math.clamp(requiredScale, 1, self.maxWorldScale)
end

function GameService:_enforceWorldBounds()
	local removedViruses = false
	local removedFood = false

	for _, cell in self.cells do
		cell.pos = self:_clampToWorld(cell.pos, cell.radius)
	end

	for _, ejected in self.ejected do
		ejected.pos = self:_clampToWorld(ejected.pos, ejected.radius)
	end

	for id, food in self.food do
		if not self:_positionWithinWorld(food.pos, food.radius) then
			self.food[id] = nil
			removedFood = true
		end
	end

	for id, virus in self.viruses do
		if not self:_positionWithinWorld(virus.pos, virus.radius) then
			self.viruses[id] = nil
			removedViruses = true
		end
	end

	for _, spawner in self.spawners do
		spawner.pos = self:_clampToWorld(spawner.pos, spawner.radius)
	end

	for _, barrier in self.barriers do
		barrier.pos = self:_clampToWorld(
			barrier.pos,
			math.max(barrier.halfSize.X, barrier.halfSize.Y)
		)
	end

	if removedFood or removedViruses then
		self:_markStaticGridsDirty()
	end
end

function GameService:_updateWorld(dt: number)
	local dynamicConfig = Config.DynamicWorld or {}
	local requestedScale = self:_requestedWorldScale()
	local hysteresis = math.max(dynamicConfig.TargetHysteresis or 0.05, 0)
	local shrinkDelay = math.max(dynamicConfig.ShrinkDelaySeconds or 10, 0)

	if requestedScale > self.targetWorldScale + hysteresis then
		self.targetWorldScale = requestedScale
		self.shrinkScaleCandidate = requestedScale
		self.shrinkCandidateElapsed = 0
	elseif requestedScale < self.targetWorldScale - hysteresis then
		if math.abs(requestedScale - self.shrinkScaleCandidate) > 0.01 then
			self.shrinkScaleCandidate = requestedScale
			self.shrinkCandidateElapsed = 0
		else
			self.shrinkCandidateElapsed += dt
			if self.shrinkCandidateElapsed >= shrinkDelay then
				self.targetWorldScale = requestedScale
				self.shrinkCandidateElapsed = 0
			end
		end
	else
		self.shrinkScaleCandidate = requestedScale
		self.shrinkCandidateElapsed = 0
	end

	local occupiedScale = self:_occupiedWorldScaleFloor()
	local desiredScale = math.max(self.targetWorldScale, occupiedScale)
	local targetWorldSize = self:_scaledWorldSize(desiredScale)
	local maxDelta = (desiredScale >= self:_worldScale())
			and math.max(dynamicConfig.ExpandSpeed or 1100, 0) * dt
		or math.max(dynamicConfig.ShrinkSpeed or 260, 0) * dt
	local nextWorldSize = Vector2.new(
		approach(self.currentWorldSize.X, targetWorldSize.X, maxDelta),
		approach(self.currentWorldSize.Y, targetWorldSize.Y, maxDelta)
	)

	if nextWorldSize ~= self.currentWorldSize then
		local previousWorldSize = self.currentWorldSize
		self.currentWorldSize = nextWorldSize
		self:_enforceWorldBounds()
		local notifyStep = math.max(dynamicConfig.SnapshotResizeStep or 0, 0)
		local reachedTarget = (targetWorldSize - nextWorldSize).Magnitude < 1
		local shouldNotify = notifyStep <= 0
			or not self.lastWorldSnapshotSize
			or (self.lastWorldSnapshotSize - nextWorldSize).Magnitude >= notifyStep
			or reachedTarget
		if shouldNotify and (previousWorldSize - nextWorldSize).Magnitude >= 1 then
			self.lastWorldSnapshotSize = nextWorldSize
			for _, state in self.playersByUserId do
				state.needsStaticSnapshot = true
			end
		end
	end
end

function GameService:_scaledAreaCount(baseCount: number): number
	return math.max(1, math.floor(baseCount * self:_worldAreaScale() + 0.5))
end

function GameService:_splitImpulseScale(mass: number): number
	local scale = (Config.Player.InitialMass / math.max(mass, 1)) ^ (Config.Cell.SplitImpulseMassExponent or 0.22)
	return math.clamp(scale, Config.Cell.MinSplitImpulseScale or 0.28, 1)
end

function GameService:_splitImpulseForMass(mass: number, multiplier: number?): number
	return Config.Cell.SplitImpulse * self:_splitImpulseScale(mass) * (multiplier or 1)
end

function GameService:_spawnFoodPellet(pos: Vector2, pelletMass: number, angle: number?, sourceRadius: number?)
	local id = self:_nextId()
	local dir = Vec2.fromAngle(angle or self.rng:NextNumber(0, math.pi * 2))
	local ringRadius = sourceRadius or 0
	local distance
	if ringRadius > 0 then
		distance = ringRadius + self.rng:NextNumber(-6, 10)
	else
		distance = self.rng:NextNumber(10, Config.Spawner.PelletScatterRadius or 110)
	end
	self.food[id] = {
		id = id,
		kind = "food",
		source = "spawner",
		pos = self:_clampToWorld(pos + dir * distance, 10),
		mass = pelletMass,
		radius = Config.Food.Radius,
		colorIndex = randomFoodColorIndex(),
		spawnedAt = os.clock(),
	}
end

function GameService:_trimSpawnerFoodPellets()
	local maxPellets = Config.Spawner.MaxMapPellets
	if not maxPellets or maxPellets <= 0 then
		return
	end

	local spawnerPellets = {}
	for id, food in self.food do
		if food.source == "spawner" then
			spawnerPellets[#spawnerPellets + 1] = {
				id = id,
				spawnedAt = food.spawnedAt or 0,
			}
		end
	end
	if #spawnerPellets <= maxPellets then
		return
	end

	table.sort(spawnerPellets, function(a, b)
		return a.spawnedAt < b.spawnedAt
	end)
	for index = 1, #spawnerPellets - maxPellets do
		self.food[spawnerPellets[index].id] = nil
	end
	self:_markStaticGridsDirty()
end

function GameService:_spawnFoodBurst(pos: Vector2, releasedMass: number, sourceRadius: number?)
	local pelletMass = (Config.Spawner.PelletMass or 0) > 0 and Config.Spawner.PelletMass or self:_foodMass()
	local ringRadius = sourceRadius or Config.Spawner.BaseRadius
	local count = math.min(
		Config.Spawner.MaxPelletsPerFeed or 64,
		math.floor(releasedMass / pelletMass)
	)
	if count <= 0 then
		return 0
	end
	local angleOffset = self.rng:NextNumber(0, math.pi * 2)

	for index = 1, count do
		local angle = angleOffset + (math.pi * 2) * ((index - 1) / count)
		self:_spawnFoodPellet(pos, pelletMass, angle, ringRadius)
	end
	self:_trimSpawnerFoodPellets()
	self:_markStaticGridsDirty()
	return count * pelletMass
end

function GameService:_flushSpawnerPellets(spawner): boolean
	local pelletMass = (Config.Spawner.PelletMass or 0) > 0 and Config.Spawner.PelletMass or self:_foodMass()
	local bufferedMass = spawner.decayPelletBuffer or 0
	if bufferedMass < pelletMass then
		return false
	end

	local releasedMass = self:_spawnFoodBurst(spawner.pos, bufferedMass, spawner.radius)
	if releasedMass <= 0 then
		return false
	end

	spawner.decayPelletBuffer = math.max(0, bufferedMass - releasedMass)
	return true
end

function GameService:_feedSpawner(spawner, absorbedMass: number)
	local releasedMass = absorbedMass * (Config.Spawner.PelletMassFraction or 0.45)
	local requestedGrowth = absorbedMass * (Config.Spawner.GrowthMassFraction or 0.35)
	local maxMass = spawnerMaxMass()
	local pendingGrowth = spawner.pendingGrowth or 0
	local availableGrowth = math.max(0, maxMass - (spawner.mass + pendingGrowth))
	local acceptedGrowth = math.min(requestedGrowth, availableGrowth)
	local overflowGrowth = requestedGrowth - acceptedGrowth

	spawner.pendingGrowth = pendingGrowth + acceptedGrowth
	releasedMass += overflowGrowth
	if releasedMass > 0 then
		spawner.decayPelletBuffer = (spawner.decayPelletBuffer or 0) + releasedMass
		self:_flushSpawnerPellets(spawner)
	end
end

function GameService:_decaySpawners(dt: number)
	local baseMass = Config.Spawner.BaseMass
	local decayRate = Config.Spawner.DecayPerSecond or 0
	local growthPerSecond = Config.Spawner.GrowthPerSecond or 0
	local maxMass = spawnerMaxMass()

	for _, spawner in self.spawners do
		if spawner.mass > maxMass then
			spawner.decayPelletBuffer = (spawner.decayPelletBuffer or 0) + (spawner.mass - maxMass)
			spawner.mass = maxMass
			spawner.radius = spawnerRadiusForMass(spawner.mass)
		end

		local pendingGrowth = spawner.pendingGrowth or 0
		if pendingGrowth > 0 and growthPerSecond > 0 and spawner.mass < maxMass then
			local growthMass = math.min(pendingGrowth, growthPerSecond * dt, maxMass - spawner.mass)
			if growthMass > 0 then
				spawner.pendingGrowth = pendingGrowth - growthMass
				spawner.mass += growthMass
				spawner.radius = spawnerRadiusForMass(spawner.mass)
				pendingGrowth = spawner.pendingGrowth
			end
		end

		if pendingGrowth > 0 and spawner.mass >= maxMass then
			spawner.decayPelletBuffer = (spawner.decayPelletBuffer or 0) + pendingGrowth
			spawner.pendingGrowth = 0
		end

		if decayRate <= 0 then
			continue
		end

		if spawner.mass > baseMass then
			local decayMass = math.min(spawner.mass - baseMass, spawner.mass * decayRate * dt)
			if decayMass > 0 then
				spawner.mass -= decayMass
				spawner.radius = spawnerRadiusForMass(spawner.mass)
				spawner.decayPelletBuffer = (spawner.decayPelletBuffer or 0) + decayMass
			end
		else
			spawner.mass = baseMass
			spawner.radius = spawnerRadiusForMass(baseMass)
		end

		self:_flushSpawnerPellets(spawner)
	end
end

function GameService:_circleBarrierOverlap(circlePos: Vector2, radius: number, barrier)
	local halfSize = barrier.halfSize
	local delta = circlePos - barrier.pos
	local closest = Vector2.new(
		math.clamp(delta.X, -halfSize.X, halfSize.X),
		math.clamp(delta.Y, -halfSize.Y, halfSize.Y)
	)
	local nearest = barrier.pos + closest
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
		local dir = Vector2.new(if delta.X >= 0 then 1 else -1, 0)
		return dir, remainingX
	end

	local dir = Vector2.new(0, if delta.Y >= 0 then 1 else -1)
	return dir, remainingY
end

function GameService:_resolveBarrierBarrierOverlap(a, b)
	local delta = b.pos - a.pos
	local overlapX = (a.halfSize.X + b.halfSize.X) - math.abs(delta.X)
	local overlapY = (a.halfSize.Y + b.halfSize.Y) - math.abs(delta.Y)
	if overlapX <= 0 or overlapY <= 0 then
		return
	end

	local dir
	local penetration
	if overlapX < overlapY then
		dir = Vector2.new(if delta.X >= 0 then 1 else -1, 0)
		penetration = overlapX
	else
		dir = Vector2.new(0, if delta.Y >= 0 then 1 else -1)
		penetration = overlapY
	end

	local offset = dir * (penetration * 0.5)
	a.pos -= offset
	b.pos += offset
	a.vel -= dir * penetration
	b.vel += dir * penetration
end

function GameService:_adjustSpawnPositionForBarriers(startPos: Vector2, desiredPos: Vector2, radius: number): Vector2
	local dir = desiredPos - startPos
	local length = dir.Magnitude
	if length <= 0.001 then
		return desiredPos
	end

	dir /= length
	local resolved = desiredPos
	for _, barrier in self.barriers do
		local expanded = barrier.halfSize + Vector2.new(radius, radius)
		local min = barrier.pos - expanded
		local max = barrier.pos + expanded

		local tMin = 0
		local tMax = length
		local valid = true
		for _, axis in { "X", "Y" } do
			local origin = startPos[axis]
			local ray = dir[axis]
			local axisMin = min[axis]
			local axisMax = max[axis]
			if math.abs(ray) < 0.0001 then
				if origin < axisMin or origin > axisMax then
					valid = false
					break
				end
			else
				local inv = 1 / ray
				local t1 = (axisMin - origin) * inv
				local t2 = (axisMax - origin) * inv
				if t1 > t2 then
					t1, t2 = t2, t1
				end
				tMin = math.max(tMin, t1)
				tMax = math.min(tMax, t2)
				if tMin > tMax then
					valid = false
					break
				end
			end
		end

		if valid and tMin >= 0 and tMin <= length then
			resolved = startPos + dir * math.max(tMin - 4, 0)
			break
		end
	end

	return resolved
end

function GameService:_baseFoodTarget(): number
	local playerCount = self:_playerCount()
	if playerCount >= Config.Network.HeavyLoadPlayers then
		return (Config.Food.HeavyLoadTargetCount or Config.Food.TargetCount)
			+ (Config.Food.HeavyLoadBonusTargetCount or Config.Food.BonusTargetCount or 0)
	end
	if playerCount >= Config.Network.AdaptiveStartPlayers then
		return (Config.Food.LoadTargetCount or Config.Food.TargetCount)
			+ (Config.Food.LoadBonusTargetCount or Config.Food.BonusTargetCount or 0)
	end
	return Config.Food.TargetCount + (Config.Food.BonusTargetCount or 0)
end

function GameService:_foodTarget(): number
	return math.max(1, math.floor(self:_baseFoodTarget() * self:_worldAreaScale() + 0.5))
end

function GameService:_foodMass(): number
	local baseTarget = math.max(self:_baseFoodTarget(), 1)
	return Config.Food.Mass * (Config.Food.TargetCount / baseTarget)
end

function GameService:_maintainFood(target: number?)
	target = target or self:_foodTarget()
	local current = self:_countFoodBySource("ambient")
	if current < target then
		self:_spawnFood(math.min(Config.Food.SpawnBatch, target - current))
	end
end

function GameService:_maintainViruses(target: number)
	local current = self:_countMap(self.viruses)
	for _ = current + 1, target do
		self:_spawnVirus()
	end
end

function GameService:_maintainSpawners(target: number)
	local current = self:_countMap(self.spawners)
	for _ = current + 1, target do
		self:_spawnSpawner()
	end
end

function GameService:_virusTarget(): number
	return self:_scaledAreaCount(Config.Virus.TargetCount)
end

function GameService:_spawnerTarget(): number
	return self:_scaledAreaCount(Config.Spawner.TargetCount)
end

function GameService:_maintainBarriers(target: number)
	if self.barriersInitialized then
		return
	end

	local current = self:_countMap(self.barriers)
	for _ = current + 1, target do
		self:_spawnBarrier()
	end
	self.barriersInitialized = true
end

function GameService:_barrierTarget(): number
	return Config.Barrier.TargetCount
end

function GameService:_filterNickname(player: Player, nickname: string): string?
	if typeof(nickname) == "string" then
		local spacesOnly = nickname:gsub("[%c]", " ")
		if spacesOnly ~= "" and not spacesOnly:match("%S") then
			return " "
		end
	end

	nickname = normaliseNickname(nickname)
	if nickname == "" then
		return ""
	end

	local ok, filteredNickname = pcall(function()
		local filterResult = TextService:FilterStringAsync(nickname, player.UserId)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if not ok or typeof(filteredNickname) ~= "string" then
		return nil
	end

	return normaliseNickname(filteredNickname)
end

function GameService:_handleShopAction(player: Player, payload)
	local state = self.playersByUserId[player.UserId]
	if not state or typeof(payload) ~= "table" then
		return
	end

	if payload.action == "avatarDisplay" then
		state.avatarDisplayMode = normaliseAvatarDisplayMode(payload.mode)
		self:_markPlayerInfoDirty(state, true)
		if self:_savePlayerInfo(state, true) then
			self:_sendShopResult(player, true, "Avatar display saved.")
		else
			self:_sendShopResult(player, false, "Avatar display changed, but save failed. It may not persist.", "datastore_failed")
		end
		return
	end

	if payload.action == "nickname" then
		local nickname = self:_filterNickname(player, payload.nickname)
		if nickname == nil then
			self:_sendShopResult(player, false, "Nickname could not be saved.", "filter_failed")
			return
		end

		state.nickname = nickname
		state.name = self:_displayNameForState(state)
		self:_markPlayerInfoDirty(state, true)
		if self:_savePlayerInfo(state, true) then
			local message = if nickname == "" then "Nickname cleared." else "Nickname saved."
			self:_sendShopResult(player, true, message)
		else
			self:_sendShopResult(player, false, "Nickname changed, but save failed. It may not persist.", "datastore_failed")
		end
		return
	end

	if typeof(payload.skinId) ~= "string" then
		return
	end

	local skin = SkinData.ById[payload.skinId]
	if not skin then
		return
	end

	if payload.action == "buy" then
		if state.ownedSkins[skin.id] then
			state.equippedSkin = skin.id
			state.useLocaleSkin = true
			self:_markPlayerInfoDirty(state, true)
			if self:_savePlayerInfo(state, true) then
				self:_sendShopResult(player, true, "Equipped " .. skin.name .. ".")
			else
				self:_sendShopResult(player, false, "Equipped, but save failed. It may not persist.", "datastore_failed")
			end
			return
		end

		local cost = tonumber(skin.cost) or 0
		if state.coins >= cost then
			state.coins -= cost
			state.ownedSkins[skin.id] = true
			state.equippedSkin = skin.id
			state.useLocaleSkin = true
			self:_markPlayerInfoDirty(state, true)
			if self:_savePlayerInfo(state, true) then
				self:_sendShopResult(player, true, "Purchased " .. skin.name .. ".")
			else
				self:_sendShopResult(player, false, "Purchased, but save failed. It may not persist.", "datastore_failed")
			end
		else
			self:_sendShopResult(player, false, "Not enough coins.", "not_enough_coins")
		end
	elseif payload.action == "equip" then
		if state.ownedSkins[skin.id] or skin.id == state.locationSkinId then
			state.equippedSkin = skin.id
			state.useLocaleSkin = true
			self:_markPlayerInfoDirty(state, true)
			if self:_savePlayerInfo(state, true) then
				self:_sendShopResult(player, true, "Equipped " .. skin.name .. ".")
			else
				self:_sendShopResult(player, false, "Equipped, but save failed. It may not persist.", "datastore_failed")
			end
		end
	elseif payload.action == "unequip" then
		if (state.ownedSkins[skin.id] or skin.id == state.locationSkinId) and state.equippedSkin == skin.id then
			state.equippedSkin = nil
			state.useLocaleSkin = skin.id ~= state.locationSkinId
			self:_markPlayerInfoDirty(state, true)
			if self:_savePlayerInfo(state, true) then
				self:_sendShopResult(player, true, "Unequipped " .. skin.name .. ".")
			else
				self:_sendShopResult(player, false, "Unequipped, but save failed. It may not persist.", "datastore_failed")
			end
		end
	end
end

function GameService:_handleDebugAction(player: Player, payload)
	if not canUseWorldResizeDebug(player) or typeof(payload) ~= "table" then
		return
	end

	if payload.action == "toggle_world_resize" then
		self.debugForceMaxWorldScale = not (self.debugForceMaxWorldScale == true)
	end
end

function GameService:_handleRespawnRequest(player: Player)
	local state = self.playersByUserId[player.UserId]
	if not state then
		return
	end

	local now = os.clock()
	if state.lastRespawnRequestAt and now - state.lastRespawnRequestAt < 2 then
		return
	end
	state.lastRespawnRequestAt = now
	self:_respawnPlayer(state)
end

function GameService:_sendShopResult(player: Player, ok: boolean, message: string, reason: string?)
	self.remotes.ShopAction:FireClient(player, {
		type = "result",
		ok = ok,
		reason = reason,
		message = message,
	})
end

function GameService:_handleInput(player: Player, payload)
	local state = self.playersByUserId[player.UserId]
	if not state or typeof(payload) ~= "table" then
		return
	end

	local input = state.input
	if typeof(payload.ax) == "number" and typeof(payload.ay) == "number" then
		input.aim = Vec2.safeUnit(Vector2.new(
			math.clamp(payload.ax, -1, 1),
			math.clamp(payload.ay, -1, 1)
		), input.aim)
	end

	if typeof(payload.tx) == "number" and typeof(payload.ty) == "number" then
		input.target = self:_clampToWorld(Vector2.new(payload.tx, payload.ty))
	end

	if typeof(payload.vw) == "number" and typeof(payload.vh) == "number" then
		local nextView = Vector2.new(
			math.clamp(payload.vw, 320, 3840),
			math.clamp(payload.vh, 240, 2160)
		)
		if (nextView - input.view).Magnitude >= 24 then
			state.needsStaticSnapshot = true
		end
		input.view = nextView
	end

	if typeof(payload.zm) == "number" then
		local nextZoom = math.clamp(payload.zm, Config.Render.MinZoom or 0.22, Config.Render.MaxZoom or 1.9)
		if math.abs(nextZoom - input.zoom) >= 0.03 then
			state.needsStaticSnapshot = true
		end
		input.zoom = nextZoom
	end

	if typeof(payload.sp) == "number" then
		input.splitToken = math.floor(payload.sp)
	end

	if typeof(payload.ej) == "number" then
		input.ejectToken = math.floor(payload.ej)
	end

	-- Extra input fields: double/triple split, freeze. See Config.
	if typeof(payload.d2) == "number" then
		input.doubleSplitToken = math.floor(payload.d2)
	end
	if typeof(payload.d3) == "number" then
		input.tripleSplitToken = math.floor(payload.d3)
	end
	if typeof(payload.fz) == "number" then
		input.freezeToken = math.floor(payload.fz)
	end
	if typeof(payload.cn) == "number" then
		input.cannibalHeld = payload.cn ~= 0
	end
end

function GameService:_step(dt: number)
	self:_updateWorld(dt)
	self:_maintainFood()
	self:_maintainViruses(self:_virusTarget())
	self:_maintainSpawners(self:_spawnerTarget())
	self:_maintainBarriers(self:_barrierTarget())

	self:_processCommands()
	self:_moveCells(dt)
	self:_updateLifeXp(dt)
	self:_moveEjected(dt)
	self:_moveViruses(dt)
	self:_rebuildEjectedGrid()
	self:_resolveEjectedMassPush()
	self:_decaySpawners(dt)
	self:_rebuildStaticGridsIfDirty()
	self:_moveBarriers(dt)
	self:_rebuildCellGrid()
	self:_rebuildStaticGridsIfDirty()
	self:_resolveSamePlayerPush()
	self:_resolveBarrierPush()
	self:_rebuildCellAndEjectedGrids()
	self:_handleEating()
	self:_bumpVirusesFromEjected()
	self:_handleSpawners()
	self.staticOverlapAccumulator += dt
	local staticOverlapDt = 1 / math.max(Config.Simulation.StaticOverlapHz or 10, 1)
	if self.staticOverlapAccumulator >= staticOverlapDt then
		self.staticOverlapAccumulator = 0
		self:_resolveStaticCircleOverlaps()
	end
	self:_rebuildMovingGrids()
	self:_updatePlayerCenters()
end

function GameService:_processCommands()
	for _, state in self.playersByUserId do
		if state.input.splitToken ~= state.lastSplitToken then
			state.lastSplitToken = state.input.splitToken
			self:_splitPlayer(state)
		end

		-- Double-split (Q): every eligible cell splits into 2 pieces.
		-- Total cell count doubles each press (1→2→4→8→16→32, capped
		-- at MaxCells).
		if Config.Cell.DoubleSplitEnabled
			and state.input.doubleSplitToken ~= state.lastDoubleSplitToken then
			state.lastDoubleSplitToken = state.input.doubleSplitToken
			self:_splitEveryCellIntoN(state, 2)
		end

		-- Triple-split (E): every eligible cell splits into 3 pieces.
		-- Total cell count triples each press (1→3→9→27, capped at
		-- MaxCells).
		if Config.Cell.TripleSplitEnabled
			and state.input.tripleSplitToken ~= state.lastTripleSplitToken then
			state.lastTripleSplitToken = state.input.tripleSplitToken
			self:_splitEveryCellIntoN(state, 3)
		end

		-- Freeze (F): toggles state.frozen. Frozen owner => cells skip
		-- movement and same-player push, but keep boost so momentum
		-- resumes on unfreeze. See _toggleFreeze and Config.Freeze.
		if Config.Freeze.Enabled
			and state.input.freezeToken ~= state.lastFreezeToken then
			state.lastFreezeToken = state.input.freezeToken
			self:_toggleFreeze(state)
		end

		if state.input.ejectToken ~= state.lastEjectToken then
			local requested = math.max(0, math.min(
				state.input.ejectToken - state.lastEjectToken,
				Config.Ejected.MaxEjectsPerStep
			))
			state.lastEjectToken = state.input.ejectToken
			local cells = self:_sortedPlayerCells(state)
			for _ = 1, requested do
				if not self:_ejectMassFromCells(state, cells) then
					break
				end
			end
		end
	end
end

function GameService:_sortedPlayerCells(state)
	local cells = {}
	for _, id in state.cells do
		local cell = self.cells[id]
		if cell then
			cells[#cells + 1] = cell
		end
	end
	table.sort(cells, sortCellsByMassDesc)
	return cells
end

function GameService:_splitPlayer(state)
	local cells = self:_sortedPlayerCells(state)

	local splitsLeft = math.min(Config.Cell.MaxSplitPiecesPerCommand, Config.Player.MaxCells - #state.cells)
	for _, cell in cells do
		if splitsLeft <= 0 then
			break
		end
		if cell.mass >= Config.Cell.SplitMinMass * 2 then
			local dir = self:_cellAimDirection(state, cell)
			local childMass = cell.mass * 0.5
			self:_setCellMass(cell, childMass)
			cell.canRecombineAt = os.clock() + recombineDelayForMass(cell.mass)
			local childRadius = massToRadius(childMass)
			-- If frozen, spawn the child with zero velocity but nudge it
			-- a short distance along aim so the group has a direction
			-- (not stacked on one point). Cells still stay bunched close.
			-- Non-frozen: normal outward launch.
			local childVelocity = if state.frozen
				then Vector2.zero
				else dir * self:_splitImpulseForMass(cell.mass)
			local spawnPos
			if state.frozen then
				local nudge = math.max(Config.Freeze and Config.Freeze.SplitNudgeDistance or 0, 0)
				spawnPos = cell.pos + dir * (childRadius * 0.6 + nudge)
				spawnPos = self:_clampToWorld(spawnPos, childRadius)
			else
				spawnPos = self:_adjustSpawnPositionForBarriers(
					cell.pos,
					cell.pos + dir * (cell.radius * 2 + 4),
					childRadius
				)
			end
			local child = self:_spawnPlayerCell(
				state,
				spawnPos,
				childMass,
				childVelocity
			)
			if child then
				child.sweptEatStartPos = cell.pos
			end
			splitsLeft -= 1
		end
	end
end

function GameService:_splitEveryCellIntoN(state, piecesPerCell: number)
	-- Each currently-eligible cell splits into `piecesPerCell` equal
	-- pieces. Total count multiplies by piecesPerCell per press (subject
	-- to MaxCells and SplitMinMass per-piece minimum). Used by Q (=2)
	-- and E (=3). Space still uses _splitPlayer (halves each cell in
	-- half, same as N=2 here, but with the classic split feel).
	piecesPerCell = math.max(math.floor(piecesPerCell), 2)
	local cells = self:_sortedPlayerCells(state)
	if #cells == 0 then
		return
	end

	for _, cell in cells do
		local freeSlots = Config.Player.MaxCells - #state.cells
		if freeSlots <= 0 then
			break
		end
		if not self.cells[cell.id] then
			continue
		end

		local minPiece = math.max(Config.Cell.SplitMinMass or 1, 1)
		local piecesAllowedByMass = math.max(math.floor(cell.mass / minPiece), 1)
		local pieces = math.min(piecesPerCell, freeSlots + 1, piecesAllowedByMass)
		if pieces < 2 then
			continue
		end

		local newChildren = pieces - 1
		local pieceMass = cell.mass / pieces
		local pieceRadius = massToRadius(pieceMass)
		local originalMass = cell.mass
		local aim = self:_cellAimDirection(state, cell)

		self:_setCellMass(cell, pieceMass)
		cell.canRecombineAt = os.clock() + recombineDelayForMass(cell.mass)

		for i = 1, newChildren do
			local fanSpread = math.max(Config.Cell.MultiSplitFanRadians or 0, 0)
			local fanIndex = i - (newChildren + 1) * 0.5
			local perChild = if newChildren > 1 then fanSpread / (newChildren - 1) else 0
			local fanAngle = fanIndex * perChild
			local cos = math.cos(fanAngle)
			local sin = math.sin(fanAngle)
			local dir = Vec2.safeUnit(Vector2.new(
				aim.X * cos - aim.Y * sin,
				aim.X * sin + aim.Y * cos
			), aim)

			local staggerStep = pieceRadius * 1.4
			local staggerOffset = (i - 1) * staggerStep
			local childVelocity
			local spawnPos
			if state.frozen then
				childVelocity = Vector2.zero
				local nudge = math.max(Config.Freeze and Config.Freeze.SplitNudgeDistance or 0, 0)
				spawnPos = cell.pos + dir * (pieceRadius * 0.6 + nudge + staggerOffset)
				spawnPos = self:_clampToWorld(spawnPos, pieceRadius)
			else
				childVelocity = dir * self:_splitImpulseForMass(originalMass)
				spawnPos = self:_adjustSpawnPositionForBarriers(
					cell.pos,
					cell.pos + dir * (cell.radius * 2 + 4 + staggerOffset),
					pieceRadius
				)
			end

			local child = self:_spawnPlayerCell(state, spawnPos, pieceMass, childVelocity)
			if child then
				child.sweptEatStartPos = cell.pos
			end
		end
	end
end

function GameService:_multiSplitBiggest(state, totalPieces: number)
	-- Splits the biggest eligible cell into `totalPieces` equal pieces
	-- (parent keeps 1/totalPieces of its mass, and (totalPieces - 1)
	-- children spawn along aim, fanned slightly). Respects the 32-cell
	-- cap and the SplitMinMass per-piece minimum. Kept for callers that
	-- still want single-cell behavior; Q/E now use _splitEveryCellIntoN.
	totalPieces = math.max(math.floor(totalPieces), 2)
	local cells = self:_sortedPlayerCells(state)
	local biggest = cells[1]
	if not biggest then
		return
	end

	local freeSlots = Config.Player.MaxCells - #state.cells
	if freeSlots <= 0 then
		return
	end

	local minPiece = math.max(Config.Cell.SplitMinMass or 1, 1)
	local piecesAllowedByMass = math.max(math.floor(biggest.mass / minPiece), 1)
	local pieces = math.min(totalPieces, freeSlots + 1, piecesAllowedByMass)
	if pieces < 2 then
		return
	end

	local newChildren = pieces - 1
	local pieceMass = biggest.mass / pieces
	local pieceRadius = massToRadius(pieceMass)
	local originalMass = biggest.mass
	local aim = self:_cellAimDirection(state, biggest)

	self:_setCellMass(biggest, pieceMass)
	biggest.canRecombineAt = os.clock() + recombineDelayForMass(biggest.mass)

	for i = 1, newChildren do
		-- Tight fan across aim so children fly nearly straight. Config
		-- knob Cell.MultiSplitFanRadians controls the total spread; 0
		-- fires everything exactly on aim.
		local fanSpread = math.max(Config.Cell.MultiSplitFanRadians or 0, 0)
		local fanIndex = i - (newChildren + 1) * 0.5
		local perChild = if newChildren > 1 then fanSpread / (newChildren - 1) else 0
		local fanAngle = fanIndex * perChild
		local cos = math.cos(fanAngle)
		local sin = math.sin(fanAngle)
		local dir = Vec2.safeUnit(Vector2.new(
			aim.X * cos - aim.Y * sin,
			aim.X * sin + aim.Y * cos
		), aim)

		local childVelocity
		local spawnPos
		-- Stagger children along aim so a straight-line (fan~=0) split
		-- doesn't spawn every child on the exact same pixel.
		local staggerStep = pieceRadius * 1.4
		local staggerOffset = (i - 1) * staggerStep
		if state.frozen then
			childVelocity = Vector2.zero
			local nudge = math.max(Config.Freeze and Config.Freeze.SplitNudgeDistance or 0, 0)
			spawnPos = biggest.pos + dir * (pieceRadius * 0.6 + nudge + staggerOffset)
			spawnPos = self:_clampToWorld(spawnPos, pieceRadius)
		else
			childVelocity = dir * self:_splitImpulseForMass(originalMass)
			spawnPos = self:_adjustSpawnPositionForBarriers(
				biggest.pos,
				biggest.pos + dir * (biggest.radius * 2 + 4 + staggerOffset),
				pieceRadius
			)
		end

		local child = self:_spawnPlayerCell(state, spawnPos, pieceMass, childVelocity)
		if child then
			child.sweptEatStartPos = biggest.pos
		end
	end
end

-- ==================================================================
-- FREEZE ability (toggle). Flips state.frozen. When frozen:
--  * _moveCells skips position updates and boost decay for the
--    owner's cells, so split momentum is preserved verbatim.
--  * _resolveSamePlayerPush skips them too, so cells cannot drift
--    apart from mutual repulsion while parked.
--  * _handleEating is NOT gated, so touching cells past their
--    recombine timer still merge normally.
-- Debounce prevents accidental double-taps.
-- ==================================================================
function GameService:_toggleFreeze(state)
	local cfg = Config.Freeze
	if not cfg or not cfg.Enabled then
		return
	end

	local now = os.clock()
	local debounce = cfg.Debounce or 0.15
	if state.lastFreezeAt and now - state.lastFreezeAt < debounce then
		return
	end
	state.lastFreezeAt = now

	-- Cost only applies when entering the frozen state.
	if not state.frozen then
		local cost = cfg.Cost or 0
		if cost > 0 then
			if (state.coins or 0) < cost then
				return
			end
			state.coins = state.coins - cost
			state.needsProgressionSave = true
		end
	else
		-- Transitioning frozen -> not frozen. Mark an unfreeze grace
		-- window so _resolveSamePlayerPush eases stacked cells apart
		-- instead of exploding them outward in one step. Also nudge
		-- coincident cells by a tiny deterministic offset so the push
		-- has a direction to resolve.
		local graceSeconds = math.max(cfg.UnfreezeGraceSeconds or 0, 0)
		if graceSeconds > 0 then
			state.unfreezeGraceUntil = now + graceSeconds
			state.unfreezeGraceStart = now
		end
		local jitter = math.max(cfg.UnfreezeJitterDistance or 0, 0)
		if jitter > 0 then
			for _, id in state.cells do
				local cell = self.cells[id]
				if cell then
					local angle = ((cell.id * 73) % 628) / 100
					cell.pos = self:_clampToWorld(
						cell.pos + Vec2.fromAngle(angle) * jitter,
						cell.radius
					)
				end
			end
		end

		-- Release fan: add a radial outward boost from the group
		-- centroid so a stacked pile actually FANS OUT on unfreeze
		-- instead of stalling in place while the cursor pulls the
		-- cluster inward.
		--
		-- Design:
		--   * Impulse strength is roughly UNIFORM per cell (no mass
		--     amplification of tiny cells — that produces "rope"
		--     spread where small cells fly to the map edge while big
		--     cells barely move).
		--   * F-spam guard: only apply if freeze was actually held for
		--     ReleaseMinHoldSeconds. Instant re-toggles do nothing so
		--     you can't stack impulses.
		--   * Boost cap: after applying, clamp total cell.boost
		--     magnitude to ReleaseImpulse so back-to-back releases
		--     never accumulate.
		--   * Skipped for 0/1 cells and if the pile isn't actually
		--     stacked (mean distance from centroid > 2 * biggest cell
		--     radius) — no explosive push when your cells are already
		--     spread out.
		local releaseImpulse = math.max(cfg.ReleaseImpulse or 0, 0)
		local minHold = math.max(cfg.ReleaseMinHoldSeconds or 0, 0)
		local heldEnough = (now - (state.lastFreezeAt or 0)) >= minHold
			or (state.frozenSince and now - state.frozenSince >= minHold)
		if releaseImpulse > 0 and #state.cells > 1 and heldEnough then
			local cx, cy, totalMass = 0, 0, 0
			local biggestRadius = 0
			for _, id in state.cells do
				local c = self.cells[id]
				if c then
					cx += c.pos.X * c.mass
					cy += c.pos.Y * c.mass
					totalMass += c.mass
					if c.radius > biggestRadius then
						biggestRadius = c.radius
					end
				end
			end
			if totalMass > 0 then
				local centroid = Vector2.new(cx / totalMass, cy / totalMass)

				-- Only fire if the pile is actually clustered.
				local sumDist = 0
				local counted = 0
				for _, id in state.cells do
					local c = self.cells[id]
					if c then
						sumDist += (c.pos - centroid).Magnitude
						counted += 1
					end
				end
				local meanDist = if counted > 0 then sumDist / counted else 0
				local stackThreshold = math.max(biggestRadius * 1.6, 1)
				if meanDist <= stackThreshold then
					for _, id in state.cells do
						local cell = self.cells[id]
						if cell then
							local delta = cell.pos - centroid
							local dist = delta.Magnitude
							local dir
							if dist > 0.1 then
								dir = delta / dist
							else
								-- Deterministic direction if cell is exactly at centroid.
								local angle = ((cell.id * 137) % 628) / 100
								dir = Vec2.fromAngle(angle)
							end
							-- Uniform impulse per cell, REPLACING any prior
							-- boost so F-spam and residual split boost can
							-- never stack. Cap not needed since we assign
							-- rather than add.
							cell.boost = dir * releaseImpulse
						end
					end
				end
			end
		end
	end

	state.frozen = not state.frozen
	if state.frozen then
		state.frozenSince = now
	else
		state.frozenSince = nil
	end
	return
end

function GameService:_ejectMassFromCells(state, cells)
	-- Identify the "target" cell: the owned cell closest to the cursor
	-- world position. If Config.Ejected.SkipTargetCell is true, that
	-- cell is excluded from firing so it becomes a pure receiver. This
	-- is what makes feeding a small cell in the middle of a cluster
	-- actually work — otherwise the surrounding big cells eat each
	-- other's pellets before they can cross to the tiny receiver.
	local targetCellId = nil
	if Config.Ejected.SkipTargetCell and state.input.target then
		local bestDistSq = math.huge
		for _, cell in cells do
			if self.cells[cell.id] then
				local d = state.input.target - cell.pos
				local dSq = d.X * d.X + d.Y * d.Y
				if dSq < bestDistSq then
					bestDistSq = dSq
					targetCellId = cell.id
				end
			end
		end
	end

	local eligible = {}
	for _, cell in cells do
		if self.cells[cell.id]
			and canCellFireEjected(cell)
			and cell.id ~= targetCellId
		then
			eligible[#eligible + 1] = cell
		end
	end

	local eligibleCount = #eligible
	if eligibleCount == 0 then
		-- Fall back to firing from the target cell if it's the only
		-- eligible option (single-cell scenario).
		if targetCellId then
			for _, cell in cells do
				if cell.id == targetCellId and canCellFireEjected(cell) then
					eligible[#eligible + 1] = cell
				end
			end
			eligibleCount = #eligible
		end
		if eligibleCount == 0 then
			return false
		end
	end

	local perTickLimit = math.min(eligibleCount, self:_ejectCellsPerTickLimit())
	local startIndex = (state.ejectCycleOffset % eligibleCount) + 1
	local firedAny = false

	for step = 0, perTickLimit - 1 do
		local index = ((startIndex - 1 + step) % eligibleCount) + 1
		local cell = eligible[index]
		if self.cells[cell.id] and canCellFireEjected(cell) then
			local aim = self:_cellAimDirection(state, cell)
			local halfCone = math.rad(Config.Ejected.ConeDegrees) * 0.5
			local angle = self.rng:NextNumber(-halfCone, halfCone)
			local cos = math.cos(angle)
			local sin = math.sin(angle)
			local shotDir = Vec2.safeUnit(Vector2.new(
				aim.X * cos - aim.Y * sin,
				aim.X * sin + aim.Y * cos
			), aim)
			local cost = math.max(Config.Ejected.Cost or 0, 0)
			if cost > 0 then
				self:_setCellMass(cell, cell.mass - cost)
			end
			local spawnDistance = cell.radius + Config.Ejected.Radius + (Config.Ejected.NozzleOffset or 0)
			self:_spawnEjected(cell.pos + aim * spawnDistance, shotDir, state.userId, cell.id, targetCellId)
			firedAny = true
		end
	end
	state.ejectCycleOffset = (startIndex - 1 + perTickLimit) % eligibleCount

	return firedAny
end

function GameService:_cellAimDirection(state, cell): Vector2
	if state.input.target then
		return Vec2.safeUnit(state.input.target - cell.pos, state.input.aim)
	end
	return state.input.aim
end

function GameService:_cellMoveVector(state, cell)
	if not state.input.target then
		return state.input.aim, 1
	end

	local offset = state.input.target - cell.pos
	local distance = offset.Magnitude
	local deadZone = math.max(
		Config.Player.MovementDeadZone,
		cell.radius * Config.Player.MovementDeadZoneRadiusScale
	)
	if distance <= deadZone then
		return Vector2.zero, 0
	end

	local slowDistance = math.max(
		Config.Player.MovementSlowDistance,
		cell.radius * Config.Player.MovementSlowRadiusScale
	)
	local speedScale = math.clamp((distance - deadZone) / slowDistance, 0, 1)
	if speedScale < 0.02 then
		return Vector2.zero, 0
	end

	return offset / distance, speedScale
end

function GameService:_moveCells(dt: number)
	local now = os.clock()

	-- Pre-compute per-player cohesion data so cells in many pieces
	-- naturally group up: cap each cell's max speed at the biggest
	-- owned cell's speed * ClusterMaxSpeedRatio, and optionally add
	-- a gentle pull toward the group centroid. Small cells can no
	-- longer sprint away from the pack.
	local playerBaseSpeed = {}
	local playerCentroid = {}
	local clusterRatio = math.max(Config.Cell.ClusterMaxSpeedRatio or 1, 1)
	local cohesion = math.clamp(Config.Cell.CohesionStrength or 0, 0, 1)
	for userId, state in self.playersByUserId do
		if #state.cells > 1 then
			local maxMass = 0
			local totalMass = 0
			local cx, cy = 0, 0
			for _, id in state.cells do
				local c = self.cells[id]
				if c then
					if c.mass > maxMass then
						maxMass = c.mass
					end
					totalMass += c.mass
					cx += c.pos.X * c.mass
					cy += c.pos.Y * c.mass
				end
			end
			if maxMass > 0 then
				local bigSpeed = Config.Player.BaseSpeed * (Config.Player.InitialMass / maxMass) ^ Config.Player.SpeedExponent
				bigSpeed = math.clamp(bigSpeed, Config.Player.MinSpeed, Config.Player.BaseSpeed)
				playerBaseSpeed[userId] = bigSpeed
			end
			if totalMass > 0 then
				playerCentroid[userId] = Vector2.new(cx / totalMass, cy / totalMass)
			end
		end
	end

	for _, cell in self.cells do
		-- Frozen owner => hard stop. Skip position update AND boost decay
		-- so split momentum resumes verbatim on unfreeze. Mass decay still
		-- applies so parking doesn't cheese decay timers.
		local ownerState = self.playersByUserId[cell.ownerUserId]
		if ownerState and ownerState.frozen then
			if cell.mass > Config.Player.MinDecayMass then
				self:_setCellMass(cell, cell.mass * (1 - Config.Player.DecayPerSecond * dt))
			end
			continue
		end
		local moveStart = cell.sweptEatStartPos or cell.pos
		local dir, speedScale = self:_cellMoveVector(cell.owner, cell)
		local speed = Config.Player.BaseSpeed * (Config.Player.InitialMass / math.max(cell.mass, 1)) ^ Config.Player.SpeedExponent
		speed = math.clamp(speed, Config.Player.MinSpeed, Config.Player.BaseSpeed)

		-- Cluster speed cap: keep small pieces from outrunning the pack.
		local bigSpeed = playerBaseSpeed[cell.ownerUserId]
		if bigSpeed and speed > bigSpeed * clusterRatio then
			speed = bigSpeed * clusterRatio
		end

		-- Optional cohesion pull toward the group centroid. Only kicks
		-- in when the cell is far from the centroid, so it doesn't
		-- fight the player's cursor movement at small offsets.
		local pull = Vector2.zero
		if cohesion > 0 then
			local centroid = playerCentroid[cell.ownerUserId]
			if centroid then
				local delta = centroid - cell.pos
				local distance = delta.Magnitude
				local slack = cell.radius * 1.8
				if distance > slack then
					local weight = math.clamp((distance - slack) / slack, 0, 1)
					pull = (delta / distance) * (speed * cohesion * weight)
				end
			end
		end

		cell.boost *= math.max(0, 1 - dt * 1.9)
		cell.sweptEatStartPos = moveStart
		cell.sweptEatBoostSpeed = cell.boost.Magnitude
		cell.pos += (dir * speed * speedScale + pull + cell.boost) * dt
		cell.pos = self:_clampToWorld(cell.pos, cell.radius)

		if cell.mass > Config.Player.MinDecayMass then
			self:_setCellMass(cell, cell.mass * (1 - Config.Player.DecayPerSecond * dt))
		end
	end
end

function GameService:_updateLifeXp(dt: number)
	local lifeXpCap = Config.Progression.LifeXpCap or 25000
	local xpRate = Config.Progression.XpRate or 0.6
	local exponent = Config.Progression.MassExponent or 0.5
	for _, state in self.playersByUserId do
		local xpPerSecond = 0
		for _, id in state.cells do
			local cell = self.cells[id]
			if cell then
				xpPerSecond += xpRate * (math.max(cell.mass, 0) ^ exponent)
			end
		end

		if xpPerSecond > 0 then
			state.lifeXp = math.min(lifeXpCap, state.lifeXp + xpPerSecond * dt)
			self:_publishLifeXpAttribute(state, false)
		end
	end
end

function GameService:_moveEjected(dt: number)
	local now = os.clock()
	local playerCount = self:_playerCount()
	local lifeSeconds = Config.Ejected.LifeSeconds
	if playerCount >= Config.Network.HeavyLoadPlayers then
		lifeSeconds = Config.Ejected.HeavyLoadLifeSeconds or lifeSeconds
	elseif playerCount >= Config.Network.AdaptiveStartPlayers then
		lifeSeconds = Config.Ejected.LoadLifeSeconds or lifeSeconds
	end

	for id, ejected in self.ejected do
		local nextPos = ejected.pos + ejected.vel * dt
		local worldMin, worldMax = self:_worldBounds()
		local minX = worldMin.X + ejected.radius
		local maxX = worldMax.X - ejected.radius
		local minY = worldMin.Y + ejected.radius
		local maxY = worldMax.Y - ejected.radius
		local bounceScale = math.max(Config.Ejected.WallBounceScale or 0, 0)

		if nextPos.X < minX then
			nextPos = Vector2.new(minX, nextPos.Y)
			if ejected.vel.X < 0 then
				ejected.vel = Vector2.new(-ejected.vel.X * bounceScale, ejected.vel.Y)
			end
		elseif nextPos.X > maxX then
			nextPos = Vector2.new(maxX, nextPos.Y)
			if ejected.vel.X > 0 then
				ejected.vel = Vector2.new(-ejected.vel.X * bounceScale, ejected.vel.Y)
			end
		end
		if nextPos.Y < minY then
			nextPos = Vector2.new(nextPos.X, minY)
			if ejected.vel.Y < 0 then
				ejected.vel = Vector2.new(ejected.vel.X, -ejected.vel.Y * bounceScale)
			end
		elseif nextPos.Y > maxY then
			nextPos = Vector2.new(nextPos.X, maxY)
			if ejected.vel.Y > 0 then
				ejected.vel = Vector2.new(ejected.vel.X, -ejected.vel.Y * bounceScale)
			end
		end

		ejected.pos = nextPos
		ejected.vel *= math.max(0, 1 - Config.Ejected.DragPerSecond * dt)
		ejected.pos = self:_clampToWorld(ejected.pos, ejected.radius)

		if now - ejected.spawnedAt > lifeSeconds then
			self:_removeEjected(id)
		end
	end
end

function GameService:_moveViruses(dt: number)
	local drag = math.max(Config.Virus.DragPerSecond or 0, 0)
	local stopSpeed = math.max(Config.Virus.StopSpeed or 0, 0)
	local stopSpeedSquared = stopSpeed * stopSpeed
	local bounceScale = math.max(Config.Virus.WallBounceScale or 0, 0)
	local worldMin, worldMax = self:_worldBounds()
	local moved = false

	for _, virus in self.viruses do
		local velocity = virus.vel or Vector2.zero
		local speedSquared = velocity:Dot(velocity)
		if speedSquared <= stopSpeedSquared then
			if speedSquared > 0 then
				virus.vel = Vector2.zero
			end
			continue
		end

		local nextPos = virus.pos + velocity * dt
		local minX = worldMin.X + virus.radius
		local maxX = worldMax.X - virus.radius
		local minY = worldMin.Y + virus.radius
		local maxY = worldMax.Y - virus.radius

		if nextPos.X < minX then
			nextPos = Vector2.new(minX, nextPos.Y)
			if velocity.X < 0 then
				velocity = Vector2.new(-velocity.X * bounceScale, velocity.Y)
			end
		elseif nextPos.X > maxX then
			nextPos = Vector2.new(maxX, nextPos.Y)
			if velocity.X > 0 then
				velocity = Vector2.new(-velocity.X * bounceScale, velocity.Y)
			end
		end

		if nextPos.Y < minY then
			nextPos = Vector2.new(nextPos.X, minY)
			if velocity.Y < 0 then
				velocity = Vector2.new(velocity.X, -velocity.Y * bounceScale)
			end
		elseif nextPos.Y > maxY then
			nextPos = Vector2.new(nextPos.X, maxY)
			if velocity.Y > 0 then
				velocity = Vector2.new(velocity.X, -velocity.Y * bounceScale)
			end
		end

		virus.pos = self:_clampToWorld(nextPos, virus.radius)
		virus.vel = velocity * math.max(0, 1 - drag * dt)
		if virus.vel:Dot(virus.vel) <= stopSpeedSquared then
			virus.vel = Vector2.zero
		end
		moved = true
	end

	if moved then
		self:_markStaticGridsDirty()
	end
end

function GameService:_ejectedCollisionMaxImpacts(): number
	local playerCount = self:_playerCount()
	if playerCount >= Config.Network.HeavyLoadPlayers then
		return Config.Ejected.HeavyLoadCollisionMaxImpactsPerMass or 0
	end
	if playerCount >= Config.Network.AdaptiveStartPlayers then
		return Config.Ejected.LoadCollisionMaxImpactsPerMass or Config.Ejected.CollisionMaxImpactsPerMass or 0
	end
	return Config.Ejected.CollisionMaxImpactsPerMass or 0
end

function GameService:_resolveEjectedMassPush()
	if Config.Ejected.CollisionEnabled == false or self.ejectedCount <= 1 then
		return
	end

	local maxImpacts = math.max(self:_ejectedCollisionMaxImpacts(), 0)
	if maxImpacts <= 0 then
		return
	end

	local minSpeed = math.max(Config.Ejected.CollisionMinSpeed or 0, 0)
	local minSpeedSquared = minSpeed * minSpeed
	local radiusScale = math.max(Config.Ejected.CollisionRadiusScale or 1, 1)
	local strength = math.clamp(Config.Ejected.CollisionStrength or 0.5, 0, 1)
	local velocityTransfer = math.clamp(Config.Ejected.CollisionVelocityTransfer or 0.3, 0, 1)
	local maxPush = math.max(Config.Ejected.CollisionMaxPush or Config.Ejected.Radius, 0)
	local queryRadius = Config.Ejected.Radius * radiusScale * 2
	local processedPairs = self.ejectedCollisionPairsScratch
	table.clear(processedPairs)

	for id, ejected in self.ejected do
		local speedSquared = ejected.vel:Dot(ejected.vel)
		if speedSquared < minSpeedSquared then
			continue
		end

		local impacts = 0
		local candidates = self.ejectedGrid:query(ejected.pos, queryRadius, self.queryScratch, self.querySeenScratch)
		for _, otherId in candidates do
			if impacts >= maxImpacts then
				break
			end
			if otherId == id then
				continue
			end

			local other = self.ejected[otherId]
			if not other then
				continue
			end

			local otherSpeedSquared = other.vel:Dot(other.vel)
			if otherSpeedSquared >= minSpeedSquared and otherId < id then
				continue
			end

			local minDist = (ejected.radius + other.radius) * radiusScale
			local delta = other.pos - ejected.pos
			local distanceSquared = delta:Dot(delta)
			if distanceSquared >= minDist * minDist then
				continue
			end

			local lowId = math.min(id, otherId)
			local highId = math.max(id, otherId)
			local pairKey = tostring(lowId) .. ":" .. tostring(highId)
			if processedPairs[pairKey] then
				continue
			end
			processedPairs[pairKey] = true

			local dist = math.sqrt(math.max(distanceSquared, 0))
			local dir = if dist > 0.001 then delta / dist else Vec2.fromAngle((id * 43 + otherId * 89) % 628 / 100)
			local overlap = minDist - dist
			local push = math.min(overlap * strength, maxPush)
			local offset = dir * (push * 0.5)
			ejected.pos = self:_clampToWorld(ejected.pos - offset, ejected.radius)
			other.pos = self:_clampToWorld(other.pos + offset, other.radius)

			local relativeVelocity = ejected.vel - other.vel
			local closingSpeed = relativeVelocity:Dot(dir)
			if closingSpeed > 0 then
				local impulse = dir * (closingSpeed * velocityTransfer)
				ejected.vel -= impulse
				other.vel += impulse
			else
				local shove = dir * (push * velocityTransfer)
				ejected.vel -= shove
				other.vel += shove
			end

			impacts += 1
		end
	end
end

function GameService:_moveBarriers(dt: number)
	for _, barrier in self.barriers do
		barrier.vel *= math.max(0, 1 - Config.Barrier.Friction * dt)
		barrier.pos += barrier.vel * dt
		barrier.pos = self:_clampToWorld(
			barrier.pos,
			math.max(barrier.halfSize.X, barrier.halfSize.Y)
		)
	end

	local barrierList = {}
	for _, barrier in self.barriers do
		barrierList[#barrierList + 1] = barrier
	end
	for i = 1, #barrierList - 1 do
		local a = barrierList[i]
		for j = i + 1, #barrierList do
			local b = barrierList[j]
			self:_resolveBarrierBarrierOverlap(a, b)
			a.pos = self:_clampToWorld(
				a.pos,
				math.max(a.halfSize.X, a.halfSize.Y)
			)
			b.pos = self:_clampToWorld(
				b.pos,
				math.max(b.halfSize.X, b.halfSize.Y)
			)
		end
	end

	local maxFoodRadius = Config.Food.Radius
	local maxEjectedRadius = Config.Ejected.Radius
	local maxVirusRadius = self:_maxEntityRadius(self.viruses, Config.Virus.Radius)
	local maxSpawnerRadius = self:_maxEntityRadius(self.spawners, Config.Spawner.BaseRadius)
	for _, barrier in self.barriers do
		local barrierRadius = math.max(barrier.halfSize.X, barrier.halfSize.Y)

		local foodCandidates = self.foodGrid:query(barrier.pos, barrierRadius + maxFoodRadius, self.queryScratch, self.querySeenScratch)
		local removedFood = false
		for _, id in foodCandidates do
			local food = self.food[id]
			if food then
				local dir, penetration = self:_circleBarrierOverlap(food.pos, food.radius, barrier)
				if dir and penetration and penetration > 0 then
					self.food[id] = nil
					removedFood = true
				end
			end
		end
		if removedFood then
			self:_markStaticGridsDirty()
		end

		local ejectedCandidates = self.ejectedGrid:query(barrier.pos, barrierRadius + maxEjectedRadius, self.queryScratch, self.querySeenScratch)
		for _, id in ejectedCandidates do
			local ejected = self.ejected[id]
			if ejected then
				local dir, penetration = self:_circleBarrierOverlap(ejected.pos, ejected.radius, barrier)
				if dir and penetration and penetration > 0 then
					ejected.pos += dir * penetration
					ejected.vel += barrier.vel * 0.55
					ejected.pos = self:_clampToWorld(ejected.pos, ejected.radius)
				end
			end
		end

		local virusCandidates = self.virusGrid:query(barrier.pos, barrierRadius + maxVirusRadius, self.queryScratch, self.querySeenScratch)
		for _, id in virusCandidates do
			local virus = self.viruses[id]
			if virus then
				local dir, penetration = self:_circleBarrierOverlap(virus.pos, virus.radius, barrier)
				if dir and penetration and penetration > 0 then
					barrier.pos -= dir * penetration
					barrier.vel -= dir * penetration * 2
				end
			end
		end

		local spawnerCandidates = self.spawnerGrid:query(barrier.pos, barrierRadius + maxSpawnerRadius, self.queryScratch, self.querySeenScratch)
		for _, id in spawnerCandidates do
			local spawner = self.spawners[id]
			if spawner then
				local dir, penetration = self:_circleBarrierOverlap(spawner.pos, spawner.radius, barrier)
				if dir and penetration and penetration > 0 then
					barrier.pos -= dir * penetration
					barrier.vel -= dir * penetration * 2
				end
			end
		end

		barrier.pos = self:_clampToWorld(
			barrier.pos,
			math.max(barrier.halfSize.X, barrier.halfSize.Y)
		)
	end
end

function GameService:_resolveCircleEntityOverlap(a, b, fallbackSeed: number)
	local minDist = a.radius + b.radius
	local dir = circleSeparationDirection(a.pos, b.pos, fallbackSeed)
	local distanceSq = Vec2.distanceSquared(a.pos, b.pos)
	if distanceSq >= minDist * minDist then
		return
	end

	local distance = math.sqrt(math.max(distanceSq, 0))
	local overlap = minDist - distance
	local offset = dir * (overlap * 0.5)
	a.pos = self:_clampToWorld(a.pos - offset, a.radius)
	b.pos = self:_clampToWorld(b.pos + offset, b.radius)
end

function GameService:_resolveStaticCircleOverlaps()
	self:_rebuildSpawnerGrid()
	self:_rebuildStaticGridsIfDirty()

	for _ = 1, 2 do
		for id, spawner in self.spawners do
			local candidates = self.spawnerGrid:query(spawner.pos, spawner.radius, self.queryScratch, self.querySeenScratch)
			for _, otherId in candidates do
				if otherId > id then
					local other = self.spawners[otherId]
					if other then
						self:_resolveCircleEntityOverlap(spawner, other, id * 37 + otherId * 97)
					end
				end
			end
		end

		for id, virus in self.viruses do
			local candidates = self.virusGrid:query(virus.pos, virus.radius, self.queryScratch, self.querySeenScratch)
			for _, otherId in candidates do
				if otherId > id then
					local other = self.viruses[otherId]
					if other then
						self:_resolveCircleEntityOverlap(virus, other, id * 41 + otherId * 101)
					end
				end
			end
		end

		for id, spawner in self.spawners do
			local candidates = self.virusGrid:query(spawner.pos, spawner.radius, self.queryScratch, self.querySeenScratch)
			for _, virusId in candidates do
				local virus = self.viruses[virusId]
				if virus then
					self:_resolveCircleEntityOverlap(spawner, virus, id * 53 + virusId * 109)
				end
			end
		end

		self:_rebuildSpawnerGrid()
		self.staticGridsDirty = true
		self:_rebuildStaticGridsIfDirty()
	end
end

function GameService:_markStaticGridsDirty()
	self.staticGridsDirty = true
end

function GameService:_rebuildCellGrid()
	self.cellGrid:clear()

	for id, cell in self.cells do
		self.cellGrid:insert(id, cell.pos, cell.radius)
	end
end

function GameService:_rebuildEjectedGrid()
	self.ejectedGrid:clear()

	for id, ejected in self.ejected do
		self.ejectedGrid:insert(id, ejected.pos, ejected.radius)
	end
end

function GameService:_rebuildSpawnerGrid()
	self.spawnerGrid:clear()

	for id, spawner in self.spawners do
		self.spawnerGrid:insert(id, spawner.pos, spawner.radius)
	end
end

function GameService:_rebuildBarrierGrid()
	self.barrierGrid:clear()

	for id, barrier in self.barriers do
		local halfSize = barrier.halfSize
		self.barrierGrid:insert(id, barrier.pos, math.max(halfSize.X, halfSize.Y))
	end
end

function GameService:_rebuildCellAndEjectedGrids()
	self:_rebuildCellGrid()
	self:_rebuildEjectedGrid()
end

function GameService:_rebuildMovingGrids()
	self:_rebuildCellGrid()
	self:_rebuildEjectedGrid()
	self:_rebuildSpawnerGrid()
	self:_rebuildBarrierGrid()
end

function GameService:_rebuildStaticGridsIfDirty()
	if not self.staticGridsDirty then
		return
	end

	self.foodGrid:clear()
	self.virusGrid:clear()

	for id, food in self.food do
		self.foodGrid:insert(id, food.pos, food.radius)
	end

	for id, virus in self.viruses do
		self.virusGrid:insert(id, virus.pos, virus.radius)
	end

	self.staticGridsDirty = false
end

function GameService:_rebuildGrids()
	self:_rebuildMovingGrids()
	self.staticGridsDirty = true
	self:_rebuildStaticGridsIfDirty()
end

function GameService:_resolveSamePlayerPush()
	local now = os.clock()
	local basePasses = Config.Cell.SamePlayerPushPasses or 2
	if self:_playerCount() >= Config.Network.AdaptiveStartPlayers then
		basePasses = Config.Cell.LoadSamePlayerPushPasses or basePasses
	end
	local freezeCfg = Config.Freeze or {}
	local gracePasses = math.max(freezeCfg.UnfreezePushPasses or basePasses, 1)

	for _, state in self.playersByUserId do
		-- Frozen owner => no push resolution. Cells sit exactly where
		-- they are so freeze truly stops them dead. Merging still
		-- happens via _handleEating when they overlap.
		if state.frozen then
			continue
		end

		-- Unfreeze grace: dampen overlap resolution so a stacked pile
		-- drifts apart smoothly instead of exploding. Uses an ease-in
		-- curve so the pile barely moves in the first ~third of the
		-- window, then smoothly ramps to full strength.
		-- A "tail" phase (same length as grace) keeps overlapCap
		-- active but widening after the ease-in completes, so residual
		-- overlap doesn't get resolved at cap=infinite the instant
		-- grace ends. Without the tail, big piles would ooze softly
		-- for the full grace, then pop apart when the timer expired.
		local pushStrength = 1
		local overlapCap = math.huge
		local passes = basePasses
		local graceUntil = state.unfreezeGraceUntil or 0
		local graceStart = state.unfreezeGraceStart or 0
		local graceSeconds = math.max(freezeCfg.UnfreezeGraceSeconds or 0, 0.0001)
		local baseCap = math.max(freezeCfg.UnfreezeMaxOverlapPerPass or 3.5, 0.1)
		if graceUntil > now then
			local graceStrength = math.clamp(freezeCfg.UnfreezeGraceStrength or 0.02, 0, 1)
			local exponent = math.max(freezeCfg.UnfreezeGraceCurveExponent or 2.5, 0.1)
			local elapsed = now - (graceStart == 0 and (graceUntil - graceSeconds) or graceStart)
			local progress = math.clamp(elapsed / graceSeconds, 0, 1) ^ exponent
			pushStrength = graceStrength + (1 - graceStrength) * progress
			overlapCap = baseCap
			passes = gracePasses
		elseif graceStart > 0 and now < graceStart + graceSeconds * 2 then
			-- Tail: strength has already hit 1.0. Widen the cap
			-- linearly from baseCap → 6x baseCap over an additional
			-- grace-length window, so remaining overlap resolves in a
			-- smoothly accelerating fashion instead of a snap.
			local tailElapsed = now - (graceStart + graceSeconds)
			local tailProgress = math.clamp(tailElapsed / graceSeconds, 0, 1)
			overlapCap = baseCap * (1 + tailProgress * 5)
			passes = gracePasses
		end

		for _ = 1, passes do
			local ownedCells = {}
			for i = 1, #state.cells do
				local cell = self.cells[state.cells[i]]
				if cell then
					ownedCells[#ownedCells + 1] = cell
				end
			end

			for i = 1, #ownedCells - 1 do
				local a = ownedCells[i]
				for j = i + 1, #ownedCells do
					local b = ownedCells[j]
					local delta = b.pos - a.pos
					local dist = delta.Magnitude
					local minDist = a.radius + b.radius
					if dist < minDist and (now < a.canRecombineAt or now < b.canRecombineAt) then
						local dir
						if dist > 0.001 then
							dir = delta / dist
						else
							dir = Vec2.fromAngle((a.id * 41 + b.id * 97) % 628 / 100)
							dist = 0
						end

						local overlap = math.min((minDist - dist) * pushStrength, overlapCap)
						local totalMass = math.max(a.mass + b.mass, 1)
						local aShare = b.mass / totalMass
						local bShare = a.mass / totalMass

						a.pos -= dir * overlap * aShare
						b.pos += dir * overlap * bShare
						a.pos = self:_clampToWorld(a.pos, a.radius)
						b.pos = self:_clampToWorld(b.pos, b.radius)
					end
				end
			end
		end
	end
end

function GameService:_resolveBarrierPush()
	local maxCellRadius = self:_maxEntityRadius(self.cells, 0)
	for _, barrier in self.barriers do
		local queryRadius = math.max(barrier.halfSize.X, barrier.halfSize.Y) + maxCellRadius
		local candidates = self.cellGrid:query(barrier.pos, queryRadius, self.queryScratch, self.querySeenScratch)
		for _, id in candidates do
			local cell = self.cells[id]
			if cell then
				local dir, penetration = self:_circleBarrierOverlap(cell.pos, cell.radius, barrier)
				if dir and penetration and penetration > 0 then
					cell.pos += dir * penetration
					cell.pos = self:_clampToWorld(cell.pos, cell.radius)
					barrier.vel -= dir * penetration * Config.Barrier.PushTransfer
				end
			end
		end
	end
end

function GameService:_handleEating()
	local events = self.eatEventsScratch
	table.clear(events)

	for _, cell in self.cells do
		self:_queueEatEventsForCell(cell, events)
	end

	if #events <= 0 then
		return
	end

	table.sort(events, function(a, b)
		if a.eaterMass ~= b.eaterMass then
			return a.eaterMass > b.eaterMass
		end
		if a.eaterId ~= b.eaterId then
			return a.eaterId < b.eaterId
		end
		if a.kindRank ~= b.kindRank then
			return a.kindRank < b.kindRank
		end
		return a.targetId < b.targetId
	end)

	for _, event in events do
		self:_applyEatEvent(event)
	end

	for _, cell in self.cells do
		cell.sweptEatStartPos = nil
		cell.sweptEatBoostSpeed = nil
	end
end

function GameService:_cellSweepSegment(cell): (Vector2?, Vector2?, number?)
	if Config.Cell.SweptEatingEnabled == false then
		return nil, nil, nil
	end

	local startPos = cell.sweptEatStartPos
	if not startPos then
		return nil, nil, nil
	end

	local minBoostSpeed = math.max(Config.Cell.SweptEatingMinBoostSpeed or 0, 0)
	if (cell.sweptEatBoostSpeed or 0) < minBoostSpeed then
		return nil, nil, nil
	end

	local endPos = cell.pos
	local delta = endPos - startPos
	local distance = delta.Magnitude
	if distance < math.max(Config.Cell.SweptEatingMinDistance or 0, 0) then
		return nil, nil, nil
	end

	local maxDistance = math.max(Config.Cell.SweptEatingMaxDistance or distance, 0)
	if maxDistance > 0 and distance > maxDistance then
		startPos = endPos - delta.Unit * maxDistance
		distance = maxDistance
	end

	return startPos, endPos, distance
end

function GameService:_canCollectPickupAlongSegment(cell, pickup, startPos: Vector2, endPos: Vector2, minMass: number?, overlapScale: number?): boolean
	if minMass and cell.mass < minMass then
		return false
	end

	local collectDistance = cell.radius + pickup.radius * (overlapScale or 1)
	return segmentTouchesCircle(startPos, endPos, pickup.pos, collectDistance)
end

function GameService:_canCollectEjectedAlongSegment(cell, ejected, startPos: Vector2, endPos: Vector2): boolean
	local minMass = Config.Ejected.EatMinCellMass or 18
	if minMass and cell.mass < minMass then
		return false
	end

	return segmentTouchesCircle(startPos, endPos, ejected.pos, ejectedTouchPickupDistance(cell, ejected))
end

function GameService:_canEatVirusAlongSegment(cell, virus, startPos: Vector2, endPos: Vector2, eaterMass: number, eaterRadius: number): boolean
	if eaterMass < Config.Virus.EatSplitMinMass then
		return false
	end

	if not meetsRadiusRatio(eaterRadius, virus.radius, 1) then
		return false
	end

	local eatDistance = eaterRadius - virus.radius * Config.Cell.EatOverlap
	return eatDistance > 0 and segmentTouchesCircle(startPos, endPos, virus.pos, eatDistance)
end

function GameService:_cellCanEatCellAlongSegmentAt(cell, target, now: number, eaterMass: number, eaterRadius: number, startPos: Vector2, endPos: Vector2): boolean
	if target.ownerUserId == cell.ownerUserId then
		return self:_cellCanEatCellAt(cell, target, now, eaterMass, eaterRadius)
	end

	if eaterMass < target.mass * Config.Cell.MinEatRatio then
		return false
	end

	local eatDistance = eaterRadius - target.radius * Config.Cell.EatOverlap
	return eatDistance > 0 and segmentTouchesCircle(startPos, endPos, target.pos, eatDistance)
end

function GameService:_queueEatEventsForCell(cell, events)
	local now = os.clock()
	local potentialMass = cell.mass
	local sweepStart, sweepEnd, sweepDistance = self:_cellSweepSegment(cell)
	local queuedFood = if sweepStart then {} else nil
	local queuedEjected = if sweepStart then {} else nil
	local queuedViruses = if sweepStart then {} else nil
	local queuedCells = if sweepStart then {} else nil

	local foodCandidates = self.foodGrid:query(cell.pos, cell.radius + Config.Food.Radius, self.queryScratch, self.querySeenScratch)
	for _, id in foodCandidates do
		local food = self.food[id]
		if food and canCoverPickup(cell, food, nil, Config.Cell.EatOverlap) then
			if queuedFood then
				queuedFood[id] = true
			end
			local foodMass = food.mass or self:_foodMass()
			potentialMass += foodMass
			events[#events + 1] = {
				kind = "food",
				kindRank = 1,
				eaterId = cell.id,
				eaterMass = cell.mass,
				targetId = id,
			}
		end
	end
	if sweepStart and sweepEnd and sweepDistance then
		local sweepCenter = (sweepStart + sweepEnd) * 0.5
		local sweepQueryRadius = sweepDistance * 0.5 + cell.radius + Config.Food.Radius
		local sweptFoodCandidates = self.foodGrid:query(sweepCenter, sweepQueryRadius, self.queryScratch, self.querySeenScratch)
		for _, id in sweptFoodCandidates do
			local food = self.food[id]
			if food and not queuedFood[id] and self:_canCollectPickupAlongSegment(cell, food, sweepStart, sweepEnd, nil, 0.8) then
				queuedFood[id] = true
				local foodMass = food.mass or self:_foodMass()
				potentialMass += foodMass
				events[#events + 1] = {
					kind = "food",
					kindRank = 1,
					eaterId = cell.id,
					eaterMass = cell.mass,
					targetId = id,
					swept = true,
					sweepStartPos = sweepStart,
					sweepEndPos = sweepEnd,
				}
			end
		end
	end

	local ejectedQueryRadius = cell.radius + Config.Ejected.Radius + math.max(Config.Ejected.TouchPickupPadding or 0, 0)
	local ejectedCandidates = self.ejectedGrid:query(cell.pos, ejectedQueryRadius, self.queryScratch, self.querySeenScratch)
	for _, id in ejectedCandidates do
		local ejected = self.ejected[id]
		local ownerDelay = Config.Ejected.OwnerReeatDelay or 0.75
		-- Only the SOURCE cell has to wait OwnerReeatDelay. Sibling cells
		-- (feeding target) may eat immediately. Legacy pellets without
		-- sourceCellId fall back to the old whole-owner delay.
		local ejectedIsSelfSource = ejected and (
			ejected.sourceCellId == cell.id
			or (ejected.sourceCellId == nil and ejected.ownerUserId == cell.ownerUserId)
		)
		if ejected
			and ownCellMayCollectOwnEjected(cell, ejected, now)
			and (not ejectedIsSelfSource or now - ejected.spawnedAt > ownerDelay)
			and canCollectEjected(cell, ejected)
		then
			if queuedEjected then
				queuedEjected[id] = true
			end
			potentialMass += self:_ejectedMassGain(cell, ejected, "selfFeed")
			events[#events + 1] = {
				kind = "ejected",
				kindRank = 2,
				eaterId = cell.id,
				eaterMass = cell.mass,
				targetId = id,
			}
		end
	end
	if sweepStart and sweepEnd and sweepDistance then
		local sweepCenter = (sweepStart + sweepEnd) * 0.5
		local sweepQueryRadius = sweepDistance * 0.5 + cell.radius + Config.Ejected.Radius + math.max(Config.Ejected.TouchPickupPadding or 0, 0)
		local sweptEjectedCandidates = self.ejectedGrid:query(sweepCenter, sweepQueryRadius, self.queryScratch, self.querySeenScratch)
		for _, id in sweptEjectedCandidates do
			local ejected = self.ejected[id]
			local ownerDelay = Config.Ejected.OwnerReeatDelay or 0.75
			local ejectedIsSelfSource = ejected and (
				ejected.sourceCellId == cell.id
				or (ejected.sourceCellId == nil and ejected.ownerUserId == cell.ownerUserId)
			)
			if ejected
				and not queuedEjected[id]
				and ownCellMayCollectOwnEjected(cell, ejected, now)
				and (not ejectedIsSelfSource or now - ejected.spawnedAt > ownerDelay)
				and self:_canCollectEjectedAlongSegment(cell, ejected, sweepStart, sweepEnd)
			then
				queuedEjected[id] = true
				potentialMass += self:_ejectedMassGain(cell, ejected, "selfFeed")
				events[#events + 1] = {
					kind = "ejected",
					kindRank = 2,
					eaterId = cell.id,
					eaterMass = cell.mass,
					targetId = id,
					swept = true,
					sweepStartPos = sweepStart,
					sweepEndPos = sweepEnd,
				}
			end
		end
	end

	local potentialRadius = massToRadius(potentialMass)
	local maxVirusRadius = Config.Virus.Radius
	local virusCandidates = self.virusGrid:query(cell.pos, potentialRadius + maxVirusRadius, self.queryScratch, self.querySeenScratch)
	for _, id in virusCandidates do
		local virus = self.viruses[id]
		if virus and potentialMass >= Config.Virus.EatSplitMinMass and canEatVirusAt(cell, virus, potentialMass, potentialRadius) then
			if queuedViruses then
				queuedViruses[id] = true
			end
			events[#events + 1] = {
				kind = "virus",
				kindRank = 3,
				eaterId = cell.id,
				eaterMass = cell.mass,
				targetId = id,
			}
		end
	end
	if sweepStart and sweepEnd and sweepDistance then
		local sweepCenter = (sweepStart + sweepEnd) * 0.5
		local sweepQueryRadius = sweepDistance * 0.5 + potentialRadius + maxVirusRadius
		local sweptVirusCandidates = self.virusGrid:query(sweepCenter, sweepQueryRadius, self.queryScratch, self.querySeenScratch)
		for _, id in sweptVirusCandidates do
			local virus = self.viruses[id]
			if virus
				and not queuedViruses[id]
				and self:_canEatVirusAlongSegment(cell, virus, sweepStart, sweepEnd, potentialMass, potentialRadius)
			then
				queuedViruses[id] = true
				events[#events + 1] = {
					kind = "virus",
					kindRank = 3,
					eaterId = cell.id,
					eaterMass = cell.mass,
					targetId = id,
					swept = true,
					sweepStartPos = sweepStart,
					sweepEndPos = sweepEnd,
				}
			end
		end
	end

	local cellCandidates = self.cellGrid:query(cell.pos, potentialRadius * 2, self.queryScratch, self.querySeenScratch)
	for _, id in cellCandidates do
		if id ~= cell.id then
			local target = self.cells[id]
			if target and self:_cellCanEatCellAt(cell, target, now, potentialMass, potentialRadius) then
				if queuedCells then
					queuedCells[id] = true
				end
				events[#events + 1] = {
					kind = "cell",
					kindRank = 4,
					eaterId = cell.id,
					eaterMass = cell.mass,
					targetId = id,
				}
			end
		end
	end
	if sweepStart and sweepEnd and sweepDistance then
		local sweepCenter = (sweepStart + sweepEnd) * 0.5
		local sweepQueryRadius = sweepDistance * 0.5 + potentialRadius * 2
		local sweptCellCandidates = self.cellGrid:query(sweepCenter, sweepQueryRadius, self.queryScratch, self.querySeenScratch)
		for _, id in sweptCellCandidates do
			if id ~= cell.id and not queuedCells[id] then
				local target = self.cells[id]
				if target and self:_cellCanEatCellAlongSegmentAt(cell, target, now, potentialMass, potentialRadius, sweepStart, sweepEnd) then
					queuedCells[id] = true
					events[#events + 1] = {
						kind = "cell",
						kindRank = 4,
						eaterId = cell.id,
						eaterMass = cell.mass,
						targetId = id,
						swept = true,
						sweepStartPos = sweepStart,
						sweepEndPos = sweepEnd,
					}
				end
			end
		end
	end
end

function GameService:_cellCanEatCellAt(cell, target, now: number, eaterMass: number, eaterRadius: number): boolean
	if target.ownerUserId == cell.ownerUserId then
		if eaterMass < target.mass then
			return false
		end
		if eaterMass == target.mass and cell.id > target.id then
			return false
		end

		-- Cannibalize (AUTOMATIC): a bigger own-cell can engulf a
		-- smaller sibling BEFORE the normal recombine timer elapses,
		-- so long as ALL of these hold — otherwise the mechanic would
		-- break normal merges by eating pieces the instant they split:
		--   * Small cell is at least CannibalizeSecondsSinceSplit old
		--     (default 2s post-split). Freshly split pieces are safe.
		--   * Eater is at least CannibalizeMassRatio times the target's
		--     mass (default 2x). Similar-sized cells can't eat each
		--     other, they must wait for the recombine timer.
		--   * Target's CENTER is inside the eater's disc (minus a small
		--     tolerance). The player has to actually steer the big cell
		--     over the small one — passing sideways won't trigger it.
		local canRecombine = now >= cell.canRecombineAt and now >= target.canRecombineAt
		local cellConfig = Config.Cell or {}
		local cannibalAllowed = false
		if not canRecombine and (cellConfig.CannibalizeEnabled ~= false) then
			local minAge = math.max(cellConfig.CannibalizeSecondsSinceSplit or 2, 0)
			local targetAge = now - (target.spawnedAt or now)
			local massRatio = math.max(cellConfig.CannibalizeMassRatio or 2, 1)
			if targetAge >= minAge and eaterMass >= target.mass * massRatio then
				cannibalAllowed = true
			end
		end

		if not canRecombine and not cannibalAllowed then
			return false
		end

		-- Base merge uses lenient overlap; cannibalize requires the
		-- target's CENTER to be inside the eater's disc so the player
		-- has to actively line it up.
		local eatDistance
		if cannibalAllowed and not canRecombine then
			eatDistance = eaterRadius - target.radius * (cellConfig.CannibalizeOverlap or 0.85)
		else
			eatDistance = eaterRadius - target.radius * 0.25
		end
		return eatDistance > 0 and Vec2.distanceSquared(cell.pos, target.pos) <= eatDistance * eatDistance
	end

	return canEatCircleAt(cell, target, Config.Cell.MinEatRatio, eaterMass, eaterRadius, Config.Cell.EatOverlap)
end

function GameService:_cellCanEatCell(cell, target, now: number): boolean
	return self:_cellCanEatCellAt(cell, target, now, cell.mass, cell.radius)
end

function GameService:_applyEatEvent(event)
	local cell = self.cells[event.eaterId]
	if not cell then
		return
	end

	if event.kind == "food" then
		local food = self.food[event.targetId]
		if food and canCoverPickup(cell, food, nil, Config.Cell.EatOverlap) then
			self.food[event.targetId] = nil
			self:_markStaticGridsDirty()
			self:_setCellMass(cell, cell.mass + (food.mass or self:_foodMass()))
		end
	elseif event.kind == "ejected" then
		local ejected = self.ejected[event.targetId]
		local ownerDelay = Config.Ejected.OwnerReeatDelay or 0.75
		local canCollect = ejected and canCollectEjected(cell, ejected)
		local ejectedIsSelfSource = ejected and (
			ejected.sourceCellId == cell.id
			or (ejected.sourceCellId == nil and ejected.ownerUserId == cell.ownerUserId)
		)
		if ejected
			and ownCellMayCollectOwnEjected(cell, ejected, os.clock())
			and (not ejectedIsSelfSource or os.clock() - ejected.spawnedAt > ownerDelay)
			and canCollect
		then
			self:_removeEjected(event.targetId)
			self:_setCellMass(cell, cell.mass + self:_ejectedMassGain(cell, ejected, "selfFeed"))
		end
	elseif event.kind == "virus" then
		local virus = self.viruses[event.targetId]
		local canEat = virus and canEatVirus(cell, virus)
		if virus and cell.mass >= Config.Virus.EatSplitMinMass and canEat then
			if self:_consumeBurstObject(cell, virus.mass, "virus") then
				self.viruses[event.targetId] = nil
				self:_markStaticGridsDirty()
			end
		end
	elseif event.kind == "cell" then
		local target = self.cells[event.targetId]
		local now = os.clock()
		local canEat = target and self:_cellCanEatCell(cell, target, now)
		if target and target.id ~= cell.id and canEat then
			self:_setCellMass(cell, cell.mass + target.mass)
			self:_removeCell(target, cell.id)
		end
	end
end

function GameService:_handleSpawners()
	local maxCellRadius = self:_maxEntityRadius(self.cells, 0)
	for spawnerId, spawner in self.spawners do
		local ejectedCandidates = self.ejectedGrid:query(
			spawner.pos,
			spawner.radius + Config.Ejected.Radius + 8,
			self.queryScratch,
			self.querySeenScratch
		)
		table.sort(ejectedCandidates, function(a, b)
			local ea = self.ejected[a]
			local eb = self.ejected[b]
			if not ea or not eb then
				return false
			end
			return Vec2.distanceSquared(spawner.pos, ea.pos) < Vec2.distanceSquared(spawner.pos, eb.pos)
		end)
		for _, id in ejectedCandidates do
			local ejected = self.ejected[id]
			if ejected and canCollectPickup(spawner, ejected, nil, 0.8) then
				self:_removeEjected(id)
				self:_feedSpawner(spawner, ejected.mass)
			end
		end

		local cellCandidates = self.cellGrid:query(
			spawner.pos,
			spawner.radius + maxCellRadius,
			self.queryScratch,
			self.querySeenScratch
		)
		table.sort(cellCandidates, function(a, b)
			local ca = self.cells[a]
			local cb = self.cells[b]
			if not ca or not cb then
				return false
			end
			return Vec2.distanceSquared(spawner.pos, ca.pos) < Vec2.distanceSquared(spawner.pos, cb.pos)
		end)

		local removeSpawner = false
		for _, id in cellCandidates do
			local cell = self.cells[id]
			if cell then
				local interactionRatio = Config.Spawner.EatCellRadiusRatio or Config.Cell.MinEatRatio or 1
				if canSpawnerConsumeCell(spawner, cell) then
					local absorbedMass = cell.mass
					self:_removeCell(cell)
					self:_feedSpawner(spawner, absorbedMass)
				elseif cell.mass >= Config.Spawner.BurstMinMass
					and canConsumeByRadius(cell, spawner, interactionRatio, Config.Cell.EatOverlap)
				then
					if self:_consumeBurstObject(cell, spawner.mass, "spawner") then
						removeSpawner = true
						break
					end
				end
			end
		end

		if removeSpawner then
			self.spawners[spawnerId] = nil
		end
	end
end

function GameService:_bumpVirusFromEjected(virus, ejected)
	local fallback = virus.lastBumpDir or Vector2.new(1, 0)
	local dir = Vec2.safeUnit(ejected.vel, fallback)
	local transfer = math.max(Config.Virus.BumpVelocityTransfer or 0.85, 0)
	local minSpeed = math.max(Config.Virus.BumpMinSpeed or 0, 0)
	local maxSpeed = math.max(Config.Virus.BumpMaxSpeed or Config.Ejected.Speed or minSpeed, minSpeed)
	local impactSpeed = ejected.vel.Magnitude * transfer
	local bumpSpeed = math.clamp(math.max(impactSpeed, minSpeed), 0, maxSpeed)
	local nextVelocity = (virus.vel or Vector2.zero) + dir * bumpSpeed

	if nextVelocity.Magnitude > maxSpeed then
		nextVelocity = nextVelocity.Unit * maxSpeed
	end

	virus.vel = nextVelocity
	virus.lastBumpDir = dir

	local nudge = math.max(Config.Virus.BumpNudge or 0, 0)
	if nudge > 0 then
		virus.pos = self:_clampToWorld(virus.pos + dir * nudge, virus.radius)
	end

	self:_markStaticGridsDirty()
end

function GameService:_bumpVirusesFromEjected()
	local viruses = {}
	for _, virus in self.viruses do
		viruses[#viruses + 1] = virus
	end

	for _, virus in viruses do
		if self.viruses[virus.id] == nil then
			continue
		end
		local candidates = self.ejectedGrid:query(virus.pos, virus.radius + Config.Ejected.Radius, self.queryScratch, self.querySeenScratch)
		table.sort(candidates, function(a, b)
			local ea = self.ejected[a]
			local eb = self.ejected[b]
			if not ea or not eb then
				return false
			end
			return Vec2.distanceSquared(virus.pos, ea.pos) < Vec2.distanceSquared(virus.pos, eb.pos)
		end)

		for _, id in candidates do
			local ejected = self.ejected[id]
			if ejected and canCollectPickup(virus, ejected, nil, 0.85) then
				self:_removeEjected(id)
				self:_bumpVirusFromEjected(virus, ejected)
			end
		end
	end
end

function GameService:_consumeBurstObject(cell, bonusMass: number?, source: string?): boolean
	-- Virus.SplitOnEat = false: absorb the mass without bursting the
	-- cell into pieces. Prevents the "auto-split" the player didn't ask
	-- for when running into a virus. Spawners still burst normally.
	if source == "virus" and Config.Virus and Config.Virus.SplitOnEat == false then
		local massGain = math.max(bonusMass or 0, 0)
		if massGain > 0 then
			self:_setCellMass(cell, cell.mass + massGain)
		end
		return true
	end

	if self:_burstCell(cell) then
		return true
	end

	if #cell.owner.cells >= Config.Player.MaxCells then
		local massGain = math.max(bonusMass or 0, 0)
		if massGain > 0 then
			self:_setCellMass(cell, cell.mass + massGain)
		end
		return true
	end

	return false
end

function GameService:_burstCell(cell): boolean
	local state = cell.owner
	local freeSlots = Config.Player.MaxCells - #state.cells
	if freeSlots <= 0 then
		return false
	end

	local minPieceMass = math.max(Config.Cell.SplitMinMass or 1, 1)
	local piecesAllowedByMass = math.floor(cell.mass / minPieceMass)
	local pieces = math.min(Config.Virus.MaxBurstPieces, freeSlots + 1, piecesAllowedByMass)
	if pieces <= 1 then
		return false
	end

	local massPerPiece = cell.mass / pieces
	self:_setCellMass(cell, massPerPiece)
	cell.canRecombineAt = os.clock() + recombineDelayForMass(cell.mass)

	for i = 1, pieces - 1 do
		local dir = Vec2.fromAngle((math.pi * 2) * (i / (pieces - 1)))
		local childRadius = massToRadius(massPerPiece)
		local spawnPos = self:_adjustSpawnPositionForBarriers(
			cell.pos,
			cell.pos + dir * (cell.radius * 2 + 4),
			childRadius
		)
		local child = self:_spawnPlayerCell(
			state,
			spawnPos,
			massPerPiece,
			dir * self:_splitImpulseForMass(cell.mass, 0.85)
		)
		if child then
			child.sweptEatStartPos = cell.pos
		end
	end

	return true
end

function GameService:_updatePlayerCenters()
	for _, state in self.playersByUserId do
		local weighted = Vector2.zero
		local totalMass = 0

		for _, id in state.cells do
			local cell = self.cells[id]
			if cell then
				weighted += cell.pos * cell.mass
				totalMass += cell.mass
			end
		end

		if totalMass <= 0 then
			self:_respawnPlayer(state)
		else
			state.center = weighted / totalMass
		end
	end
end

function GameService:_snapshotRadius(state): number
	local view = state.input.view
	local zoom = math.clamp(state.input.zoom or 1, Config.Render.MinZoom or 0.22, Config.Render.MaxZoom or 1.9)
	local maxView = math.max(view.X, view.Y) / zoom
	local playerCount = self:_playerCount()
	local padding = Config.Network.ViewportPadding
	local maxRadius = Config.Network.MaxSnapshotRadius or 4400
	if playerCount >= Config.Network.HeavyLoadPlayers then
		padding = Config.Network.HeavyLoadViewportPadding or padding
		maxRadius = Config.Network.HeavyLoadMaxSnapshotRadius or maxRadius
	elseif playerCount >= Config.Network.AdaptiveStartPlayers then
		padding = Config.Network.LoadViewportPadding or padding
		maxRadius = Config.Network.LoadMaxSnapshotRadius or maxRadius
	end

	local totalRadius = 0
	for _, id in state.cells do
		local cell = self.cells[id]
		if cell then
			totalRadius += cell.radius
		end
	end

	return math.clamp(maxView * 0.65 + totalRadius + padding, 1400, maxRadius)
end

function GameService:_appendSnapshotEntities(list, grid, source, center: Vector2, radius: number, maxCount: number, pack, sortByDistance: boolean?)
	local candidates = grid:query(center, radius, self.queryScratch, self.querySeenScratch)
	if sortByDistance then
		local nearest = {}
		for _, id in candidates do
			local entity = source[id]
			if entity then
				local distanceSquared = Vec2.distanceSquared(center, entity.pos)
				local entityRadius = entity.radius or math.max(entity.halfSize and entity.halfSize.X or 0, entity.halfSize and entity.halfSize.Y or 0)
				local inclusionRadius = radius + entityRadius
				if distanceSquared <= inclusionRadius * inclusionRadius then
					insertNearestCandidate(nearest, id, distanceSquared, maxCount)
				end
			end
		end

		for _, candidate in nearest do
			local entity = source[candidate.id]
			if entity then
				list[#list + 1] = pack(entity)
			end
		end
		return
	end

	for _, id in candidates do
		if #list >= maxCount then
			break
		end

		local entity = source[id]
		if entity then
			local entityRadius = entity.radius or math.max(entity.halfSize and entity.halfSize.X or 0, entity.halfSize and entity.halfSize.Y or 0)
			local inclusionRadius = radius + entityRadius
			if Vec2.distanceSquared(center, entity.pos) <= inclusionRadius * inclusionRadius then
				list[#list + 1] = pack(entity)
			end
		end
	end
end

function GameService:_appendEjectedSnapshot(list, center: Vector2, radius: number, caps, viewerUserId: number, visiblePlayers)
	local candidates = self.ejectedGrid:query(center, radius, self.queryScratch, self.querySeenScratch)
	local ownNearest = {}
	local remoteNearest = {}

	local function append(ejected)
		local owner = self.playersByUserId[ejected.ownerUserId]
		if owner then
			visiblePlayers[ejected.ownerUserId] = owner
		end
		list[#list + 1] = {
			ejected.id,
			round(ejected.pos.X, Config.Network.PositionPrecision),
			round(ejected.pos.Y, Config.Network.PositionPrecision),
			ejected.colorPayload,
		}
	end

	for _, id in candidates do
		local ejected = self.ejected[id]
		if ejected then
			local distanceSquared = Vec2.distanceSquared(center, ejected.pos)
			local inclusionRadius = radius + ejected.radius
			if distanceSquared <= inclusionRadius * inclusionRadius then
				if ejected.ownerUserId == viewerUserId then
					insertNearestCandidate(ownNearest, id, distanceSquared, caps.ownEjected)
				else
					insertNearestCandidate(remoteNearest, id, distanceSquared, caps.remoteEjected)
				end
			end
		end
	end

	for _, candidate in ownNearest do
		if #list >= caps.ejected then
			break
		end
		local ejected = self.ejected[candidate.id]
		if ejected then
			append(ejected)
		end
	end

	for _, candidate in remoteNearest do
		if #list >= caps.ejected then
			break
		end
		local ejected = self.ejected[candidate.id]
		if ejected then
			append(ejected)
		end
	end
end

function GameService:_appendFastCellSnapshot(list, center: Vector2, radius: number, maxCount: number, maxRemoteCount: number, viewerState, visiblePlayers, precision: number)
	local function pack(cell)
		visiblePlayers[cell.ownerUserId] = cell.owner
		list[#list + 1] = {
			cell.id,
			cell.ownerUserId,
			round(cell.pos.X, precision),
			round(cell.pos.Y, precision),
			round(cell.radius, Config.Network.MassPrecision),
			round(cell.mass, Config.Network.MassPrecision),
		}
	end

	local remoteCount = 0
	for _, id in viewerState.cells do
		if #list >= maxCount then
			return
		end
		local cell = self.cells[id]
		if cell then
			pack(cell)
		end
	end

	local candidates = self.cellGrid:query(center, radius, self.queryScratch, self.querySeenScratch)
	local remoteOwners = {}
	local remoteOwnerOrder = {}
	for _, id in candidates do
		local cell = self.cells[id]
		if cell
			and cell.ownerUserId ~= viewerState.userId
		then
			local distanceSquared = Vec2.distanceSquared(center, cell.pos)
			local inclusionRadius = radius + cell.radius
			if distanceSquared <= inclusionRadius * inclusionRadius then
				local ownerEntry = remoteOwners[cell.ownerUserId]
				if not ownerEntry then
					ownerEntry = {
						ownerUserId = cell.ownerUserId,
						nearestDistanceSquared = distanceSquared,
						cells = {},
					}
					remoteOwners[cell.ownerUserId] = ownerEntry
					remoteOwnerOrder[#remoteOwnerOrder + 1] = ownerEntry
				elseif distanceSquared < ownerEntry.nearestDistanceSquared then
					ownerEntry.nearestDistanceSquared = distanceSquared
				end
				ownerEntry.cells[#ownerEntry.cells + 1] = {
					id = id,
					distanceSquared = distanceSquared,
				}
			end
		end
	end

	table.sort(remoteOwnerOrder, function(a, b)
		return a.nearestDistanceSquared < b.nearestDistanceSquared
	end)

	for _, ownerEntry in remoteOwnerOrder do
		if #list >= maxCount or remoteCount >= maxRemoteCount then
			break
		end

		table.sort(ownerEntry.cells, function(a, b)
			return a.distanceSquared < b.distanceSquared
		end)

		local remainingCells = maxCount - #list
		local remainingRemoteCells = maxRemoteCount - remoteCount
		local completeOwnerFits = #ownerEntry.cells <= remainingCells and #ownerEntry.cells <= remainingRemoteCells
		if completeOwnerFits or remoteCount == 0 then
			local cellsToPack = math.min(#ownerEntry.cells, remainingCells, remainingRemoteCells)
			for index = 1, cellsToPack do
				local cell = self.cells[ownerEntry.cells[index].id]
				if cell and cell.ownerUserId == ownerEntry.ownerUserId then
					pack(cell)
					remoteCount += 1
				end
			end
		end
	end
end

function GameService:_playerCount(): number
	return self.playerCount
end

function GameService:_hasMovingVirusesForSnapshot(): boolean
	local minSpeed = math.max(Config.Virus.DynamicSnapshotMinSpeed or Config.Virus.StopSpeed or 0, 0)
	local minSpeedSquared = minSpeed * minSpeed
	for _, virus in self.viruses do
		local velocity = virus.vel
		if velocity and velocity:Dot(velocity) > minSpeedSquared then
			return true
		end
	end
	return false
end

function GameService:_staticNetworkHz(): number
	local playerCount = self:_playerCount()
	if playerCount >= Config.Network.HeavyLoadPlayers then
		return Config.Network.HeavyLoadStaticHz
	end
	return Config.Simulation.StaticNetworkHz
end

function GameService:_snapshotCaps()
	local playerCount = self:_playerCount()
	local staticScale = 1
	local dynamicScale = 1

	if playerCount >= Config.Network.HeavyLoadPlayers then
		staticScale = Config.Network.HeavyStaticScale
		dynamicScale = Config.Network.HeavyDynamicScale
	elseif playerCount >= Config.Network.AdaptiveStartPlayers then
		staticScale = Config.Network.MediumStaticScale
		dynamicScale = Config.Network.MediumDynamicScale or dynamicScale
	end

	local ejectedCap = math.max(Config.Network.FastMaxEjectedPerSnapshot or 24, math.floor(Config.Network.MaxEjectedPerSnapshot * dynamicScale))
	return {
		cells = math.max(Config.Network.FastMaxCellsPerSnapshot or 64, math.floor(Config.Network.MaxCellsPerSnapshot * dynamicScale)),
		ejected = ejectedCap,
		ownEjected = math.min(ejectedCap, Config.Network.MaxOwnEjectedPerSnapshot),
		remoteEjected = math.min(ejectedCap, math.max(Config.Network.FastMaxRemoteEjectedPerSnapshot or 8, math.floor(Config.Network.MaxRemoteEjectedPerSnapshot * dynamicScale))),
		food = math.max(60, math.floor(Config.Network.MaxFoodPerSnapshot * staticScale)),
		viruses = math.max(12, math.floor(Config.Network.MaxVirusesPerSnapshot * staticScale)),
		spawners = math.max(1, math.floor(Config.Network.MaxSpawnersPerSnapshot * staticScale)),
		barriers = math.max(Config.Barrier.TargetCount or 1, Config.Network.MaxBarriersPerSnapshot),
	}
end

function GameService:_fastSnapshotCaps(caps)
	local networkConfig = Config.Network or {}
	local ejectedCap = math.min(caps.ejected, networkConfig.FastMaxEjectedPerSnapshot or 48)
	local remoteCellCap = networkConfig.FastMaxRemoteCellsPerSnapshot or 24
	return {
		cells = math.min(caps.cells, networkConfig.FastMaxCellsPerSnapshot or 96),
		remoteCells = math.min(caps.cells, remoteCellCap),
		ejected = ejectedCap,
		ownEjected = math.min(ejectedCap, networkConfig.FastMaxOwnEjectedPerSnapshot or 32),
		remoteEjected = math.min(ejectedCap, networkConfig.FastMaxRemoteEjectedPerSnapshot or 24),
		food = caps.food,
		viruses = caps.viruses,
		spawners = math.min(caps.spawners, networkConfig.FastMaxSpawnersPerSnapshot or 6),
		barriers = math.min(caps.barriers, networkConfig.FastMaxBarriersPerSnapshot or 6),
	}
end

function GameService:_trimFastSnapshotRows(cellsPayload, ejectedPayload, spawnersPayload, barriersPayload, viewerUserId: number)
	local budget = Config.Network.FastSnapshotByteBudget or 760
	local used = 96
	local cellOverflow = nil
	local write = 1
	for read = 1, #cellsPayload do
		local row = cellsPayload[read]
		local rowBytes = if row[2] == viewerUserId then 20 else 28
		if row[2] == viewerUserId or used + rowBytes <= budget then
			cellsPayload[write] = row
			write += 1
			used += rowBytes
		else
			cellOverflow = cellOverflow or {}
			cellOverflow[#cellOverflow + 1] = row
		end
	end
	for index = write, #cellsPayload do
		cellsPayload[index] = nil
	end

	write = 1
	local ejectedOverflow = {}
	for read = 1, #ejectedPayload do
		local rowBytes = 21
		if used + rowBytes <= budget then
			ejectedPayload[write] = ejectedPayload[read]
			write += 1
			used += rowBytes
		else
			ejectedOverflow[#ejectedOverflow + 1] = ejectedPayload[read]
		end
	end
	for index = write, #ejectedPayload do
		ejectedPayload[index] = nil
	end

	local spawnerBytes = #spawnersPayload * 16
	local includeSpawners = #spawnersPayload > 0 and used + spawnerBytes <= budget
	if includeSpawners then
		used += spawnerBytes
	end

	local barrierBytes = #barriersPayload * 20
	local includeBarriers = #barriersPayload > 0 and used + barrierBytes <= budget
	return includeSpawners, includeBarriers, ejectedOverflow, cellOverflow
end

function GameService:_compactRows(rows, width: number)
	if not rows or #rows <= 0 then
		return nil
	end

	local compact = {}
	for _, row in rows do
		for i = 1, width do
			compact[#compact + 1] = row[i]
		end
	end
	return compact
end

function GameService:_packCellBuffer(rows)
	if not rows or #rows <= 0 then
		return nil
	end
	if typeof(buffer) ~= "table" then
		return self:_compactRows(rows, 6)
	end

	local rowBytes = 28
	local payload = buffer.create(#rows * rowBytes)
	local offset = 0
	for _, row in rows do
		buffer.writeu32(payload, offset, row[1])
		buffer.writef64(payload, offset + 4, row[2])
		buffer.writef32(payload, offset + 12, row[3])
		buffer.writef32(payload, offset + 16, row[4])
		buffer.writef32(payload, offset + 20, row[5])
		buffer.writef32(payload, offset + 24, row[6])
		offset += rowBytes
	end
	return payload
end

function GameService:_packOwnCellBuffer(rows, viewerUserId: number)
	if not rows or #rows <= 0 then
		return nil
	end

	local ownRows = {}
	for _, row in rows do
		if row[2] == viewerUserId then
			ownRows[#ownRows + 1] = row
		end
	end
	if #ownRows <= 0 then
		return nil
	end
	if typeof(buffer) ~= "table" then
		local compact = {}
		for _, row in ownRows do
			compact[#compact + 1] = row[1]
			compact[#compact + 1] = row[3]
			compact[#compact + 1] = row[4]
			compact[#compact + 1] = row[5]
			compact[#compact + 1] = row[6]
		end
		return compact
	end

	local rowBytes = 20
	local payload = buffer.create(#ownRows * rowBytes)
	local offset = 0
	for _, row in ownRows do
		buffer.writeu32(payload, offset, row[1])
		buffer.writef32(payload, offset + 4, row[3])
		buffer.writef32(payload, offset + 8, row[4])
		buffer.writef32(payload, offset + 12, row[5])
		buffer.writef32(payload, offset + 16, row[6])
		offset += rowBytes
	end
	return payload
end

function GameService:_packRemoteCellBuffer(rows, viewerUserId: number)
	if not rows or #rows <= 0 then
		return nil
	end

	local remoteRows = {}
	for _, row in rows do
		if row[2] ~= viewerUserId then
			remoteRows[#remoteRows + 1] = row
		end
	end
	if #remoteRows <= 0 then
		return nil
	end
	return self:_packCellBuffer(remoteRows)
end

function GameService:_packEjectedBuffer(rows)
	if not rows or #rows <= 0 then
		return nil
	end
	if typeof(buffer) ~= "table" then
		return self:_compactRows(rows, 4)
	end

	local rowBytes = 21
	local payload = buffer.create(#rows * rowBytes)
	local offset = 0
	for _, row in rows do
		local ownerOrColor = row[4]
		buffer.writeu32(payload, offset, row[1])
		buffer.writef32(payload, offset + 4, row[2])
		buffer.writef32(payload, offset + 8, row[3])
		if typeof(ownerOrColor) == "number" then
			buffer.writeu8(payload, offset + 12, 1)
			buffer.writef64(payload, offset + 13, ownerOrColor)
		else
			buffer.writeu8(payload, offset + 12, 2)
			buffer.writef64(payload, offset + 13, packedColorValue(ownerOrColor))
		end
		offset += rowBytes
	end
	return payload
end

function GameService:_packFixedBuffer(rows, width: number)
	if not rows or #rows <= 0 then
		return nil
	end
	if typeof(buffer) ~= "table" then
		return self:_compactRows(rows, width)
	end

	local rowBytes = width * 4
	local payload = buffer.create(#rows * rowBytes)
	local offset = 0
	for _, row in rows do
		for column = 1, width do
			buffer.writef32(payload, offset + (column - 1) * 4, row[column])
		end
		offset += rowBytes
	end
	return payload
end

function GameService:_trackKnownStatics(known, source, payload)
	if payload then
		for _, packed in payload do
			known[packed[1]] = true
		end
	end

	local removed = {}
	for id in known do
		if source[id] == nil then
			known[id] = nil
			removed[#removed + 1] = id
		end
	end

	return removed
end

function GameService:_staticRemovalPayload(removedFood, removedViruses)
	local gone = nil
	if #removedFood > 0 then
		gone = gone or {}
		gone.f = removedFood
	end
	if #removedViruses > 0 then
		gone = gone or {}
		gone.v = removedViruses
	end
	return gone
end

function GameService:_appendRemovalPayload(gone, key: string, removed)
	if #removed <= 0 then
		return gone
	end

	gone = gone or {}
	gone[key] = removed
	return gone
end

function GameService:_appendCellConsumePayload(gone, removedCells)
	local rows = nil
	for _, id in removedCells do
		local consume = self.cellConsumeTargets[id]
		if consume then
			rows = rows or {}
			rows[#rows + 1] = { id, consume.eaterId }
		end
	end
	if rows then
		gone = gone or {}
		gone.m = rows
	end
	return gone
end

function GameService:_appendPayloadRows(target, source)
	if not source or #source <= 0 then
		return target
	end
	target = target or {}
	for _, row in source do
		target[#target + 1] = row
	end
	return target
end

function GameService:_fireFastEjectedSidecars(player, viewerUserId: number, rows)
	if not self.remotes.SnapshotFastEjected or not rows or #rows <= 0 then
		return
	end

	local maxRows = math.max(1, Config.Network.FastEjectedSidecarRows or 24)
	for startIndex = 1, #rows, maxRows do
		local chunk = {}
		local endIndex = math.min(#rows, startIndex + maxRows - 1)
		for index = startIndex, endIndex do
			chunk[#chunk + 1] = rows[index]
		end

		self.remotes.SnapshotFastEjected:FireClient(player, {
			k = "e",
			y = viewerUserId,
			ej = self:_packEjectedBuffer(chunk),
		})
	end
end

function GameService:_fireFastCellSidecars(player, viewerUserId: number, rows)
	if not self.remotes.SnapshotFast or not rows or #rows <= 0 then
		return
	end

	local maxRows = math.max(1, Config.Network.FastCellSidecarRows or 20)
	for startIndex = 1, #rows, maxRows do
		local chunk = {}
		local endIndex = math.min(#rows, startIndex + maxRows - 1)
		for index = startIndex, endIndex do
			chunk[#chunk + 1] = rows[index]
		end

		self.remotes.SnapshotFast:FireClient(player, {
			k = "c",
			y = viewerUserId,
			cr = self:_packRemoteCellBuffer(chunk, viewerUserId),
		})
	end
end

function GameService:_playerMass(state): number
	local total = 0
	for _, id in state.cells do
		local cell = self.cells[id]
		if cell then
			total += cell.mass
		end
	end
	return total
end

function GameService:_playerRadiusSum(state): number
	local total = 0
	for _, id in state.cells do
		local cell = self.cells[id]
		if cell then
			total += cell.radius
		end
	end
	return total
end

function GameService:_ownedSkinsPayload(state)
	local owned = {}
	for id in state.ownedSkins do
		owned[#owned + 1] = id
	end
	if state.locationSkinId and not state.ownedSkins[state.locationSkinId] then
		owned[#owned + 1] = state.locationSkinId
	end
	table.sort(owned)
	return owned
end

function GameService:_shouldSendStatics(state, center: Vector2, radius: number, staticTick: boolean, now: number): boolean
	if state.needsStaticSnapshot then
		return true
	end
	if not staticTick then
		return false
	end
	local buckets = math.max(Config.Network.StaticRefreshBuckets or 1, 1)
	if buckets > 1 and state.staticRefreshPhase ~= self.staticRefreshBucket then
		return false
	end
	if not state.lastStaticSnapshotCenter then
		return true
	end
	if not state.lastStaticSnapshotRadius or radius > state.lastStaticSnapshotRadius + (Config.Network.StaticRefreshRadiusDelta or 160) then
		return true
	end
	if now - (state.lastStaticSnapshotAt or 0) >= Config.Network.StaticRefreshMaxInterval then
		return true
	end

	local refreshDistance = Config.Network.StaticRefreshDistance or 140
	return Vec2.distanceSquared(center, state.lastStaticSnapshotCenter) >= refreshDistance * refreshDistance
end

function GameService:_playerMetaPayload(viewerState, visiblePlayers)
	local payload = nil
	viewerState.knownPlayerMeta = viewerState.knownPlayerMeta or {}

	for userId, playerState in visiblePlayers do
		local version = playerState.metaVersion or 1
		if viewerState.knownPlayerMeta[userId] ~= version then
			local locationSkinId = if playerState.useLocaleSkin == false then nil else playerState.locationSkinId
			payload = payload or {}
			payload[#payload + 1] = {
				userId,
				playerState.colorPayload,
				playerState.name,
				playerState.equippedSkin,
				locationSkinId,
				normaliseAvatarDisplayMode(playerState.avatarDisplayMode),
			}
			viewerState.knownPlayerMeta[userId] = version
		end
	end

	return payload
end

function GameService:_sendSnapshots(includeStatics: boolean?)
	self:_rebuildStaticGridsIfDirty()
	local caps = self:_snapshotCaps()
	local now = os.clock()
	local sendMovingViruses = self:_hasMovingVirusesForSnapshot()
	for _, state in self.playersByUserId do
		if not state.clientReady then
			continue
		end
		local radius = self:_snapshotRadius(state)
		local center = state.center
		local cellsPayload = {}
		local ejectedPayload = {}
		local ejectedOverflowPayload = nil
		local cellOverflowPayload = nil
		local spawnersPayload = {}
		local barriersPayload = {}
		local fastSpawnersPayload = nil
		local fastBarriersPayload = nil
		local visiblePlayers = {}
		local sendStatics = self:_shouldSendStatics(state, center, radius, includeStatics == true, now)
		local sendViruses = sendStatics or sendMovingViruses
		local foodPayload = nil
		local virusesPayload = nil
		local precision = Config.Network.PositionPrecision
		local includeShop = state.shopDirty == true
		local useFastSnapshot = self.remotes.SnapshotFast ~= nil and not includeShop
		local dynamicCaps = if useFastSnapshot then self:_fastSnapshotCaps(caps) else caps

		if useFastSnapshot then
			self:_appendFastCellSnapshot(cellsPayload, center, radius, dynamicCaps.cells, dynamicCaps.remoteCells, state, visiblePlayers, precision)
		else
			self:_appendSnapshotEntities(cellsPayload, self.cellGrid, self.cells, center, radius, dynamicCaps.cells, function(cell)
				visiblePlayers[cell.ownerUserId] = cell.owner
				return {
					cell.id,
					cell.ownerUserId,
					round(cell.pos.X, precision),
					round(cell.pos.Y, precision),
					round(cell.radius, Config.Network.MassPrecision),
					round(cell.mass, Config.Network.MassPrecision),
				}
			end, true)
		end

		self:_appendEjectedSnapshot(ejectedPayload, center, radius, dynamicCaps, state.userId, visiblePlayers)
		self:_appendSnapshotEntities(spawnersPayload, self.spawnerGrid, self.spawners, center, radius, dynamicCaps.spawners, function(spawner)
			return {
				spawner.id,
				round(spawner.pos.X, precision),
				round(spawner.pos.Y, precision),
				round(spawner.radius, Config.Network.MassPrecision),
			}
		end, true)

		self:_appendSnapshotEntities(barriersPayload, self.barrierGrid, self.barriers, center, radius, dynamicCaps.barriers, function(barrier)
			return {
				barrier.id,
				round(barrier.pos.X, precision),
				round(barrier.pos.Y, precision),
				round(barrier.halfSize.X * 2, precision),
				round(barrier.halfSize.Y * 2, precision),
			}
		end, true)

		if useFastSnapshot then
			local includeFastSpawners, includeFastBarriers, overflowEjected, overflowCells = self:_trimFastSnapshotRows(cellsPayload, ejectedPayload, spawnersPayload, barriersPayload, state.userId)
			ejectedOverflowPayload = overflowEjected
			cellOverflowPayload = overflowCells
			fastSpawnersPayload = if includeFastSpawners then spawnersPayload else nil
			fastBarriersPayload = if includeFastBarriers then barriersPayload else nil
		end

		if sendStatics then
			foodPayload = {}

			self:_appendSnapshotEntities(foodPayload, self.foodGrid, self.food, center, radius, caps.food, function(food)
				return {
					food.id,
					round(food.pos.X, precision),
					round(food.pos.Y, precision),
					food.colorIndex,
				}
			end, true)
		end

		if sendViruses then
			virusesPayload = {}
			self:_appendSnapshotEntities(virusesPayload, self.virusGrid, self.viruses, center, radius, caps.viruses, function(virus)
				return {
					virus.id,
					round(virus.pos.X, precision),
					round(virus.pos.Y, precision),
					round(virus.radius, Config.Network.MassPrecision),
				}
			end, true)
		end

		state.knownStatics = state.knownStatics or {
			food = {},
			viruses = {},
		}
		local removedFood = self:_trackKnownStatics(state.knownStatics.food, self.food, foodPayload)
		local removedViruses = self:_trackKnownStatics(state.knownStatics.viruses, self.viruses, virusesPayload)
		state.knownCells = state.knownCells or {}
		local cellsKnownPayload = self:_appendPayloadRows(nil, cellsPayload)
		cellsKnownPayload = self:_appendPayloadRows(cellsKnownPayload, cellOverflowPayload)
		local removedCells = self:_trackKnownStatics(state.knownCells, self.cells, cellsKnownPayload)
		state.knownSpawners = state.knownSpawners or {}
		local removedSpawners = self:_trackKnownStatics(state.knownSpawners, self.spawners, fastSpawnersPayload or spawnersPayload)
		local ejectedKnownPayload = self:_appendPayloadRows(nil, ejectedPayload)
		ejectedKnownPayload = self:_appendPayloadRows(ejectedKnownPayload, ejectedOverflowPayload)
		local removedEjected = self:_trackKnownStatics(state.knownEjected, self.ejected, ejectedKnownPayload)
		local staticGonePayload = self:_staticRemovalPayload(removedFood, removedViruses)
		local dynamicGonePayload = nil
		dynamicGonePayload = self:_appendRemovalPayload(dynamicGonePayload, "c", removedCells)
		dynamicGonePayload = self:_appendCellConsumePayload(dynamicGonePayload, removedCells)
		dynamicGonePayload = self:_appendRemovalPayload(dynamicGonePayload, "s", removedSpawners)
		dynamicGonePayload = self:_appendRemovalPayload(dynamicGonePayload, "e", removedEjected)
		if sendStatics then
			state.needsStaticSnapshot = false
			state.lastStaticSnapshotCenter = center
			state.lastStaticSnapshotRadius = radius
			state.lastStaticSnapshotAt = now
		end
		local playerMetaPayload = self:_playerMetaPayload(state, visiblePlayers)
		local snapshotGonePayload = dynamicGonePayload
		local sidecarGonePayload = staticGonePayload
		sidecarGonePayload = self:_appendRemovalPayload(sidecarGonePayload, "c", removedCells)
		sidecarGonePayload = self:_appendCellConsumePayload(sidecarGonePayload, removedCells)
		sidecarGonePayload = self:_appendRemovalPayload(sidecarGonePayload, "s", removedSpawners)
		sidecarGonePayload = self:_appendRemovalPayload(sidecarGonePayload, "e", removedEjected)
		if not useFastSnapshot then
			snapshotGonePayload = staticGonePayload
			snapshotGonePayload = self:_appendRemovalPayload(snapshotGonePayload, "c", removedCells)
			snapshotGonePayload = self:_appendCellConsumePayload(snapshotGonePayload, removedCells)
			snapshotGonePayload = self:_appendRemovalPayload(snapshotGonePayload, "s", removedSpawners)
			snapshotGonePayload = self:_appendRemovalPayload(snapshotGonePayload, "e", removedEjected)
		end
		local snapshotPayload
		if useFastSnapshot then
			snapshotPayload = {
				k = "d",
				y = state.userId,
				c = { round(center.X, precision), round(center.Y, precision) },
				sr = round(self:_playerRadiusSum(state), Config.Network.MassPrecision),
				co = self:_packOwnCellBuffer(cellsPayload, state.userId),
				cr = self:_packRemoteCellBuffer(cellsPayload, state.userId),
				ej = self:_packEjectedBuffer(ejectedPayload),
				sp = self:_packFixedBuffer(fastSpawnersPayload, 4),
				ba = self:_packFixedBuffer(fastBarriersPayload, 5),
				sc = round(self:_playerMass(state), Config.Network.MassPrecision),
			}
		else
			snapshotPayload = {
				t = now,
				serverTime = serverTimeNow(),
				you = state.userId,
				world = { self.currentWorldSize.X, self.currentWorldSize.Y },
				center = { round(center.X, precision), round(center.Y, precision) },
				radius = radius,
				cells = cellsPayload,
				food = foodPayload,
				viruses = virusesPayload,
				ejected = ejectedPayload,
				spawners = spawnersPayload,
				barriers = barriersPayload,
				players = playerMetaPayload,
				gone = snapshotGonePayload,
				score = round(self:_playerMass(state), Config.Network.MassPrecision),
				coinBalance = state.coins,
				level = state.accountLevel,
				accountXp = math.floor(state.accountXp + 0.5),
				nextLevelXp = xpRequiredForNextLevel(state.accountLevel),
				lifeXp = math.floor(state.lifeXp + 0.5),
				lifeXpCap = Config.Progression.LifeXpCap or 25000,
				hasShop = includeShop,
				ownedSkins = includeShop and self:_ownedSkinsPayload(state) or nil,
				equippedSkin = includeShop and state.equippedSkin or nil,
				avatarDisplayMode = includeShop and normaliseAvatarDisplayMode(state.avatarDisplayMode) or nil,
				nickname = includeShop and normaliseNickname(state.nickname) or nil,
				debugWorldResizeEnabled = canUseWorldResizeDebug(state.player) and self.debugForceMaxWorldScale == true or false,
			}
		end
		local snapshotRemote = if useFastSnapshot then self.remotes.SnapshotFast else self.remotes.Snapshot
		snapshotRemote:FireClient(state.player, snapshotPayload)
		if useFastSnapshot then
			self:_fireFastCellSidecars(state.player, state.userId, cellOverflowPayload)
			self:_fireFastEjectedSidecars(state.player, state.userId, ejectedOverflowPayload)
		end
		local sidecarSpawnersPayload = if useFastSnapshot and not fastSpawnersPayload then spawnersPayload else nil
		local sidecarBarriersPayload = if useFastSnapshot and not fastBarriersPayload then barriersPayload else nil
		if useFastSnapshot and (sendStatics or sendMovingViruses or sidecarGonePayload or playerMetaPayload or sidecarSpawnersPayload or sidecarBarriersPayload) then
			self.remotes.Snapshot:FireClient(state.player, {
				t = now,
				serverTime = serverTimeNow(),
				staticOnly = true,
				you = state.userId,
				world = { self.currentWorldSize.X, self.currentWorldSize.Y },
				food = foodPayload,
				viruses = virusesPayload,
				spawners = sidecarSpawnersPayload,
				barriers = sidecarBarriersPayload,
				players = playerMetaPayload,
				gone = sidecarGonePayload,
			})
		end
		if includeShop then
			state.shopDirty = false
		end
	end
	for id, consume in self.cellConsumeTargets do
		if now >= consume.expiresAt then
			self.cellConsumeTargets[id] = nil
		end
	end
end

return GameService
