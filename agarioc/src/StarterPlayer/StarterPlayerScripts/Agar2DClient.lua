local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local clientModules = script.Parent:WaitForChild("Agar2D")
local sharedModules = ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared")
local Camera2D = require(clientModules:WaitForChild("Camera2D"))
local Config = require(sharedModules:WaitForChild("Config"))
local InputController = require(clientModules:WaitForChild("InputController"))
local Renderer = require(clientModules:WaitForChild("Renderer"))

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Agar2DRemotes")
local inputRemote = remotes:WaitForChild("InputFast", 1) or remotes:WaitForChild("Input")
local snapshotRemote = remotes:WaitForChild("Snapshot")
-- Wait indefinitely for ClientReady. The original 1-second timeout races
-- with server-side remote creation in Roblox Studio (published servers
-- are faster), causing the client to skip FireServer, which leaves the
-- server thinking the client never loaded and refusing to send snapshots.
-- Symptom: HUD renders, Ping stays "--", no player blob ever appears.
local clientReadyRemote = remotes:WaitForChild("ClientReady")
local shopRemote = remotes:WaitForChild("ShopAction")
local debugRemote = remotes:WaitForChild("DebugAction")
local respawnRemote = remotes:WaitForChild("RespawnRequest")

local camera = Camera2D.new()
local renderer = Renderer.new(player:WaitForChild("PlayerGui"), camera, shopRemote, debugRemote)
local input = InputController.new(inputRemote, camera, renderer)

local FORCED_ORIENTATION = (Config.UI and Config.UI.ForcedScreenOrientation) or Enum.ScreenOrientation.LandscapeRight
local optionalRemoteConnections = {}

local function applyScreenOrientation()
	pcall(function()
		StarterGui.ScreenOrientation = FORCED_ORIENTATION
	end)
	pcall(function()
		player:WaitForChild("PlayerGui").ScreenOrientation = FORCED_ORIENTATION
	end)
end

local function configureScreenOrientation()
	applyScreenOrientation()
	task.spawn(function()
		for _ = 1, 30 do
			task.wait(0.25)
			applyScreenOrientation()
		end
	end)
end

local function configureResetButton()
	local resetEvent = Instance.new("BindableEvent")
	resetEvent.Event:Connect(function()
		respawnRemote:FireServer()
	end)

	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", resetEvent)
			end)
			if ok then
				return
			end
			task.wait(0.25)
		end
	end)
end

local function bindOptionalClientRemote(remoteName: string, callback)
	local function connectRemote(remote)
		if optionalRemoteConnections[remoteName] then
			return
		end
		optionalRemoteConnections[remoteName] = remote.OnClientEvent:Connect(callback)
	end

	local existing = remotes:FindFirstChild(remoteName)
	if existing then
		connectRemote(existing)
		return
	end

	remotes.ChildAdded:Connect(function(child)
		if child.Name == remoteName then
			connectRemote(child)
		end
	end)
end

local function muteCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
	end

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Sound") then
			descendant.Volume = 0
		end
	end

	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Sound") then
			descendant.Volume = 0
		end
	end)
end

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)
snapshotRemote.OnClientEvent:Connect(function(snapshot)
	camera:updateFromSnapshot(snapshot)
	renderer:setSnapshot(snapshot)
end)
bindOptionalClientRemote("SnapshotFast", function(snapshot)
	camera:updateFromSnapshot(snapshot)
	renderer:setSnapshot(snapshot)
end)
bindOptionalClientRemote("SnapshotFastEjected", function(snapshot)
	renderer:setSnapshot(snapshot)
end)
if clientReadyRemote then
	clientReadyRemote:FireServer()
end
configureScreenOrientation()
configureResetButton()
if player.Character then
	muteCharacter(player.Character)
end
player.CharacterAdded:Connect(function(character)
	muteCharacter(character)
end)

local lastViewport = nil

local function updateViewport(force: boolean?)
	local cameraViewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
	local rootSize = renderer.root.AbsoluteSize
	local activeViewport = if rootSize.X > 0 and rootSize.Y > 0 then rootSize else cameraViewport
	if not force and lastViewport and lastViewport == activeViewport then
		return
	end
	lastViewport = activeViewport
	renderer:setViewport(cameraViewport)
	local viewport = renderer:getViewportSize(cameraViewport)
	camera:setViewport(viewport)
	renderer:setViewport(viewport)
end

updateViewport(true)
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		updateViewport(true)
	end)
end

shopRemote.OnClientEvent:Connect(function(payload)
	renderer:handleShopMessage(payload)
end)

RunService.RenderStepped:Connect(function(dt)
	updateViewport()
	input:step(dt)
	renderer:step(dt)
	camera:step(dt)
	renderer:render(dt)
end)

-- ==================================================================
-- LIVE CONFIG MENU (admin only) — press ] to toggle.
-- Non-admins never see the UI; the server also rejects their edits.
-- ==================================================================
local configMenuRemote = remotes:WaitForChild("ConfigUpdate", 10)

local function _splitConfigPath(path)
	local parts = {}
	for part in string.gmatch(path, "[^.]+") do
		table.insert(parts, part)
	end
	return parts
end

local function readConfigLocal(path)
	local parts = _splitConfigPath(path)
	local node = Config
	for _, part in ipairs(parts) do
		if type(node) ~= "table" then
			return nil
		end
		node = node[part]
	end
	return node
end

local function writeConfigLocal(path, value)
	local parts = _splitConfigPath(path)
	if #parts == 0 then
		return
	end
	local node = Config
	for i = 1, #parts - 1 do
		node = node[parts[i]]
		if type(node) ~= "table" then
			return
		end
	end
	node[parts[#parts]] = value
end

local function isLocalAdmin()
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

local configMenuState = {
	gui = nil,
	entries = {},
	open = false,
	search = "",
}

local function refreshAllEntries()
	for _, entry in ipairs(configMenuState.entries) do
		if entry.paint then
			entry.paint()
		end
	end
end

local function buildConfigMenu()
	if configMenuState.gui then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ConfigMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5000
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
	root.BackgroundTransparency = 0.05
	root.BorderSizePixel = 0
	root.Position = UDim2.new(0, 16, 0, 16)
	root.Size = UDim2.new(0, 420, 0, 560)
	root.ZIndex = 5000
	root.Parent = gui
	local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 8); rc.Parent = root
	local rs = Instance.new("UIStroke"); rs.Color = Color3.fromRGB(80, 88, 100); rs.Thickness = 1; rs.Parent = root

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Position = UDim2.new(0, 12, 0, 8)
	header.Size = UDim2.new(1, -60, 0, 20)
	header.Font = Enum.Font.GothamBold
	header.TextSize = 15
	header.TextColor3 = Color3.fromRGB(240, 240, 240)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Live Config"
	header.ZIndex = 5001
	header.Parent = root

	local subheader = Instance.new("TextLabel")
	subheader.Name = "Subheader"
	subheader.BackgroundTransparency = 1
	subheader.Position = UDim2.new(0, 12, 0, 26)
	subheader.Size = UDim2.new(1, -60, 0, 14)
	subheader.Font = Enum.Font.Gotham
	subheader.TextSize = 11
	subheader.TextColor3 = Color3.fromRGB(150, 158, 170)
	subheader.TextXAlignment = Enum.TextXAlignment.Left
	subheader.Text = "]  to toggle  ·  Enter to commit  ·  broadcasts to all clients"
	subheader.ZIndex = 5001
	subheader.Parent = root

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.BackgroundColor3 = Color3.fromRGB(60, 66, 76)
	closeBtn.BorderSizePixel = 0
	closeBtn.Position = UDim2.new(1, -36, 0, 8)
	closeBtn.Size = UDim2.new(0, 26, 0, 26)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
	closeBtn.Text = "X"
	closeBtn.AutoButtonColor = true
	closeBtn.ZIndex = 5001
	closeBtn.Parent = root
	local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 4); cc.Parent = closeBtn

	local search = Instance.new("TextBox")
	search.Name = "Search"
	search.BackgroundColor3 = Color3.fromRGB(36, 40, 48)
	search.BorderSizePixel = 0
	search.Position = UDim2.new(0, 12, 0, 48)
	search.Size = UDim2.new(1, -24, 0, 28)
	search.Font = Enum.Font.Gotham
	search.TextSize = 13
	search.TextColor3 = Color3.fromRGB(240, 240, 240)
	search.PlaceholderText = "Search…"
	search.PlaceholderColor3 = Color3.fromRGB(140, 148, 160)
	search.Text = ""
	search.ClearTextOnFocus = false
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.ZIndex = 5001
	search.Parent = root
	local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(0, 4); sc.Parent = search
	local searchPad = Instance.new("UIPadding")
	searchPad.PaddingLeft = UDim.new(0, 8)
	searchPad.PaddingRight = UDim.new(0, 8)
	searchPad.Parent = search

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.new(0, 8, 0, 84)
	scroll.Size = UDim2.new(1, -16, 1, -92)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Color3.fromRGB(120, 128, 140)
	scroll.ZIndex = 5001
	scroll.Parent = root
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local function formatNumber(schema, v)
		if type(v) ~= "number" then
			return "?"
		end
		if schema.int then
			return string.format("%d", math.floor(v + 0.5))
		end
		if math.abs(v) > 0 and math.abs(v) < 0.001 then
			return string.format("%.6f", v)
		end
		return string.format("%.4g", v)
	end

	local function makeEntry(schema, index)
		local row = Instance.new("Frame")
		row.Name = schema.path
		row.BackgroundColor3 = Color3.fromRGB(36, 40, 48)
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, -6, 0, 36)
		row.LayoutOrder = index
		row.ZIndex = 5002
		row.Parent = scroll
		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 4)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 8, 0, 3)
		label.Size = UDim2.new(0.5, -8, 0, 16)
		label.Font = Enum.Font.Gotham
		label.TextSize = 13
		label.TextColor3 = Color3.fromRGB(220, 224, 230)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = schema.label or schema.path
		label.ZIndex = 5003
		label.Parent = row

		local pathLabel = Instance.new("TextLabel")
		pathLabel.Name = "Path"
		pathLabel.BackgroundTransparency = 1
		pathLabel.Position = UDim2.new(0, 8, 0, 19)
		pathLabel.Size = UDim2.new(0.5, -8, 0, 14)
		pathLabel.Font = Enum.Font.Code
		pathLabel.TextSize = 10
		pathLabel.TextColor3 = Color3.fromRGB(130, 138, 150)
		pathLabel.TextXAlignment = Enum.TextXAlignment.Left
		pathLabel.Text = schema.path
		pathLabel.ZIndex = 5003
		pathLabel.Parent = row

		local entry = { row = row, schema = schema }

		if schema.type == "bool" then
			local btn = Instance.new("TextButton")
			btn.Name = "Toggle"
			btn.Position = UDim2.new(1, -84, 0.5, -13)
			btn.Size = UDim2.new(0, 76, 0, 26)
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = 12
			btn.BorderSizePixel = 0
			btn.AutoButtonColor = true
			btn.ZIndex = 5003
			btn.Parent = row
			local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 4); bc.Parent = btn

			local function paint()
				local v = readConfigLocal(schema.path)
				if v then
					btn.Text = "ON"
					btn.BackgroundColor3 = Color3.fromRGB(56, 130, 84)
					btn.TextColor3 = Color3.fromRGB(240, 255, 240)
				else
					btn.Text = "OFF"
					btn.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
					btn.TextColor3 = Color3.fromRGB(255, 240, 240)
				end
			end
			paint()

			btn.MouseButton1Click:Connect(function()
				local newValue = not readConfigLocal(schema.path)
				writeConfigLocal(schema.path, newValue)
				paint()
				if configMenuRemote then
					configMenuRemote:FireServer({ path = schema.path, value = newValue })
				end
			end)

			entry.paint = paint
		else
			local box = Instance.new("TextBox")
			box.Name = "Value"
			box.Position = UDim2.new(1, -180, 0.5, -13)
			box.Size = UDim2.new(0, 100, 0, 26)
			box.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
			box.BorderSizePixel = 0
			box.Font = Enum.Font.Code
			box.TextSize = 13
			box.TextColor3 = Color3.fromRGB(240, 240, 240)
			box.ClearTextOnFocus = false
			box.TextXAlignment = Enum.TextXAlignment.Right
			box.ZIndex = 5003
			box.Parent = row
			local boxCorner = Instance.new("UICorner"); boxCorner.CornerRadius = UDim.new(0, 4); boxCorner.Parent = box
			local pad = Instance.new("UIPadding")
			pad.PaddingRight = UDim.new(0, 6)
			pad.PaddingLeft = UDim.new(0, 6)
			pad.Parent = box

			local rangeLabel = Instance.new("TextLabel")
			rangeLabel.Name = "Range"
			rangeLabel.BackgroundTransparency = 1
			rangeLabel.Position = UDim2.new(1, -74, 0.5, -8)
			rangeLabel.Size = UDim2.new(0, 68, 0, 16)
			rangeLabel.Font = Enum.Font.Code
			rangeLabel.TextSize = 10
			rangeLabel.TextColor3 = Color3.fromRGB(130, 138, 150)
			rangeLabel.TextXAlignment = Enum.TextXAlignment.Left
			rangeLabel.Text = string.format("%.4g..%.4g", schema.min or 0, schema.max or 0)
			rangeLabel.ZIndex = 5003
			rangeLabel.Parent = row

			local function paint()
				if box:IsFocused() then
					return
				end
				box.Text = formatNumber(schema, readConfigLocal(schema.path))
			end
			paint()

			box.FocusLost:Connect(function()
				local n = tonumber(box.Text)
				if not n then
					paint()
					return
				end
				if schema.min then
					n = math.max(schema.min, n)
				end
				if schema.max then
					n = math.min(schema.max, n)
				end
				if schema.int then
					n = math.floor(n + 0.5)
				end
				writeConfigLocal(schema.path, n)
				box.Text = formatNumber(schema, n)
				if configMenuRemote then
					configMenuRemote:FireServer({ path = schema.path, value = n })
				end
			end)

			entry.paint = paint
		end

		return entry
	end

	for i, schema in ipairs(Config.Tunables or {}) do
		table.insert(configMenuState.entries, makeEntry(schema, i))
	end

	local function applyFilter()
		local q = string.lower(configMenuState.search or "")
		for _, entry in ipairs(configMenuState.entries) do
			local hay = string.lower((entry.schema.label or "") .. " " .. entry.schema.path)
			entry.row.Visible = (q == "" or string.find(hay, q, 1, true) ~= nil)
		end
	end
	search:GetPropertyChangedSignal("Text"):Connect(function()
		configMenuState.search = search.Text
		applyFilter()
	end)

	closeBtn.MouseButton1Click:Connect(function()
		configMenuState.open = false
		gui.Enabled = false
	end)

	configMenuState.gui = gui
end

local function toggleConfigMenu()
	if not isLocalAdmin() then
		return
	end
	buildConfigMenu()
	configMenuState.open = not configMenuState.open
	configMenuState.gui.Enabled = configMenuState.open
	if configMenuState.open then
		refreshAllEntries()
	end
end

UserInputService.InputBegan:Connect(function(inputObj, processed)
	if processed then
		return
	end
	if inputObj.KeyCode == Enum.KeyCode.RightBracket then
		toggleConfigMenu()
	end
end)

if configMenuRemote then
	configMenuRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.values) ~= "table" then
			return
		end
		for path, value in pairs(payload.values) do
			writeConfigLocal(path, value)
		end
		if configMenuState.gui then
			refreshAllEntries()
		end
	end)
end
