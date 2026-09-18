local CirclePool = {}
CirclePool.__index = CirclePool

local function cacheFrameParts(frame: Frame)
	local skin = frame:FindFirstChild("Skin")
	local avatar = frame:FindFirstChild("Avatar")
	local labelStack = frame:FindFirstChild("LabelStack")
	return {
		stroke = frame:FindFirstChildOfClass("UIStroke"),
		frameCorner = frame:FindFirstChild("FrameCorner"),
		skin = skin,
		skinCorner = skin and skin:FindFirstChild("SkinCorner") or nil,
		avatar = avatar,
		avatarCorner = avatar and avatar:FindFirstChild("AvatarCorner") or nil,
		labelStack = labelStack,
		nameLabel = labelStack and labelStack:FindFirstChild("NameLabel") or nil,
		scoreLabel = labelStack and labelStack:FindFirstChild("ScoreLabel") or nil,
		cache = {},
	}
end

local function setCached(parts, key: string, instance: Instance, property: string, value)
	if parts.cache[key] == value then
		return
	end
	parts.cache[key] = value
	instance[property] = value
end

local function ensureSerrations(frame: Frame, parts)
	if parts.serrations then
		return
	end

	parts.serrations = {}
	for index = 1, 16 do
		local angle = (index - 1) * (math.pi * 2 / 16)
		local tooth = Instance.new("Frame")
		tooth.Name = "Serration"
		tooth.AnchorPoint = Vector2.new(0.5, 0.5)
		tooth.BorderSizePixel = 0
		tooth.Position = UDim2.fromScale(
			0.5 + math.cos(angle) * 0.48,
			0.5 + math.sin(angle) * 0.48
		)
		tooth.Rotation = math.deg(angle) + 45
		tooth.Size = UDim2.fromScale(0.2, 0.2)
		tooth.Visible = false
		tooth.Parent = frame
		parts.serrations[index] = tooth
	end
end

local function ensureLiquidRipples(frame: Frame, parts)
	if parts.liquidRipples then
		return
	end

	parts.liquidRipples = {}
	for index = 1, 3 do
		local ring = Instance.new("Frame")
		ring.Name = "LiquidRipple"
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.Position = UDim2.fromScale(0.5, 0.5)
		ring.Size = UDim2.fromScale(1, 1)
		ring.Visible = false
		ring.Parent = frame

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = ring

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Thickness = 1.5
		stroke.Transparency = 1
		stroke.Parent = ring

		parts.liquidRipples[index] = {
			frame = ring,
			stroke = stroke,
		}
	end
end

local function resetFrame(frame: Frame, parts)
	parts.cache = {}
	frame.Visible = false
	frame.BackgroundTransparency = 0
	frame.Position = UDim2.fromOffset(-100000, -100000)
	frame.Size = UDim2.fromOffset(1, 1)
	frame.Rotation = 0
	parts.lastZIndex = nil

	if parts.frameCorner then
		parts.frameCorner.CornerRadius = UDim.new(1, 0)
	end

	if parts.skin then
		parts.skin.Visible = false
		parts.skin.Rotation = 0
		parts.skin.ScaleType = Enum.ScaleType.Crop
		parts.skin.Image = ""
		parts.skin.ImageColor3 = Color3.fromRGB(255, 255, 255)
		parts.skin.ImageTransparency = 0
		parts.skin.ImageRectOffset = Vector2.new(0, 0)
		parts.skin.ImageRectSize = Vector2.new(0, 0)
	end
	if parts.skinCorner then
		parts.skinCorner.CornerRadius = UDim.new(1, 0)
	end

	if parts.avatar then
		parts.avatar.Visible = false
		parts.avatar.Rotation = 0
		parts.avatar.Image = ""
		parts.avatar.ImageColor3 = Color3.fromRGB(255, 255, 255)
		parts.avatar.ImageTransparency = 0
		parts.avatar.ImageRectOffset = Vector2.new(0, 0)
		parts.avatar.ImageRectSize = Vector2.new(0, 0)
		parts.avatar.ScaleType = Enum.ScaleType.Crop
	end
	if parts.avatarCorner then
		parts.avatarCorner.CornerRadius = UDim.new(1, 0)
	end

	if parts.labelStack then
		parts.labelStack.Visible = false
		parts.labelStack.Rotation = 0
	end
	if parts.serrations then
		for _, tooth in parts.serrations do
			tooth.Visible = false
		end
	end
	if parts.liquidRipples then
		for _, ripple in parts.liquidRipples do
			ripple.frame.Visible = false
		end
	end
end

local function applyZIndex(frame: Frame, parts, zIndex: number)
	if parts.lastZIndex == zIndex then
		return
	end
	parts.lastZIndex = zIndex
	frame.ZIndex = zIndex
	if parts.skin then
		parts.skin.ZIndex = zIndex + 1
	end
	if parts.avatar then
		parts.avatar.ZIndex = zIndex + 2
	end
	if parts.labelStack then
		parts.labelStack.ZIndex = zIndex + 3
	end
	if parts.nameLabel then
		parts.nameLabel.ZIndex = zIndex + 4
	end
	if parts.scoreLabel then
		parts.scoreLabel.ZIndex = zIndex + 4
	end
	if parts.serrations then
		for _, tooth in parts.serrations do
			tooth.ZIndex = zIndex
		end
	end
	if parts.liquidRipples then
		for _, ripple in parts.liquidRipples do
			ripple.frame.ZIndex = zIndex + 3
		end
	end
end

local function makeCircle(parent: Instance, zIndex: number)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	-- Serration teeth extend beyond the circular body.
	frame.ClipsDescendants = false
	frame.ZIndex = zIndex
	frame.Visible = false
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.Name = "FrameCorner"
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Transparency = 0.35
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Parent = frame

	local skin = Instance.new("ImageLabel")
	skin.Name = "Skin"
	skin.AnchorPoint = Vector2.new(0.5, 0.5)
	skin.BackgroundTransparency = 1
	skin.BorderSizePixel = 0
	skin.Position = UDim2.fromScale(0.5, 0.5)
	skin.ScaleType = Enum.ScaleType.Crop
	skin.Size = UDim2.fromScale(1, 1)
	skin.Visible = false
	skin.ZIndex = zIndex + 1
	skin.Parent = frame

	local skinCorner = Instance.new("UICorner")
	skinCorner.Name = "SkinCorner"
	skinCorner.CornerRadius = UDim.new(1, 0)
	skinCorner.Parent = skin

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.AnchorPoint = Vector2.new(0.5, 0.5)
	avatar.BackgroundTransparency = 1
	avatar.BorderSizePixel = 0
	avatar.Position = UDim2.fromScale(0.5, 0.5)
	avatar.ScaleType = Enum.ScaleType.Crop
	avatar.Size = UDim2.fromScale(1, 1)
	avatar.Visible = false
	avatar.ZIndex = zIndex + 2
	avatar.Parent = frame

	local avatarCorner = Instance.new("UICorner")
	avatarCorner.Name = "AvatarCorner"
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar

	local labelStack = Instance.new("Frame")
	labelStack.Name = "LabelStack"
	labelStack.AnchorPoint = Vector2.new(0.5, 0.5)
	labelStack.BackgroundTransparency = 1
	labelStack.Position = UDim2.fromScale(0.5, 0.5)
	labelStack.Size = UDim2.fromScale(0.92, 0.46)
	labelStack.Visible = false
	labelStack.ZIndex = zIndex + 3
	labelStack.Parent = frame

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.BackgroundTransparency = 1
	nameLabel.BorderSizePixel = 0
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.Size = UDim2.fromScale(1, 0.5)
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextScaled = true
	nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	nameLabel.TextStrokeTransparency = 0.25
	nameLabel.ZIndex = zIndex + 4
	nameLabel.Parent = labelStack

	local scoreLabel = Instance.new("TextLabel")
	scoreLabel.Name = "ScoreLabel"
	scoreLabel.BackgroundTransparency = 1
	scoreLabel.BorderSizePixel = 0
	scoreLabel.Font = Enum.Font.GothamMedium
	scoreLabel.Position = UDim2.fromScale(0, 0.5)
	scoreLabel.Size = UDim2.fromScale(1, 0.5)
	scoreLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	scoreLabel.TextScaled = true
	scoreLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	scoreLabel.TextStrokeTransparency = 0.25
	scoreLabel.ZIndex = zIndex + 4
	scoreLabel.Parent = labelStack

	return frame
end

function CirclePool.new(parent: Instance, zIndex: number)
	return setmetatable({
		parent = parent,
		zIndex = zIndex,
		active = {},
		free = {},
		retired = {},
		parts = {},
		touched = {},
		stale = {},
	}, CirclePool)
end

function CirclePool:_retire(frame: Frame)
	resetFrame(frame, self.parts[frame])
	self.retired[#self.retired + 1] = frame
end

function CirclePool:_promoteRetired()
	if #self.retired == 0 then
		return
	end

	for i = 1, #self.retired do
		self.free[#self.free + 1] = self.retired[i]
		self.retired[i] = nil
	end
end

function CirclePool:begin()
	for id in self.touched do
		self.touched[id] = nil
	end
end

function CirclePool:draw(id: number, screenPos: Vector2, radius: number, color: Color3, options)
	local frame = self.active[id]
	if not frame then
		frame = table.remove(self.free)
		if not frame then
			frame = makeCircle(self.parent, self.zIndex)
			self.parts[frame] = cacheFrameParts(frame)
		end
		resetFrame(frame, self.parts[frame])
		self.active[id] = frame
	end

	local parts = self.parts[frame]
	if options and options.serrated then
		ensureSerrations(frame, parts)
	end
	if options and options.liquidRippleProgress then
		ensureLiquidRipples(frame, parts)
	end
	local zIndex = options and options.zIndex or self.zIndex
	applyZIndex(frame, parts, zIndex)
	local width = options and options.width and math.max(math.floor(options.width + 0.5), 1) or math.max(math.floor(radius * 2 + 0.5), 1)
	local height = options and options.height and math.max(math.floor(options.height + 0.5), 1) or math.max(math.floor(radius * 2 + 0.5), 1)
	local x = math.floor(screenPos.X + 0.5)
	local y = math.floor(screenPos.Y + 0.5)
	self.touched[id] = true
	setCached(parts, "frameColor", frame, "BackgroundColor3", color)
	setCached(parts, "frameTransparency", frame, "BackgroundTransparency", options and options.backgroundTransparency or 0)
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(width, height)
	setCached(parts, "frameRotation", frame, "Rotation", 0)

	if parts.stroke then
		setCached(parts, "strokeEnabled", parts.stroke, "Enabled", not options or options.strokeEnabled ~= false)
	end
	if parts.frameCorner then
		setCached(parts, "frameCorner", parts.frameCorner, "CornerRadius", options and options.cornerRadius or UDim.new(1, 0))
	end
	if parts.serrations then
		local serrated = options and options.serrated == true
		for index, tooth in parts.serrations do
			setCached(parts, "serrationVisible" .. index, tooth, "Visible", serrated)
			if serrated then
				setCached(parts, "serrationColor" .. index, tooth, "BackgroundColor3", color)
			end
		end
	end

	if options then
		if parts.skin then
			setCached(parts, "skinRotation", parts.skin, "Rotation", 0)
			setCached(parts, "skinScaleType", parts.skin, "ScaleType", Enum.ScaleType.Crop)
			setCached(parts, "skinVisible", parts.skin, "Visible", options.baseImage ~= nil)
			setCached(parts, "skinImage", parts.skin, "Image", options.baseImage or "")
			setCached(parts, "skinColor", parts.skin, "ImageColor3", options.baseImageColor or Color3.fromRGB(255, 255, 255))
			setCached(parts, "skinTransparency", parts.skin, "ImageTransparency", options.baseImageTransparency or 0)
			setCached(parts, "skinRectOffset", parts.skin, "ImageRectOffset", options.baseImageRectOffset or Vector2.new(0, 0))
			setCached(parts, "skinRectSize", parts.skin, "ImageRectSize", options.baseImageRectSize or Vector2.new(0, 0))
		end
		if parts.skinCorner then
			setCached(parts, "skinCorner", parts.skinCorner, "CornerRadius", options.cornerRadius or UDim.new(1, 0))
		end

		if parts.avatar then
			setCached(parts, "avatarRotation", parts.avatar, "Rotation", 0)
			local overlayScale = options.overlayScale or 1
			local overlaySize = if overlayScale < 1 then math.max(math.floor(math.min(width, height) * overlayScale + 0.5), 1) else nil
			setCached(parts, "avatarVisible", parts.avatar, "Visible", options.image ~= nil)
			setCached(parts, "avatarImage", parts.avatar, "Image", options.image or "")
			setCached(parts, "avatarColor", parts.avatar, "ImageColor3", options.imageColor or Color3.fromRGB(255, 255, 255))
			setCached(parts, "avatarTransparency", parts.avatar, "ImageTransparency", options.imageTransparency or 0)
			setCached(parts, "avatarRectOffset", parts.avatar, "ImageRectOffset", options.imageRectOffset or Vector2.new(0, 0))
			setCached(parts, "avatarRectSize", parts.avatar, "ImageRectSize", options.imageRectSize or Vector2.new(0, 0))
			setCached(parts, "avatarScaleType", parts.avatar, "ScaleType", options.imageScaleType or Enum.ScaleType.Crop)
			if overlaySize then
				parts.avatar.Size = UDim2.fromOffset(overlaySize, overlaySize)
			else
				parts.avatar.Size = UDim2.fromScale(1, 1)
			end
			parts.avatar.Position = UDim2.fromScale(0.5, 0.5)
		end
		if parts.avatarCorner then
			setCached(parts, "avatarCorner", parts.avatarCorner, "CornerRadius", options.cornerRadius or UDim.new(1, 0))
		end

		if parts.labelStack then
			setCached(parts, "labelRotation", parts.labelStack, "Rotation", 0)
			setCached(parts, "labelVisible", parts.labelStack, "Visible", radius >= 18)
			if parts.nameLabel then
				setCached(parts, "nameText", parts.nameLabel, "Text", options.name or "")
			end
			if parts.scoreLabel then
				setCached(parts, "scoreText", parts.scoreLabel, "Text", options.score or "")
			end
		end
	else
		if parts.skin then
			setCached(parts, "skinRotation", parts.skin, "Rotation", 0)
			setCached(parts, "skinScaleType", parts.skin, "ScaleType", Enum.ScaleType.Crop)
			setCached(parts, "skinVisible", parts.skin, "Visible", false)
			setCached(parts, "skinImage", parts.skin, "Image", "")
			setCached(parts, "skinColor", parts.skin, "ImageColor3", Color3.fromRGB(255, 255, 255))
			setCached(parts, "skinTransparency", parts.skin, "ImageTransparency", 0)
		end
		if parts.avatar then
			setCached(parts, "avatarRotation", parts.avatar, "Rotation", 0)
			setCached(parts, "avatarVisible", parts.avatar, "Visible", false)
			setCached(parts, "avatarImage", parts.avatar, "Image", "")
			setCached(parts, "avatarColor", parts.avatar, "ImageColor3", Color3.fromRGB(255, 255, 255))
			setCached(parts, "avatarTransparency", parts.avatar, "ImageTransparency", 0)
			setCached(parts, "avatarScaleType", parts.avatar, "ScaleType", Enum.ScaleType.Crop)
		end
		if parts.labelStack then
			setCached(parts, "labelRotation", parts.labelStack, "Rotation", 0)
			setCached(parts, "labelVisible", parts.labelStack, "Visible", false)
		end
	end

	if parts.liquidRipples then
		local progress = options and options.liquidRippleProgress
		local depth = math.clamp(options and options.liquidRippleDepth or 0.18, 0, 0.5)
		for index, ripple in parts.liquidRipples do
			local delay = (index - 1) * 0.14
			local waveProgress = if progress then (progress - delay) / math.max(1 - delay, 0.01) else -1
			local visible = waveProgress >= 0 and waveProgress < 1
			setCached(parts, "liquidVisible" .. index, ripple.frame, "Visible", visible)
			if visible then
				waveProgress = math.clamp(waveProgress, 0, 1)
				local sizeScale = 1 - depth * waveProgress
				ripple.frame.Size = UDim2.fromScale(sizeScale, sizeScale)
				setCached(
					parts,
					"liquidTransparency" .. index,
					ripple.stroke,
					"Transparency",
					0.18 + waveProgress * 0.82
				)
			end
		end
	end

	frame.Visible = true
end

function CirclePool:release(id: number)
	local frame = self.active[id]
	if not frame then
		return
	end

	self.active[id] = nil
	self:_retire(frame)
end

function CirclePool:finish()
	local stale = self.stale
	for i = 1, #stale do
		stale[i] = nil
	end
	for id, frame in self.active do
		if not self.touched[id] then
			self:_retire(frame)
			stale[#stale + 1] = id
		end
	end

	for _, id in stale do
		self.active[id] = nil
	end

	self:_promoteRetired()
end

return CirclePool
