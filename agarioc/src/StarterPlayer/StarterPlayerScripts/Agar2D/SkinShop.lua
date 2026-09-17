local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared"):WaitForChild("Config"))
local SkinData = require(ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared"):WaitForChild("SkinData"))
local Localization = require(script.Parent:WaitForChild("Localization"))

local SkinShop = {}
SkinShop.__index = SkinShop
local DEFAULT_AVATAR_DISPLAY_MODE = "face"
local AVATAR_DISPLAY_HIDDEN = "hidden"
local AVATAR_MODE_ORDER = {
	{ mode = "fullBody", key = "avatar_full_body" },
	{ mode = "bust", key = "avatar_bust" },
	{ mode = "face", key = "avatar_face" },
}

local function makeCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function makeButton(parent: Instance, text: string)
	local button = Instance.new("TextButton")
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.fromRGB(34, 40, 52)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamMedium
	button.Text = text
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 14
	button.Parent = parent
	makeCorner(button, 6)
	return button
end

local function makeTextBox(parent: Instance, placeholder: string)
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = Color3.fromRGB(34, 40, 52)
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.GothamMedium
	box.PlaceholderColor3 = Color3.fromRGB(155, 165, 184)
	box.PlaceholderText = placeholder
	box.Text = ""
	box.TextColor3 = Color3.fromRGB(255, 255, 255)
	box.TextSize = 14
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Parent = parent
	makeCorner(box, 6)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = box
	return box
end

local function viewportSize(parent: Instance): Vector2
	local size = parent.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return Vector2.new(1280, 720)
	end
	return size
end

local function normaliseAvatarDisplayMode(value): string
	if value == "face" or value == "bust" or value == "fullBody" or value == AVATAR_DISPLAY_HIDDEN then
		return value
	end
	return DEFAULT_AVATAR_DISPLAY_MODE
end

local function trim(value: string): string
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
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
	local maxLength = math.max(Config.Shop.NicknameMaxLength or 20, 0)
	if maxLength > 0 and #value > maxLength then
		value = string.sub(value, 1, maxLength)
	end
	return value
end

function SkinShop.new(parent: Instance, remote: RemoteEvent, localization)
	local strings = localization or Localization.new()

	local openButton = makeButton(parent, strings:shopButtonText())
	openButton.Name = "SkinsButton"
	openButton.AnchorPoint = Vector2.new(1, 0)
	openButton.Position = UDim2.new(1, -14, 0, 14)
	openButton.Size = UDim2.fromOffset(92, 34)
	openButton.ZIndex = 125

	local panel = Instance.new("Frame")
	panel.Name = "SkinShop"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(360, 420)
	panel.Visible = false
	panel.ZIndex = 130
	panel.Parent = parent
	makeCorner(panel, 8)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Position = UDim2.fromOffset(12, 8)
	title.Size = UDim2.new(1, -64, 0, 28)
	title.Text = strings:shopTitleText()
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 131
	title.Parent = panel

	local closeButton = makeButton(panel, "X")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -10, 0, 8)
	closeButton.Size = UDim2.fromOffset(34, 28)
	closeButton.ZIndex = 131

	local nicknameBox = makeTextBox(panel, strings:text("nickname_placeholder"))
	nicknameBox.Name = "Nickname"
	nicknameBox.Position = UDim2.fromOffset(12, 42)
	nicknameBox.Size = UDim2.new(1, -24, 0, 30)
	nicknameBox.ZIndex = 131

	local avatarRow = Instance.new("Frame")
	avatarRow.Name = "AvatarDisplay"
	avatarRow.BackgroundTransparency = 1
	avatarRow.Position = UDim2.fromOffset(12, 78)
	avatarRow.Size = UDim2.new(1, -24, 0, 30)
	avatarRow.ZIndex = 131
	avatarRow.Parent = panel

	local avatarLayout = Instance.new("UIListLayout")
	avatarLayout.FillDirection = Enum.FillDirection.Horizontal
	avatarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	avatarLayout.Padding = UDim.new(0, 6)
	avatarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	avatarLayout.Parent = avatarRow

	local avatarButtons = {}
	for index, modeInfo in AVATAR_MODE_ORDER do
		local button = makeButton(avatarRow, strings:text(modeInfo.key))
		button.Name = modeInfo.mode
		button.LayoutOrder = index
		button.Size = UDim2.new(1 / #AVATAR_MODE_ORDER, -4, 1, 0)
		button.TextSize = 12
		button.ZIndex = 131
		avatarButtons[modeInfo.mode] = button
	end

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.GothamMedium
	statusLabel.Position = UDim2.fromOffset(12, 114)
	statusLabel.Size = UDim2.new(1, -24, 0, 34)
	statusLabel.Text = ""
	statusLabel.TextColor3 = Color3.fromRGB(255, 215, 120)
	statusLabel.TextSize = 13
	statusLabel.TextWrapped = true
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.ZIndex = 131
	statusLabel.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.Active = true
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.Position = UDim2.fromOffset(10, 154)
	scroll.ScrollBarThickness = 6
	scroll.Size = UDim2.new(1, -20, 1, -164)
	scroll.ZIndex = 131
	scroll.Parent = panel

	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.CellSize = UDim2.fromOffset(104, 142)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local self = setmetatable({
		remote = remote,
		parent = parent,
		localization = strings,
		openButton = openButton,
		panel = panel,
		scroll = scroll,
		statusLabel = statusLabel,
		nicknameBox = nicknameBox,
		avatarButtons = avatarButtons,
		tiles = {},
		coins = 0,
		owned = {},
		equippedSkin = nil,
		avatarDisplayMode = DEFAULT_AVATAR_DISPLAY_MODE,
		nickname = "",
		visibilityChanged = nil,
	}, SkinShop)

	self:_layout()
	for index, skin in SkinData.OrderedSkins do
		self:_createTile(index, skin)
	end

	parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end)

	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		scroll.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 8)
	end)

	openButton.Activated:Connect(function()
		self:setOpen(not panel.Visible)
	end)

	closeButton.Activated:Connect(function()
		self:setOpen(false)
	end)

	for mode, button in avatarButtons do
		button.Activated:Connect(function()
			local requestedMode = if self.avatarDisplayMode == mode then AVATAR_DISPLAY_HIDDEN else mode
			self.avatarDisplayMode = requestedMode
			self:_refresh()
			remote:FireServer({
				action = "avatarDisplay",
				mode = requestedMode,
			})
		end)
	end

	nicknameBox.FocusLost:Connect(function()
		local nickname = normaliseNickname(nicknameBox.Text)
		if nickname == self.nickname then
			nicknameBox.Text = nickname
			return
		end

		remote:FireServer({
			action = "nickname",
			nickname = nickname,
		})
	end)

	self:_refresh()
	return self
end

function SkinShop:_layout()
	local viewport = viewportSize(self.parent)
	local width = math.clamp(viewport.X - 28, 300, 560)
	local height = math.clamp(viewport.Y - 120, 300, 580)

	self.openButton.Position = UDim2.new(1, -14, 0, 14)
	self.panel.Size = UDim2.fromOffset(width, height)
end

function SkinShop:setOpen(isOpen: boolean)
	self.panel.Visible = isOpen
	if self.visibilityChanged then
		self.visibilityChanged(isOpen)
	end
end

function SkinShop:handleServerMessage(payload)
	if typeof(payload) ~= "table" or payload.type ~= "result" then
		return
	end

	local message = if typeof(payload.message) == "string" then payload.message else ""
	self.statusLabel.Text = message
	if payload.ok then
		self.statusLabel.TextColor3 = Color3.fromRGB(150, 245, 180)
	else
		self.statusLabel.TextColor3 = Color3.fromRGB(255, 215, 120)
		if payload.reason == "filter_failed" and self.nicknameBox then
			self.nicknameBox.Text = self.nickname
		end
	end
end

function SkinShop:_createTile(index: number, skin)
	local tile = Instance.new("Frame")
	tile.BackgroundColor3 = Color3.fromRGB(28, 34, 45)
	tile.BorderSizePixel = 0
	tile.LayoutOrder = index
	tile.ZIndex = 131
	tile.Parent = self.scroll
	makeCorner(tile, 8)

	local image = Instance.new("ImageLabel")
	image.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
	image.BorderSizePixel = 0
	image.Image = skin.image
	if skin.imageRectOffset then
		image.ImageRectOffset = skin.imageRectOffset
	end
	if skin.imageRectSize then
		image.ImageRectSize = skin.imageRectSize
	end
	image.Position = UDim2.fromOffset(20, 8)
	image.ScaleType = Enum.ScaleType.Crop
	image.Size = UDim2.fromOffset(64, 64)
	image.ZIndex = 132
	image.Parent = tile
	makeCorner(image, 32)

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamMedium
	name.Position = UDim2.fromOffset(6, 76)
	name.Size = UDim2.new(1, -12, 0, 30)
	name.Text = skin.name
	name.TextColor3 = Color3.fromRGB(255, 255, 255)
	name.TextScaled = true
	name.TextWrapped = true
	name.ZIndex = 132
	name.Parent = tile

	local action = makeButton(tile, "")
	action.Position = UDim2.fromOffset(8, 110)
	action.Size = UDim2.new(1, -16, 0, 24)
	action.TextSize = 12
	action.ZIndex = 132
	action.Activated:Connect(function()
		if self.owned[skin.id] then
			self.remote:FireServer({
				action = if self.equippedSkin == skin.id then "unequip" else "equip",
				skinId = skin.id,
			})
		else
			self.remote:FireServer({
				action = "buy",
				skinId = skin.id,
			})
		end
	end)

	self.tiles[skin.id] = {
		skin = skin,
		action = action,
	}
end

function SkinShop:update(coins: number, ownedSkins, equippedSkin: string?, avatarDisplayMode: string?, nickname: string?)
	self.coins = coins or 0
	table.clear(self.owned)
	if typeof(ownedSkins) == "table" then
		for _, id in ownedSkins do
			self.owned[id] = true
		end
	end
	self.equippedSkin = equippedSkin
	self.avatarDisplayMode = normaliseAvatarDisplayMode(avatarDisplayMode)
	self.nickname = normaliseNickname(nickname)
	self:_refresh()
end

function SkinShop:updateCoins(coins: number)
	self.coins = coins or 0
	self:_refresh()
end

function SkinShop:_refresh()
	if self.nicknameBox and not self.nicknameBox:IsFocused() and self.nicknameBox.Text ~= self.nickname then
		self.nicknameBox.Text = self.nickname
	end

	for mode, button in self.avatarButtons do
		if self.avatarDisplayMode == mode then
			button.BackgroundColor3 = Color3.fromRGB(50, 135, 90)
		else
			button.BackgroundColor3 = Color3.fromRGB(34, 40, 52)
		end
	end

	for id, tile in self.tiles do
		local skin = tile.skin
		local action = tile.action
		if self.equippedSkin == id then
			action.Text = self.localization:text("equipped")
			action.BackgroundColor3 = Color3.fromRGB(50, 135, 90)
		elseif self.owned[id] then
			action.Text = self.localization:text("equip")
			action.BackgroundColor3 = Color3.fromRGB(52, 74, 110)
		elseif self.coins >= skin.cost then
			action.Text = self.localization:buyText(skin.cost)
			action.BackgroundColor3 = Color3.fromRGB(88, 110, 52)
		else
			action.Text = tostring(skin.cost) .. " " .. self.localization:text("coins")
			action.BackgroundColor3 = Color3.fromRGB(68, 68, 78)
		end
	end
end

return SkinShop
