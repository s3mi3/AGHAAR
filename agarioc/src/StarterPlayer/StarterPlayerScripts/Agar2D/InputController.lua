local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Agar2D"):WaitForChild("Shared"):WaitForChild("Config"))

local InputController = {}
InputController.__index = InputController

local DEFAULT_TOUCH_BUTTON_IMAGES = {
	Shoot = {
		Up = "rbxassetid://138709858109425",
		Down = "rbxassetid://120562342792348",
	},
	Split = {
		Up = "rbxassetid://113043524762022",
		Down = "rbxassetid://88597800137043",
	},
}

local DEFAULT_TOUCH_BUTTON_POSITIONS = {
	Shoot = UDim2.new(0.805, 0, 0.738, 0),
	Split = UDim2.new(0.863, 0, 0.513, 0),
}

local inputConfig = Config.Input or {}
local TOUCH_BUTTON_IMAGES = inputConfig.TouchButtonImages or DEFAULT_TOUCH_BUTTON_IMAGES
local TOUCH_BUTTON_POSITIONS = inputConfig.TouchButtonPositions or DEFAULT_TOUCH_BUTTON_POSITIONS

local function setTouchButtonPressed(button: ImageButton, pressed: boolean)
	button.Image = if pressed then button:GetAttribute("DownImage") else button:GetAttribute("UpImage")
end

local function makeTouchButton(parent: Instance, name: string, images)
	local button = Instance.new("ImageButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(0, 0)
	button.AutoButtonColor = true
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Image = images.Up
	button.ImageTransparency = 0
	button.ScaleType = Enum.ScaleType.Fit
	button:SetAttribute("UpImage", images.Up)
	button:SetAttribute("DownImage", images.Down)
	button.Visible = false
	button.ZIndex = 50
	button.Parent = parent

	return button
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

local function makeJoystickPart(parent: Instance, name: string, size: number, color: Color3, transparency: number)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(size, size)
	frame.Visible = false
	frame.ZIndex = 45
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.35
	stroke.Thickness = 2
	stroke.Parent = frame

	return frame
end

local function aimToViewportEdge(aim: Vector2, viewport: Vector2): Vector2
	local unit = if aim.Magnitude > 0.001 then aim.Unit else Vector2.new(1, 0)
	local half = viewport * 0.5
	local margin = 12
	local maxX = math.max(half.X - margin, 1)
	local maxY = math.max(half.Y - margin, 1)
	local scaleX = if math.abs(unit.X) > 0.001 then maxX / math.abs(unit.X) else math.huge
	local scaleY = if math.abs(unit.Y) > 0.001 then maxY / math.abs(unit.Y) else math.huge
	return half + unit * math.min(scaleX, scaleY)
end

function InputController.new(remote: RemoteEvent, camera, renderer)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "Agar2DTouchControls"
	configureFullscreenGui(gui)
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Parent = playerGui

	local shootButton = makeTouchButton(gui, "Shoot", TOUCH_BUTTON_IMAGES.Shoot)
	local splitButton = makeTouchButton(gui, "Split", TOUCH_BUTTON_IMAGES.Split)
	local joystickBase = makeJoystickPart(gui, "JoystickBase", 128, Color3.fromRGB(20, 26, 34), 0.55)
	local joystickThumb = makeJoystickPart(gui, "JoystickThumb", 58, Color3.fromRGB(245, 248, 255), 0.2)

	local self = setmetatable({
		remote = remote,
		camera = camera,
		renderer = renderer,
		gui = gui,
		shootButton = shootButton,
		splitButton = splitButton,
		joystickBase = joystickBase,
		joystickThumb = joystickThumb,
		joystickRadius = 64,
		splitToken = 0,
		ejectToken = 0,
		-- Extra split modes and freeze — see Config.Cell / Config.Freeze.
		doubleSplitToken = 0,
		tripleSplitToken = 0,
		freezeToken = 0,
		-- Cannibalize is now AUTOMATIC (server-side): bigger own-cells
		-- eat smaller ones on contact once the smaller is >=2s old and
		-- the eater is >=2x its mass. No keybind. This field is kept
		-- so the `cn` payload key stays a stable no-op for the server.
		cannibalHeld = false,
		-- Last-sent counters so InputController.update() can detect
		-- action-token changes and skip the InputHz throttle for them.
		lastSentSplitToken = 0,
		lastSentEjectToken = 0,
		lastSentDoubleSplitToken = 0,
		lastSentTripleSplitToken = 0,
		lastSentFreezeToken = 0,
		-- Client-side mirror of server freeze state for renderer prediction.
		localFrozen = false,
		lastFreezePressAt = 0,
		ejectHeld = false,
		ejectAccumulator = 0,
		sendAccumulator = 0,
		lastTarget = camera.center,
		lastAim = Vector2.new(1, 0),
		moveTouchInput = nil,
		joystickStart = nil,
		joystickPosition = nil,
		joystickVector = Vector2.zero,
		joystickTargetVector = Vector2.zero,
		lastPinchScale = nil,
		lastTouchLayoutEnabled = nil,
		lastTouchLayoutViewport = nil,
	}, InputController)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Touch then
			self:_beginMoveTouch(input)
			return
		end

		if processed then
			return
		end

		if input.KeyCode == Enum.KeyCode.Space then
			self.splitToken += 1
		elseif input.KeyCode == Enum.KeyCode.W then
			self.ejectHeld = true
			self.ejectAccumulator = 0
			self.ejectToken += 1
			self:_predictEject()
		elseif input.KeyCode == Enum.KeyCode.Q then
			-- Double split. Server runs _splitPlayer twice.
			self.doubleSplitToken += 1
		elseif input.KeyCode == Enum.KeyCode.E then
			-- Triple split. Server runs _splitPlayer three times.
			self.tripleSplitToken += 1
		elseif input.KeyCode == Enum.KeyCode.F then
			-- Freeze toggle (Config.Freeze). Mirror the toggle locally so
			-- the renderer immediately stops predicting movement toward
			-- the cursor — otherwise cells visibly drift for one round
			-- trip before authoritative snapshots hold them in place.
			local now = os.clock()
			local debounce = (Config.Freeze and Config.Freeze.Debounce) or 0.15
			if now - (self.lastFreezePressAt or 0) >= debounce then
				self.lastFreezePressAt = now
				self.freezeToken += 1
				self.localFrozen = not self.localFrozen
				if self.renderer and self.renderer.setLocalFrozen then
					self.renderer:setLocalFrozen(self.localFrozen)
				end
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.W then
			self.ejectHeld = false
			self.ejectAccumulator = 0
		elseif input.UserInputType == Enum.UserInputType.Touch and self.moveTouchInput == input then
			self:_endMoveTouch()
		end
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		self:_cancelTouches()
	end)

	UserInputService.InputChanged:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Touch and self.moveTouchInput == input then
			self:_updateMoveTouch(input)
			return
		end

		if processed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseWheel then
			if input.Position.Z > 0 then
				self.camera:zoomIn()
			elseif input.Position.Z < 0 then
				self.camera:zoomOut()
			end
		end
	end)

	UserInputService.TouchPinch:Connect(function(_, scale, _, state)
		if state == Enum.UserInputState.Begin then
			self.lastPinchScale = scale
		elseif state == Enum.UserInputState.Change and self.lastPinchScale and self.lastPinchScale > 0 then
			self.camera:adjustZoom(scale / self.lastPinchScale)
			self.lastPinchScale = scale
		else
			self.lastPinchScale = nil
		end
	end)

	shootButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			setTouchButtonPressed(shootButton, true)
			self.ejectHeld = true
			self.ejectAccumulator = 0
			self.ejectToken += 1
			self:_predictEject()
		end
	end)

	shootButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			setTouchButtonPressed(shootButton, false)
			self.ejectHeld = false
			self.ejectAccumulator = 0
		end
	end)

	splitButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			setTouchButtonPressed(splitButton, true)
		end
	end)

	splitButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			setTouchButtonPressed(splitButton, false)
		end
	end)

	splitButton.Activated:Connect(function()
		self.splitToken += 1
	end)

	return self
end

function InputController:_inputScreenPosition(input): Vector2
	return Vector2.new(input.Position.X, input.Position.Y)
end

function InputController:_pointerScreenPosition(): Vector2
	local mouse = UserInputService:GetMouseLocation()
	return Vector2.new(mouse.X, mouse.Y)
end

function InputController:_shouldUseMoveTouch(input): boolean
	if self.moveTouchInput then
		return false
	end

	local pos = self:_inputScreenPosition(input)
	local viewport = self.camera.viewport
	return pos.X <= viewport.X * 0.58 and pos.Y >= viewport.Y * 0.22
end

function InputController:_beginMoveTouch(input)
	if not self:_shouldUseMoveTouch(input) then
		return
	end

	local pos = self:_inputScreenPosition(input)
	self.moveTouchInput = input
	self.joystickStart = pos
	self.joystickPosition = pos
	self.joystickVector = Vector2.zero
	self.joystickTargetVector = Vector2.zero
	self.joystickBase.Visible = true
	self.joystickThumb.Visible = true
	self:_layoutJoystick()
end

function InputController:_updateMoveTouch(input)
	if not self.joystickStart then
		return
	end

	local pos = self:_inputScreenPosition(input)
	local delta = pos - self.joystickStart
	local radius = math.max(self.joystickRadius, 1)
	local clampedDelta = if delta.Magnitude > radius then delta.Unit * radius else delta
	self.joystickPosition = self.joystickStart + clampedDelta
	self.joystickTargetVector = clampedDelta / radius
	self:_layoutJoystick()
end

function InputController:_endMoveTouch()
	self.moveTouchInput = nil
	self.joystickStart = nil
	self.joystickPosition = nil
	self.joystickVector = Vector2.zero
	self.joystickTargetVector = Vector2.zero
	self.joystickBase.Visible = false
	self.joystickThumb.Visible = false
end

function InputController:_cancelTouches()
	self:_endMoveTouch()
	self.ejectHeld = false
	self.ejectAccumulator = 0
	setTouchButtonPressed(self.shootButton, false)
	setTouchButtonPressed(self.splitButton, false)
end

function InputController:_layoutTouchButtons()
	local touchOnly = UserInputService.TouchEnabled
	local viewport = self.camera.viewport
	local layoutChanged = self.lastTouchLayoutEnabled ~= touchOnly
	if touchOnly then
		layoutChanged = layoutChanged
			or not self.lastTouchLayoutViewport
			or (self.lastTouchLayoutViewport - viewport).Magnitude >= 1
	end
	if not layoutChanged then
		return
	end

	self.lastTouchLayoutEnabled = touchOnly
	self.lastTouchLayoutViewport = viewport
	self.shootButton.Visible = touchOnly
	self.splitButton.Visible = touchOnly

	if not touchOnly then
		return
	end

	local size = 70
	self.joystickRadius = math.clamp(math.min(viewport.X, viewport.Y) * 0.105, 48, 78)

	self.shootButton.Size = UDim2.fromOffset(size, size)
	self.splitButton.Size = UDim2.fromOffset(size, size)
	self.joystickBase.Size = UDim2.fromOffset(self.joystickRadius * 2, self.joystickRadius * 2)
	self.joystickThumb.Size = UDim2.fromOffset(self.joystickRadius * 0.9, self.joystickRadius * 0.9)

	self.shootButton.Position = TOUCH_BUTTON_POSITIONS.Shoot
	self.splitButton.Position = TOUCH_BUTTON_POSITIONS.Split

	self:_layoutJoystick()
end

function InputController:_layoutJoystick()
	if not self.joystickStart or not self.joystickPosition then
		return
	end

	self.joystickBase.Position = UDim2.fromOffset(self.joystickStart.X, self.joystickStart.Y)
	self.joystickThumb.Position = UDim2.fromOffset(self.joystickPosition.X, self.joystickPosition.Y)
end

function InputController:_predictEject()
	if self.renderer and self.renderer.predictEject then
		local aim = self.lastAim
		local target = nil
		if UserInputService.TouchEnabled and self.joystickVector.Magnitude > 0.001 then
			aim = self.joystickVector.Unit
			self.lastAim = aim
		elseif not UserInputService.TouchEnabled then
			target = self.camera:screenToWorld(self:_pointerScreenPosition())
			local delta = target - self.camera.center
			if delta.Magnitude > 0.001 then
				aim = delta.Unit
				self.lastAim = aim
			end
		end
		self.renderer:predictEject(aim, target)
	end
end

function InputController:_smoothJoystickVector(dt: number)
	if not UserInputService.TouchEnabled then
		return
	end

	local target = self.joystickTargetVector or Vector2.zero
	if not self.moveTouchInput then
		self.joystickVector = Vector2.zero
		self.joystickTargetVector = Vector2.zero
		return
	end

	local alpha = 1 - math.exp(-dt * (Config.Render.MobileJoystickSmoothingSharpness or 32))
	self.joystickVector = self.joystickVector:Lerp(target, alpha)
	if self.joystickVector.Magnitude < 0.001 then
		self.joystickVector = Vector2.zero
	end
end

function InputController:_currentMoveCommand()
	local target
	local aim
	if UserInputService.TouchEnabled then
		local move = self.joystickVector
		if move.Magnitude > 0.001 then
			aim = move.Unit
			self.lastAim = aim
			target = self.camera:screenToWorld(aimToViewportEdge(aim, self.camera.viewport))
		else
			aim = self.lastAim
			target = self.camera.center
		end
	else
		local pointer = self:_pointerScreenPosition()
		target = self.camera:screenToWorld(pointer)
		aim = target - self.camera.center
		if aim.Magnitude > 0.001 then
			aim = aim.Unit
			self.lastAim = aim
		else
			aim = self.lastAim
		end
	end
	self.lastTarget = target
	return target, aim
end

function InputController:step(dt: number)
	self:_layoutTouchButtons()
	self:_smoothJoystickVector(dt)

	if self.ejectHeld then
		self.ejectAccumulator += dt
		local ejectInterval = 1 / Config.Ejected.FireHz
		local emitted = 0
		while self.ejectAccumulator >= ejectInterval and emitted < Config.Ejected.MaxEjectsPerStep do
			self.ejectAccumulator -= ejectInterval
			self.ejectToken += 1
			self:_predictEject()
			emitted += 1
		end
	end

	local target, aim = self:_currentMoveCommand()
	if self.renderer and self.renderer.setLocalMoveCommand then
		self.renderer:setLocalMoveCommand(target, aim)
	end

	-- Force an immediate send when any discrete-action token changes
	-- (split / eject / double / triple / freeze) so those actions don't
	-- eat up to 1/InputHz seconds of aim-driven drift before the server
	-- sees them. Without this, pressing F would still let cells slide
	-- toward the mouse for a full input-tick before the freeze applies.
	local actionDirty = self.splitToken ~= self.lastSentSplitToken
		or self.ejectToken ~= self.lastSentEjectToken
		or self.doubleSplitToken ~= self.lastSentDoubleSplitToken
		or self.tripleSplitToken ~= self.lastSentTripleSplitToken
		or self.freezeToken ~= self.lastSentFreezeToken

	self.sendAccumulator += dt
	if not actionDirty and self.sendAccumulator < 1 / Config.Network.InputHz then
		return
	end
	self.sendAccumulator = 0

	self.lastSentSplitToken = self.splitToken
	self.lastSentEjectToken = self.ejectToken
	self.lastSentDoubleSplitToken = self.doubleSplitToken
	self.lastSentTripleSplitToken = self.tripleSplitToken
	self.lastSentFreezeToken = self.freezeToken

	self.remote:FireServer({
		ax = aim.X,
		ay = aim.Y,
		tx = target.X,
		ty = target.Y,
		vw = self.camera.viewport.X,
		vh = self.camera.viewport.Y,
		zm = self.camera.zoom,
		sp = self.splitToken,
		ej = self.ejectToken,
		-- Extra abilities. Server ignores fields it doesn't know about,
		-- so this stays backward-compatible with older server versions.
		d2 = self.doubleSplitToken,
		d3 = self.tripleSplitToken,
		fz = self.freezeToken,
		cn = if self.cannibalHeld then 1 else 0,
	})
end

return InputController
